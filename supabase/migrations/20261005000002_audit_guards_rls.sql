-- One shared audit log, guards for billing rules, and row-level security on every table.

------------------------------------------------------------------ audit
create schema if not exists audit;

create table audit.log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      uuid default auth.uid(),
  table_name text not null,
  op         text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  row_id     text,
  old_row    jsonb,
  new_row    jsonb
);
create index audit_log_row_idx on audit.log (table_name, row_id, at desc);

-- RLS on with NO policy: application roles can never read or write the log. Only service_role / owner.
alter table audit.log enable row level security;
revoke all on schema audit from anon, authenticated;
revoke all on audit.log from anon, authenticated;

create function audit.log_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare j jsonb := to_jsonb(coalesce(new, old));
begin
  insert into audit.log (table_name, op, row_id, old_row, new_row)
  values (tg_table_name, tg_op,
          coalesce(j ->> 'id', concat_ws(':', j ->> 'user_id', j ->> 'client_id')),
          case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

-- Audit the low-volume, high-value tables. Leads and deliveries are high volume: for those use pgaudit or
-- logical decoding, not a row trigger on the hot path.
do $$ declare t text; begin
  foreach t in array array['clients', 'markets', 'market_budgets', 'memberships', 'invoices', 'invoice_lines'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function audit.log_change()', t);
  end loop;
end $$;

------------------------------------------------------------------ billing guards
-- A delivery that is on an invoice keeps its price.
create function private.guard_billed_delivery() returns trigger language plpgsql as $$
begin
  if new.price_cents is distinct from old.price_cents
     and exists (select 1 from public.invoice_lines where lead_delivery_id = old.id) then
    raise exception 'delivery % is billed; its price is frozen', old.id using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger lead_deliveries_billed_price_frozen before update of price_cents on public.lead_deliveries
  for each row execute function private.guard_billed_delivery();

-- An invoice may only bill deliveries that belong to the same client (delivery -> lead -> market -> client).
create function private.guard_line_client() returns trigger language plpgsql as $$
declare v_delivery_client uuid; v_invoice_client uuid;
begin
  select m.client_id into v_delivery_client
    from public.lead_deliveries d join public.leads l on l.id = d.lead_id join public.markets m on m.id = l.market_id
   where d.id = new.lead_delivery_id;
  select client_id into v_invoice_client from public.invoices where id = new.invoice_id;
  if v_delivery_client is distinct from v_invoice_client then
    raise exception 'delivery % belongs to another client than invoice %', new.lead_delivery_id, new.invoice_id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger invoice_lines_same_client before insert or update on public.invoice_lines
  for each row execute function private.guard_line_client();

------------------------------------------------------------------ RLS helpers
-- security definer so policies can read memberships without recursing into memberships' own policy.
-- (select auth.uid()) is evaluated once per statement, not once per row.
create function private.is_member(p_client uuid, p_roles text[] default array['owner', 'analyst', 'viewer'])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.memberships m
                  where m.user_id = (select auth.uid()) and m.client_id = p_client and m.role = any (p_roles))
$$;
revoke all on function private.is_member(uuid, text[]) from public;
grant usage on schema private to authenticated;
grant execute on function private.is_member(uuid, text[]) to authenticated;

create function private.market_client(p_market uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select client_id from public.markets where id = p_market
$$;
revoke all on function private.market_client(uuid) from public;
grant execute on function private.market_client(uuid) to authenticated;

------------------------------------------------------------------ RLS on every table
alter table public.clients         enable row level security;
alter table public.markets         enable row level security;
alter table public.service_types   enable row level security;
alter table public.market_budgets  enable row level security;
alter table public.contractors     enable row level security;
alter table public.leads           enable row level security;
alter table public.lead_deliveries enable row level security;
alter table public.invoices        enable row level security;
alter table public.invoice_lines   enable row level security;
alter table public.memberships     enable row level security;

-- privileges: least needed, RLS is the second gate
grant usage on schema public to anon, authenticated, service_role;
grant select on all tables in schema public to authenticated;
grant update on public.clients to authenticated;
grant insert, update, delete on public.markets, public.market_budgets to authenticated;
grant all on all tables in schema public to service_role;

create policy clients_read    on public.clients for select to authenticated using (private.is_member(id));
create policy clients_update  on public.clients for update to authenticated
  using (private.is_member(id, array['owner'])) with check (private.is_member(id, array['owner']));

create policy markets_read    on public.markets for select to authenticated using (private.is_member(client_id));
create policy markets_write   on public.markets for all to authenticated
  using (private.is_member(client_id, array['owner'])) with check (private.is_member(client_id, array['owner']));

create policy service_types_read on public.service_types for select to authenticated using (true);
create policy contractors_read   on public.contractors   for select to authenticated using (true);

create policy budgets_read    on public.market_budgets for select to authenticated
  using (private.is_member(private.market_client(market_id)));
create policy budgets_write   on public.market_budgets for all to authenticated
  using (private.is_member(private.market_client(market_id), array['owner']))
  with check (private.is_member(private.market_client(market_id), array['owner']));

create policy leads_read      on public.leads for select to authenticated
  using (private.is_member(private.market_client(market_id)));

create policy deliveries_read on public.lead_deliveries for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id and private.is_member(private.market_client(l.market_id))));

create policy invoices_read   on public.invoices for select to authenticated using (private.is_member(client_id));
create policy lines_read      on public.invoice_lines for select to authenticated
  using (exists (select 1 from public.invoices i where i.id = invoice_id and private.is_member(i.client_id)));

create policy memberships_own on public.memberships for select to authenticated using (user_id = (select auth.uid()));
