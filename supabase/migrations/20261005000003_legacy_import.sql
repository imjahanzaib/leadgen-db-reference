-- Moving data from an older spreadsheet-style store, and proving nothing was lost or duplicated.
-- legacy.* holds the OLD shape (all text, as exported). The import is one transaction, idempotent, and every
-- row it does not load is written to legacy.import_rejects with a reason.

create schema if not exists legacy;
revoke all on schema legacy from anon, authenticated;

create table legacy.budget_sheet (          -- one row per spreadsheet line, text exactly as exported
  row_no       int primary key,
  client_name  text,
  market_name  text,
  service      text,
  month_label  text,
  budget_text  text
);
create table legacy.sheet_leads (lead_ref text primary key, market_name text);
create table legacy.sheet_deliveries (delivery_no int primary key, lead_ref text, contractor text, price_text text);
create table legacy.sheet_invoices (invoice_no text primary key, stored_total_text text);
create table legacy.sheet_invoice_lines (line_no int primary key, invoice_no text, amount_text text);

create table legacy.import_rejects (row_no int primary key, reason text not null);
create table legacy.import_report (
  id bigint generated always as identity primary key,
  run_at timestamptz not null default now(),
  rows_in bigint, rows_loaded bigint, rows_rejected bigint,
  cents_in bigint, cents_loaded bigint, cents_rejected bigint
);

-- RLS on every table, these included. No policies: only the owner and service_role can reach them.
-- (The schema is also not exposed through the Data API, and USAGE on it is revoked from the app roles above.)
alter table legacy.budget_sheet        enable row level security;
alter table legacy.sheet_leads         enable row level security;
alter table legacy.sheet_deliveries    enable row level security;
alter table legacy.sheet_invoices      enable row level security;
alter table legacy.sheet_invoice_lines enable row level security;
alter table legacy.import_rejects      enable row level security;
alter table legacy.import_report       enable row level security;

create function legacy.parse_cents(t text) returns bigint language sql immutable as $$
  select case when regexp_replace(coalesce(t, ''), '[^0-9.]', '', 'g') ~ '^[0-9]+(\.[0-9]{1,2})?$'
              then round(regexp_replace(t, '[^0-9.]', '', 'g')::numeric * 100)::bigint end
$$;

create function legacy.parse_month(t text) returns date language sql immutable as $$
  select case
    when t ~* '^[a-z]{3}-[0-9]{4}$'          then to_date(initcap(t), 'Mon-YYYY')
    when t ~* '^[a-z]{4,9} [0-9]{4}$'        then to_date(initcap(t), 'FMMonth YYYY')
    when t ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'    then to_date(t || '-01', 'YYYY-MM-DD')
  end
$$;

create function legacy.service_code(t text) returns text language sql immutable as $$
  select nullif(regexp_replace(lower(btrim(coalesce(t, ''))), '[^a-z0-9]+', '_', 'g'), '')
$$;

