\set ON_ERROR_STOP on
\ir _helpers.sql
begin;
\echo == 05 time zones: a budget month ends at midnight on the market clock
\o /dev/null
insert into public.clients (id, name) values ('00000000-0000-0000-0000-0000000005a0', 'Zone Client');
insert into public.service_types (id, code, name) values ('00000000-0000-0000-0000-0000000005c1', 'roofing', 'Roofing');
insert into public.contractors (id, name) values ('00000000-0000-0000-0000-0000000005d1', 'Pro');

select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Mars', 'Mars/Olympus_Mons')$$, '23503', 'an unknown zone name is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Abbrev', 'EST')$$, '23503', 'an abbreviation (EST) is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Posix', 'EST5EDT')$$, '23503', 'a POSIX string (EST5EDT) is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Offset', '+05')$$, '23503', 'a bare offset (+05) is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Empty', '')$$, '23503', 'an empty zone is refused');
select pg_temp.expect($$insert into public.markets (client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005a0', 'Case', 'america/new_york')$$, '23503', 'a wrongly cased zone name is refused');

insert into public.markets (id, client_id, name, timezone) values
  ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-0000000005a0', 'New York', 'America/New_York'),
  ('00000000-0000-0000-0000-0000000005b2', '00000000-0000-0000-0000-0000000005a0', 'Auckland', 'Pacific/Auckland'),
  ('00000000-0000-0000-0000-0000000005b3', '00000000-0000-0000-0000-0000000005a0', 'Utc', 'UTC');
select pg_temp.expect($$update public.markets set timezone = 'Nowhere/City' where id = '00000000-0000-0000-0000-0000000005b1'$$, '23503', 'changing a zone to a bad one is refused too');

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

-- ------------------------------------------------------------ the zone is fixed once it has decided a month
insert into public.markets (id, client_id, name, timezone) values
  ('00000000-0000-0000-0000-0000000005b9', '00000000-0000-0000-0000-0000000005a0', 'Fresh', 'America/New_York'),
  ('00000000-0000-0000-0000-0000000005b8', '00000000-0000-0000-0000-0000000005a0', 'Leads only', 'America/New_York');
update public.markets set timezone = 'America/Chicago' where id = '00000000-0000-0000-0000-0000000005b9';
select pg_temp.ok((select timezone from public.markets where id = '00000000-0000-0000-0000-0000000005b9') = 'America/Chicago', 'a market with no budgets or leads can still have its zone corrected');
select pg_temp.expect_msg($$update public.markets set timezone = 'America/Chicago' where id = '00000000-0000-0000-0000-0000000005b1'$$, '%time zone cannot change%', 'a market that has budgets cannot change zone (it would move leads between months)');
insert into public.leads (market_id, service_type_id, source_system, source_id, received_at) values ('00000000-0000-0000-0000-0000000005b8', '00000000-0000-0000-0000-0000000005c1', 'tz', 'lo-1', now());
select pg_temp.expect_msg($$update public.markets set timezone = 'America/Chicago' where id = '00000000-0000-0000-0000-0000000005b8'$$, '%time zone cannot change%', 'a market that has only leads cannot change zone either');

-- ------------------------------------------------------------ midnight that happens twice (Havana, 1 Nov 2026)
-- Cuba puts its clocks back at 01:00 on 1 Nov, so local 00:00-01:00 occurs twice. at time zone picks the LATER midnight; the month starts at the earlier one.
insert into public.markets (id, client_id, name, timezone) values ('00000000-0000-0000-0000-0000000005b4', '00000000-0000-0000-0000-0000000005a0', 'Havana', 'America/Havana');
insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values
  ('00000000-0000-0000-0000-0000000005b4', '00000000-0000-0000-0000-0000000005c1', '2026-10-01', 100000),
  ('00000000-0000-0000-0000-0000000005b4', '00000000-0000-0000-0000-0000000005c1', '2026-11-01', 100000);
insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at)
select gen_random_uuid(), '00000000-0000-0000-0000-0000000005b4', '00000000-0000-0000-0000-0000000005c1', 'tz', v.label, v.at
from (values ('hv-oct',  timestamptz '2026-11-01 03:59:59+00'),   -- 23:59:59 on 31 Oct (UTC-4)
             ('hv-nov1', timestamptz '2026-11-01 04:30:00+00'),   -- 00:30 on 1 Nov, first pass through the midnight hour (UTC-4)
             ('hv-nov2', timestamptz '2026-11-01 05:30:00+00')) v(label, at);  -- 00:30 on 1 Nov, second pass (UTC-5)
insert into public.lead_deliveries (lead_id, contractor_id, delivered_at, price_cents)
select id, '00000000-0000-0000-0000-0000000005d1', received_at, 1000 from public.leads where source_id like 'hv-%';
select pg_temp.ok(pg_temp.spent('00000000-0000-0000-0000-0000000005b4', '2026-10-01') = 1000 and pg_temp.spent('00000000-0000-0000-0000-0000000005b4', '2026-11-01') = 2000,
                  'Havana: the lead at 00:30 on the first pass through a repeated midnight counts in November, not October');
select pg_temp.ok(private.local_month_start('2026-11-01', 'America/Havana') = timestamptz '2026-11-01 04:00+00'
              and (date '2026-11-01'::timestamp at time zone 'America/Havana') = timestamptz '2026-11-01 05:00+00',
                  'the plain conversion gives the LATER midnight (05:00 UTC); the month starts at the earlier one (04:00 UTC)');
select pg_temp.ok(private.local_month_start('2026-02-01', 'Pacific/Auckland') = timestamptz '2026-01-31 11:00+00', 'an ordinary zone is untouched by the repeated-midnight rule');

-- ------------------------------------------------------------ who can use the view
set local role service_role;
select pg_temp.ok((select count(*) from public.budget_vs_spend) >= 6, 'service_role can read budget_vs_spend (the function behind it is granted)');
reset role;
set local role authenticated;
select pg_temp.ok((select count(*) from public.budget_vs_spend) = 0, 'authenticated can query it and, with no membership, sees no rows');
reset role;
set local role anon;
select pg_temp.expect($$select * from public.budget_vs_spend$$, '42501', 'anon cannot read it');
reset role;
rollback;
