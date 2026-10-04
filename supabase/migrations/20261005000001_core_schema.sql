-- Core schema for a home-services lead-generation platform (reference design, synthetic).
-- Standards applied: one fact per column; nothing stored that can be calculated (views instead);
-- finest detail stored (one row per delivered lead); money in integer cents; times as timestamptz;
-- uuid keys; outside ids kept exactly as given; every link a foreign key; every "only one X per Y" a unique constraint.

create schema if not exists private;

create table public.clients (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (btrim(name) <> ''),
  name_key      text generated always as (lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))) stored,
  status        text not null default 'active' check (status in ('active', 'paused', 'closed')),
  source_system text,
  source_id     text,
  created_at    timestamptz not null default now(),
  check ((source_system is null) = (source_id is null)),
  unique (source_system, source_id)
);
-- one live client per normalised name: blocks "Acme Roofing" / "ACME  roofing " duplicates
create unique index clients_one_live_per_name on public.clients (name_key) where status <> 'closed';

create table public.markets (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.clients (id) on delete restrict,
  name       text not null check (btrim(name) <> ''),
  timezone   text not null default 'America/New_York',
  created_at timestamptz not null default now(),
  unique (client_id, name)
);
create index markets_client_id_idx on public.markets (client_id);

create table public.service_types (
  id   uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z0-9_]+$'),
  name text not null
);

-- "A client has several markets, and each market has one budget per service type per month."
create table public.market_budgets (
  id              uuid primary key default gen_random_uuid(),
  market_id       uuid not null references public.markets (id) on delete restrict,
  service_type_id uuid not null references public.service_types (id) on delete restrict,
  budget_month    date not null check (extract(day from budget_month) = 1),
  amount_cents    bigint not null check (amount_cents >= 0),
  created_at      timestamptz not null default now(),
  unique (market_id, service_type_id, budget_month)
);
create index market_budgets_service_type_idx on public.market_budgets (service_type_id);

create table public.contractors (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (btrim(name) <> ''),
  status     text not null default 'active' check (status in ('active', 'paused', 'closed')),
  created_at timestamptz not null default now()
);

create table public.leads (
  id              uuid primary key default gen_random_uuid(),
  market_id       uuid not null references public.markets (id) on delete restrict,
  service_type_id uuid not null references public.service_types (id) on delete restrict,
  source_system   text not null,
  source_id       text not null,          -- the outside id, exactly as given
  received_at     timestamptz not null,
  created_at      timestamptz not null default now(),
  unique (source_system, source_id)
);
create index leads_market_received_idx on public.leads (market_id, received_at);
create index leads_service_type_idx on public.leads (service_type_id);

create table public.lead_deliveries (
  id            uuid primary key default gen_random_uuid(),
  lead_id       uuid not null references public.leads (id) on delete restrict,
  contractor_id uuid not null references public.contractors (id) on delete restrict,
  delivered_at  timestamptz not null,
  price_cents   integer not null check (price_cents >= 0),   -- the finest detail; totals are views
  unique (lead_id, contractor_id)
);
create index lead_deliveries_contractor_idx on public.lead_deliveries (contractor_id);

create table public.invoices (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.clients (id) on delete restrict,
  period_start date not null,
  period_end   date not null,
  issued_at    timestamptz,
  check (period_end >= period_start),
  unique (client_id, period_start)
);

create table public.invoice_lines (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references public.invoices (id) on delete restrict,
  lead_delivery_id uuid not null unique references public.lead_deliveries (id) on delete restrict  -- a delivery is billed once
);
create index invoice_lines_invoice_idx on public.invoice_lines (invoice_id);

create table public.memberships (
  user_id   uuid not null references auth.users (id) on delete cascade,
  client_id uuid not null references public.clients (id) on delete cascade,
  role      text not null check (role in ('owner', 'analyst', 'viewer')),
  primary key (user_id, client_id)
);
create index memberships_client_idx on public.memberships (client_id);

-- Calculated values live in views, never in columns. security_invoker so RLS of the caller applies.
create view public.invoice_totals with (security_invoker = true) as
select i.id as invoice_id, i.client_id,
       count(l.id)                           as line_count,
       coalesce(sum(d.price_cents), 0)::bigint as total_cents
from public.invoices i
left join public.invoice_lines l on l.invoice_id = i.id
left join public.lead_deliveries d on d.id = l.lead_delivery_id
group by i.id;

create view public.budget_vs_spend with (security_invoker = true) as
select b.market_id, b.service_type_id, b.budget_month, b.amount_cents as budget_cents,
       coalesce(sum(d.price_cents), 0)::bigint as delivered_cents,
       b.amount_cents - coalesce(sum(d.price_cents), 0) as remaining_cents
from public.market_budgets b
left join public.leads l
       on l.market_id = b.market_id and l.service_type_id = b.service_type_id
      and l.received_at >= b.budget_month and l.received_at < (b.budget_month + interval '1 month')
left join public.lead_deliveries d on d.lead_id = l.id
group by b.id;
