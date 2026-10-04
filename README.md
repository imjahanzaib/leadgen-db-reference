# leadgen-db-reference

A reference **Postgres / Supabase** schema for a home-services lead-generation platform, with tests that prove it works.
Synthetic data only. Client databases are under NDA, so this is a design I built to show how I work.

It covers the parts that usually go wrong on a growing platform:

- **Constraints that do the policing.** Bad data is refused by the database, not left to the app.
- **Row-level security on every table**, tested with several users, anonymous access and the service role.
- **One shared audit log** that application roles cannot read.
- **Moving data from a spreadsheet-style store**, reconciled to the cent, with three data checks (duplicates, dangling links, stored totals that no longer match).
- **Adding a required foreign-key column to a busy table without blocking writes**, measured with a live writer.

![schema](docs/erd.png)

## Run it
Needs a local PostgreSQL 15+ (`psql` on your PATH; tested on 15.14). It rebuilds a scratch database called `leadgen_demo` and runs every test in about a minute:

```bash
./run_tests.sh
```

`local/00_supabase_shim.sql` only stands in for what a hosted Supabase project already has (the `anon`, `authenticated` and `service_role` roles, `auth.users`, `auth.uid()`) so the security rules can be tested locally. It is not part of the migrations. The migrations in `supabase/migrations/` are plain SQL. I have run the suite locally; I have not pushed this to a hosted Supabase project yet.

## What the last run showed
| test | result |
|---|---|
| `01_constraints` | 14 checks pass: duplicate client spellings, a second budget for the same month, negative amounts, double billing, another client's delivery on an invoice, a changed price on a billed delivery |
| `02_rls` | 18 checks pass: three users on two clients, a read-only viewer, no identity, anonymous, service role, views obey RLS, audit log unreadable |
| `03_import_and_checks` | 12 checks pass: 12 rows in = 8 loaded + 4 rejected with reasons, 863,100 cents in = out, loaded rows equal a hand-written expected set in both directions, a second run adds nothing, the 3 data checks find the planted defects |
| `04_online_column` | 500,000 leads, a required FK column added while a writer kept inserting: backfill about 10 s in batches, worst live insert under 100 ms (52 ms and 88 ms on two runs) over about 3,000 live inserts, 0 errors |

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
supabase/migrations/   three migrations: core schema, audit + guards + RLS, legacy import
seed/                  synthetic spreadsheet-style data with planted defects
tests/                 four test files and a helper
local/                 stand-in for Supabase roles and auth.uid() (local testing only)
docs/                  schema diagram
```

MIT licensed. Jahanzaib Ahmed.
