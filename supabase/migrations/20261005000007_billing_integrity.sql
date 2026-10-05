-- P0-4: billing integrity. Before this migration only a delivery's price was frozen once billed. An issued invoice could still
-- gain, lose or swap lines, change its period or its client, be deleted, and had no number or currency; a correction meant
-- editing history.
--
-- Rules after this migration:
--   * An invoice is a draft (issued_at is null) or issued. Issuing = setting issued_at; the database then assigns the next
--     gap-free number for that client. Nobody picks a number.
--   * An issued invoice never changes: not its columns, not its lines, and it cannot be deleted.
--   * A correction is a credit note: a new, immutable document that points at the invoice and carries its own number.
--   * Money has a currency. A client has one, fixed at creation; its invoices and credit notes must match it.
--   * The links that decide which client a delivery belongs to (delivery -> lead -> market -> client) are write-once, so
--     nothing can be moved underneath an issued invoice.

begin;

------------------------------------------------------------------ currency
alter table public.clients add column currency char(3) not null default 'USD' check (currency ~ '^[A-Z]{3}$');
alter table public.clients add constraint clients_id_currency_key unique (id, currency);

alter table public.invoices add column currency char(3) not null default 'USD' check (currency ~ '^[A-Z]{3}$');
alter table public.invoices add column invoice_number text;
alter table public.invoices add constraint invoices_id_client_currency_key unique (id, client_id, currency);
-- the invoice must be in its client's currency; a client's currency cannot change while an invoice exists (RESTRICT)
alter table public.invoices add constraint invoices_client_currency_fk
  foreign key (client_id, currency) references public.clients (id, currency) on update restrict on delete restrict;

