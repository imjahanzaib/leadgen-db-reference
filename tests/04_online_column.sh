#!/usr/bin/env bash
# Add a required foreign-key column to a busy 500k-row table while a writer keeps inserting.
set -euo pipefail
DB="${1:-leadgen_demo}"; cd "$(dirname "$0")"
P="psql -d $DB -v ON_ERROR_STOP=1 -q"
echo "== 04 online migration: add a required FK column to a busy table without blocking writes"
$P <<'SQL'
insert into public.clients (id, name) values ('00000000-0000-0000-0000-0000000000aa', 'Bench Client') on conflict do nothing;
insert into public.markets (id, client_id, name) values ('00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000aa', 'Bench') on conflict do nothing;
insert into public.service_types (id, code, name) values ('00000000-0000-0000-0000-0000000000cc', 'bench', 'Bench') on conflict do nothing;
insert into public.leads (market_id, service_type_id, source_system, source_id, received_at)
select '00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000cc', 'bench', g::text,
       timestamptz '2026-01-01 00:00+00' + (g % 100000) * interval '1 minute'
from generate_series(1, 500000) g;
analyze public.leads;
create table public.writer_stats (max_ms numeric, inserts int, errors int);
SQL
echo "   loaded 500,000 leads"
# the writer: one committed insert every ~20 ms for 70 s, recording its worst latency
$P <<'SQL' &
do $$
declare t0 timestamptz; worst numeric := 0; n int := 0; errs int := 0; stop_at timestamptz := clock_timestamp() + interval '70 seconds';
begin
  while clock_timestamp() < stop_at loop
    t0 := clock_timestamp();
    begin
      insert into public.leads (market_id, service_type_id, source_system, source_id, received_at)
      values ('00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000cc', 'live', n::text || '-' || extract(epoch from t0)::text, now());
    exception when others then errs := errs + 1; end;
    commit;
    worst := greatest(worst, extract(epoch from clock_timestamp() - t0) * 1000);
    n := n + 1;
    perform pg_sleep(0.02);
  end loop;
  insert into public.writer_stats values (round(worst, 1), n, errs);
end $$;
SQL
WRITER=$!
sleep 3
echo "   writer running; migrating"
$P <<'SQL'
\timing on
set lock_timeout = '2s';
-- 1. the target table, one default campaign
create table public.campaigns (id uuid primary key default gen_random_uuid(), market_id uuid not null references public.markets (id), name text not null, created_at timestamptz not null default now());
insert into public.campaigns (market_id, name) values ('00000000-0000-0000-0000-0000000000bb', 'default');
-- 2. nullable column: metadata only, no table rewrite
alter table public.leads add column campaign_id uuid;
-- 3. new rows get filled by a trigger while the old ones are backfilled
create function private.fill_campaign() returns trigger language plpgsql as $f$
begin
  if new.campaign_id is null then
    new.campaign_id := (select id from public.campaigns where market_id = new.market_id order by created_at limit 1);
  end if;
  return new;
end $f$;
create trigger leads_fill_campaign before insert on public.leads for each row execute function private.fill_campaign();
SQL
# 4. backfill old rows in small committed batches (short row locks, no long transaction)
$P <<'SQL'
\timing on
do $$
declare n int;
begin
  loop
    update public.leads l set campaign_id = (select id from public.campaigns c where c.market_id = l.market_id order by created_at limit 1)
     where l.id in (select id from public.leads where campaign_id is null limit 50000);
    get diagnostics n = row_count;
    exit when n = 0;
    commit;
  end loop;
end $$;
SQL
$P <<'SQL'
\timing on
set lock_timeout = '2s';
-- 5. index without blocking writes
create index concurrently leads_campaign_idx on public.leads (campaign_id);
-- 6. foreign key: add NOT VALID (no scan), then VALIDATE (scan that does not block writes)
alter table public.leads add constraint leads_campaign_fk foreign key (campaign_id) references public.campaigns (id) not valid;
alter table public.leads validate constraint leads_campaign_fk;
-- 7. NOT NULL without a long lock: a validated CHECK lets SET NOT NULL skip the scan
alter table public.leads add constraint leads_campaign_nn check (campaign_id is not null) not valid;
alter table public.leads validate constraint leads_campaign_nn;
alter table public.leads alter column campaign_id set not null;
alter table public.leads drop constraint leads_campaign_nn;
SQL
wait $WRITER
$P <<'SQL'
\ir _helpers.sql
\o /dev/null
select pg_temp.ok((select count(*) from public.leads where campaign_id is null) = 0, 'every lead, old and live-written, has a campaign');
select pg_temp.ok((select convalidated from pg_constraint where conname = 'leads_campaign_fk'), 'the foreign key is validated');
select pg_temp.ok((select attnotnull from pg_attribute where attrelid = 'public.leads'::regclass and attname = 'campaign_id'), 'the column is now NOT NULL');
select pg_temp.ok((select errors from public.writer_stats) = 0, 'the live writer had zero errors during the whole migration');
\o
select max_ms as "worst_insert_ms_during_migration", inserts as "live inserts made" from public.writer_stats;
\o /dev/null
select pg_temp.ok((select max_ms from public.writer_stats) < 1500, 'the worst insert waited under 1.5 s');
SQL
