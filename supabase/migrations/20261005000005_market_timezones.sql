-- P0-1: a budget month is a month on the MARKET's clock, not the server's.
-- Before this migration budget_vs_spend cut months at server (UTC) midnight, so a lead received at 00:01 on 1 Feb in
-- Auckland (11:01 UTC on 31 Jan) was charged to January's budget. And markets.timezone was free text.

-- 1. Only real IANA zone names are accepted. A CHECK cannot query pg_timezone_names, so a trigger does it.
--    Abbreviations ('EST') and POSIX strings ('EST5EDT', '+05') are refused: they do not follow daylight saving rules
--    the way a place does, and Postgres accepts them silently.
begin;

create function private.is_iana_timezone(p_tz text) returns boolean
language sql stable set search_path = '' as $$
  select p_tz ~ '^([A-Za-z_]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?|UTC)$'
     and exists (select 1 from pg_catalog.pg_timezone_names n where n.name = p_tz)
$$;

do $$ declare bad text; begin
  select string_agg(distinct timezone, ', ') into bad from public.markets where not private.is_iana_timezone(timezone);
  if bad is not null then
    raise exception 'markets.timezone holds values that are not IANA zone names (%). Fix them, then re-run.', bad;
  end if;
end $$;

create function private.guard_market_timezone() returns trigger language plpgsql set search_path = '' as $$
begin
  if not private.is_iana_timezone(new.timezone) then
    raise exception 'timezone % is not an IANA zone name (use e.g. America/New_York)', new.timezone
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger markets_valid_timezone before insert or update of timezone on public.markets
  for each row execute function private.guard_market_timezone();

-- 2. The view cuts each month at local midnight in the market's zone. The bounds are converted to timestamptz
--    (not the lead's time to local time), so the (market_id, received_at) index is still usable.
--    Local midnight that does not exist (a spring-forward gap) resolves to the first instant after the gap.
create or replace view public.budget_vs_spend with (security_invoker = true) as
select b.market_id, b.service_type_id, b.budget_month, b.amount_cents as budget_cents,
       coalesce(sum(d.price_cents), 0)::bigint as delivered_cents,
       b.amount_cents - coalesce(sum(d.price_cents), 0) as remaining_cents
from public.market_budgets b
join public.markets m on m.id = b.market_id
left join public.leads l
       on l.market_id = b.market_id and l.service_type_id = b.service_type_id
      and l.received_at >= (b.budget_month::timestamp at time zone m.timezone)
      and l.received_at <  ((b.budget_month + interval '1 month') at time zone m.timezone)
left join public.lead_deliveries d on d.lead_id = l.id
group by b.id;

commit;
