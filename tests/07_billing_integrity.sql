\set ON_ERROR_STOP on
\ir _helpers.sql
begin;
\echo == 07 billing integrity: issued invoices never change, corrections are credit notes, numbers have no gaps
\o /dev/null
insert into public.clients (id, name, currency) values
  ('00000000-7777-0000-0000-00000000000a', 'Bill A', 'USD'),
  ('00000000-7777-0000-0000-00000000000b', 'Bill B', 'USD'),
  ('00000000-7777-0000-0000-00000000000e', 'Bill E', 'EUR');
insert into public.markets (id, client_id, name) values
  ('00000000-7777-0000-0000-0000000000a1', '00000000-7777-0000-0000-00000000000a', 'A-Dallas'),
  ('00000000-7777-0000-0000-0000000000b1', '00000000-7777-0000-0000-00000000000b', 'B-Denver'),
  ('00000000-7777-0000-0000-0000000000e1', '00000000-7777-0000-0000-00000000000e', 'E-Paris');
insert into public.service_types (id, code, name) values ('00000000-7777-0000-0000-0000000000c1', 'roofing', 'Roofing');
insert into public.contractors (id, name) values ('00000000-7777-0000-0000-0000000000d1', 'Pro');
insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at)
select l.id, l.m, '00000000-7777-0000-0000-0000000000c1', 'bill', l.id::text, '2026-01-05 10:00+00'
from (values ('00000000-7777-0000-0000-0000000001a1'::uuid, '00000000-7777-0000-0000-0000000000a1'::uuid),
             ('00000000-7777-0000-0000-0000000001a2', '00000000-7777-0000-0000-0000000000a1'),
             ('00000000-7777-0000-0000-0000000001a3', '00000000-7777-0000-0000-0000000000a1'),
             ('00000000-7777-0000-0000-0000000001b1', '00000000-7777-0000-0000-0000000000b1'),
             ('00000000-7777-0000-0000-0000000001e1', '00000000-7777-0000-0000-0000000000e1')) l(id, m);
insert into public.lead_deliveries (id, lead_id, contractor_id, delivered_at, price_cents) values
  ('00000000-7777-0000-0000-0000000002a1', '00000000-7777-0000-0000-0000000001a1', '00000000-7777-0000-0000-0000000000d1', '2026-01-05 10:05+00', 4000),
  ('00000000-7777-0000-0000-0000000002a2', '00000000-7777-0000-0000-0000000001a2', '00000000-7777-0000-0000-0000000000d1', '2026-01-05 10:05+00', 3000),
  ('00000000-7777-0000-0000-0000000002a3', '00000000-7777-0000-0000-0000000001a3', '00000000-7777-0000-0000-0000000000d1', '2026-02-05 10:05+00', 2000),
  ('00000000-7777-0000-0000-0000000002b1', '00000000-7777-0000-0000-0000000001b1', '00000000-7777-0000-0000-0000000000d1', '2026-01-05 10:05+00', 5500),
  ('00000000-7777-0000-0000-0000000002e1', '00000000-7777-0000-0000-0000000001e1', '00000000-7777-0000-0000-0000000000d1', '2026-01-05 10:05+00', 1000);
insert into public.invoices (id, client_id, period_start, period_end) values
  ('00000000-7777-0000-0000-000000000a11', '00000000-7777-0000-0000-00000000000a', '2026-01-01', '2026-01-31'),
  ('00000000-7777-0000-0000-000000000a12', '00000000-7777-0000-0000-00000000000a', '2026-02-01', '2026-02-28'),
  ('00000000-7777-0000-0000-000000000a13', '00000000-7777-0000-0000-00000000000a', '2026-03-01', '2026-03-31'),
  ('00000000-7777-0000-0000-000000000b11', '00000000-7777-0000-0000-00000000000b', '2026-01-01', '2026-01-31');
