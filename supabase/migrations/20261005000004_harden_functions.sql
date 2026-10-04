-- Hardening found by running the first three migrations on a hosted Supabase project (Security Advisor, 2026-10-05).

-- 1. Pin search_path on every function that did not set one (advisor: "Function Search Path Mutable").
--    All of them already use schema-qualified names, so an empty path changes nothing except closing the hole.
alter function private.guard_billed_delivery() set search_path = '';
alter function private.guard_line_client()     set search_path = '';
alter function legacy.parse_cents(text)        set search_path = '';
alter function legacy.parse_month(text)        set search_path = '';
alter function legacy.service_code(text)       set search_path = '';
alter function legacy.import_budgets()         set search_path = '';

-- 2. Supabase's "automatic RLS" option installs public.rls_auto_enable() for an event trigger. An event trigger does
--    not need the API roles to hold EXECUTE, so close it to them. (It only exists on Supabase, hence the guard.)
do $$ begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;
