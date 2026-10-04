#!/usr/bin/env bash
# Rebuilds a scratch database from scratch and runs every test. Needs only a local Postgres 15+.
set -euo pipefail
cd "$(dirname "$0")"; DB=leadgen_demo
psql -d postgres -q -c "drop database if exists $DB" -c "create database $DB"
P="psql -d $DB -v ON_ERROR_STOP=1 -q"
$P -f local/00_supabase_shim.sql
for f in supabase/migrations/*.sql; do echo "migrate  $f"; $P -f "$f"; done
$P -f tests/01_constraints.sql
$P -f tests/02_rls.sql
$P -f tests/03_import_and_checks.sql
bash tests/04_online_column.sh $DB
echo "ALL TESTS PASSED"