insert into public.invoice_lines (invoice_id, lead_delivery_id) values
  ('00000000-7777-0000-0000-000000000a11', '00000000-7777-0000-0000-0000000002a1'),
  ('00000000-7777-0000-0000-000000000a11', '00000000-7777-0000-0000-0000000002a2'),
  ('00000000-7777-0000-0000-000000000a12', '00000000-7777-0000-0000-0000000002a3'),
  ('00000000-7777-0000-0000-000000000b11', '00000000-7777-0000-0000-0000000002b1');

-- ------------------------------------------------------------ drafts
select pg_temp.expect_msg($$insert into public.invoices (client_id, period_start, period_end, issued_at) values ('00000000-7777-0000-0000-00000000000b', '2026-05-01', '2026-05-31', now())$$, '%invoices start as drafts%', 'an invoice cannot be created already issued');
select pg_temp.expect_msg($$insert into public.invoices (client_id, period_start, period_end, invoice_number) values ('00000000-7777-0000-0000-00000000000b', '2026-05-01', '2026-05-31', 'INV-999999')$$, '%invoices start as drafts%', 'a number cannot be chosen at creation');
select pg_temp.expect_msg($$update public.invoices set invoice_number = 'INV-000042' where id = '00000000-7777-0000-0000-000000000a11'$$, '%assigned by the database%', 'a number cannot be chosen by hand on a draft');
select pg_temp.expect_msg($$update public.invoices set issued_at = now() where id = '00000000-7777-0000-0000-000000000a13'$$, '%no lines cannot be issued%', 'an invoice with no lines cannot be issued');
update public.invoices set period_end = '2026-01-30' where id = '00000000-7777-0000-0000-000000000a11';
update public.invoices set period_end = '2026-01-31' where id = '00000000-7777-0000-0000-000000000a11';
select pg_temp.ok(true, 'a draft can still be edited');
select pg_temp.expect($$update public.invoices set client_id = '00000000-7777-0000-0000-00000000000b' where id = '00000000-7777-0000-0000-000000000a11'$$, '23514', 'a draft that has lines cannot move to another client');
delete from public.invoice_lines where lead_delivery_id = '00000000-7777-0000-0000-0000000002a2';
insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('00000000-7777-0000-0000-000000000a11', '00000000-7777-0000-0000-0000000002a2');
select pg_temp.ok(true, 'lines can be removed from and added to a draft');

-- ------------------------------------------------------------ issuing
update public.invoices set issued_at = now() where id = '00000000-7777-0000-0000-000000000a11';
select pg_temp.ok((select invoice_number from public.invoices where id = '00000000-7777-0000-0000-000000000a11') = 'INV-000001', 'issuing assigns the first number of that client: INV-000001');

