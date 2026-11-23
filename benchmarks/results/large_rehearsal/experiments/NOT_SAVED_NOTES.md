# Experiments run on the 20x rehearsal database whose raw output was NOT saved

Only console observations (no raw plan files) exist for these. Re-run them on the official large data if you want evidence files.

- R25 with `WHERE (property_id,user_id) IN (SELECT property_id,user_id FROM enquiries)` (hashed SubPlan, exceeds work_mem at 20x): killed after 10 min 34 s without finishing. Replaced by LEFT JOIN on DISTINCT pairs (sql/06_optimized_queries.sql): about 2.3 s at 20x.
- I2 integrity check in sql/02_load_data.sql (correlated subquery): killed after 11 min at 20x. Replaced by DISTINCT ON join.
- `CLUSTER properties USING idx_prop_search`: R01 2.1 ms, R02 2.8 ms, R09 98 ms, but W04 6.6 s (fillfactor 70 still 3.5-3.9 s). Rejected.
- Saved: `status_partial_indexes/` (partial indexes on status = 'ACTIVE': W04 18.3 s) and `first_rehearsal_run_no_cluster/` (an earlier full run, slightly different timings).
