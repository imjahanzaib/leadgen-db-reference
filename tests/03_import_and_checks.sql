\set ON_ERROR_STOP on
\ir _helpers.sql
begin;
\echo == 03 data move: prove nothing was lost or duplicated, and find the three kinds of bad data
\o /dev/null
\ir ../seed/legacy_seed.sql

select pg_temp.ok(legacy.import_budgets() = 8, 'import loaded 8 of 12 sheet rows');
select pg_temp.ok((select rows_in = 12 and rows_loaded = 8 and rows_rejected = 4 from legacy.import_report order by id desc limit 1), 'report: 12 in = 8 loaded + 4 rejected');
select pg_temp.ok((select cents_in = cents_loaded + cents_rejected from legacy.import_report order by id desc limit 1), 'report: money in = money loaded + money rejected, to the cent');
select pg_temp.ok((select array_agg(row_no order by row_no) from legacy.import_rejects) = array[6, 7, 8, 12], 'rejected exactly rows 6, 7, 8 and 12');
select pg_temp.ok((select count(*) from legacy.import_rejects where row_no = 6 and reason like 'duplicate%') = 1, 'row 6 rejected as a duplicate of row 5');

-- reconcile independently: the expected set is written out by hand from the spreadsheet, then compared both ways
with expected(client_key, market, service_code, month, cents) as (values
  ('acme roofing', 'Dallas', 'roofing', date '2026-01-01', 125000), ('acme roofing', 'Dallas', 'gutters', date '2026-01-01', 40000),
  ('acme roofing', 'Austin', 'roofing', date '2026-01-01', 98050), ('blue door paint', 'Denver', 'painting', date '2026-01-01', 210000),
  ('blue door paint', 'Denver', 'painting', date '2026-02-01', 230000), ('cedar hvac', 'Boise', 'hvac', date '2026-04-01', 100000),
  ('delta pools', 'Tampa', 'pool_care', date '2026-01-01', 30025), ('delta pools', 'Tampa', 'pool_care', date '2026-02-01', 30025)),
actual as (
  select c.name_key as client_key, m.name as market, st.code as service_code, b.budget_month as month, b.amount_cents::int as cents
  from public.market_budgets b join public.markets m on m.id = b.market_id join public.clients c on c.id = m.client_id
  join public.service_types st on st.id = b.service_type_id)
select pg_temp.ok(not exists (select * from expected except select * from actual) and not exists (select * from actual except select * from expected),
                  'loaded rows equal the hand-written expected rows, none missing, none extra');
select pg_temp.ok((select sum(amount_cents) from public.market_budgets) = 863100, 'money in the new tables = 863,100 cents, matching the sheet');
select pg_temp.ok((select count(*) from public.clients) = 4, 'three spellings of Acme became ONE client (4 clients in total)');

-- idempotent: running the import again changes nothing
select legacy.import_budgets();
select pg_temp.ok((select count(*) from public.market_budgets) = 8 and (select count(*) from public.clients) = 4, 'a second run adds no rows');

-- the three data checks
select pg_temp.ok((select count(*) from legacy.dup_clients) = 1 and (select spellings from legacy.dup_clients) = 3, 'check 1: one client appears under 3 spellings');
select pg_temp.ok((select array_agg(delivery_no order by delivery_no) from legacy.orphan_deliveries) = array[3, 5], 'check 2: deliveries 3 and 5 point at leads that do not exist');
select pg_temp.ok((select count(*) from legacy.total_mismatch) = 1 and (select difference_cents from legacy.total_mismatch where invoice_no = 'INV-2') = 4000, 'check 3: INV-2 stored total is 40.00 more than its lines');
rollback;