-- an issued invoice is frozen
select pg_temp.expect($$update public.invoices set period_end = '2026-01-15' where id = '00000000-7777-0000-0000-000000000a11'$$, '23514', 'an issued invoice''s period is fixed');
select pg_temp.expect($$update public.invoices set client_id = '00000000-7777-0000-0000-00000000000b' where id = '00000000-7777-0000-0000-000000000a11'$$, '23514', 'an issued invoice cannot change client');
select pg_temp.expect($$update public.invoices set currency = 'EUR' where id = '00000000-7777-0000-0000-000000000a11'$$, '23514', 'an issued invoice cannot change currency');
select pg_temp.expect($$update public.invoices set issued_at = null, invoice_number = null where id = '00000000-7777-0000-0000-000000000a11'$$, '23514', 'an issued invoice cannot be un-issued');
select pg_temp.expect($$update public.invoices set invoice_number = 'INV-000009' where id = '00000000-7777-0000-0000-000000000a11'$$, '23514', 'an issued invoice cannot be renumbered');
select pg_temp.expect($$delete from public.invoices where id = '00000000-7777-0000-0000-000000000a11'$$, '23514', 'an issued invoice cannot be deleted');
select pg_temp.expect($$insert into public.invoice_lines (invoice_id, lead_delivery_id) select '00000000-7777-0000-0000-000000000a11', '00000000-7777-0000-0000-0000000002a3'$$, '23514', 'a line cannot be added to an issued invoice');
select pg_temp.expect($$delete from public.invoice_lines where lead_delivery_id = '00000000-7777-0000-0000-0000000002a1'$$, '23514', 'a line cannot be removed from an issued invoice');
select pg_temp.expect($$update public.invoice_lines set invoice_id = '00000000-7777-0000-0000-000000000a12' where lead_delivery_id = '00000000-7777-0000-0000-0000000002a1'$$, '23514', 'a line cannot be moved off an issued invoice');
select pg_temp.expect($$update public.invoice_lines set invoice_id = '00000000-7777-0000-0000-000000000a11' where lead_delivery_id = '00000000-7777-0000-0000-0000000002a3'$$, '23514', 'a line cannot be moved onto an issued invoice');
select pg_temp.expect($$update public.invoice_lines set lead_delivery_id = '00000000-7777-0000-0000-0000000002a3' where lead_delivery_id = '00000000-7777-0000-0000-0000000002a1'$$, '23514', 'a line on an issued invoice cannot point at another delivery');
select pg_temp.expect($$update public.lead_deliveries set price_cents = 1 where id = '00000000-7777-0000-0000-0000000002a1'$$, '23514', 'a billed delivery keeps its price');
select pg_temp.expect($$truncate public.invoices cascade$$, '42501', 'invoices cannot be truncated');
select pg_temp.expect($$truncate public.invoice_lines$$, '42501', 'invoice lines cannot be truncated');

-- ------------------------------------------------------------ numbering
do $$ begin                                  -- an issue that rolls back must not use up a number
  begin
    update public.invoices set issued_at = now() where id = '00000000-7777-0000-0000-000000000a12';
    raise exception 'abort' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;
end $$;
select pg_temp.ok((select last_number from private.document_counters where client_id = '00000000-7777-0000-0000-00000000000a' and series = 'invoice') = 1, 'a rolled-back issue does not use up a number');
update public.invoices set issued_at = '1999-01-01 00:00+00' where id = '00000000-7777-0000-0000-000000000a12';   -- a caller-chosen time must be ignored
select pg_temp.ok((select invoice_number from public.invoices where id = '00000000-7777-0000-0000-000000000a12') = 'INV-000002', 'the next invoice of the client is INV-000002: no gap');
update public.invoices set issued_at = now() where id = '00000000-7777-0000-0000-000000000b11';
select pg_temp.ok((select invoice_number from public.invoices where id = '00000000-7777-0000-0000-000000000b11') = 'INV-000001', 'another client starts its own series at INV-000001');

select pg_temp.ok((select abs(extract(epoch from clock_timestamp() - issued_at)) < 60 from public.invoices where id = '00000000-7777-0000-0000-000000000a12'), 'issued_at is the real issue time, whatever the caller sent');
select pg_temp.ok((select (select issued_at from public.invoices where invoice_number = 'INV-000001' and client_id = '00000000-7777-0000-0000-00000000000a')
                        < (select issued_at from public.invoices where invoice_number = 'INV-000002' and client_id = '00000000-7777-0000-0000-00000000000a')), 'INV-000001 was issued before INV-000002: numbers and dates run in the same order');

-- the unique rule and the check, tested with the guard switched off (owner only; rolled back with the test)
alter table public.invoices disable trigger invoices_guard;
select pg_temp.expect($$insert into public.invoices (client_id, currency, period_start, period_end, issued_at, invoice_number) values ('00000000-7777-0000-0000-00000000000a', 'USD', '2026-06-01', '2026-06-30', now(), 'INV-000001')$$, '23505', 'one client cannot have two invoices with the same number');
select pg_temp.expect($$insert into public.invoices (client_id, currency, period_start, period_end, issued_at) values ('00000000-7777-0000-0000-00000000000a', 'USD', '2026-07-01', '2026-07-31', now())$$, '23514', 'the table itself refuses an issued invoice with no number');
select pg_temp.expect($$insert into public.invoices (client_id, currency, period_start, period_end, invoice_number) values ('00000000-7777-0000-0000-00000000000a', 'USD', '2026-08-01', '2026-08-31', 'INV-000007')$$, '23514', 'the table itself refuses a number on an unissued invoice');
alter table public.invoices enable trigger invoices_guard;

