-- SYNTHETIC data with planted defects. No real client, person or number.
insert into legacy.budget_sheet (row_no, client_name, market_name, service, month_label, budget_text) values
 (1,  'Acme Roofing',     'Dallas',  'Roofing',  'Jan-2026',     '$1,250.00'),
 (2,  'ACME  roofing',    'Dallas',  'Gutters',  'Jan-2026',     '$400.00'),      -- same client, other spelling
 (3,  'acme roofing ',    'Austin',  'Roofing',  'January 2026', '$980.50'),      -- same client again
 (4,  'Blue Door Paint',  'Denver',  'Painting', '2026-01',      '2,100'),
 (5,  'Blue Door Paint',  'Denver',  'Painting', 'Feb-2026',     '2,300'),
 (6,  'Blue Door Paint',  'Denver',  'Painting', 'Feb-2026',     '2,350'),        -- duplicate key: rejected
 (7,  'Cedar HVAC',       'Boise',   'HVAC',     'Mar-2026',     'TBD'),          -- unreadable amount: rejected
 (8,  'Cedar HVAC',       'Boise',   'HVAC',     'Spring',       '$900'),         -- unreadable month: rejected
 (9,  'Cedar HVAC',       'Boise',   'HVAC',     'Apr-2026',     '$1,000.00'),
 (10, 'Delta Pools',      'Tampa',   'Pool Care','Jan-2026',     '$300.25'),
 (11, 'Delta Pools',      'Tampa',   'Pool Care','Feb-2026',     '$300.25'),
 (12, NULL,               'Tampa',   'Pool Care','Mar-2026',     '$300.25');      -- missing client: rejected
insert into legacy.sheet_leads values ('L-1','Dallas'),('L-2','Dallas'),('L-3','Austin');
insert into legacy.sheet_deliveries values (1,'L-1','Pro A','$40'),(2,'L-2','Pro B','$40'),(3,'L-9','Pro A','$40'),(4,'L-3','Pro C','$55'),(5,'L-77','Pro C','$55');  -- L-9, L-77 do not exist
insert into legacy.sheet_invoices values ('INV-1','$80.00'),('INV-2','$120.00'),('INV-3','$55.00');
insert into legacy.sheet_invoice_lines values (1,'INV-1','$40'),(2,'INV-1','$40'),(3,'INV-2','$40'),(4,'INV-2','$40'),(5,'INV-3','$55');  -- INV-2 stored 120, details 80

-- Run the import, then show the reconciliation in one row.
select legacy.import_budgets();

select r.rows_in, r.rows_loaded, r.rows_rejected,
       r.cents_in, r.cents_loaded, r.cents_rejected,
       (select sum(amount_cents) from public.market_budgets where created_at >= r.run_at - interval '1 minute') as cents_in_new_tables,
       (select count(*) from public.clients where source_system = 'sheet') as clients_created,
       (select count(*) from legacy.dup_clients) as duplicate_client_groups,
       (select count(*) from legacy.orphan_deliveries) as dangling_links,
       (select count(*) from legacy.total_mismatch) as stored_total_mismatches
from legacy.import_report r order by r.id desc limit 1;
