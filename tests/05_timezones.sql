\set ON_ERROR_STOP on
\ir _helpers.sql
begin;
\echo == 05 time zones: a budget month ends at midnight on the market clock
\o /dev/null
insert into public.clients (id, name) values ('00000000-0000-0000-0000-0000000005a0', 'Zone Client');
insert into public.service_types (id, code, name) values ('00000000-0000-0000-0000-0000000005c1', 'roofing', 'Roofing');
insert into public.contractors (id, name) values ('00000000-0000-0000-0000-0000000005d1', 'Pro');

select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Mars', 'Mars/Olympus_Mons')$$, '23514', 'an unknown zone name is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Abbrev', 'EST')$$, '23514', 'an abbreviation (EST) is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Posix', 'EST5EDT')$$, '23514', 'a POSIX string (EST5EDT) is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Offset', '+05')$$, '23514', 'a bare offset (+05) is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Empty', '')$$, '23514', 'an empty zone is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Case', 'america/new_york')$$, '23514', 'a wrongly cased zone name is refused');

insert into public.markets (id, client_id, name, timezone) values
  ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-0000000005a0', 'New York', 'America/New_York'),
  ('00000000-0000-0000-0000-0000000005b2', '00000000-0000-0000-0000-0000000005a0', 'Auckland', 'Pacific/Auckland'),
  ('00000000-0000-0000-0000-0000000005b3', '00000000-0000-0000-0000-0000000005a0', 'Utc', 'UTC');
select pg_temp.expect($$update public.markets set timezone = 'Nowhere/City' where id = '00000000-0000-0000-0000-0000000005b1'$$, '23514', 'changing a zone to a bad one is refused too');

insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents)
select m, '00000000-0000-0000-0000-0000000005c1', mo, 100000
from unnest(array['00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-0000000005b2', '00000000-0000-0000-0000-0000000005b3']::uuid[]) m,
     unnest(array[date '2026-01-01', date '2026-02-01']) mo;

-- Each market gets leads one minute either side of local midnight on 31 Jan -> 1 Feb. Each lead is worth 1000 cents.
-- New York is UTC-5 in winter; Auckland is UTC+13 (summer time); UTC is the control.
insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at)
select gen_random_uuid(), v.m, '00000000-0000-0000-0000-0000000005c1', 'tz', v.label, v.at
from (values
  ('00000000-0000-0000-0000-0000000005b1'::uuid, 'ny-before', timestamptz '2026-01-31 23:59 America/New_York'),
  ('00000000-0000-0000-0000-0000000005b1'::uuid, 'ny-after',  timestamptz '2026-02-01 00:01 America/New_York'),
  ('00000000-0000-0000-0000-0000000005b2'::uuid, 'nz-before', timestamptz '2026-01-31 23:59 Pacific/Auckland'),
  ('00000000-0000-0000-0000-0000000005b2'::uuid, 'nz-after',  timestamptz '2026-02-01 00:01 Pacific/Auckland'),
  ('00000000-0000-0000-0000-0000000005b3'::uuid, 'utc-before', timestamptz '2026-01-31 23:59 UTC'),
  ('00000000-0000-0000-0000-0000000005b3'::uuid, 'utc-after',  timestamptz '2026-02-01 00:01 UTC')) v(m, label, at);
insert into public.lead_deliveries (lead_id, contractor_id, delivered_at, price_cents)
select id, '00000000-0000-0000-0000-0000000005d1', received_at, 1000 from public.leads where source_system = 'tz';

create or replace function pg_temp.spent(p_market uuid, p_month date) returns bigint language sql as $$
  select delivered_cents from public.budget_vs_spend where market_id = p_market and budget_month = p_month
$$;
select pg_temp.ok(pg_temp.spent('00000000-0000-0000-0000-0000000005b1', '2026-01-01') = 1000 and pg_temp.spent('00000000-0000-0000-0000-0000000005b1', '2026-02-01') = 1000,
                  'New York: 23:59 on 31 Jan is January, 00:01 on 1 Feb is February (one lead each)');
select pg_temp.ok(pg_temp.spent('00000000-0000-0000-0000-0000000005b2', '2026-01-01') = 1000 and pg_temp.spent('00000000-0000-0000-0000-0000000005b2', '2026-02-01') = 1000,
                  'Auckland (UTC+13): 00:01 on 1 Feb local, still 31 Jan in UTC, is February (the old view charged it to January)');
select pg_temp.ok(pg_temp.spent('00000000-0000-0000-0000-0000000005b3', '2026-01-01') = 1000 and pg_temp.spent('00000000-0000-0000-0000-0000000005b3', '2026-02-01') = 1000,
                  'UTC control: unchanged behaviour');
-- the same instants, read the old way (server time), must differ for Auckland: proves the test can fail
select pg_temp.ok((select count(*) from public.leads l where l.market_id = '00000000-0000-0000-0000-0000000005b2' and l.received_at < timestamptz '2026-02-01 00:00 UTC') = 2,
                  'both Auckland leads fall in January by UTC, so the fixture does expose the old bug');

-- the bounds never overlap or leave a gap, even in a zone that changes its clock during the year
select pg_temp.ok((select count(*) from generate_series(date '2026-01-01', date '2026-12-01', interval '1 month') mo
                   where (mo::timestamp at time zone 'Pacific/Auckland') >= ((mo + interval '1 month') at time zone 'Pacific/Auckland')) = 0,
                  'month bounds in a DST zone are strictly increasing all year');
rollback;