-- ------------------------------------------------------------ the chain a delivery belongs to is write-once
select pg_temp.expect($$update public.markets set client_id = '00000000-7777-0000-0000-00000000000b' where id = '00000000-7777-0000-0000-0000000000a1'$$, '23514', 'a market cannot move to another client');
select pg_temp.expect($$update public.leads set market_id = '00000000-7777-0000-0000-0000000000b1' where id = '00000000-7777-0000-0000-0000000001a1'$$, '23514', 'a lead cannot move to another market');
select pg_temp.expect($$update public.lead_deliveries set lead_id = '00000000-7777-0000-0000-0000000001b1' where id = '00000000-7777-0000-0000-0000000002a1'$$, '23514', 'a delivery cannot move to another lead');
select pg_temp.expect($$update public.clients set currency = 'EUR' where id = '00000000-7777-0000-0000-00000000000a'$$, '23514', 'a client''s currency cannot change');
update public.markets set name = 'A-Dallas-2' where id = '00000000-7777-0000-0000-0000000000a1';
select pg_temp.ok(true, 'other market columns can still be edited');

-- ------------------------------------------------------------ currency
select pg_temp.expect($$insert into public.invoices (client_id, currency, period_start, period_end) values ('00000000-7777-0000-0000-00000000000e', 'USD', '2026-01-01', '2026-01-31')$$, '23503', 'a EUR client cannot be invoiced in USD');
select pg_temp.expect($$insert into public.invoices (client_id, currency, period_start, period_end) values ('00000000-7777-0000-0000-00000000000a', 'usd', '2026-09-01', '2026-09-30')$$, '23514', 'currency must be three capital letters');
insert into public.invoices (id, client_id, currency, period_start, period_end) values ('00000000-7777-0000-0000-000000000e11', '00000000-7777-0000-0000-00000000000e', 'EUR', '2026-01-01', '2026-01-31');
insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('00000000-7777-0000-0000-000000000e11', '00000000-7777-0000-0000-0000000002e1');
update public.invoices set issued_at = now() where id = '00000000-7777-0000-0000-000000000e11';
select pg_temp.ok((select currency from public.invoices where id = '00000000-7777-0000-0000-000000000e11') = 'EUR', 'a EUR client is invoiced in EUR');

-- the invoice takes its client's currency when none is given; a client's currency can be corrected until money is recorded
insert into public.clients (id, name, currency) values ('00000000-7777-0000-0000-0000000000f0', 'Bill F', 'USD');
update public.clients set currency = 'GBP' where id = '00000000-7777-0000-0000-0000000000f0';
select pg_temp.ok((select currency from public.clients where id = '00000000-7777-0000-0000-0000000000f0') = 'GBP', 'a client with no money recorded can still have its currency corrected');
insert into public.invoices (id, client_id, period_start, period_end) values ('00000000-7777-0000-0000-000000000f11', '00000000-7777-0000-0000-0000000000f0', '2026-01-01', '2026-01-31');
select pg_temp.ok((select currency from public.invoices where id = '00000000-7777-0000-0000-000000000f11') = 'GBP', 'an invoice left without a currency takes its client''s (GBP), not a default');
select pg_temp.expect_msg($$update public.clients set currency = 'USD' where id = '00000000-7777-0000-0000-0000000000f0'$$, '%currency cannot change%', 'once an invoice exists the client''s currency is fixed');
select pg_temp.expect_msg($$update public.clients set currency = 'GBP' where id = '00000000-7777-0000-0000-00000000000b'$$, '%currency cannot change%', 'and so is it once deliveries exist');
select pg_temp.expect($$insert into public.invoices (client_id, period_start, period_end) values ('00000000-7777-0000-0000-0000000fffff', '2026-01-01', '2026-01-31')$$, '23503', 'an invoice for a client that does not exist is a foreign-key error');

