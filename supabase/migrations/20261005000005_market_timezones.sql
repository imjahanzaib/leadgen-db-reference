-- P0-1: a budget month is a month on the MARKET's clock, not the server's.
-- Before this migration budget_vs_spend cut months at server (UTC) midnight, so a lead received at 00:01 on 1 Feb in
-- Auckland (11:01 UTC on 31 Jan) was charged to January's budget. And markets.timezone was free text.

begin;
set local lock_timeout = '5s';   -- give up instead of queueing behind a long transaction (and everything behind it)

-- 1. Only real IANA zone names are accepted: a reference table and a foreign key, like every other link in this schema.
--    The list is copied once from the server's own tz database. Abbreviations ('EST') and POSIX strings ('EST5EDT', '+05')
--    are left out on purpose: they do not follow a place's daylight-saving rules, and Postgres accepts them silently.
--    (A trigger calling pg_timezone_names worked too, but that view costs about 25 ms a call; a primary-key lookup is free.)
--    When the tz database gains a zone: insert it here (insert ... on conflict do nothing).
create table private.iana_timezones (name text primary key);
alter table private.iana_timezones enable row level security;
revoke all on private.iana_timezones from public, anon, authenticated, service_role;
insert into private.iana_timezones (name)
  select name from pg_catalog.pg_timezone_names
  where (name ~ '^[A-Z][A-Za-z_+-]*/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?$' or name = 'UTC') and name !~ '^(posix|right)/';

do $$ declare bad text; begin
  select string_agg(distinct m.timezone, ', ') into bad from public.markets m
  where not exists (select 1 from private.iana_timezones z where z.name = m.timezone);
  if bad is not null then
    raise exception 'markets.timezone holds values that are not IANA zone names (%). Fix them, then re-run.', bad;
  end if;
end $$;

alter table public.markets add constraint markets_timezone_fkey
  foreign key (timezone) references private.iana_timezones (name) on update cascade on delete restrict;

-- 2. A market's zone decides which month a lead belongs to, so it cannot change once the market has budgets or leads:
--    the change would silently move leads between months and re-cut history. Security definer: it must see every row.
create function private.guard_market_timezone_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.timezone is distinct from old.timezone
     and (exists (select 1 from public.market_budgets where market_id = new.id)
          or exists (select 1 from public.leads where market_id = new.id)) then
    raise exception 'market % has budgets or leads: its time zone cannot change (it would move leads between months)', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
revoke all on function private.guard_market_timezone_change() from public, anon, authenticated, service_role;
create trigger markets_timezone_fixed before update of timezone on public.markets
  for each row execute function private.guard_market_timezone_change();

-- 3. The view cuts each month at local midnight in the market's zone. The bounds are timestamptz (not the lead's time
--    converted to local time), so the (market_id, received_at) index is still usable, and each bound is computed once per
--    budget row. Two clock oddities are handled:
--      * a local midnight that does not exist (spring-forward gap): at time zone gives the first instant after the gap;
--      * a local midnight that happens TWICE (clocks put back across midnight, e.g. Havana, Gaza): at time zone gives the
--        LATER instant, but the month starts at the EARLIER one, so step back while the local time is still on the 1st.
create function private.local_month_start(p_month date, p_tz text) returns timestamptz
language plpgsql stable set search_path = '' as $$
declare t timestamptz := p_month::timestamp at time zone p_tz; i int := 0;
begin
  while i < 4 and ((t - interval '30 minutes') at time zone p_tz) >= p_month::timestamp loop
    t := t - interval '30 minutes'; i := i + 1;
  end loop;
  return t;
end $$;
revoke all on function private.local_month_start(date, text) from public, anon;
grant execute on function private.local_month_start(date, text) to authenticated, service_role;
grant usage on schema private to service_role;   -- the view below runs as the caller; this exposes no function that was not granted

create or replace view public.budget_vs_spend with (security_invoker = true) as
select b.market_id, b.service_type_id, b.budget_month, b.amount_cents as budget_cents,
       coalesce(sum(d.price_cents), 0)::bigint as delivered_cents,
       b.amount_cents - coalesce(sum(d.price_cents), 0) as remaining_cents
from public.market_budgets b
join public.markets m on m.id = b.market_id
cross join lateral (select private.local_month_start(b.budget_month, m.timezone) as lo,
                           private.local_month_start((b.budget_month + interval '1 month')::date, m.timezone) as hi) w
left join public.leads l
       on l.market_id = b.market_id and l.service_type_id = b.service_type_id
      and l.received_at >= w.lo and l.received_at < w.hi
left join public.lead_deliveries d on d.lead_id = l.id
group by b.id;

commit;
