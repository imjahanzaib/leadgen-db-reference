\set ON_ERROR_STOP on
\ir _helpers.sql
begin;
\echo == 10 least privilege: the API roles hold no TRUNCATE, REFERENCES or TRIGGER on anything in public
\o /dev/null
select pg_temp.ok((select count(*) from information_schema.role_table_grants
                   where table_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role')
                     and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')) = 0,
                  'no table or view in public gives anon, authenticated or service_role TRUNCATE, REFERENCES or TRIGGER');

-- a table created AFTER the migrations (a later migration) must not pick them up either
create table public.zz_later_table (id int);
select pg_temp.ok((select count(*) from information_schema.role_table_grants
                   where table_schema = 'public' and table_name = 'zz_later_table' and grantee in ('anon', 'authenticated', 'service_role')
                     and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')) = 0,
                  'a table created later gets none of them (the default privileges were changed, not just the existing tables)');
create view public.zz_later_view as select 1 as x;
select pg_temp.ok((select count(*) from information_schema.role_table_grants
                   where table_schema = 'public' and table_name = 'zz_later_view' and grantee in ('anon', 'authenticated', 'service_role')
                     and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')) = 0, 'and neither does a view created later');

-- what the API roles DO need is still there
select pg_temp.ok(has_table_privilege('authenticated', 'public.clients', 'SELECT') and has_table_privilege('service_role', 'public.leads', 'INSERT')
              and has_table_privilege('authenticated', 'public.markets', 'UPDATE'), 'the privileges the design relies on are untouched (authenticated reads clients and edits markets, service_role writes leads)');
set local role service_role;
select pg_temp.expect($$truncate public.leads$$, '42501', 'service_role cannot truncate leads');
reset role;
set local role authenticated;
select pg_temp.expect($$truncate public.clients$$, '42501', 'authenticated cannot truncate clients');
reset role;
set local role anon;
select pg_temp.expect($$truncate public.markets$$, '42501', 'anon cannot truncate markets');
reset role;
rollback;
