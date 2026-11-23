#!/usr/bin/env bash
# Measures the cost of the extra indexes on bulk writes (supplement to W01-W05, which touch 1 row
# or, for W04, rows that are updated in place).  Runs the same statements in two databases:
#   <db_plain>   schema + data only (the baseline: PK/UNIQUE indexes)
#   <db_indexed> same data + sql/05_indexes.sql
# 1) bulk INSERT of 20,000 properties and 10,000 enquiries (copies of existing rows, new ids)
# 2) UPDATE of price on 14,000 properties (price is a key/INCLUDE column of 3 new indexes -> not HOT)
# All inside BEGIN ... ROLLBACK. 3 runs each, plans saved to benchmarks/results/optimized/write_overhead.txt
# Usage: ./benchmarks/write_overhead.sh <db_plain> <db_indexed>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/benchmarks/results/optimized/write_overhead.txt"
mkdir -p "$(dirname "$OUT")"; : > "$OUT"
run() { # db label sql
  for i in 1 2 3; do
    echo "=== $2 | database $1 | run $i ===" >> "$OUT"
    printf 'SET search_path TO housing;\nBEGIN;\nEXPLAIN (ANALYZE, BUFFERS) %s\nROLLBACK;\n' "$3" | psql -d "$1" -X -q -A -t -v ON_ERROR_STOP=1 >> "$OUT"
  done
}
INS_P="INSERT INTO properties (property_id, listed_by, project_id, locality_id, listing_type, property_type, bhk, carpet_area_sqft, floor_no, total_floors, furnishing, facing, price, maintenance_monthly, security_deposit, available_from, latitude, longitude, is_verified, status, posted_at)
SELECT property_id + 100000000, listed_by, project_id, locality_id, listing_type, property_type, bhk, carpet_area_sqft, floor_no, total_floors, furnishing, facing, price, maintenance_monthly, security_deposit, available_from, latitude, longitude, is_verified, status, posted_at
FROM properties WHERE property_id <= 40000 LIMIT 20000;"
INS_E="INSERT INTO enquiries (enquiry_id, property_id, user_id, channel, message, created_at)
SELECT enquiry_id + 100000000, property_id, user_id, channel, message, created_at FROM enquiries LIMIT 10000;"
UPD="UPDATE properties SET price = price + 100 WHERE property_id IN (SELECT property_id FROM properties WHERE status = 'ACTIVE' ORDER BY property_id LIMIT 14000);"
for db in "$1" "$2"; do
  run "$db" "bulk INSERT 20000 properties" "$INS_P"
  run "$db" "bulk INSERT 10000 enquiries" "$INS_E"
  run "$db" "UPDATE price on 14000 properties" "$UPD"
done
python3 - "$OUT" "$1" "$2" <<'PY'
import re,sys
t=open(sys.argv[1]).read()
blocks=re.split(r'(?m)^=== ',t)[1:]
agg={}
for b in blocks:
    head=b.split(' ===')[0]; lab,db,run=[x.strip() for x in head.split('|')]
    ms=float(re.findall(r'Execution Time: ([0-9.]+)',b)[0]); agg.setdefault((lab,db.replace('database ','')),[]).append(ms)
print(f"{'statement':36} {'db':14} {'avg_ms':>10}")
for (lab,db),v in agg.items(): print(f"{lab:36} {db:14} {sum(v)/len(v):10.1f}")
PY
