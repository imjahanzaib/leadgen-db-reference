\set ON_ERROR_STOP on
\ir _helpers.sql
begin;
\echo == 02 row-level security: each user sees only their own client
\o /dev/null
-- fixtures, written as the table owner (RLS does not apply to the owner)
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'owner-a@example.test'),
  ('22222222-2222-2222-2222-222222222222', 'viewer-a@example.test'),
  ('33333333-3333-3333-3333-333333333333', 'owner-b@example.test');
insert into public.clients (id, name) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Client A'), ('bbbbbbbb-0000-0000-0000-000000000001', 'Client B');
insert into public.memberships (user_id, client_id, role) values
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'owner'),
  ('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000001', 'viewer'),
  ('33333333-3333-3333-3333-333333333333', 'bbbbbbbb-0000-0000-0000-000000000001', 'owner');
insert into public.markets (id, client_id, name) values
  ('aaaaaaaa-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 'A-Dallas'),
  ('bbbbbbbb-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000001', 'B-Denver');
insert into public.service_types (id, code, name) values ('cccccccc-0000-0000-0000-000000000001', 'roofing', 'Roofing');
insert into public.contractors (id, name) values ('dddddddd-0000-0000-0000-000000000001', 'Pro');
insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values
  ('aaaaaaaa-0000-0000-0000-0000000000a1', 'cccccccc-0000-0000-0000-000000000001', '2026-01-01', 1000),
  ('bbbbbbbb-0000-0000-0000-0000000000b1', 'cccccccc-0000-0000-0000-000000000001', '2026-01-01', 2000);
insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at) values
  ('eeeeeeee-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-0000000000a1', 'cccccccc-0000-0000-0000-000000000001', 's', '1', '2026-01-02+00'),
  ('eeeeeeee-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-0000000000b1', 'cccccccc-0000-0000-0000-000000000001', 's', '2', '2026-01-02+00');
insert into public.lead_deliveries (id, lead_id, contractor_id, delivered_at, price_cents) values
  ('ffffffff-0000-0000-0000-0000000000a1', 'eeeeeeee-0000-0000-0000-0000000000a1', 'dddddddd-0000-0000-0000-000000000001', '2026-01-02+00', 100),
  ('ffffffff-0000-0000-0000-0000000000b1', 'eeeeeeee-0000-0000-0000-0000000000b1', 'dddddddd-0000-0000-0000-000000000001', '2026-01-02+00', 200);
insert into public.invoices (id, client_id, period_start, period_end) values
  ('99999999-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', '2026-01-01', '2026-01-31'),
  ('99999999-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000001', '2026-01-01', '2026-01-31');
insert into public.invoice_lines (invoice_id, lead_delivery_id) values
  ('99999999-0000-0000-0000-0000000000a1', 'ffffffff-0000-0000-0000-0000000000a1'),
  ('99999999-0000-0000-0000-0000000000b1', 'ffffffff-0000-0000-0000-0000000000b1');

-- act as the owner of client A
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select pg_temp.ok((select count(*) from public.clients) = 1, 'owner A sees exactly 1 client');
select pg_temp.ok((select count(*) from public.markets where client_id <> 'aaaaaaaa-0000-0000-0000-000000000001') = 0, 'owner A sees no market of client B');
select pg_temp.ok((select count(*) from public.market_budgets) = 1 and (select count(*) from public.leads) = 1
                  and (select count(*) from public.lead_deliveries) = 1 and (select count(*) from public.invoices) = 1
                  and (select count(*) from public.invoice_lines) = 1, 'owner A sees only A in budgets, leads, deliveries, invoices, lines');
select pg_temp.ok((select count(*) from public.invoice_totals) = 1, 'the views obey RLS too (security_invoker)');
select pg_temp.ok((select count(*) from public.memberships) = 1, 'owner A sees only their own membership');
insert into public.markets (client_id, name) values ('aaaaaaaa-0000-0000-0000-000000000001', 'A-Austin');
select pg_temp.ok(true, 'owner A can add a market to client A');
select pg_temp.expect($$insert into public.markets (client_id, name) values ('bbbbbbbb-0000-0000-0000-000000000001', 'Sneaky')$$, '42501', 'owner A cannot add a market to client B');
select pg_temp.expect($$select * from audit.log$$, '42501', 'the audit log is not readable by app users');
select pg_temp.expect($$insert into public.leads (market_id, service_type_id, source_system, source_id, received_at) values ('aaaaaaaa-0000-0000-0000-0000000000a1','cccccccc-0000-0000-0000-000000000001','s','9', now())$$, '42501', 'leads are written by the service role only');
reset role;

-- viewer of client A: reads, cannot write
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select pg_temp.ok((select count(*) from public.markets) = 2, 'viewer A reads the markets of client A');
select pg_temp.expect($$insert into public.markets (client_id, name) values ('aaaaaaaa-0000-0000-0000-000000000001', 'ViewerAdd')$$, '42501', 'a viewer cannot add a market');
update public.markets set name = 'Hacked' where id = 'aaaaaaaa-0000-0000-0000-0000000000a1';
reset role;
select pg_temp.ok((select name from public.markets where id = 'aaaaaaaa-0000-0000-0000-0000000000a1') = 'A-Dallas', 'a viewer''s update changed nothing (0 rows allowed by policy)');

-- owner of client B
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
select pg_temp.ok((select count(*) from public.clients) = 1 and (select name from public.clients) = 'Client B', 'owner B sees only Client B');
select pg_temp.ok((select count(*) from public.markets) = 1, 'owner B sees only B''s market');
select pg_temp.ok((select count(*) from public.invoice_lines l join public.lead_deliveries d on d.id = l.lead_delivery_id where d.price_cents = 100) = 0, 'owner B cannot reach A''s delivery through the join');
reset role;

-- a signed-in user with no membership, and no login at all
set local role authenticated;
select set_config('request.jwt.claims', '', true);
select pg_temp.ok((select count(*) from public.clients) = 0, 'authenticated with no identity sees nothing');
reset role;
set local role anon;
select pg_temp.expect($$select * from public.clients$$, '42501', 'anon has no access to clients');
reset role;

-- service role bypasses RLS
set local role service_role;
select pg_temp.ok((select count(*) from public.clients) = 2, 'service role sees both clients (for the server side only)');
reset role;
rollback;
