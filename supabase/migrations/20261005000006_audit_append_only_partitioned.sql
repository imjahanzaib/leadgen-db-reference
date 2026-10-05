-- P0-3: the audit log becomes append-only, partitioned by month, bounded by a retention job, and records who did it.
-- Before this migration audit.log was a plain table: nothing stopped an UPDATE or DELETE, it grew without bound, and a row
-- did not say which API role, JWT or request produced it.
--
-- What this does NOT stop: the table owner (the postgres role) can still disable a trigger or drop the table.
-- The application only ever connects as anon / authenticated / service_role, none of which can. Evidence that must survive
-- the owner too has to leave the database (log shipping, pgaudit); see the README.

------------------------------------------------------------------ 1. swap the table (rows are kept, ids are kept)
begin;
set local lock_timeout = '5s';   -- give up instead of queueing behind a long transaction (and everything behind it)

lock table audit.log in access exclusive mode;
alter table audit.log rename to log_unpartitioned;
alter index audit.log_pkey rename to log_unpartitioned_pkey;
alter index audit.audit_log_row_idx rename to log_unpartitioned_row_idx;
alter sequence audit.log_id_seq rename to log_unpartitioned_id_seq;

create table audit.log (
  id             bigint generated always as identity,
  at             timestamptz not null default now(),
  txid           bigint default (pg_current_xact_id()::text::bigint),  -- every change of one request shares it
  actor          uuid,          -- auth.uid(): the signed-in user
  jwt_role       text,          -- role claim of the verified JWT (authenticated, service_role)
  session_role   text,          -- who is connected (authenticator via the API, postgres in the SQL editor)
  effective_role text,          -- the role in force after SET ROLE
  request_id     text,          -- x-request-id / sb-request-id header, if the caller or gateway sent one. A hint: a client can set it
  table_name     text not null,
  op             text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  row_id         text,
  old_row        jsonb,
  new_row        jsonb,
  primary key (id, at)          -- a primary key on a partitioned table must contain the partition key
) partition by range (at);
create index audit_log_row_idx on audit.log (table_name, row_id, at desc);
alter table audit.log enable row level security;   -- no policy: only the owner and service_role can reach it

create table audit.retention_log (   -- what the retention job dropped, and how much was in it
  id             bigint generated always as identity primary key,
  dropped_at     timestamptz not null default now(),
  partition_name text not null,
  rows_dropped   bigint not null,
  first_at       timestamptz,
  last_at        timestamptz,
  dropped_by     text not null default session_user
);
alter table audit.retention_log enable row level security;

------------------------------------------------------------------ 2. append-only
create function audit.deny_change() returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'audit.% is append-only: % is not allowed', tg_table_name, tg_op
    using errcode = 'insufficient_privilege', hint = 'Corrections are new rows, never edits.';
end $$;

-- Row triggers on a partitioned table are copied to every partition. TRUNCATE triggers are NOT, and TRUNCATE on a single
-- partition skips the parent's trigger (found by probing on Postgres 15), so every partition gets its own.
create trigger log_no_change   before update or delete on audit.log for each row       execute function audit.deny_change();
create trigger log_no_truncate before truncate         on audit.log for each statement execute function audit.deny_change();
create trigger retention_no_change   before update or delete on audit.retention_log for each row       execute function audit.deny_change();
create trigger retention_no_truncate before truncate         on audit.retention_log for each statement execute function audit.deny_change();

-- Privileges: nobody but the owner writes; service_role may read (admin tooling); app roles see nothing.
revoke all on audit.log, audit.retention_log from public, anon, authenticated, service_role;
revoke all on schema audit from public, anon, authenticated;
grant usage on schema audit to service_role;
grant select on audit.log, audit.retention_log to service_role;

create function audit.protect_partition(p_rel regclass) returns void language plpgsql set search_path = '' as $$
begin
  execute format('alter table %s enable row level security', p_rel);
  execute format('revoke all on %s from public, anon, authenticated, service_role', p_rel);
  if not exists (select 1 from pg_catalog.pg_trigger where tgrelid = p_rel and tgname = 'log_no_truncate') then
    execute format('create trigger log_no_truncate before truncate on %s for each statement execute function audit.deny_change()', p_rel);
  end if;
end $$;

------------------------------------------------------------------ 3. monthly partitions (UTC months)
-- A DEFAULT partition catches anything that has no partition yet, so a stalled maintenance job can never make a
-- business write fail. audit.partition_health shows when it is holding rows.
create table audit.log_default partition of audit.log default;
select audit.protect_partition('audit.log_default');

create function audit.utc_month(p_ts timestamptz default now()) returns date
language sql stable set search_path = '' as $$ select date_trunc('month', p_ts at time zone 'UTC')::date $$;

