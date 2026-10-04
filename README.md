# leadgen-db-reference

A reference **Postgres / Supabase** schema for a home-services lead-generation platform, with tests that prove it works.
Synthetic data only. Client databases are under NDA, so this is a design I built to show how I work.

It covers the parts that usually go wrong on a growing platform:

- **Constraints that do the policing.** Bad data is refused by the database, not left to the app.
- **Row-level security on every table**, tested with several users, anonymous access and the service role.
- **One shared audit log** that application roles cannot read.
- **Moving data from a spreadsheet-style store**, reconciled to the cent, with three data checks (duplicates, dangling links, stored totals that no longer match).
- **Adding a required foreign-key column to a busy table without blocking writes**, measured with a live writer.

It has been run and checked on a **hosted Supabase project** as well as locally (details below).

![schema](docs/erd.png)

## Run it
Needs a local PostgreSQL 15+ (`psql` on your PATH; tested on 15.14). It rebuilds a scratch database called `leadgen_demo` and runs every test in about a minute:

```bash
./run_tests.sh
```

`local/00_supabase_shim.sql` only stands in for what a hosted Supabase project already has (the `anon`, `authenticated` and `service_role` roles, `auth.users`, `auth.uid()`) so the security rules can be tested locally. It is not part of the migrations. The migrations in `supabase/migrations/` are plain SQL.

### On a hosted Supabase project
1. Create a project (the Free plan is enough). Settings used: Data API **on**, "Automatically expose new tables" **off**, "Enable automatic RLS" **on**.
2. In the SQL editor, run the four files in `supabase/migrations/` in order. The editor shows a "destructive operations" notice for the import function; it only drops a temp table and deletes from an empty staging table.
3. Run `tests/supabase_verify.sql`. It returns 21 rows, all `true`, and changes nothing (every fixture is rolled back). It uses the real `anon`, `authenticated` and `service_role` roles and the real `auth.uid()`.
4. Optional: run `seed/demo_import.sql` to load the synthetic spreadsheet export and see the reconciliation row.

## What the last run showed
| test | result |
|---|---|
| `01_constraints` | 14 checks pass: duplicate client spellings, a second budget for the same month, negative amounts, double billing, another client's delivery on an invoice, a changed price on a billed delivery |
| `02_rls` | 18 checks pass: three users on two clients, a read-only viewer, no identity, anonymous, service role, views obey RLS, audit log unreadable |
| `03_import_and_checks` | 12 checks pass: 12 rows in = 8 loaded + 4 rejected with reasons, 863,100 cents in = out, loaded rows equal a hand-written expected set in both directions, a second run adds nothing, the 3 data checks find the planted defects |
| `04_online_column` | 500,000 leads, a required FK column added while a writer kept inserting: backfill about 10 s in batches, worst live insert under 100 ms (52 ms and 88 ms on two runs) over about 3,000 live inserts, 0 errors |
| hosted Supabase, 2026-10-05 | `supabase_verify.sql`: 21 of 21 checks `true`. `demo_import.sql`: 12 rows in = 8 loaded + 4 rejected, 863,100 cents in = out, 4 clients created, all 3 planted problems found. Security Advisor: 0 errors, 0 warnings, 8 info |

## What running it on Supabase changed
Running the migrations on a real project found three things the local tests could not:
- The SQL editor warned that the `legacy` staging tables had no RLS. They are in a schema the API does not expose and the app roles cannot enter, but the rule here is RLS on every table, so migration 3 now enables it on them.
- Security Advisor flagged six of my functions for a mutable `search_path`, and Supabase's own `public.rls_auto_enable()` (created by the automatic-RLS option) as callable by signed-in users. Migration 4 pins the `search_path` and closes that function to the API roles; a probe table confirmed automatic RLS still fires afterwards.
- The 8 remaining Advisor items are informational "RLS enabled, no policy" notes on `audit.log` and the 7 staging tables. That is intentional: with RLS on and no policy, only the owner and the service role can read them.

## Design standards used
| standard | where |
|---|---|
| One fact per column; nothing stored that can be calculated | `invoices` has no total: `invoice_totals` and `budget_vs_spend` are views; `clients.name_key` is a generated column |
| Store the finest detail | one row per delivered lead (`lead_deliveries.price_cents`); money as integer cents |
| `timestamptz`, uuid keys, outside ids kept exactly as given | everywhere; `source_system` + `source_id` kept and unique |
| Every link is a foreign key | all links; `on delete restrict` on the money path |
| Every "only one X per Y" is a unique constraint | one budget per market, service and month; one delivery per lead and contractor; a delivery is billed once; one live client per normalised name |
| Row-level security on every table; one shared audit log | all 10 public tables; `audit.log` has RLS on and no policy |

## Design notes
**A budget per market, service type and month.** `clients` -> `markets(client_id)` -> `market_budgets(market_id, service_type_id, budget_month, amount_cents)` with `UNIQUE (market_id, service_type_id, budget_month)`. The service type is a reference table, not text. `budget_month` is a `date` with a check that it is the first of a month, so a month has one spelling.

**Proving a data move lost and duplicated nothing.** Rows in = loaded + rejected, and money in = loaded + rejected, with every rejected row stored with a reason. Then compare the loaded rows with an independently written expected list, both ways (`EXCEPT` in each direction must be empty). The import is one transaction and can run twice. Outside ids stay on every row so each one traces to its source line.

**A required foreign key on a large busy table.** Add the column nullable (metadata only). A trigger fills new rows. Backfill old rows in small committed batches. `CREATE INDEX CONCURRENTLY`. Add the foreign key `NOT VALID`, then `VALIDATE` (scans without blocking writes). Add `CHECK (col IS NOT NULL) NOT VALID`, validate it, `SET NOT NULL` (Postgres skips the scan), drop the check. Set `lock_timeout` so DDL gives up instead of queueing behind a long transaction.

**Testing a migration before it touches real data.** Run it on a copy inside a transaction with `lock_timeout`, run assertions like the ones in `tests/`, compare query plans at realistic row counts, read the audit log, then review it statement by statement before production.

**What is deliberately not here.** The audit trigger is attached to low-volume tables only. For high-volume tables (leads, deliveries) use `pgaudit` or logical decoding instead of a row trigger on the hot path.

## Layout
```
supabase/migrations/   four migrations: core schema, audit + guards + RLS, legacy import, function hardening
seed/                  synthetic spreadsheet-style data with planted defects; demo_import.sql runs it end to end
tests/                 four test files, a helper, and supabase_verify.sql (21 checks, runs in the Supabase SQL editor)
local/                 stand-in for Supabase roles and auth.uid() (local testing only)
docs/                  schema diagram
```

MIT licensed. Jahanzaib Ahmed.
