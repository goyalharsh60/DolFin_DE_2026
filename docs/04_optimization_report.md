# Phase 4: Optimization report

## Summary

- Total workload time (sum of 30 averages): **10,174.5 ms -> 451.2 ms** (95.6% less, 23x).
- R19 (the 'several seconds' query) went from 8,755 ms to 20.8 ms (420x). R22 went from 63.5 to 0.063 ms; R25 from 911 to 170 ms.
- **R13 returned a wrong answer** (0 rows instead of 120). Found, explained and fixed below.
- 8 new indexes (37 MB; database 55 MB -> 97 MB), 7 queries rewritten, 1 storage setting (`fillfactor = 80` on `properties`). No server settings changed, no data changed.
- Cost: inserts and non-HOT updates on `properties`/`enquiries` are 1.5-3x slower; see *Write overhead*.

## How it was measured

- Machine and method are the same as the baseline (`docs/03_baseline_timings.md`): PostgreSQL 16.15, 2 vCPU / 8 GB cloud container, default server settings, session time zone UTC, warm cache. **TEAM TO CHECK:** these were not run on a team laptop; re-run on yours and replace `benchmarks/results/` plus the numbers in this file if the course requires laptop timings (the report below is generated from the result files, so regenerating keeps them consistent).
- Fresh load from `sql/01_schema.sql` + `sql/02_load_data.sql`, then `sql/05_indexes.sql` (which ends with `VACUUM (ANALYZE)`), then `./benchmarks/run_benchmark.sh dolfin optimized 5 sql/06_optimized_queries.sql` -> 5 runs were recorded per query. To follow the course method (3 runs, average of the three) `benchmarks/results/optimized/summary.csv` and the raw plan files `R01.txt` to `W05.txt` there contain **runs 1 to 3 only**; the original files with all 5 runs are kept in `benchmarks/results/optimized/all_5_runs_original/` (their 5-run total is 450.8 ms, the 3-run total is 451.2 ms). Averages below are the `avg_ms` column of the 3-run `summary.csv`.
- Results were reloaded from scratch before each benchmark because the ROLLBACK of write queries leaves dead rows that would otherwise change later timings.

