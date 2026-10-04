\set ON_ERROR_STOP on
\ir _helpers.sql
begin;
\echo == 01 constraints: bad data is refused by the database, not by the app
\o /dev/null
insert into public.clients (id, name) values ('00000000-0000-0000-0000-00000000000a', 'Alpha Roofing'), ('00000000-0000-0000-0000-00000000000b', 'Beta Paint');
insert into public.markets (id, client_id, name) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'Dallas'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000b', 'Denver');
insert into public.service_types (id, code, name) values ('00000000-0000-0000-0000-0000000000c1', 'roofing', 'Roofing');
insert into public.contractors (id, name) values ('00000000-0000-0000-0000-0000000000d1', 'Pro A');
insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c1', 'form', 'F-1', '2026-01-05 10:00+00'),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000c1', 'form', 'F-2', '2026-01-06 10:00+00');
insert into public.lead_deliveries (id, lead_id, contractor_id, delivered_at, price_cents) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1', '2026-01-05 10:05+00', 4000),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000d1', '2026-01-06 10:05+00', 5500);
insert into public.invoices (id, client_id, period_start, period_end) values ('00000000-0000-0000-0000-000000000a11', '00000000-0000-0000-0000-00000000000a', '2026-01-01', '2026-01-31');
insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('00000000-0000-0000-0000-000000000a11', '00000000-0000-0000-0000-0000000000f1');
insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c1', '2026-01-01', 100000);

select pg_temp.expect($$insert into public.clients (name) values ('  alpha   ROOFING ')$$, '23505', 'same client under another spelling is refused');
select pg_temp.expect($$insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000c1','2026-01-01',5)$$, '23505', 'one budget per market, service and month');
select pg_temp.expect($$insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000c1','2026-02-15',5)$$, '23514', 'budget month must be the first of a month');
select pg_temp.expect($$insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000c1','2026-03-01',-1)$$, '23514', 'a budget cannot be negative');
select pg_temp.expect($$insert into public.leads (market_id, service_type_id, source_system, source_id, received_at) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000c1','form','F-1', now())$$, '23505', 'the same outside lead id cannot load twice');
select pg_temp.expect($$insert into public.lead_deliveries (lead_id, contractor_id, delivered_at, price_cents) values ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000d1', now(), 1)$$, '23505', 'a lead goes to a contractor once');
select pg_temp.expect($$insert into public.markets (client_id, name) values ('99999999-9999-9999-9999-999999999999', 'Ghost')$$, '23503', 'a market must point at a real client');
select pg_temp.expect($$insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('00000000-0000-0000-0000-000000000a11','00000000-0000-0000-0000-0000000000f1')$$, '23505', 'a delivery is billed once');
select pg_temp.expect($$insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('00000000-0000-0000-0000-000000000a11','00000000-0000-0000-0000-0000000000f2')$$, '23514', 'an invoice cannot bill another client''s delivery');
select pg_temp.expect($$update public.lead_deliveries set price_cents = 1 where id = '00000000-0000-0000-0000-0000000000f1'$$, '23514', 'a billed delivery keeps its price');
update public.lead_deliveries set price_cents = 4100 where id = '00000000-0000-0000-0000-0000000000f2';
select pg_temp.ok((select total_cents from public.invoice_totals where invoice_id = '00000000-0000-0000-0000-000000000a11') = 4000, 'invoice total is computed from the details (4000), never stored');
select pg_temp.ok((select delivered_cents from public.budget_vs_spend where market_id = '00000000-0000-0000-0000-0000000000a1') = 4000, 'budget vs spend is a view over the deliveries');
select pg_temp.ok((select count(*) from audit.log where table_name = 'clients' and op = 'INSERT') = 2, 'the audit log recorded both client inserts');
select pg_temp.ok((select count(*) from audit.log where table_name = 'invoice_lines') = 1, 'the audit log recorded the invoice line');
rollback;
