#!/usr/bin/env bash
# Rebuilds a scratch database from scratch and runs every test. Needs only a local Postgres 15+.
# 04_online_column.sh adds a NOT NULL column to leads, so it changes the schema and must run last.
set -euo pipefail
cd "$(dirname "$0")"; DB=leadgen_demo
psql -d postgres -q -c "drop database if exists $DB" -c "create database $DB"
P="psql -d $DB -v ON_ERROR_STOP=1 -q"
$P -f local/00_supabase_shim.sql
for f in supabase/migrations/*.sql; do echo "migrate  $f"; $P -f "$f"; done
for t in 01_constraints 02_rls 03_import_and_checks 05_timezones 06_audit_append_only 07_billing_integrity 10_least_privilege; do $P -f tests/$t.sql; done
bash tests/08_billing_concurrency.sh $DB
bash tests/09_upgrade_path.sh $DB
bash tests/04_online_column.sh $DB
echo "ALL TESTS PASSED"