create function legacy.import_budgets() returns bigint language plpgsql as $$
declare v_in bigint; v_loaded bigint; v_rej bigint; v_cents_in bigint; v_cents_loaded bigint; v_cents_rej bigint;
begin
  -- 0. classify every sheet row once
  drop table if exists pg_temp._s;
  create temp table _s on commit drop as
  select b.row_no, btrim(b.client_name) as client_name, btrim(b.market_name) as market_name,
         legacy.service_code(b.service) as service_code, legacy.parse_month(btrim(b.month_label)) as month,
         legacy.parse_cents(b.budget_text) as cents,
         lower(regexp_replace(btrim(coalesce(b.client_name, '')), '\s+', ' ', 'g')) as client_key
  from legacy.budget_sheet b;

  delete from legacy.import_rejects;
  insert into legacy.import_rejects (row_no, reason)
  select row_no, case when client_name is null or client_name = '' then 'missing client'
                      when market_name is null or market_name = '' then 'missing market'
                      when service_code is null then 'missing service'
                      when month is null then 'unreadable month'
                      when cents is null then 'unreadable amount' end
  from _s where client_name is null or client_name = '' or market_name is null or market_name = ''
             or service_code is null or month is null or cents is null;

  -- duplicates of (client, market, service, month): keep the first row, reject the rest with a reason
  insert into legacy.import_rejects (row_no, reason)
  select row_no, 'duplicate of an earlier row for the same client, market, service and month'
  from (select row_no, row_number() over (partition by client_key, lower(market_name), service_code, month order by row_no) as n
        from _s where row_no not in (select row_no from legacy.import_rejects)) q
  where n > 1;

  -- 1. reference rows, idempotent
  insert into public.clients (name, source_system, source_id)
  select distinct on (client_key) client_name, 'sheet', client_key from _s
  where row_no not in (select row_no from legacy.import_rejects) order by client_key, row_no
  on conflict (source_system, source_id) do nothing;

  insert into public.markets (client_id, name)
  select distinct c.id, s.market_name from _s s
  join public.clients c on c.source_system = 'sheet' and c.source_id = s.client_key
  where s.row_no not in (select row_no from legacy.import_rejects)
  on conflict (client_id, name) do nothing;

  insert into public.service_types (code, name)
  select distinct service_code, initcap(replace(service_code, '_', ' ')) from _s
  where row_no not in (select row_no from legacy.import_rejects)
  on conflict (code) do nothing;

  -- 2. the budgets themselves
  insert into public.market_budgets (market_id, service_type_id, budget_month, amount_cents)
  select m.id, st.id, s.month, s.cents
  from _s s
  join public.clients c on c.source_system = 'sheet' and c.source_id = s.client_key
  join public.markets m on m.client_id = c.id and m.name = s.market_name
  join public.service_types st on st.code = s.service_code
  where s.row_no not in (select row_no from legacy.import_rejects)
  on conflict (market_id, service_type_id, budget_month) do nothing;

  -- 3. report: what came in = what went in + what was rejected, in rows AND in money
  select count(*), coalesce(sum(cents), 0) into v_in, v_cents_in from _s;
  select count(*), coalesce(sum(s.cents), 0) into v_rej, v_cents_rej
    from _s s join legacy.import_rejects r using (row_no);
  v_loaded := v_in - v_rej; v_cents_loaded := v_cents_in - v_cents_rej;
  insert into legacy.import_report (rows_in, rows_loaded, rows_rejected, cents_in, cents_loaded, cents_rejected)
  values (v_in, v_loaded, v_rej, v_cents_in, v_cents_loaded, v_cents_rej);
  return v_loaded;
end $$;

-- ---------------------------------------------------------------- the three data checks, as views
-- 1. duplicate records for the same client (same normalised name, different spellings)
create view legacy.dup_clients as
select lower(regexp_replace(btrim(client_name), '\s+', ' ', 'g')) as client_key,
       count(distinct client_name) as spellings, array_agg(distinct client_name order by client_name) as variants
from legacy.budget_sheet group by 1 having count(distinct client_name) > 1;

-- 2. links pointing at records that no longer exist
create view legacy.orphan_deliveries as
select d.delivery_no, d.lead_ref from legacy.sheet_deliveries d
left join legacy.sheet_leads l on l.lead_ref = d.lead_ref where l.lead_ref is null;

-- 3. stored totals that no longer match the details they came from
create view legacy.total_mismatch as
select i.invoice_no, legacy.parse_cents(i.stored_total_text) as stored_cents,
       coalesce(sum(legacy.parse_cents(l.amount_text)), 0)::bigint as detail_cents,
       legacy.parse_cents(i.stored_total_text) - coalesce(sum(legacy.parse_cents(l.amount_text)), 0)::bigint as difference_cents
from legacy.sheet_invoices i left join legacy.sheet_invoice_lines l using (invoice_no)
group by i.invoice_no, i.stored_total_text
having legacy.parse_cents(i.stored_total_text) is distinct from coalesce(sum(legacy.parse_cents(l.amount_text)), 0)::bigint;
