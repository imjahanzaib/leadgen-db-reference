#!/usr/bin/env bash
# Two real sessions: the billing guards rely on row locks, which a single-session test cannot show.
# Builds its own scratch database (<db>_race) so committed fixtures do not touch the main one.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${1:-leadgen_demo}"; DB="${BASE}_race"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
psql -d postgres -q -c "drop database if exists $DB" -c "create database $DB"
P="psql -d $DB -v ON_ERROR_STOP=1 -q -At"
$P -f local/00_supabase_shim.sql >/dev/null
for f in supabase/migrations/*.sql; do $P -f "$f" >/dev/null 2>&1; done
echo "== 08 billing concurrency: the locks do what the guards assume"

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; [ "${KEEP_GOING:-0}" = 1 ] || exit 1; }
# waits (up to 5 s) until some backend in this database is blocked on a lock, proving the second session really waited
wait_for_waiter() { for _ in $(seq 1 50); do
  [ "$($P -c "select count(*) from pg_stat_activity where datname = '$DB' and wait_event_type = 'Lock'")" -ge 1 ] && return 0; sleep 0.1; done; return 1; }

U() { echo "00000000-8888-0000-0000-$(printf '%012d' "$1")"; }
$P <<SQL
insert into public.clients (id, name) values ('$(U 1)', 'Race A'), ('$(U 2)', 'Race B');
insert into public.markets (id, client_id, name) values ('$(U 11)', '$(U 1)', 'A1'), ('$(U 12)', '$(U 2)', 'B1');
insert into public.service_types (id, code, name) values ('$(U 21)', 'roofing', 'Roofing');
insert into public.contractors (id, name) values ('$(U 31)', 'Pro');
insert into public.leads (id, market_id, service_type_id, source_system, source_id, received_at)
  select ('00000000-8888-0000-0001-' || lpad(g::text, 12, '0'))::uuid, case when g <= 8 then '$(U 11)' else '$(U 12)' end::uuid, '$(U 21)', 'race', g::text, now()
  from generate_series(1, 14) g;
insert into public.lead_deliveries (id, lead_id, contractor_id, delivered_at, price_cents)
  select ('00000000-8888-0000-0002-' || lpad(g::text, 12, '0'))::uuid, ('00000000-8888-0000-0001-' || lpad(g::text, 12, '0'))::uuid, '$(U 31)', now(), 500
  from generate_series(1, 14) g;
SQL
D() { echo "00000000-8888-0000-0002-$(printf '%012d' "$1")"; }
I() { echo "00000000-8888-0000-0003-$(printf '%012d' "$1")"; }
mkdraft() { $P -c "insert into public.invoices (id, client_id, period_start, period_end) values ('$(I $1)', '$2', '2026-0$1-01', '2026-0$1-28');
                   insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('$(I $1)', '$(D $3)');"; }

# ---- 1. a line arrives while the invoice is being issued: it must wait, then be refused
mkdraft 1 "$(U 1)" 1
$P -c "begin; update public.invoices set issued_at = now() where id = '$(I 1)'; select pg_sleep(4); commit;" >/dev/null &
sleep 0.5
( $P -c "insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('$(I 1)', '$(D 2)')" >"$T/1.out" 2>&1 || true ) &
wait_for_waiter && pass "1a. the line insert waits while the invoice is being issued" || fail "1a. the line insert did not wait on the issuing transaction"
wait
grep -q "is issued" "$T/1.out" && pass "1b. once the issue commits, the waiting line is refused" || fail "1b. the line was not refused: $(cat "$T/1.out")"
[ "$($P -c "select count(*) from public.invoice_lines where invoice_id = '$(I 1)'")" = 1 ] && pass "1c. the issued invoice kept exactly its one line" || fail "1c. line count changed"

# ---- 2. the issue arrives while a line is being added: it must wait, then include the line
mkdraft 2 "$(U 1)" 3
$P -c "begin; insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('$(I 2)', '$(D 4)'); select pg_sleep(4); commit;" >/dev/null &
sleep 0.5
( $P -c "update public.invoices set issued_at = now() where id = '$(I 2)'" >"$T/2.out" 2>&1 || true ) &
wait_for_waiter && pass "2a. issuing waits while a line is being added" || fail "2a. the issue did not wait"
wait
[ "$($P -c "select count(*) from public.invoice_lines where invoice_id = '$(I 2)'")" = 2 ] && pass "2b. the line that committed first is on the issued invoice" || fail "2b. line missing: $(cat "$T/2.out")"
[ "$($P -c "select invoice_number from public.invoices where id = '$(I 2)'")" = "INV-000002" ] && pass "2c. and the invoice got the next number, INV-000002" || fail "2c. number wrong"

# ---- 3. two issuers for one client: distinct, consecutive numbers (and the second one waits)
mkdraft 3 "$(U 1)" 5; mkdraft 4 "$(U 1)" 6
$P -c "begin; update public.invoices set issued_at = now() where id = '$(I 3)'; select pg_sleep(4); commit;" >/dev/null &
sleep 0.5
( $P -c "update public.invoices set issued_at = now() where id = '$(I 4)'" >"$T/3.out" 2>&1 || true ) &
wait_for_waiter && pass "3a. the second issuer waits for the first one's number" || fail "3a. no wait"
wait
[ "$($P -c "select string_agg(invoice_number, ',' order by invoice_number) from public.invoices where id in ('$(I 3)', '$(I 4)')")" = "INV-000003,INV-000004" ] \
  && pass "3b. two concurrent issues got INV-000003 and INV-000004: no duplicate, no gap" || fail "3b. numbers wrong: $($P -c "select invoice_number from public.invoices where client_id = '$(U 1)' order by 1")"

# ---- 4. two credit notes that cannot both fit: only one gets in
mkdraft 5 "$(U 2)" 9; $P -c "insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('$(I 5)', '$(D 10)'); update public.invoices set issued_at = now() where id = '$(I 5)'"   # total 1000
CN="insert into public.credit_notes (client_id, invoice_id, currency, amount_cents, reason) values ('$(U 2)', '$(I 5)', 'USD', 600, 'race')"
$P -c "begin; $CN; select pg_sleep(4); commit;" >/dev/null &
sleep 0.5
( $P -c "$CN" >"$T/4.out" 2>&1 || true ) &
wait_for_waiter && pass "4a. the second credit note waits for the first" || fail "4a. no wait"
wait
grep -q "would exceed" "$T/4.out" && pass "4b. after the first commits, the second is refused (600 + 600 > 1000)" || fail "4b. not refused: $(cat "$T/4.out")"
[ "$($P -c "select coalesce(sum(amount_cents), 0) from public.credit_notes where invoice_id = '$(I 5)'")" = 600 ] && pass "4c. exactly 600 is credited" || fail "4c. credited total wrong"
# ---- 5. a delivery's price changes while its line is being added and the invoice issued: the line waits, so the invoice is issued with the NEW price
mkdraft 6 "$(U 2)" 11
$P -c "begin; update public.lead_deliveries set price_cents = 1 where id = '$(D 12)'; select pg_sleep(4); commit;" >/dev/null &
sleep 0.5
( $P -c "begin; insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('$(I 6)', '$(D 12)'); update public.invoices set issued_at = now() where id = '$(I 6)'; commit;" >"$T/5.out" 2>&1 || true ) &
wait_for_waiter && pass "5a. adding a line waits while the delivery's price is being changed" || fail "5a. no wait: $(cat "$T/5.out")"
wait
[ "$($P -c "select total_cents from public.invoice_totals where invoice_id = '$(I 6)'")" = 501 ] && pass "5b. the invoice was issued with the new price (500 + 1), so its total cannot move afterwards" || fail "5b. total wrong: $(cat "$T/5.out")"
$P -c "update public.lead_deliveries set price_cents = 9 where id = '$(D 12)'" >"$T/5c.out" 2>&1 || true
grep -q "price is frozen" "$T/5c.out" && pass "5c. and the price is frozen from then on" || fail "5c. price changed after issue"

# ---- 5'. the other order: the line is added and the invoice issued first; the price change waits, then is refused
mkdraft 7 "$(U 2)" 13
$P -c "begin; insert into public.invoice_lines (invoice_id, lead_delivery_id) values ('$(I 7)', '$(D 14)'); update public.invoices set issued_at = now() where id = '$(I 7)'; select pg_sleep(4); commit;" >/dev/null &
sleep 0.5
( $P -c "update public.lead_deliveries set price_cents = 1 where id = '$(D 14)'" >"$T/5d.out" 2>&1 || true ) &
wait_for_waiter && pass "5d. the price change waits while the line is being billed" || fail "5d. no wait"
wait
grep -q "price is frozen" "$T/5d.out" && pass "5e. then it is refused: the delivery is billed" || fail "5e. not refused: $(cat "$T/5d.out")"
[ "$($P -c "select price_cents from public.lead_deliveries where id = '$(D 14)'")" = 500 ] && pass "5f. the price is unchanged (500)" || fail "5f. price changed"

# ---- 6. a FRESH session as service_role: no 'permission denied for schema private' (a cached plan hid it inside one session)
$P -c "set role service_role; insert into public.markets (client_id, name) values ('$(U 1)', 'svc-1'); update public.markets set timezone = 'America/Chicago' where name = 'svc-1'; select count(*) from public.budget_vs_spend;" >"$T/6.out" 2>&1 \
  && pass "6. a fresh service_role session can insert and re-zone a market and read budget_vs_spend" || fail "6. service_role failed: $(cat "$T/6.out")"

# ---- 7. creating the next audit partition must not stall behind an open audited write
$P -c "begin; insert into public.markets (client_id, name) values ('$(U 1)', 'hold-open'); select pg_sleep(4); commit;" >/dev/null &
sleep 0.5
SECONDS=0
$P -c "select audit.ensure_partitions('2031-01-01', '2031-01-01')" >"$T/7.out" 2>&1 || true
[ "$SECONDS" -lt 3 ] && [ "$(cat "$T/7.out")" = 1 ] && pass "7a. a new audit partition was created in under 3 s while another transaction held an audited write open" || fail "7a. creating the partition stalled ($SECONDS s): $(cat "$T/7.out")"
$P -c "begin; insert into public.markets (client_id, name) values ('$(U 1)', 'during-ddl'); commit;" >"$T/7b.out" 2>&1 && pass "7b. and ordinary audited writes keep working" || fail "7b. write failed: $(cat "$T/7b.out")"
wait
echo "   concurrency tests passed"
psql -d postgres -q -c "drop database if exists $DB"
