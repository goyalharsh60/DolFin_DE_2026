#!/usr/bin/env bash
# Compares the RESULTS of the 25 read queries between two databases/workloads, ignoring row order.
#   ./benchmarks/compare_results.sh <db_before> <db_after> [after_workload.sql]
# <db_before> runs queries/workload_30.sql; <db_after> runs sql/06_optimized_queries.sql (default).
# Prints SAME / DIFFERENT per query (md5 of the sorted output). Expected: all SAME except
#   R13 (intended fix: wrong NOT IN -> correct NOT EXISTS) and R05 (LIMIT 200 without ORDER BY:
#   any 200 qualifying rows are valid; see sql/07_verify_results.sql).
set -euo pipefail
BEFORE="${1:?db before}"; AFTER="${2:?db after}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W_AFTER="${3:-$ROOT/sql/06_optimized_queries.sql}"
split() { awk -v dir="$2" '/^-- @/ { id=""; if ($2 ~ /^@[RW][0-9]+$/) { id=substr($2,2); file=dir "/" id ".sql"; printf "" > file }; next } id!="" && !/^--/ { print >> file }' "$1"; }
TMP="$(mktemp -d)"; mkdir "$TMP/o" "$TMP/n"
split "$ROOT/queries/workload_30.sql" "$TMP/o"; split "$W_AFTER" "$TMP/n"
printf '%-5s %-8s %-8s %s\n' query rows_before rows_after result
for i in $(seq -w 1 25); do q="R$i"
  a="$( (echo "SET search_path TO housing;"; cat "$TMP/o/$q.sql") | psql -d "$BEFORE" -X -q -A -t)"
  b="$( (echo "SET search_path TO housing;"; cat "$TMP/n/$q.sql") | psql -d "$AFTER" -X -q -A -t)"
  ma="$(echo "$a" | sort | md5sum | cut -c1-8)"; mb="$(echo "$b" | sort | md5sum | cut -c1-8)"
  printf '%-5s %-8s %-8s %s\n' "$q" "$(echo -n "$a" | grep -c . || true)" "$(echo -n "$b" | grep -c . || true)" "$([ "$ma" = "$mb" ] && echo SAME || echo DIFFERENT)"
done
rm -rf "$TMP"
