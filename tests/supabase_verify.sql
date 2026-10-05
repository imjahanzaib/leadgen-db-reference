-- Run this in the Supabase SQL editor (or psql) AFTER all seven migrations.
-- It changes nothing: every fixture is rolled back. It returns one row per check.
-- Real roles (anon, authenticated, service_role) and real auth.uid() are used, so this tests the actual security setup.

create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $fn$
begin execute p_sql; return 'ok'; exception when others then return sqlstate; end $fn$;

create or replace function pg_temp.rec(p_res jsonb, p_check text, p_ok boolean, p_detail text) returns jsonb
language sql as $fn$ select p_res || jsonb_build_object('c', p_check, 'p', coalesce(p_ok, false), 'd', p_detail) $fn$;

create or replace function pg_temp.verify() returns table (n int, check_name text, passed boolean, detail text)
language plpgsql as $fn$
declare
  res jsonb := '[]'::jsonb;
  ua uuid := gen_random_uuid(); uv uuid := gen_random_uuid(); ub uuid := gen_random_uuid();
  ca uuid := gen_random_uuid(); cb uuid := gen_random_uuid();
  ma uuid := gen_random_uuid(); mb uuid := gen_random_uuid();
  st uuid := gen_random_uuid(); ct uuid := gen_random_uuid();
  la uuid := gen_random_uuid(); lb uuid := gen_random_uuid();
  da uuid := gen_random_uuid(); db uuid := gen_random_uuid();
  ia uuid := gen_random_uuid();
  cf uuid := gen_random_uuid(); mf uuid := gen_random_uuid(); mz uuid := gen_random_uuid();
  lf1 uuid := gen_random_uuid(); lf2 uuid := gen_random_uuid(); lz uuid := gen_random_uuid();
  df1 uuid := gen_random_uuid(); df2 uuid := gen_random_uuid(); dz uuid := gen_random_uuid(); i1 uuid := gen_random_uuid();
  r text; k bigint;