## Optimization table (all 30 queries)

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|---|---:|---|---|---:|---:|:--|
| R01 | 14.373 | Parallel Seq Scan of all 120,060 properties (116,636 rows discarded) | `idx_prop_search`: Bitmap Index Scan on the Koramangala + RENT entries, bhk and price tested inside the index; status/furnishing checked on 110 heap rows | 0.537 | 96% (26.8x) | ✅ |
| R02 | 13.255 | Parallel Seq Scan of all properties, 5 filters, then sort | `idx_prop_search` probed once per Pune locality (10 probes); `status` checked on the 25 rows each probe returns | 0.987 | 93% (13.4x) | ✅ |
| R03 | 0.156 | None: already PK lookups | No change | 0.242 | -55% (0.6x) | ✅ |
| R04 | 18.757 | Seq Scan; `EXTRACT(YEAR FROM posted_at)` blocks any index on the date | `idx_prop_search` as covering index (Index Only Scan, posted_at/price/area included) + rewrite to `posted_at >= '2026-01-01' AND < '2027-01-01'` | 0.360 | 98% (52.1x) | ✅ |
| R05 | 14.004 | Parallel Seq Scan, 98k rows discarded before `LIMIT 200` is satisfied | `idx_prop_map` (listing_type, latitude, longitude) INCLUDE (price, bhk): box test inside the index | 3.396 | 76% (4.1x) | ✅ (any 200 qualifying rows are valid; checked) |
| R06 | 20.612 | Seq Scans of properties (listed_by), enquiries and site_visits (no FK indexes) | `idx_prop_lister` finds the owner's 34 listings; `idx_enq_property_user` and `idx_visit_property_user` count their children by index | 0.722 | 96% (28.5x) | ✅ |
| R07 | 3.349 | Seq Scan of site_visits because `DATE(scheduled_at)` is a function on the column | `idx_prop_lister` (lister's properties) -> `idx_visit_property_user` (visits per property) + rewrite to `scheduled_at >= '2026-07-01' AND < '2026-07-02'` | 0.199 | 94% (16.8x) | ✅ |
| R08 | 2.601 | Seq Scan of 23k price_changes (no index on changed_at), small table | No change kept: the index we tried gave 2.2 ms vs 2.6 ms (see experiments) and is not worth its write cost | 3.583 | -38% (0.7x) | ✅ |
| R09 | 18.945 | Seq Scan of properties filtered by status only, then hash join | `idx_prop_project` (project_id) INCLUDE (price): the 58 qualifying projects are looked up by index; status filtered on heap | 7.131 | 62% (2.7x) | ✅ |
| R10 | 0.085 | None: UNIQUE index on rera_id already used | No change | 0.179 | -111% (0.5x) | ✅ |
| R11 | 15.037 | Seq Scan of all properties to find 19 rows of one project | `idx_prop_project` (project_id) INCLUDE (price, bhk, listing_type): 52 index entries, 19 survive the status filter | 0.461 | 97% (32.6x) | ✅ |
| R12 | 14.420 | Seq Scan of enquiries (date range) and hash anti join against all site_visits | `idx_enq_created` for the date window; anti join still hashes site_visits (35k rows): only ~10% faster | 13.547 | 6% (1.1x) | ✅ |
| R13 | 25.679 | **Wrong result (0 rows)** and Seq Scan of all properties; `NOT IN` with a NULL in the list | Rewrite to `NOT EXISTS` (correct: 120 rows) + `idx_prop_project` index-only probes (1,200 probes, 0 heap fetches) | 3.141 | 88% (8.2x) | ❌→✅ fixed (0 → 120 rows) |
| R14 | 19.385 | Seq Scan of properties (10.5k sold/rented in 2026) and of users (2k agents) | No change kept (aggregation-bound); a status-indexed design gave 8.5 ms but made W04 2.7x slower | 21.818 | -13% (0.9x) | ✅ |
| R15 | 20.433 | Seq Scan of properties for all 97,695 apartments, then join to 10 Bengaluru localities | `idx_prop_search` Index Only Scan, 10 probes by locality_id (993 entries each), 0 heap fetches | 4.702 | 77% (4.3x) | ✅ |
| R16 | 0.604 | Seq Scan of 1,200 projects (`ILIKE '%greens%'`) | No change: 0.5 ms; a trigram index would not be used on 1,200 rows | 0.593 | 2% (~same) | ✅ |
| R17 | 39.022 | Seq Scan of properties (active, >90 days) + hash anti join over all 100k enquiries | No change kept: set-difference over most of both tables | 50.546 | -30% (0.8x) | ✅ |
| R18 | 26.817 | Seq Scan of 36,819 active properties, HashAggregate on 5 columns | No change kept: must group all active listings; status-indexed variant gave 8.3 ms but cost W04 | 29.056 | -8% (0.9x) | ✅ |
| R19 | 8755.323 | 2 correlated subqueries x 1,780 properties, each a Seq Scan of 100k enquiries (3.09 M buffer hits) | Rewrite to one `LATERAL` aggregate per property + `idx_enq_property_user` (property_id, user_id) INCLUDE (created_at) | 20.844 | 100% (420.0x) | ✅ |
| R20 | 24.733 | Seq Scan of properties; `posted_at::date` is a cast on the column | Rewrite to a `posted_at` range + `idx_prop_posted` Index Only Scan (6,550 entries) | 1.925 | 92% (12.8x) | ✅ |
| R21 | 22.700 | Parallel Seq Scan of properties + Seq Scan of site_visits | No change kept: reads every rated visit; best index tried gave 21 ms vs 23 ms | 24.435 | -8% (0.9x) | ✅ |
| R22 | 63.522 | Seq Scan + external-merge sort of 50,025 rows (5.7 MB spilled) to discard 50,000 for `OFFSET` | Keyset pagination on `idx_prop_posted (posted_at DESC, property_id DESC)`: reads exactly 25 index entries | 0.063 | 100% (1008.3x) | ✅ |
| R23 | 0.045 | None: UNIQUE index on phone already used | No change | 0.058 | -29% (0.8x) | ✅ |
| R24 | 0.315 | Seq Scan of 1,200 projects, tiny | No change: 0.3 ms | 0.291 | 8% (1.1x) | ✅ |
| R25 | 911.206 | Correlated EXISTS per shortlist (70k), nested loop against localities discarding 6.9 M rows, JIT 189 ms | Rewrite to `LEFT JOIN (SELECT DISTINCT property_id, user_id FROM enquiries)` (index-only, hashed once); shortlists read by index-only scan. (A plain `IN (SELECT ..)` was faster on the seed data but unsafe at 20x: see the scalability report) | 169.923 | 81% (5.4x) | ✅ |
| W01 | 1.165 | Single-row INSERT | No query change; now maintains 5 more indexes on properties (all entries are written) | 1.118 | 4% (~same) | ✅ (rolled back) |
| W02 | 1.219 | `max(property_id)` walked properties_pkey backwards, skipping 3,150 rows | `idx_prop_lister (listed_by, listing_type, property_id)`: range end read directly | 0.579 | 53% (2.1x) | ✅ (rolled back) |
| W03 | 1.018 | Single-row INSERT | No query change; maintains 1 more index on site_visits | 1.539 | -51% (0.7x) | ✅ (rolled back) |
| W04 | 111.125 | Seq Scan of 120k rows + 14,440 row updates; only the PK index to maintain, so already cheap per row | `fillfactor = 80` keeps the 8 new indexes from slowing it (HOT updates, see *Write overhead*); plan is still a Seq Scan, no index on `status` | 88.624 | 20% (1.3x) | ✅ (rolled back) |
| W05 | 14.603 | `min(property_id)` walked properties_pkey forward, skipping 53,025 rows (15,713 buffer hits) | `idx_prop_lister`: range start read directly | 0.623 | 96% (23.4x) | ✅ (rolled back) |
| **Total** | **10174.508** | | | **451.222** | **95.6%** | |

Improvement % = (before - after) / before x 100. A negative value means slower. Differences under ~5 ms or ~20% on sub-30 ms queries are within run-to-run noise on this machine (the same unchanged query varies by that much between runs).

### Queries that got slower, and why

Unchanged whole-table readers of `properties` that got slower: R17 (39.0 -> 50.5 ms). The cause is `fillfactor = 80`: `properties` grew from 17 MB to 22 MB because each page is left 20% empty for HOT updates, so a Seq Scan reads ~30% more pages. This is the price of making W04 fast (see *Write overhead*); every such query is far inside its large-data target.

## The query that returns a wrong answer: R13

```sql
SELECT pj.project_id, pj.project_name, pj.possession_status
FROM projects pj
WHERE pj.project_id NOT IN (SELECT p.project_id FROM properties p);   -- returns 0 rows
```
- **What the business asked:** projects with no property listed (P5: 'the list is always empty').
- **Why it is wrong:** `x NOT IN (list)` is `x <> a AND x <> b AND ...`. In SQL, comparing anything to NULL gives UNKNOWN, and `TRUE AND UNKNOWN` is UNKNOWN, which `WHERE` treats as false. `properties.project_id` is NULL for **54,009** listings (standalone houses and plots have no project), so the subquery list contains NULL and `NOT IN` can never be true: the result is empty for every project.
- **Fix:** `WHERE NOT EXISTS (SELECT 1 FROM properties p WHERE p.project_id = pj.project_id)`. `EXISTS` only asks whether a matching row exists and ignores NULLs. It returns **120** projects. A third, independent method (`LEFT JOIN ... WHERE p.property_id IS NULL`) returns the same 120 rows (proof in `sql/07_verify_results.sql`).
- The plan itself gives no hint: it is a valid plan that returns a valid-looking empty set, which is why the bug survives. It is found by comparing with `NOT EXISTS`, or by knowing the complaint in P5. Speed is irrelevant when the answer is wrong.

## Results proven unchanged

Two checks, both reproducible:

1. `psql -d <db> -f sql/07_verify_results.sql` compares each **rewritten** query with its original on the same data: row counts, `EXCEPT ALL` in both directions, and an md5 of the ordered result.
2. `./benchmarks/compare_results.sh <db_without_indexes> <db_with_indexes>` runs **all 25 read queries** (original text in a plain database, `sql/06_optimized_queries.sql` in the indexed one) and compares the md5 of the sorted output.

```text
          query           | orig_rows | new_rows | only_in_orig | only_in_new | same_order |                                                                   note                                                                    
--------------------------+-----------+----------+--------------+-------------+------------+-------------------------------------------------------------------------------------------------------------------------------------------
 R04                      |         6 |        6 |            0 |           0 | t          | 
 R05 (LIMIT, no ORDER BY) |           |      200 |              |             |            | distinct ids = 200; rows violating the filter = 0; qualifying rows in table = 731
 R07                      |         2 |        2 |            0 |           0 | t          | ordered by scheduled_at only; ties possible
 R13 (fix)                |         0 |      120 |            0 |         120 |            | ORIGINAL IS WRONG: NULL project_id rows in properties = 54009; LEFT JOIN anti-join (3rd method) = 120 rows, identical to NOT EXISTS: true
 R19                      |      1780 |     1780 |            0 |           0 | t          | ORDER BY enquiries DESC has ties, so compared as sets sorted by property_id
 R20                      |        30 |       30 |            0 |           0 | t          | 
 R22                      |        25 |       25 |            0 |           0 | t          | posted_at is unique in the seed data (120060 distinct of 120060), so the OFFSET order is deterministic
 R25                      |        10 |       10 |            0 |           0 | t          | 
(8 rows)
```
```text
query rows_before rows_after result
R01   25       25       SAME
R02   30       30       SAME
R03   1        1        SAME
R04   6        6        SAME
R05   200      200      DIFFERENT
R06   34       34       SAME
R07   2        2        SAME
R08   557      557      SAME
R09   50       50       SAME
R10   1        1        SAME
R11   8        8        SAME
R12   3843     3843     SAME
R13   0        120      DIFFERENT
R14   20       20       SAME
R15   10       10       SAME
R16   30       30       SAME
R17   8940     8940     SAME
R18   60       60       SAME
R19   1780     1780     SAME
R20   30       30       SAME
R21   100      100      SAME
R22   25       25       SAME
R23   1        1        SAME
R24   180      180      SAME
R25   10       10       SAME
```
- 23 of 25 read queries are identical. The two differences are expected: **R13** (the fix) and **R05**, which is `LIMIT 200` without `ORDER BY`, so the database may return *any* 200 qualifying rows; the check above shows it returns 200 distinct rows, 0 of which violate the filter, out of 731 qualifying.
- R22 uses `posted_at`, which is unique in the data (120,060 distinct values), so the `OFFSET` order is deterministic and the keyset page equals the original page exactly.
- R19's `ORDER BY enquiries DESC` has ties, so it is compared as a set (sorted by property_id).
- Write queries W01-W05 are unchanged text; they run inside `BEGIN ... ROLLBACK`.

## Before / after EXPLAIN for the 5 biggest improvements

Chosen as the three largest time savings (R19, R25, R22) plus the two largest speed-up factors among the rest (R04, R11). Last run of each, from `benchmarks/results/baseline/` and `benchmarks/results/optimized/`; cost estimates and buffer lines removed for space (full plans are in the result files).

### R19: 8755.323 ms -> 20.844 ms

Before:
```text
Sort (actual time=9262.947..9263.137 rows=1780 loops=1)
  Sort Key: ((SubPlan 1)) DESC
  Sort Method: quicksort  Memory: 140kB
  ->  Hash Join (actual time=223.056..9260.128 rows=1780 loops=1)
        Hash Cond: (p.locality_id = l.locality_id)
        ->  Seq Scan on properties p (actual time=216.360..233.647 rows=16683 loops=1)
              Filter: (((listing_type)::text = 'SALE'::text) AND ((status)::text = 'ACTIVE'::text))
              Rows Removed by Filter: 103377
        ->  Hash (actual time=0.041..0.042 rows=10 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 9kB
              ->  Seq Scan on localities l (actual time=0.024..0.028 rows=10 loops=1)
                    Filter: (city_id = 1)
                    Rows Removed by Filter: 90
        SubPlan 1
          ->  Aggregate (actual time=2.535..2.535 rows=1 loops=1780)
                ->  Seq Scan on enquiries e (actual time=1.622..2.530 rows=1 loops=1780)
                      Filter: (property_id = p.property_id)
                      Rows Removed by Filter: 99999
        SubPlan 2
          ->  Aggregate (actual time=2.526..2.526 rows=1 loops=1780)
                ->  Seq Scan on enquiries e_1 (actual time=1.621..2.521 rows=1 loops=1780)
  ...
```
After:
```text
Sort (actual time=20.358..20.463 rows=1780 loops=1)
  Sort Key: (count(*)) DESC
  Sort Method: quicksort  Memory: 140kB
  ->  Nested Loop (actual time=0.057..20.059 rows=1780 loops=1)
        ->  Hash Join (actual time=0.038..17.019 rows=1780 loops=1)
              Hash Cond: (p.locality_id = l.locality_id)
              ->  Seq Scan on properties p (actual time=0.011..15.985 rows=16683 loops=1)
                    Filter: (((listing_type)::text = 'SALE'::text) AND ((status)::text = 'ACTIVE'::text))
                    Rows Removed by Filter: 103377
              ->  Hash (actual time=0.012..0.013 rows=10 loops=1)
                    Buckets: 1024  Batches: 1  Memory Usage: 9kB
                    ->  Seq Scan on localities l (actual time=0.002..0.006 rows=10 loops=1)
                          Filter: (city_id = 1)
                          Rows Removed by Filter: 90
        ->  Aggregate (actual time=0.001..0.001 rows=1 loops=1780)
              ->  Index Only Scan using idx_enq_property_user on enquiries e (actual time=0.001..0.001 rows=1 loops=1780)
                    Index Cond: (property_id = p.property_id)
                    Heap Fetches: 0
Planning Time: 0.829 ms
Execution Time: 20.586 ms
```

### R25: 911.206 ms -> 169.923 ms

Before:
```text
GroupAggregate (actual time=367.900..921.640 rows=10 loops=1)
  Group Key: l.city_id
  ->  Nested Loop (actual time=197.904..833.970 rows=69999 loops=1)
        Join Filter: (l.locality_id = p.locality_id)
        Rows Removed by Join Filter: 6929901
        ->  Index Scan using uq_localities_city_name on localities l (actual time=0.008..0.308 rows=100 loops=1)
        ->  Materialize (actual time=1.976..5.143 rows=69999 loops=100)
              ->  Hash Join (actual time=197.602..231.683 rows=69999 loops=1)
                    Hash Cond: (s.property_id = p.property_id)
                    ->  Seq Scan on shortlists s (actual time=0.013..5.354 rows=69999 loops=1)
                    ->  Hash (actual time=197.112..197.114 rows=120060 loops=1)
                          Buckets: 131072  Batches: 1  Memory Usage: 5480kB
                          ->  Seq Scan on properties p (actual time=161.184..175.669 rows=120060 loops=1)
  SubPlan 2
    ->  Seq Scan on enquiries e (actual time=16.700..26.743 rows=100000 loops=1)
Planning Time: 0.696 ms
Execution Time: 939.897 ms
```
After:
```text
Finalize GroupAggregate (actual time=154.695..157.689 rows=10 loops=1)
  Group Key: l.city_id
  ->  Gather Merge (actual time=154.685..157.673 rows=30 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        ->  Sort (actual time=146.877..146.885 rows=10 loops=3)
              Sort Key: l.city_id
              Sort Method: quicksort  Memory: 25kB
              ->  Partial HashAggregate (actual time=146.844..146.852 rows=10 loops=3)
                    Group Key: l.city_id
                    Batches: 1  Memory Usage: 24kB
                    ->  Hash Left Join (actual time=117.610..144.149 rows=23333 loops=3)
                          Hash Cond: ((s.property_id = enquiries.property_id) AND (s.user_id = enquiries.user_id))
                          ->  Hash Join (actual time=20.448..40.673 rows=23333 loops=3)
                                Hash Cond: (p.locality_id = l.locality_id)
                                ->  Parallel Hash Join (actual time=20.393..37.623 rows=23333 loops=3)
                                      Hash Cond: (s.property_id = p.property_id)
                                      ->  Parallel Index Only Scan using shortlists_pkey on shortlists s (actual time=0.035..2.332 rows=23333 loops=3)
                                            Heap Fetches: 0
                                      ->  Parallel Hash (actual time=18.880..18.881 rows=40020 loops=3)
                                            Buckets: 131072  Batches: 1  Memory Usage: 5760kB
  ...
```

### R22: 63.522 ms -> 0.063 ms

Before:
```text
Limit (actual time=65.042..65.049 rows=25 loops=1)
  ->  Sort (actual time=58.348..63.210 rows=50025 loops=1)
        Sort Key: posted_at DESC
        Sort Method: external merge  Disk: 5744kB
        ->  Seq Scan on properties (actual time=0.014..24.131 rows=120060 loops=1)
Planning Time: 0.339 ms
Execution Time: 65.834 ms
```
After:
```text
Limit (actual time=0.023..0.030 rows=25 loops=1)
  ->  Index Scan using idx_prop_posted on properties (actual time=0.022..0.027 rows=25 loops=1)
        Index Cond: (ROW(posted_at, property_id) < ROW('2025-11-15 11:18:17+00'::timestamp with time zone, 70045))
Planning Time: 0.426 ms
Execution Time: 0.060 ms
```

### R04: 18.757 ms -> 0.360 ms

Before:
```text
GroupAggregate (actual time=17.907..17.965 rows=6 loops=1)
  Group Key: (date_trunc('month'::text, p.posted_at))
  ->  Sort (actual time=17.892..17.898 rows=143 loops=1)
        Sort Key: (date_trunc('month'::text, p.posted_at))
        Sort Method: quicksort  Memory: 31kB
        ->  Nested Loop (actual time=11.355..17.858 rows=143 loops=1)
              Join Filter: (l.locality_id = p.locality_id)
              Rows Removed by Join Filter: 13865
              ->  Seq Scan on localities l (actual time=0.004..0.008 rows=1 loops=1)
                    Filter: ((locality_name)::text = 'Whitefield'::text)
                    Rows Removed by Filter: 99
              ->  Seq Scan on properties p (actual time=11.264..17.217 rows=14008 loops=1)
                    Filter: (((listing_type)::text = 'SALE'::text) AND ((property_type)::text = 'APARTMENT'::text) AND (EXTRACT(year FROM posted_at) =
                    Rows Removed by Filter: 106052
Planning Time: 0.455 ms
Execution Time: 18.005 ms
```
After:
```text
GroupAggregate (actual time=0.241..0.288 rows=6 loops=1)
  Group Key: (date_trunc('month'::text, p.posted_at))
  ->  Sort (actual time=0.215..0.227 rows=143 loops=1)
        Sort Key: (date_trunc('month'::text, p.posted_at))
        Sort Method: quicksort  Memory: 31kB
        ->  Nested Loop (actual time=0.046..0.163 rows=143 loops=1)
              ->  Seq Scan on localities l (actual time=0.009..0.016 rows=1 loops=1)
                    Filter: ((locality_name)::text = 'Whitefield'::text)
                    Rows Removed by Filter: 99
              ->  Index Only Scan using idx_prop_search on properties p (actual time=0.026..0.108 rows=143 loops=1)
                    Index Cond: ((locality_id = l.locality_id) AND (listing_type = 'SALE'::text) AND (property_type = 'APARTMENT'::text))
                    Filter: ((posted_at >= '2026-01-01 00:00:00+00'::timestamp with time zone) AND (posted_at < '2027-01-01 00:00:00+00'::timestamp wi
                    Rows Removed by Filter: 276
                    Heap Fetches: 0
Planning Time: 1.174 ms
Execution Time: 0.377 ms
```

### R11: 15.037 ms -> 0.461 ms

Before:
```text
GroupAggregate (actual time=11.540..11.545 rows=8 loops=1)
  Group Key: bhk, listing_type
  ->  Sort (actual time=11.526..11.527 rows=19 loops=1)
        Sort Key: bhk, listing_type
        Sort Method: quicksort  Memory: 25kB
        ->  Seq Scan on properties (actual time=0.658..11.494 rows=19 loops=1)
              Filter: ((project_id = 217) AND ((status)::text = 'ACTIVE'::text))
              Rows Removed by Filter: 120041
Planning Time: 0.302 ms
Execution Time: 11.593 ms
```
After:
```text
GroupAggregate (actual time=0.450..0.461 rows=8 loops=1)
  Group Key: bhk, listing_type
  ->  Sort (actual time=0.431..0.433 rows=19 loops=1)
        Sort Key: bhk, listing_type
        Sort Method: quicksort  Memory: 25kB
        ->  Bitmap Heap Scan on properties (actual time=0.070..0.385 rows=19 loops=1)
              Recheck Cond: (project_id = 217)
              Filter: ((status)::text = 'ACTIVE'::text)
              Rows Removed by Filter: 33
              Heap Blocks: exact=52
              ->  Bitmap Index Scan on idx_prop_project (actual time=0.031..0.031 rows=52 loops=1)
                    Index Cond: (project_id = 217)
Planning Time: 0.853 ms
Execution Time: 0.551 ms
```

## Write overhead

| Write query | Before (ms) | After (ms) | Change |
|---|---:|---:|---|
| W01 | 1.165 | 1.118 | 4% faster |
| W02 | 1.219 | 0.579 | 53% faster |
| W03 | 1.018 | 1.539 | 51% slower |
| W04 | 111.125 | 88.624 | 20% faster |
| W05 | 14.603 | 0.623 | 96% faster |

W01 and W03 are single-row INSERTs, so they barely notice the new indexes; their changes are fractions of a millisecond. The visible overhead is on bulk writes (`benchmarks/write_overhead.sh`, raw plans in `benchmarks/results/optimized/write_overhead.txt`, 3 runs each, rolled back):

| Statement | No new indexes (ms) | With our 8 indexes (ms) | Slower by |
|---|---:|---:|---:|
| bulk INSERT 20000 properties | 304.1 | 710.6 | 2.3x |
| bulk INSERT 10000 enquiries | 102.5 | 166.8 | 1.6x |
| UPDATE price on 14000 properties | 138.3 | 406.0 | 2.9x |

Is it acceptable? Yes for this workload: listings are read far more often than written (a search returns hundreds of rows per listing posted), the heaviest write is the nightly W04, and a 20,000-row bulk insert still takes under a second. A listing site with sustained bulk imports could drop `idx_prop_map` (5.9 MB, serves only R05) first. Each new index also costs memory and `VACUUM` time.

### Why W04 needed a storage setting, not just fewer indexes

W04 flips `status` on 14,440 rows. A PostgreSQL UPDATE is *HOT* (no new index entries at all) only if (1) no indexed column changes and (2) the new row version fits on the same page. We measured W04 five ways (3 runs each, raw plans in the result folders):

| Design | W04 avg (ms) |
|---|---:|
| Baseline: PK index only | 111.1 |
| `status` inside 6 indexes (key / INCLUDE / partial predicate) -- rejected | 301.6 |
| No index mentions `status`, fillfactor 100 (pages full, nowhere to put the new version) | 479.0 |
| No index mentions `status`, fillfactor 90 | 200.6 |
| No index mentions `status`, fillfactor 80 (**final**) | 88.6 |

This is why none of our indexes has `status` in it (not even as a partial-index predicate such as `WHERE status = 'ACTIVE'`, which would otherwise be the textbook search index). Searches check `status` on the handful of rows the index returns instead.

## Index storage

Measured with `pg_relation_size` right after `sql/05_indexes.sql` on a freshly loaded database (`benchmarks/results/optimized/index_sizes.txt`).

| Index | Table | Size | Table size | Index / table | Serves |
|---|---|---:|---:|---:|---|
| `idx_enq_created` | enquiries | 3104 kB | 6944 kB | 44.7% | R12 |
| `idx_enq_property_user` | enquiries | 3104 kB | 6944 kB | 44.7% | R06 R17 R19 R25 |
| `idx_prop_lister` | properties | 3720 kB | 22 MB | 16.7% | R06 R07 W02 W05 |
| `idx_prop_map` | properties | 5872 kB | 22 MB | 26.4% | R05 |
| `idx_prop_posted` | properties | 5832 kB | 22 MB | 26.2% | R20 R22 (W04) |
| `idx_prop_project` | properties | 4776 kB | 22 MB | 21.5% | R09 R11 R13 |
| `idx_prop_search` | properties | 9880 kB | 22 MB | 44.4% | R01 R02 R04 R15 R19 |
| `idx_visit_property_user` | site_visits | 1400 kB | 2312 kB | 60.6% | R06 R07 R12 |

Total new index storage **37 MB**; the whole database grew from **55 MB** (`benchmarks/results/baseline/db_sizes.txt`) to **97 MB**. The other ~5 MB is `fillfactor = 80` (properties heap 17 MB -> 22 MB). `idx_prop_search` is the biggest (44% of its table) because it has five key columns and four INCLUDE columns; it replaces what would otherwise be separate indexes for R01, R02, R04, R15 and R19.

## Queries we could not speed up, and why

| Query | Before -> after (ms) | Why |
|---|---|---|
| R14 | 19.4 -> 21.8 | Must read the 10.5k sold/rented rows of 2026 and every agent; a status-indexed variant ran in 8.5 ms but cost W04 2.7x, so it was rejected. |
| R17 | 39.0 -> 50.5 | Set difference: 20k old active listings minus those with any enquiry. It reads most of two tables; the hash anti join is already the right plan. |
| R18 | 26.8 -> 29.1 | Groups every active listing on five columns; a covering index on those columns needs `status` as a predicate (rejected for W04). |
| R21 | 22.7 -> 24.4 | Averages over all 14.7k rated visits joined to their property; reads most of both tables. |
| R12 | 14.4 -> 13.5 | Anti join against 35k site_visits; the index shrinks the enquiry side by 17x (5,928 of 100,000 rows), but hashing all of site_visits is the cost: ~10% gain. |
| R08 | 2.6 -> 3.6 | 23k-row table; index gave 2.2 vs 2.6 ms, below noise. |
| R16 / R24 / R10 / R23 / R03 | - | Already 0.05-0.6 ms; nothing to gain. |

An honest limit: these are all *reports or tiny tables* with generous large-data targets (250 ms to 5,000 ms). If R14/R21 ever need to be real-time, the next step is a summary table or materialized view refreshed nightly, not another index.

## Reproduce

```bash
createdb dolfin && psql -d dolfin -f sql/01_schema.sql && psql -d dolfin -f sql/02_load_data.sql   # run from the folder that contains seed_data/
psql -d dolfin -f sql/05_indexes.sql                       # ends with VACUUM (ANALYZE)
./benchmarks/run_benchmark.sh dolfin optimized 5 sql/06_optimized_queries.sql
psql -d dolfin -f sql/07_verify_results.sql
```