------------------------------------------------------------------ numbering
-- One counter row per client and document series. Taking the row lock serialises issuers, and a rolled-back issue rolls the
-- counter back with it, so numbers have no gaps (an auditor's usual demand). The cost: issuers for ONE client queue up.
create table private.document_counters (
  client_id   uuid not null references public.clients (id) on delete restrict,
  series      text not null check (series in ('invoice', 'credit_note')),
  last_number bigint not null default 0 check (last_number >= 0),
  primary key (client_id, series)
);

create function private.next_document_number(p_client uuid, p_series text) returns text
language plpgsql security definer set search_path = '' as $$
declare n bigint;
begin
  insert into private.document_counters (client_id, series, last_number) values (p_client, p_series, 1)
  on conflict (client_id, series) do update set last_number = private.document_counters.last_number + 1
  returning last_number into n;
  return case p_series when 'invoice' then 'INV-' else 'CN-' end || lpad(n::text, 6, '0');
end $$;

-- Invoices that were already issued get numbers, oldest first, so the new rule can be switched on.
with ordered as (
  select id, client_id, row_number() over (partition by client_id order by issued_at, period_start, id) as n
  from public.invoices where issued_at is not null)
update public.invoices i set invoice_number = 'INV-' || lpad(o.n::text, 6, '0') from ordered o where o.id = i.id;
insert into private.document_counters (client_id, series, last_number)
  select client_id, 'invoice', count(*) from public.invoices where issued_at is not null group by client_id;

alter table public.invoices add constraint invoices_number_unique unique (client_id, invoice_number);
alter table public.invoices add constraint invoices_number_iff_issued check ((issued_at is null) = (invoice_number is null));

------------------------------------------------------------------ issuing, and immutability of an issued invoice
-- The guards are security definer: they must see the true state of the invoice, its lines and its credits whatever the
-- caller's row-level security lets that caller see, and the caller needs no access to private.document_counters.
create function private.guard_invoice() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.issued_at is not null then
      raise exception 'invoice % is issued and cannot be deleted; issue a credit note', old.invoice_number using errcode = 'check_violation';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.issued_at is not null or new.invoice_number is not null then
      raise exception 'invoices start as drafts; set issued_at on an existing draft to issue it' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  -- UPDATE
  if old.issued_at is not null then
    raise exception 'invoice % is issued and cannot be changed; issue a credit note', old.invoice_number using errcode = 'check_violation';
  end if;
  if new.invoice_number is not null then
    raise exception 'invoice numbers are assigned by the database when the invoice is issued' using errcode = 'check_violation';
  end if;
  if new.client_id is distinct from old.client_id and exists (select 1 from public.invoice_lines where invoice_id = new.id) then
    raise exception 'a draft that has lines cannot move to another client' using errcode = 'check_violation';
  end if;
  if new.issued_at is not null then                      -- the one allowed transition: draft -> issued
    if not exists (select 1 from public.invoice_lines where invoice_id = new.id) then
      raise exception 'an invoice with no lines cannot be issued' using errcode = 'check_violation';
    end if;
    new.invoice_number := private.next_document_number(new.client_id, 'invoice');
  end if;
  return new;
end $$;
create trigger invoices_guard before insert or update or delete on public.invoices
  for each row execute function private.guard_invoice();

-- Lines: only on a draft. FOR SHARE on the invoice row conflicts with the UPDATE that issues it, so a line cannot slip in
-- while the invoice is being issued (the foreign key's own lock, FOR KEY SHARE, would not stop that).
create function private.guard_invoice_line_edit() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_old timestamptz; v_new timestamptz;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select issued_at into v_old from public.invoices where id = old.invoice_id for share;
    if v_old is not null then
      raise exception 'invoice % is issued; its lines cannot be changed or removed', old.invoice_id using errcode = 'check_violation';
    end if;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    select issued_at into v_new from public.invoices where id = new.invoice_id for share;
    if v_new is not null then
      raise exception 'invoice % is issued; lines cannot be added or moved to it', new.invoice_id using errcode = 'check_violation';
    end if;
  end if;
  return coalesce(new, old);
end $$;
create trigger invoice_lines_draft_only before insert or update or delete on public.invoice_lines
  for each row execute function private.guard_invoice_line_edit();

------------------------------------------------------------------ the chain a delivery belongs to is write-once
create function private.guard_immutable() returns trigger language plpgsql set search_path = '' as $$
declare c text;
begin
  foreach c in array tg_argv loop
    if to_jsonb(new) -> c is distinct from to_jsonb(old) -> c then
      raise exception '%.% cannot be changed once written', tg_table_name, c using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end $$;
create trigger markets_client_fixed         before update of client_id  on public.markets         for each row execute function private.guard_immutable('client_id');
create trigger leads_market_fixed           before update of market_id  on public.leads           for each row execute function private.guard_immutable('market_id');
create trigger deliveries_lead_fixed        before update of lead_id    on public.lead_deliveries for each row execute function private.guard_immutable('lead_id');
create trigger clients_currency_fixed       before update of currency   on public.clients         for each row execute function private.guard_immutable('currency');

------------------------------------------------------------------ credit notes
create table public.credit_notes (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null,
  invoice_id    uuid not null,
  currency      char(3) not null,
  credit_number text not null,
  amount_cents  bigint not null check (amount_cents > 0),
  reason        text not null check (btrim(reason) <> ''),
  issued_at     timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  -- same client and same currency as the invoice it corrects
  foreign key (invoice_id, client_id, currency) references public.invoices (id, client_id, currency) on delete restrict,
  unique (client_id, credit_number)
);
create index credit_notes_invoice_idx on public.credit_notes (invoice_id);

-- A credit note is written once. It may only correct an ISSUED invoice and may not credit more than the invoice total
-- minus earlier credit notes. The invoice row is locked so two concurrent credit notes cannot both fit.
create function private.guard_credit_note() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_issued timestamptz; v_total bigint; v_credited bigint;
begin
  if tg_op <> 'INSERT' then
    raise exception 'credit notes are never edited or deleted; issue another credit note' using errcode = 'check_violation';
  end if;
  if new.credit_number is not null then
    raise exception 'credit numbers are assigned by the database' using errcode = 'check_violation';
  end if;
  select issued_at into v_issued from public.invoices where id = new.invoice_id for update;
  if not found then
    raise exception 'invoice % does not exist', new.invoice_id using errcode = 'foreign_key_violation';
  end if;
  if v_issued is null then
    raise exception 'invoice % is not issued; edit the draft instead of crediting it', new.invoice_id using errcode = 'check_violation';
  end if;
  select coalesce(sum(d.price_cents), 0) into v_total
    from public.invoice_lines l join public.lead_deliveries d on d.id = l.lead_delivery_id where l.invoice_id = new.invoice_id;
  select coalesce(sum(amount_cents), 0) into v_credited from public.credit_notes where invoice_id = new.invoice_id;
  if v_credited + new.amount_cents > v_total then
    raise exception 'credit of % would exceed the invoice total % (already credited %)', new.amount_cents, v_total, v_credited
      using errcode = 'check_violation';
  end if;
  new.credit_number := private.next_document_number(new.client_id, 'credit_note');   -- assigned here, never supplied
  new.issued_at := now();
  return new;
end $$;
create trigger credit_notes_guard before insert or update or delete on public.credit_notes
  for each row execute function private.guard_credit_note();
create function private.deny_truncate() returns trigger language plpgsql set search_path = '' as $$
begin raise exception '% cannot be truncated', tg_table_name using errcode = 'insufficient_privilege'; end $$;
create trigger credit_notes_no_truncate before truncate on public.credit_notes for each statement execute function private.deny_truncate();
create trigger invoices_no_truncate     before truncate on public.invoices     for each statement execute function private.deny_truncate();
create trigger invoice_lines_no_truncate before truncate on public.invoice_lines for each statement execute function private.deny_truncate();

------------------------------------------------------------------ security and audit for the new objects
alter table public.credit_notes enable row level security;
alter table private.document_counters enable row level security;
revoke all on private.document_counters from public, anon, authenticated, service_role;
revoke all on public.credit_notes from public, anon, authenticated;   -- a project that auto-exposes new tables would have granted these
grant select on public.credit_notes to authenticated;
grant all on public.credit_notes to service_role;
revoke all on function private.next_document_number(uuid, text), private.guard_invoice(), private.guard_invoice_line_edit(),
  private.guard_immutable(), private.guard_credit_note(), private.deny_truncate() from public, anon, authenticated, service_role;
create policy credit_notes_read on public.credit_notes for select to authenticated using (private.is_member(client_id));
create trigger audit_credit_notes after insert or update or delete on public.credit_notes for each row execute function audit.log_change();

-- Net position per invoice, calculated from the details; nothing stored.
create view public.invoice_balances with (security_invoker = true) as
select t.invoice_id, t.client_id, i.invoice_number, i.currency, t.total_cents,
       coalesce(sum(c.amount_cents), 0)::bigint                        as credited_cents,
       t.total_cents - coalesce(sum(c.amount_cents), 0)::bigint        as net_cents
from public.invoice_totals t
join public.invoices i on i.id = t.invoice_id
left join public.credit_notes c on c.invoice_id = t.invoice_id
group by t.invoice_id, t.client_id, i.invoice_number, i.currency, t.total_cents;
revoke all on public.invoice_balances from public, anon, authenticated;
grant select on public.invoice_balances to authenticated;
grant all on public.invoice_balances to service_role;

commit;
