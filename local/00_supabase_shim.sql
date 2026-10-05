-- Local stand-in for what a real Supabase project already provides (roles, auth.users, auth.uid()).
-- NOT part of the migrations: on Supabase this file is not needed.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text);
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- What a hosted Supabase project does to every table the migrations create in public, even with "Automatically expose new
-- tables" OFF (read from pg_default_acl on the hosted project, 2026-10-05): the three API roles get TRUNCATE, REFERENCES and
-- TRIGGER (and MAINTAIN on Postgres 17) by default. The local tests must see the same, or a revoke that comes too early
-- (before a later table or view exists) passes here and leaks there.
alter default privileges in schema public grant truncate, references, trigger on tables to anon, authenticated, service_role;
