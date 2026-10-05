-- Found by running migration 7 on the hosted project: a Supabase project grants anon, authenticated and service_role
-- TRUNCATE, REFERENCES and TRIGGER (and MAINTAIN on Postgres 17) on EVERY new table in public by default, even with
-- "Automatically expose new tables" off (pg_default_acl, read 2026-10-05). The revoke in migration 7 ran before the view
-- invoice_balances existed, so that view kept them for service_role; and migrations 1-4 left the same three privileges
-- with anon and authenticated on every older table.
--
-- Why it matters: TRUNCATE is not subject to row-level security, and TRIGGER lets a role attach its own trigger to a table.
-- The API cannot issue either today, but a role should not hold what it never needs.
--
-- Tables created by supabase_admin (the dashboard's Table Editor) follow supabase_admin's own defaults, which a migration
-- cannot change; create tables with migrations.

begin;
set local lock_timeout = '5s';   -- give up instead of queueing behind a long transaction (and everything behind it)

revoke truncate, references, trigger on all tables in schema public from anon, authenticated, service_role;
alter default privileges in schema public revoke truncate, references, trigger on tables from anon, authenticated, service_role;

-- Postgres 17 added MAINTAIN (VACUUM, ANALYZE, REINDEX, CLUSTER, LOCK TABLE); the keyword does not exist before that.
do $$ begin
  if current_setting('server_version_num')::int >= 170000 then
    execute 'revoke maintain on all tables in schema public from anon, authenticated, service_role';
    execute 'alter default privileges in schema public revoke maintain on tables from anon, authenticated, service_role';
  end if;
end $$;

commit;