-- the database stamps the issue time, under the counter lock, so numbers and dates agree
-- ------------------------------------------------------------ credit notes
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a13', 'USD', 100, 'x')$$, '23514', 'a draft is edited, not credited');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'USD', 0, 'zero')$$, '23514', 'a credit of zero is refused');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'USD', 100, '  ')$$, '23514', 'a credit note needs a reason');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason, credit_number) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'USD', 100, 'x', 'CN-000777')$$, '23514', 'a credit number cannot be chosen');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000b', '00000000-7777-0000-0000-000000000a11', 'USD', 100, 'wrong client')$$, '23503', 'a credit note must belong to the invoice''s client');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'EUR', 100, 'wrong currency')$$, '23503', 'a credit note must be in the invoice''s currency');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-0000000fffff', 'USD', 100, 'ghost')$$, '23503', 'a credit note must point at a real invoice');

insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values
  ('00000000-7777-0000-0000-0000000c0001', '00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'USD', 2000, 'one lead was a duplicate');
select pg_temp.ok((select credit_number from public.credit_notes where id = '00000000-7777-0000-0000-0000000c0001') = 'CN-000001', 'the first credit note is CN-000001 (its own series)');
insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values
  ('00000000-7777-0000-0000-0000000c0002', '00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'USD', 3000, 'price correction');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'USD', 2001, 'one cent too much')$$, '23514', 'credits cannot exceed the invoice total (7000 - 5000 = 2000 left)');
insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values
  ('00000000-7777-0000-0000-0000000c0003', '00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'USD', 2000, 'the rest');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a11', 'USD', 1, 'nothing left')$$, '23514', 'a fully credited invoice takes no more credit');
select pg_temp.expect($$update public.credit_notes set amount_cents = 1 where id = '00000000-7777-0000-0000-0000000c0001'$$, '23514', 'a credit note cannot be edited');
select pg_temp.expect($$delete from public.credit_notes where id = '00000000-7777-0000-0000-0000000c0001'$$, '23514', 'a credit note cannot be deleted');
select pg_temp.expect($$truncate public.credit_notes$$, '42501', 'credit notes cannot be truncated');
select pg_temp.ok((select total_cents = 7000 and credited_cents = 7000 and net_cents = 0 and invoice_number = 'INV-000001' from public.invoice_balances where invoice_id = '00000000-7777-0000-0000-000000000a11'),
                  'invoice_balances: total 7000, credited 7000, net 0 (calculated, not stored)');
select pg_temp.ok((select total_cents = 7000 and line_count = 2 from public.invoice_totals where invoice_id = '00000000-7777-0000-0000-000000000a11'), 'the invoice itself still totals 7000: history was not rewritten');

-- a retried INSERT ... ON CONFLICT DO NOTHING must not use up credit numbers
insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values
  ('00000000-7777-0000-0000-0000000c00e1', '00000000-7777-0000-0000-00000000000e', '00000000-7777-0000-0000-000000000e11', 'EUR', 100, 'first');
insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values
  ('00000000-7777-0000-0000-0000000c00e1', '00000000-7777-0000-0000-00000000000e', '00000000-7777-0000-0000-000000000e11', 'EUR', 100, 'first') on conflict (id) do nothing;
insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values
  ('00000000-7777-0000-0000-0000000c00e1', '00000000-7777-0000-0000-00000000000e', '00000000-7777-0000-0000-000000000e11', 'EUR', 100, 'first') on conflict (id) do nothing;
insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values
  ('00000000-7777-0000-0000-0000000c00e2', '00000000-7777-0000-0000-00000000000e', '00000000-7777-0000-0000-000000000e11', 'EUR', 200, 'second');
select pg_temp.ok((select string_agg(credit_number, ',' order by credit_number) from public.credit_notes where client_id = '00000000-7777-0000-0000-00000000000e') = 'CN-000001,CN-000002',
                  'two retried inserts used no numbers: the next credit note is CN-000002, not CN-000004');
select pg_temp.expect($$insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-0000000c00e1', '00000000-7777-0000-0000-00000000000e', '00000000-7777-0000-0000-000000000e11', 'EUR', 100, 'dup')$$, '23505', 'a plain duplicate insert still fails on the primary key');
select pg_temp.expect_msg($$insert into public.credit_notes (id, client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-0000000c00e1', '00000000-7777-0000-0000-00000000000e', '00000000-7777-0000-0000-000000000e11', 'EUR', 100, 'x') on conflict (id) do update set amount_cents = 1$$, '%never edited%', 'ON CONFLICT DO UPDATE cannot edit a credit note');

-- service_role keeps what it needs and loses what it does not
select pg_temp.ok(not has_table_privilege('service_role', 'public.credit_notes', 'update') and not has_table_privilege('service_role', 'public.credit_notes', 'delete')
              and has_table_privilege('service_role', 'public.credit_notes', 'insert'), 'service_role can insert credit notes but not update or delete them');
set local role service_role;
select pg_temp.expect($$create trigger zz_probe before update on public.invoices for each row execute function suppress_redundant_updates_trigger()$$, '42501', 'service_role cannot attach its own trigger to a table');
select pg_temp.expect($$truncate public.memberships$$, '42501', 'service_role cannot truncate (a truncate leaves no audit row)');
select pg_temp.ok((select count(*) from public.invoices) > 0, 'but it can still read');
reset role;

-- ------------------------------------------------------------ audit
select pg_temp.ok((select count(*) from audit.log where table_name = 'invoices' and op = 'UPDATE' and row_id = '00000000-7777-0000-0000-000000000a11'
                   and old_row ->> 'issued_at' is null and new_row ->> 'invoice_number' = 'INV-000001') = 1, 'the audit log recorded the moment invoice INV-000001 was issued');
select pg_temp.ok((select count(*) from audit.log where table_name = 'credit_notes' and op = 'INSERT') = 5, 'the audit log recorded the five credit notes (and nothing for the retried inserts that did nothing)');

-- ------------------------------------------------------------ who can read them
insert into auth.users (id, email) values ('11111111-7777-7777-7777-777777777777', 'a@example.test'), ('22222222-7777-7777-7777-777777777777', 'b@example.test');
insert into public.memberships (user_id, client_id, role) values
  ('11111111-7777-7777-7777-777777777777', '00000000-7777-0000-0000-00000000000a', 'owner'),
  ('22222222-7777-7777-7777-777777777777', '00000000-7777-0000-0000-00000000000b', 'owner');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-7777-7777-7777-777777777777","role":"authenticated"}', true);
select pg_temp.ok((select count(*) from public.credit_notes) = 3, 'owner A reads the 3 credit notes of client A');
select pg_temp.ok((select count(*) from public.invoice_balances) = 3, 'owner A reads only client A''s three invoice balances (two issued, one draft)');
select pg_temp.expect($$insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('00000000-7777-0000-0000-00000000000a', '00000000-7777-0000-0000-000000000a12', 'USD', 1, 'x')$$, '42501', 'an app user cannot write a credit note');
select pg_temp.expect($$update public.invoices set period_end = period_end$$, '42501', 'an app user cannot touch invoices');
select pg_temp.expect($$select * from private.document_counters$$, '42501', 'the number counters are not readable by app users');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-7777-7777-7777-777777777777","role":"authenticated"}', true);
select pg_temp.ok((select count(*) from public.credit_notes) = 0 and (select count(*) from public.invoice_balances) = 1, 'owner B sees no credit note of A and only B''s own balance');
reset role;
set local role anon;
select pg_temp.expect($$select * from public.credit_notes$$, '42501', 'anon cannot read credit notes');
select pg_temp.expect($$select * from public.invoice_balances$$, '42501', 'anon cannot read invoice balances');
reset role;
rollback;
