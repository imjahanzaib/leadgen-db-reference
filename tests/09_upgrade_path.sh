#!/usr/bin/env bash
# A fresh database proves the migrations run. This proves they also run on a database that already holds data:
# audit rows keep their ids, invoices that were issued get numbers, bad time zones stop the migration cleanly.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${1:-leadgen_demo}"; DB="${BASE}_upgrade"
P="psql -d $DB -v ON_ERROR_STOP=1 -q -At"
build() { psql -d postgres -q -c "drop database if exists $DB" -c "create database $DB"; $P -f local/00_supabase_shim.sql >/dev/null; }
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; exit 1; }
echo "== 09 upgrade path: migrations 5-7 applied on top of a database that already has data"

build
for f in supabase/migrations/2026100500000[1-4]_*.sql; do $P -f "$f" >/dev/null 2>&1; done   # the state before this work
$P >/dev/null <<'SQL'
insert into auth.users (id, email) values ('11111111-9999-9999-9999-999999999999', 'u@example.test');
insert into public.clients (id, name) values ('00000000-9999-0000-0000-00000000000a', 'Up A'), ('00000000-9999-0000-0000-00000000000b', 'Up B');
insert into public.memberships (user_id, client_id, role) values ('11111111-9999-9999-9999-999999999999', '00000000-9999-0000-0000-00000000000a', 'owner');
insert into public.markets (id, client_id, name, timezone) values
  ('00000000-9999-0000-0000-0000000000a1', '00000000-9999-0000-0000-00000000000a', 'Dallas', 'America/Chicago'),
  ('00000000-9999-0000-0000-0000000000b1', '00000000-9999-0000-0000-00000000000b', 'Denver', 'America/Denver');
update public.markets set name = 'Dallas TX' where id = '00000000-9999-0000-0000-0000000000a1';
insert into public.service_types (id, code, name) values ('00000000-9999-0000-0000-0000000000c1', 'roofing', 'Roofing');
insert into public.contractors (id, name) values ('00000000-9999-0000-0000-0000000000d1', 'Pro');
insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at)
  select ('00000000-9999-0000-0001-' || lpad(g::text, 12, '0'))::uuid, case when g <= 3 then '00000000-9999-0000-0000-0000000000a1' else '00000000-9999-0000-0000-0000000000b1' end::uuid,
         '00000000-9999-0000-0000-0000000000c1', 'up', g::text, '2026-01-10 10:00+00' from generate_series(1, 4) g;
insert into public.lead_deliveries (id, lead_id, contractor_id, delivered_at, price_cents)
  select ('00000000-9999-0000-0002-' || lpad(g::text, 12, '0'))::uuid, ('00000000-9999-0000-0001-' || lpad(g::text, 12, '0'))::uuid,
         '00000000-9999-0000-0000-0000000000d1', '2026-01-10 10:05+00', 1000 * g from generate_series(1, 4) g;
-- client A: a Feb invoice issued BEFORE the Jan one (so oldest-first numbering is visible), plus a draft; client B: one issued
insert into public.invoices (id, client_id, period_start, period_end, issued_at) values
  ('00000000-9999-0000-0003-000000000001', '00000000-9999-0000-0000-00000000000a', '2026-02-01', '2026-02-28', '2026-03-01 09:00+00'),
  ('00000000-9999-0000-0003-000000000002', '00000000-9999-0000-0000-00000000000a', '2026-01-01', '2026-01-31', '2026-03-05 09:00+00'),
  ('00000000-9999-0000-0003-000000000003', '00000000-9999-0000-0000-00000000000a', '2026-03-01', '2026-03-31', null),
  ('00000000-9999-0000-0003-000000000004', '00000000-9999-0000-0000-00000000000b', '2026-01-01', '2026-01-31', '2026-03-02 09:00+00');
insert into public.invoice_lines (invoice_id, lead_delivery_id) values
  ('00000000-9999-0000-0003-000000000001', '00000000-9999-0000-0002-000000000001'),
  ('00000000-9999-0000-0003-000000000002', '00000000-9999-0000-0002-000000000002'),
  ('00000000-9999-0000-0003-000000000003', '00000000-9999-0000-0002-000000000003'),
  ('00000000-9999-0000-0003-000000000004', '00000000-9999-0000-0002-000000000004');
SQL
BEFORE="$($P -c "select count(*) || ':' || max(id) || ':' || md5(string_agg(id || table_name || op || coalesce(row_id, '') || coalesce(old_row::text, '') || coalesce(new_row::text, ''), '|' order by id)) from audit.log")"
N0="${BEFORE%%:*}"
for f in supabase/migrations/2026100500000[5-7]_*.sql; do $P -f "$f" >/dev/null 2>&1 || fail "migration $f failed on a database with data"; done
pass "migrations 5, 6 and 7 applied on a database that already had data"