begin
  -- Fixtures and checks run inside a sub-transaction that is rolled back at the end.
  -- (plpgsql variables survive the rollback, so the results do too.)
  begin
    insert into auth.users (id, email) values (ua, 'owner-a@example.test'), (uv, 'viewer-a@example.test'), (ub, 'owner-b@example.test');
    insert into public.clients (id, name) values (ca, 'Verify Client A'), (cb, 'Verify Client B');
    insert into public.memberships (user_id, client_id, role) values (ua, ca, 'owner'), (uv, ca, 'viewer'), (ub, cb, 'owner');
    insert into public.markets (id, client_id, name) values (ma, ca, 'A-Dallas'), (mb, cb, 'B-Denver');
    insert into public.service_types (id, code, name) values (st, 'verify_roofing', 'Roofing');
    insert into public.contractors (id, name) values (ct, 'Verify Pro');
    insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values (ma, st, '2026-01-01', 1000), (mb, st, '2026-01-01', 2000);
    insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at)
      values (la, ma, st, 'verify', '1', '2026-01-02+00'), (lb, mb, st, 'verify', '2', '2026-01-02+00');
    insert into public.lead_deliveries (id, lead_id, contractor_id, delivered_at, price_cents)
      values (da, la, ct, '2026-01-02+00', 100), (db, lb, ct, '2026-01-02+00', 200);
    insert into public.invoices (id, client_id, period_start, period_end) values (ia, ca, '2026-01-01', '2026-01-31');
    insert into public.invoice_lines (invoice_id, lead_delivery_id) values (ia, da);

    -- A. constraints and guards (as the table owner)
    r := pg_temp.try($q$insert into public.clients (name) values ('  verify   client a ')$q$);
    res := pg_temp.rec(res, 'constraint: the same client under another spelling is refused', r = '23505', r);
    r := pg_temp.try(format($q$insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values (%L, %L, '2026-01-01', 5)$q$, ma, st));
    res := pg_temp.rec(res, 'constraint: one budget per market, service and month', r = '23505', r);
    r := pg_temp.try(format($q$insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents) values (%L, %L, '2026-02-15', 5)$q$, ma, st));
    res := pg_temp.rec(res, 'constraint: a budget month must be the first of a month', r = '23514', r);
    r := pg_temp.try(format($q$update public.lead_deliveries set price_cents = 1 where id = %L$q$, da));
    res := pg_temp.rec(res, 'guard: a billed delivery keeps its price', r = '23514', r);
    r := pg_temp.try(format($q$insert into public.invoice_lines (invoice_id, lead_delivery_id) values (%L, %L)$q$, ia, db));
    res := pg_temp.rec(res, 'guard: an invoice cannot bill another client''s delivery', r = '23514', r);
    select total_cents into k from public.invoice_totals where invoice_id = ia;
    res := pg_temp.rec(res, 'view: the invoice total is calculated from the details (100)', k = 100, k::text);
    select count(*) into k from audit.log where table_name = 'clients' and op = 'INSERT' and new_row ->> 'name' like 'Verify Client%';
    res := pg_temp.rec(res, 'audit: the log recorded both client inserts', k = 2, k::text);

    -- B. row-level security as owner of client A
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    select count(*) into k from public.clients;
    res := pg_temp.rec(res, 'rls: owner A sees exactly 1 client', k = 1, k::text);
    select count(*) into k from public.markets where client_id = cb;
    res := pg_temp.rec(res, 'rls: owner A sees no market of client B', k = 0, k::text);
    select (select count(*) from public.market_budgets) + (select count(*) from public.leads) + (select count(*) from public.lead_deliveries)
         + (select count(*) from public.invoices) + (select count(*) from public.invoice_lines) into k;
    res := pg_temp.rec(res, 'rls: owner A sees only client A in budgets, leads, deliveries, invoices and lines (5 rows)', k = 5, k::text);
    select count(*) into k from public.invoice_totals;
    res := pg_temp.rec(res, 'rls: the views obey RLS too (security_invoker)', k = 1, k::text);
    r := pg_temp.try(format($q$insert into public.markets (client_id, name) values (%L, 'Sneaky')$q$, cb));
    res := pg_temp.rec(res, 'rls: owner A cannot add a market to client B', r = '42501', r);
    r := pg_temp.try($q$select * from audit.log$q$);
    res := pg_temp.rec(res, 'rls: the audit log is not readable by app users', r = '42501', r);
    r := pg_temp.try(format($q$insert into public.leads (market_id, service_type_id, source_system, source_id, received_at) values (%L, %L, 'verify', '9', now())$q$, ma, st));
    res := pg_temp.rec(res, 'rls: leads can only be written by the service role', r = '42501', r);
    reset role;

    -- C. a viewer of client A
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', uv, 'role', 'authenticated')::text, true);
    select count(*) into k from public.markets;
    res := pg_temp.rec(res, 'rls: a viewer can read client A''s market', k = 1, k::text);
    r := pg_temp.try(format($q$insert into public.markets (client_id, name) values (%L, 'ViewerAdd')$q$, ca));
    res := pg_temp.rec(res, 'rls: a viewer cannot add a market', r = '42501', r);
    execute format($q$update public.markets set name = 'Hacked' where id = %L$q$, ma);
    reset role;
    select name into r from public.markets where id = ma;
    res := pg_temp.rec(res, 'rls: a viewer''s update changed nothing', r = 'A-Dallas', r);

    -- D. owner of client B, a user with no identity, anon, service role
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    select count(*) into k from public.markets where client_id = ca;
    res := pg_temp.rec(res, 'rls: owner B cannot see any of client A''s markets', k = 0, k::text);
    reset role;
    set local role authenticated;
    perform set_config('request.jwt.claims', '', true);
    select count(*) into k from public.clients where name like 'Verify Client%';
    res := pg_temp.rec(res, 'rls: authenticated with no identity sees nothing', k = 0, k::text);
    reset role;
    set local role anon;
    r := pg_temp.try($q$select * from public.clients$q$);
    res := pg_temp.rec(res, 'rls: anon has no access to clients', r = '42501', r);
    reset role;
    set local role service_role;
    select count(*) into k from public.clients where name like 'Verify Client%';
    res := pg_temp.rec(res, 'rls: the service role sees both (server side only)', k = 2, k::text);
    reset role;

    -- E. time zones, billing integrity and the audit log (migrations 5 to 7). Fresh fixtures, so the counts above stay as they were.
    insert into public.clients (id, name) values (cf, 'Verify Client F');
    insert into public.markets (id, client_id, name, timezone) values (mf, cf, 'F-NY', 'America/New_York'), (mz, cf, 'F-Auckland', 'Pacific/Auckland');
    insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents)
      values (mf, st, '2026-01-01', 1000), (mf, st, '2026-02-01', 1000), (mz, st, '2026-02-01', 1000);
    insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at) values
      (lf1, mf, st, 'verify', 'f1', timestamptz '2026-01-31 23:59 America/New_York'),
      (lf2, mf, st, 'verify', 'f2', timestamptz '2026-02-01 00:01 America/New_York'),
      (lz,  mz, st, 'verify', 'f3', timestamptz '2026-02-01 00:01 Pacific/Auckland');
    insert into public.lead_deliveries (id, lead_id, contractor_id, delivered_at, price_cents)
      values (df1, lf1, ct, now(), 7), (df2, lf2, ct, now(), 11), (dz, lz, ct, now(), 13);

    r := pg_temp.try(format($q$insert into public.markets (client_id, name, timezone) values (%L, 'Bad', 'Mars/Base')$q$, cf));
    res := pg_temp.rec(res, 'time zone: an unknown zone name is refused', r = '23514', r);
    select delivered_cents into k from public.budget_vs_spend where market_id = mf and budget_month = '2026-01-01';
    res := pg_temp.rec(res, 'time zone: New York 23:59 on 31 Jan counts in January (7)', k = 7, k::text);
    select delivered_cents into k from public.budget_vs_spend where market_id = mf and budget_month = '2026-02-01';
    res := pg_temp.rec(res, 'time zone: New York 00:01 on 1 Feb counts in February (11)', k = 11, k::text);
    select delivered_cents into k from public.budget_vs_spend where market_id = mz and budget_month = '2026-02-01';
    res := pg_temp.rec(res, 'time zone: Auckland 00:01 on 1 Feb (still 31 Jan in UTC) counts in February (13)', k = 13, k::text);

    insert into public.invoices (id, client_id, period_start, period_end) values (i1, cf, '2026-01-01', '2026-01-31');
    insert into public.invoice_lines (invoice_id, lead_delivery_id) values (i1, df1);
    update public.invoices set issued_at = now() where id = i1;
    select invoice_number into r from public.invoices where id = i1;
    res := pg_temp.rec(res, 'billing: issuing numbers the invoice INV-000001', r = 'INV-000001', r);
    r := pg_temp.try(format($q$update public.invoices set period_end = '2026-01-15' where id = %L$q$, i1));
    res := pg_temp.rec(res, 'billing: an issued invoice''s period is fixed', r = '23514', r);
    r := pg_temp.try(format($q$insert into public.invoice_lines (invoice_id, lead_delivery_id) values (%L, %L)$q$, i1, df2));
    res := pg_temp.rec(res, 'billing: a line cannot be added to an issued invoice', r = '23514', r);
    r := pg_temp.try(format($q$delete from public.invoices where id = %L$q$, i1));
    res := pg_temp.rec(res, 'billing: an issued invoice cannot be deleted', r = '23514', r);
    insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values (cf, i1, 'USD', 5, 'verify correction');
    select credit_number into r from public.credit_notes where invoice_id = i1;
    res := pg_temp.rec(res, 'billing: a correction is a credit note, numbered CN-000001', r = 'CN-000001', r);
    r := pg_temp.try(format($q$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values (%L, %L, 'USD', 3, 'too much')$q$, cf, i1));
    res := pg_temp.rec(res, 'billing: credits cannot exceed the invoice total (7 - 5 = 2 left)', r = '23514', r);
    r := pg_temp.try(format($q$update public.credit_notes set amount_cents = 1 where invoice_id = %L$q$, i1));
    res := pg_temp.rec(res, 'billing: a credit note cannot be edited', r = '23514', r);

    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    perform set_config('request.headers', '{"x-request-id":"verify-req-1"}', true);
    insert into public.markets (client_id, name) values (ca, 'Audit-ctx');
    reset role;
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.headers', '', true);
    select count(*) into k from audit.log where table_name = 'markets' and new_row ->> 'name' = 'Audit-ctx'
       and actor = ua and jwt_role = 'authenticated' and effective_role = 'authenticated' and request_id = 'verify-req-1';
    res := pg_temp.rec(res, 'audit: a change through the API records the user, JWT role, effective role and request id', k = 1, k::text);
    res := pg_temp.rec(res, 'audit: the current month has its partition',
                       to_regclass('audit.log_' || to_char(now() at time zone 'UTC', 'YYYY_MM')) is not null, 'partition');
    set local role service_role;
    r := pg_temp.try($q$update audit.log set op = op$q$);
    res := pg_temp.rec(res, 'audit: service_role cannot UPDATE the log', r = '42501', r);
    r := pg_temp.try($q$delete from audit.log$q$);
    res := pg_temp.rec(res, 'audit: service_role cannot DELETE from the log', r = '42501', r);
    reset role;
    r := pg_temp.try($q$delete from audit.log$q$);
    res := pg_temp.rec(res, 'audit: even the table owner is stopped by the trigger (DELETE)', r = '42501', r);
    r := pg_temp.try($q$truncate audit.log$q$);
    res := pg_temp.rec(res, 'audit: even the table owner is stopped by the trigger (TRUNCATE)', r = '42501', r);

    raise exception 'rollback everything' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;

  return query select (e.i)::int, e.v ->> 'c', (e.v ->> 'p')::boolean, e.v ->> 'd'
               from jsonb_array_elements(res) with ordinality as e(v, i);
end $fn$;

select * from pg_temp.verify();