-- Creates the table first and attaches it afterwards. CREATE TABLE ... PARTITION OF takes ACCESS EXCLUSIVE on the parent and
-- stalled every audited write behind one open transaction for the whole lock timeout (measured: 4 s); ATTACH PARTITION takes
-- only SHARE UPDATE EXCLUSIVE, which ordinary inserts do not conflict with. Returns false when the month already exists.
create function audit.create_month_partition(p_month date) returns boolean
language plpgsql security definer set search_path = '' set lock_timeout = '5s' as $$
declare v_name text := format('log_%s', to_char(p_month, 'YYYY_MM'));
begin
  if to_regclass('audit.' || v_name) is not null then return false; end if;
  execute format('create table audit.%I (like audit.log including defaults including constraints including indexes)', v_name);
  execute format('alter table audit.log attach partition audit.%I for values from (%L) to (%L)', v_name,
                 to_char(p_month, 'YYYY-MM-DD') || ' 00:00:00+00', to_char(p_month + interval '1 month', 'YYYY-MM-DD') || ' 00:00:00+00');
  perform audit.protect_partition(format('audit.%I', v_name)::regclass);
  return true;
end $$;

-- Rows that landed in the default partition (the job was late) are moved into real partitions with DDL and INSERT
-- only: detach the default, create the months, insert the rows through the parent, drop the emptied table.
-- No UPDATE or DELETE is needed, so the append-only rule has no exception in it.
create function audit.repair_default_partition() returns int
language plpgsql security definer set search_path = '' set lock_timeout = '5s' as $$
declare m date; n_months int; n_rows bigint;
begin
  select count(distinct audit.utc_month(at)), count(*) into n_months, n_rows from audit.log_default;
  if n_rows = 0 then return 0; end if;
  if n_months > 60 then
    raise exception 'audit.log_default holds rows from % different months; look at them before moving them', n_months;
  end if;
  alter table audit.log detach partition audit.log_default;
  alter table audit.log_default rename to log_default_stranded;
  for m in select distinct audit.utc_month(at) from audit.log_default_stranded order by 1 loop
    perform audit.create_month_partition(m);
  end loop;
  insert into audit.log overriding system value
    select id, at, txid, actor, jwt_role, session_role, effective_role, request_id, table_name, op, row_id, old_row, new_row
    from audit.log_default_stranded;
  drop table audit.log_default_stranded;
  create table audit.log_default partition of audit.log default;
  perform audit.protect_partition('audit.log_default');
  return n_rows;
end $$;

-- Creates the partitions for [p_from, p_to] (months), skipping the ones that exist. Safe to run daily.
create function audit.ensure_partitions(
  p_from date default audit.utc_month(),
  p_to   date default (audit.utc_month() + interval '3 months')::date) returns int
language plpgsql security definer set search_path = '' set lock_timeout = '5s' as $$
declare m date; n int := 0; v_name text;
begin
  for m in select g::date from generate_series(date_trunc('month', p_from::timestamp), date_trunc('month', p_to::timestamp), interval '1 month') g loop
    v_name := format('log_%s', to_char(m, 'YYYY_MM'));
    continue when to_regclass('audit.' || v_name) is not null;
    if exists (select 1 from audit.log_default where at >= (m::timestamp at time zone 'UTC')
                                               and at <  ((m + interval '1 month') at time zone 'UTC')) then
      perform audit.repair_default_partition();     -- creates this month too
      if to_regclass('audit.' || v_name) is not null then n := n + 1; continue; end if;
    end if;
    perform audit.create_month_partition(m);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Retention: drop whole months older than p_keep_months, and write down what was dropped. The floor stops a typo
-- ("keep 1") from wiping the history. Archive a partition (pg_dump to storage) BEFORE this runs if you must keep it.
create function audit.drop_old_partitions(p_keep_months int default 24) returns int
language plpgsql security definer set search_path = '' set lock_timeout = '5s' as $$
declare r record; v_cut date; v_rows bigint; v_first timestamptz; v_last timestamptz; n int := 0;
begin
  if p_keep_months is null or p_keep_months < 12 then
    raise exception 'refusing to keep fewer than 12 months of audit history (asked for %)', p_keep_months;
  end if;
  v_cut := (audit.utc_month() - make_interval(months => p_keep_months))::date;
  for r in
    select c.relname from pg_catalog.pg_inherits i join pg_catalog.pg_class c on c.oid = i.inhrelid
    where i.inhparent = 'audit.log'::regclass and c.relname ~ '^log_[0-9]{4}_[0-9]{2}$'
      and to_date(substring(c.relname from 5), 'YYYY_MM') < v_cut
    order by c.relname
  loop
    execute format('select count(*), min(at), max(at) from audit.%I', r.relname) into v_rows, v_first, v_last;
    insert into audit.retention_log (partition_name, rows_dropped, first_at, last_at) values (r.relname, v_rows, v_first, v_last);
    execute format('drop table audit.%I', r.relname);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Cover the rows already there (history goes back to the oldest one) and the next three months.