# rows that were there before: count, max id and a checksum over every column that existed
OLD_MAX="$(echo "$BEFORE" | cut -d: -f2)"
AFTER="$($P -c "select count(*) || ':' || max(id) || ':' || md5(string_agg(id || table_name || op || coalesce(row_id, '') || coalesce(old_row::text, '') || coalesce(new_row::text, ''), '|' order by id)) from audit.log where id <= $OLD_MAX")"
[ "$BEFORE" = "$AFTER" ] && pass "all $N0 old audit rows survived with the same ids and the same content" || fail "audit rows changed: $BEFORE vs $AFTER"
[ "$($P -c "select bool_and(txid is null and jwt_role is null and request_id is null) from audit.log where id <= $OLD_MAX")" = t ] && pass "old rows have NULL for what was not recorded then (nothing invented)" || fail "old rows got invented context"
$P -c "insert into public.clients (name) values ('Up New')" >/dev/null
[ "$($P -c "select min(id) > $OLD_MAX from audit.log where new_row ->> 'name' = 'Up New'")" = t ] && pass "new audit rows continue after the old ids" || fail "identity restarted"
[ "$($P -c "select bool_and(tableoid::regclass::text = 'audit.log_' || to_char(at at time zone 'UTC', 'YYYY_MM')) from audit.log")" = t ] && pass "every row, old and new, sits in the partition of its month" || fail "rows in wrong partitions"

[ "$($P -c "select string_agg(invoice_number, ',' order by issued_at) from public.invoices where client_id = '00000000-9999-0000-0000-00000000000a' and issued_at is not null")" = "INV-000001,INV-000002" ] \
  && pass "client A's two already-issued invoices were numbered oldest first" || fail "numbering wrong"
[ "$($P -c "select invoice_number from public.invoices where id = '00000000-9999-0000-0003-000000000001'")" = "INV-000001" ] && pass "the one issued first (1 Mar) is INV-000001, though its period is later" || fail "order wrong"
[ "$($P -c "select invoice_number from public.invoices where id = '00000000-9999-0000-0003-000000000004'")" = "INV-000001" ] && pass "client B starts its own series" || fail "B numbering wrong"
[ "$($P -c "select invoice_number is null from public.invoices where id = '00000000-9999-0000-0003-000000000003'")" = t ] && pass "the draft has no number yet" || fail "draft got a number"
$P -c "update public.invoices set issued_at = now() where id = '00000000-9999-0000-0003-000000000003'" >/dev/null
[ "$($P -c "select invoice_number from public.invoices where id = '00000000-9999-0000-0003-000000000003'")" = "INV-000003" ] && pass "issuing the draft continues the series: INV-000003" || fail "counter not set from backfill"
[ "$($P -c "select count(*) from public.clients where currency <> 'USD'")" = 0 ] && [ "$($P -c "select count(*) from public.invoices where currency <> 'USD'")" = 0 ] && pass "existing clients and invoices became USD" || fail "currency backfill"
[ "$($P -c "select count(*) from public.invoices where currency is null")" = 0 ] && pass "every existing invoice got its client's currency (none left NULL)" || fail "currency backfill left NULLs"
[ "$($P -c "select (issued_at at time zone 'UTC')::text from public.invoices where id = '00000000-9999-0000-0003-000000000001'")" = "2026-03-01 09:00:00" ] \
  && pass "an invoice issued before the migration keeps its original issue time (stamping applies to new issues only)" || fail "issue time of an old invoice changed"
[ "$($P -c "select count(*) from public.budget_vs_spend")" = 0 ] && pass "budget_vs_spend still answers after the view was replaced" || fail "view broken"

# ---- a bad time zone must stop migration 5 and leave nothing behind
build
for f in supabase/migrations/2026100500000[1-4]_*.sql; do $P -f "$f" >/dev/null 2>&1; done
$P -c "insert into public.clients (id, name) values ('00000000-9999-0000-0000-0000000000ff', 'Bad Zone'); insert into public.markets (client_id, name, timezone) values ('00000000-9999-0000-0000-0000000000ff', 'Nowhere', 'Central Time')" >/dev/null
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
if $P -f supabase/migrations/20261005000005_market_timezones.sql >"$OUT" 2>&1; then fail "migration 5 accepted a bad time zone"; fi
grep -q "not IANA zone names (Central Time)" "$OUT" && pass "a bad time zone stops migration 5 with a message naming it" || fail "migration 5 failed, but not with the expected message: $(cat "$OUT")"
[ "$($P -c "select to_regclass('private.iana_timezones') is null")" = t ] && pass "and nothing of migration 5 was left behind (it ran in one transaction)" || fail "half-applied migration"
echo "   upgrade-path tests passed"
psql -d postgres -q -c "drop database if exists $DB"
