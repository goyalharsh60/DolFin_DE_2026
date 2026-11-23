-- =====================================================================
-- Phase 4: indexes for the 30-query workload  (DolFin, team T0019)
-- Run AFTER sql/01_schema.sql + sql/02_load_data.sql, then VACUUM (ANALYZE).
-- Baseline had only the 20 PK/UNIQUE indexes. Every index below says which
-- queries it serves and why that type / column order was chosen.
-- Rules followed: no server settings changed, no data changed.
-- =====================================================================
SET search_path TO housing;

-- ---------------------------------------------------------------------
-- properties (120,060 rows)
-- ---------------------------------------------------------------------

-- Serves R01, R02, R19.
-- Search screens always filter on ACTIVE listings, so the index is PARTIAL (only ~37k of
-- 120k rows). Equality columns first (locality_id, listing_type, bhk) then the range/sort
-- column price. INCLUDE puts the remaining output columns in the leaf pages so R01 can be
-- answered without visiting the table (Index Only Scan). R19 uses the (locality_id,
-- listing_type) prefix to find active sale listings of the 10 Bengaluru localities.
CREATE INDEX idx_prop_active_search ON properties (locality_id, listing_type, bhk, price)
  INCLUDE (property_type, carpet_area_sqft, furnishing, available_from)
  WHERE status = 'ACTIVE';

-- Serves R06, R07, W02, W05.
-- "Everything owner/agent X listed". Equality columns first: listed_by, status, listing_type,
-- then property_id last, so min()/max(property_id) in W02/W05 is read from the end of one
-- index range instead of walking the whole primary key. Not partial, because R06 lists the
-- owner's listings in every status.
CREATE INDEX idx_prop_lister ON properties (listed_by, status, listing_type, property_id);

-- Serves R09, R11, R13.
-- Foreign-key column (project_id) with the columns those queries read, so all three are
-- Index Only Scans: R11 groups by bhk/listing_type with price min/max filtered on status;
-- R09 ranks by price; R13 only needs to know whether a project_id exists.
CREATE INDEX idx_prop_project ON properties (project_id) INCLUDE (status, price, bhk, listing_type);

-- Serves R04, R15.
-- Both aggregate price per sq ft for one city/locality and one property type.
-- Covering index (locality_id, listing_type, property_type) with posted_at, price and area
-- included -> Index Only Scan, no table visits.
CREATE INDEX idx_prop_locality_cover ON properties (locality_id, listing_type, property_type)
  INCLUDE (posted_at, price, carpet_area_sqft);

-- Serves R17, R20, R22, W04.
-- Time-ordered access. DESC + property_id gives R22 a keyset ("seek") page instead of
-- OFFSET; the range on posted_at makes R20 and the ">90/120 days old" tests of R17/W04
-- index range scans. INCLUDE holds the columns R22 shows and the status filter of
-- R17/W04 so those can be checked inside the index.
CREATE INDEX idx_prop_posted ON properties (posted_at DESC, property_id DESC)
  INCLUDE (listed_by, listing_type, status, price);

-- Serves R05.
-- Map view: active rentals in a lat/lng box, LIMIT 200. Partial on the exact filter
-- (RENT + ACTIVE). Latitude first (range), longitude second so the box test is done inside
-- the index; price and bhk are included so no table visit is needed.
CREATE INDEX idx_prop_map ON properties (latitude, longitude) INCLUDE (price, bhk)
  WHERE listing_type = 'RENT' AND status = 'ACTIVE';

-- Serves R18.
-- Fraud check groups ACTIVE listings by five columns. Partial + covering in GROUP BY order
-- lets PostgreSQL read the rows already sorted and group them in the index.
CREATE INDEX idx_prop_dup_check ON properties (listed_by, locality_id, carpet_area_sqft, floor_no, bhk)
  WHERE status = 'ACTIVE';

-- ---------------------------------------------------------------------
-- enquiries (100,000 rows): foreign keys are NOT indexed by PostgreSQL
-- ---------------------------------------------------------------------

-- Serves R06, R17, R19, R25.
-- All four look up enquiries of a property (and R25 also by user). Composite
-- (property_id, user_id) answers both; created_at is included so R19's max(created_at)
-- and counts come from the index.
CREATE INDEX idx_enq_property_user ON enquiries (property_id, user_id) INCLUDE (created_at);

-- Serves R12.
-- Date window on enquiries.created_at (June 2026 = ~6% of rows); property_id/user_id are
-- included so the anti join key is available without visiting the table.
CREATE INDEX idx_enq_created ON enquiries (created_at) INCLUDE (property_id, user_id);

-- ---------------------------------------------------------------------
-- site_visits (35,120 rows)
-- ---------------------------------------------------------------------

-- Serves R06, R07, R12.
-- property_id first: R06 counts visits per property, R07 reaches visits through the
-- lister's properties, R12 anti-joins on (property_id, user_id). scheduled_at and visit_id
-- are included for R07's date test and R06's count.
CREATE INDEX idx_visit_property_user ON site_visits (property_id, user_id)
  INCLUDE (scheduled_at, visit_id);

-- Serves R21.
-- Only the 14,694 visits that have a rating matter (partial); rating is included.
CREATE INDEX idx_visit_rated ON site_visits (property_id) INCLUDE (feedback_rating)
  WHERE feedback_rating IS NOT NULL;

-- ---------------------------------------------------------------------
-- price_changes (23,425 rows)
-- ---------------------------------------------------------------------

-- Serves R08.
-- Range on changed_at (one month = 3% of rows). Prices are included so the price test
-- (new_price <= old_price * 0.9) is applied inside the index.
CREATE INDEX idx_pc_changed ON price_changes (changed_at) INCLUDE (property_id, old_price, new_price);

-- ---------------------------------------------------------------------
-- NOT indexed on purpose
--   R03, R10, R23  already use PK/UNIQUE indexes (0.04 - 0.16 ms).
--   R16            projects has 1,200 rows; a trigram GIN index would cost more than the
--                  0.6 ms Seq Scan it replaces (revisit if projects grows far beyond 24k).
--   R24            projects / builders are tiny (1,200 / 150 rows), 0.3 ms.
--   R14, R25       aggregation-bound; see docs/04_optimization_report.md.
-- ---------------------------------------------------------------------
VACUUM (ANALYZE);