select audit.ensure_partitions(coalesce((select audit.utc_month(min(at)) from audit.log_unpartitioned), audit.utc_month()));

------------------------------------------------------------------ 4. copy the old rows, keep their ids, drop the old table
-- txid is NULL on purpose: the column default would stamp these rows with THIS migration's transaction id, and the old
-- rows were never recorded with one. Context that was not captured stays empty rather than being invented.
insert into audit.log (id, at, txid, actor, table_name, op, row_id, old_row, new_row) overriding system value
  select id, at, null, actor, table_name, op, row_id, old_row, new_row from audit.log_unpartitioned;
select setval(pg_get_serial_sequence('audit.log', 'id'), coalesce(max(id), 0) + 1, false) from audit.log;
drop table audit.log_unpartitioned;

------------------------------------------------------------------ 5. who did it
-- A malformed setting must never break a business write, so unreadable JSON becomes NULL.
create function audit.setting_json(p_name text) returns jsonb language plpgsql stable set search_path = '' as $$
declare v text := nullif(current_setting(p_name, true), '');
begin
  if v is null then return null; end if;
  return v::jsonb;
exception when others then return null;
end $$;

create or replace function audit.log_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  j jsonb := to_jsonb(coalesce(new, old));
  v_claims  jsonb := audit.setting_json('request.jwt.claims');
  v_headers jsonb := audit.setting_json('request.headers');
begin
  insert into audit.log (actor, jwt_role, session_role, effective_role, request_id, table_name, op, row_id, old_row, new_row)
  values (auth.uid(), v_claims ->> 'role', session_user, nullif(current_setting('role', true), 'none'),
          left(coalesce(v_headers ->> 'x-request-id', v_headers ->> 'sb-request-id'), 200),
          tg_table_name, tg_op,
          coalesce(j ->> 'id', concat_ws(':', j ->> 'user_id', j ->> 'client_id')),
          case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

------------------------------------------------------------------ 6. operations
-- A view would bind to the default partition by OID and follow it when repair_default_partition() renames it,
-- so the count lives in a function that looks the name up each time.
create function audit.default_rows() returns bigint language plpgsql stable security definer set search_path = '' as $$
declare n bigint;
begin select count(*) into n from audit.log_default; return n; end $$;

create view audit.partition_health as
select audit.default_rows()                                                                         as default_rows,
       (select max(to_date(substring(c.relname from 5), 'YYYY_MM'))
          from pg_catalog.pg_inherits i join pg_catalog.pg_class c on c.oid = i.inhrelid
         where i.inhparent = 'audit.log'::regclass and c.relname ~ '^log_[0-9]{4}_[0-9]{2}$')       as newest_partition_month,
       (select count(*) from pg_catalog.pg_inherits where inhparent = 'audit.log'::regclass) - 1    as monthly_partitions;
grant select on audit.partition_health to service_role;

revoke all on function audit.deny_change(), audit.protect_partition(regclass), audit.utc_month(timestamptz),
  audit.repair_default_partition(), audit.ensure_partitions(date, date), audit.drop_old_partitions(int),
  audit.setting_json(text), audit.log_change(), audit.default_rows(), audit.create_month_partition(date) from public, anon, authenticated, service_role;

-- Scheduling needs pg_cron (Supabase: Database > Extensions). Creating partitions is harmless, so this migration schedules
-- that job when pg_cron is present. RETENTION DELETES history, so it is opt-in: after you have decided how long to keep the log
-- (and archived what must outlive it), run  select audit.schedule_maintenance(24);  to add the monthly drop. Without pg_cron,
-- run audit.ensure_partitions() daily (and audit.drop_old_partitions(n) monthly) from any scheduler.
create function audit.schedule_maintenance(p_retention_months int default null) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if p_retention_months is not null and p_retention_months < 12 then
    raise exception 'refusing to schedule retention below 12 months (asked for %)', p_retention_months;
  end if;
  if to_regprocedure('cron.schedule(text,text,text)') is null then
    raise notice 'pg_cron is not installed: schedule audit.ensure_partitions() daily yourself, then run audit.schedule_maintenance() once pg_cron is on';
    return false;
  end if;
  perform cron.schedule('audit-ensure-partitions', '15 3 * * *', 'select audit.ensure_partitions()');
  if p_retention_months is not null then
    perform cron.schedule('audit-drop-old-partitions', '30 3 1 * *', format('select audit.drop_old_partitions(%s)', p_retention_months));
  end if;
  return true;
end $$;
revoke all on function audit.schedule_maintenance(int) from public, anon, authenticated, service_role;
select audit.schedule_maintenance();

commit;
