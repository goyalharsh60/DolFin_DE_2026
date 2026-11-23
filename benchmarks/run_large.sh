#!/usr/bin/env bash
# Phase 5 in one command: builds a NEW database from the large CSV files with OUR scripts, indexes it,
# runs the OPTIMIZED workload (never the original 30 on large data) and checks the performance targets.
#
# Usage:   ./benchmarks/run_large.sh <new_database> <path/to/large_data> [results_folder] [runs]
# Example: ./benchmarks/run_large.sh dolfin_large ~/large_data large 3        # -> benchmarks/results/large/
#
# Steps: createdb -> sql/01_schema.sql -> sql/02_load_data.sql (folder name changed only) -> sql/05_indexes.sql
#        -> R22 keyset anchor recomputed for THIS data -> run_benchmark.sh on sql/06_optimized_queries.sql
#        -> sizes + target check.  Connection settings come from PGHOST / PGPORT / PGUSER.
# The database is DROPPED and re-created if it already exists.
set -euo pipefail
DB="${1:?new database name}"; DATA="$(cd "${2:?path to large_data folder}" && pwd)"
PHASE="${3:-large}"; RUNS="${4:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for f in cities localities builders projects amenities project_amenities users properties price_changes enquiries site_visits shortlists; do
  [[ -f "$DATA/$f.csv" ]] || { echo "missing $DATA/$f.csv"; exit 1; }
done
echo "== 1/5 create database $DB"
psql -d postgres -X -q -c "DROP DATABASE IF EXISTS \"$DB\"" -c "CREATE DATABASE \"$DB\""
echo "== 2/5 schema + load (this is the slow step)"
psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -f "$ROOT/sql/01_schema.sql" > /dev/null
sed "s#seed_data/#$DATA/#g" "$ROOT/sql/02_load_data.sql" > "$TMP/load.sql"
( time psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -f "$TMP/load.sql" ) 2>&1 | tee "$TMP/load.log" | grep -E "MISMATCH|violations|real" || true
echo "   (row counts show MISMATCH against the SEED counts hard-coded in 02_load_data.sql; compare with the faculty's large-data counts instead)"
echo "== 3/5 indexes"
( time psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -f "$ROOT/sql/05_indexes.sql" ) 2>&1 | grep real
echo "== 4/5 benchmark (optimized workload, $RUNS runs)"
ANCHOR="$(psql -d "$DB" -X -A -t -c "SET search_path=housing; SELECT posted_at || '|' || property_id FROM properties ORDER BY posted_at DESC, property_id DESC OFFSET 49999 LIMIT 1" | tail -1)"
TS="${ANCHOR%|*}"; ID="${ANCHOR#*|}"
echo "   R22 keyset anchor for this data = last row of page 2,000: ($TS, $ID)"
sed "s/TIMESTAMPTZ '2025-11-15 11:18:17+00', 70045/TIMESTAMPTZ '$TS', $ID/" "$ROOT/sql/06_optimized_queries.sql" > "$TMP/06_large.sql"
grep -q "$TS" "$TMP/06_large.sql" || { echo "anchor substitution failed"; exit 1; }
cp "$TMP/06_large.sql" "$ROOT/benchmarks/results/.06_large_used.sql" 2>/dev/null || true
"$ROOT/benchmarks/run_benchmark.sh" "$DB" "$PHASE" "$RUNS" "$TMP/06_large.sql" | tee "$TMP/bench.log"
echo "== 5/5 sizes and targets"
OUT="$ROOT/benchmarks/results/$PHASE"
{ echo "-- sizes of $DB after sql/05_indexes.sql"; psql -d "$DB" -X -f /dev/stdin <<'SQL'
SET search_path TO housing;
SELECT t.relname AS table_name, c.relname AS index_name, pg_size_pretty(pg_relation_size(c.oid)) AS index_size, pg_size_pretty(pg_relation_size(t.oid)) AS table_size
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_class t ON t.oid=i.indrelid JOIN pg_namespace n ON n.oid=t.relnamespace
WHERE n.nspname='housing' AND c.relname LIKE 'idx\_%' ORDER BY t.relname, c.relname;
SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;
SELECT relname, pg_size_pretty(pg_relation_size(c.oid)) AS "table", pg_size_pretty(pg_indexes_size(c.oid)) AS all_indexes FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='housing' AND relkind='r' ORDER BY pg_relation_size(c.oid) DESC;
SQL
} > "$OUT/db_sizes.txt"
python3 - "$OUT/summary.csv" <<'PY'
import csv,sys
T={'real-time (<5 ms)':(5,"R01 R02 R03 R05 R06 R07 R10 R11 R23 W01 W02 W03 W05"),
   'interactive (<250 ms)':(250,"R08 R09 R12 R13 R16 R17 R22 R24"),
   'reports (<5000 ms)':(5000,"R04 R14 R15 R18 R19 R20 R21 R25"),
   'batch (<1000 ms)':(1000,"W04")}
r={x['query_id']:float(x['avg_ms']) for x in csv.DictReader(open(sys.argv[1]))}
miss=0
for g,(lim,ids) in T.items():
    for q in ids.split():
        ok=r[q]<lim; miss+=not ok
        if not ok: print(f"  MISSED {g:22} {q:4} {r[q]:10.1f} ms")
print(f"targets missed: {miss} of 30 (explain each in docs/05_scalability_report.md)")
PY
