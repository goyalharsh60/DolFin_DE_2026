-- =====================================================================
-- Phase 4: proof that every rewritten query returns the same result as the original.
-- For each rewritten query: row counts, rows only in the original, rows only in the
-- rewrite (EXCEPT ALL, so duplicates count), and an md5 of the ordered result where the
-- ORDER BY is deterministic. Expected: rows_only_* = 0, same_order = true.
-- R13 is the one query whose result is SUPPOSED to change (the original is wrong).
-- Run:  psql -d <db> -f sql/07_verify_results.sql
-- =====================================================================
SET search_path TO housing;
\pset format aligned

CREATE TEMP TABLE chk (query text, orig_rows bigint, new_rows bigint, only_in_orig bigint, only_in_new bigint, same_order boolean, note text);

-- ---------- R04 ----------
WITH a AS (
  SELECT date_trunc('month', p.posted_at) AS month, count(*) AS listings, round(avg(p.price / p.carpet_area_sqft), 0) AS avg_price_per_sqft
  FROM properties p JOIN localities l ON l.locality_id = p.locality_id
  WHERE l.locality_name = 'Whitefield' AND p.listing_type = 'SALE' AND p.property_type = 'APARTMENT' AND EXTRACT(YEAR FROM p.posted_at) = 2026
  GROUP BY 1 ORDER BY 1),
b AS (
  SELECT date_trunc('month', p.posted_at) AS month, count(*) AS listings, round(avg(p.price / p.carpet_area_sqft), 0) AS avg_price_per_sqft
  FROM properties p JOIN localities l ON l.locality_id = p.locality_id
  WHERE l.locality_name = 'Whitefield' AND p.listing_type = 'SALE' AND p.property_type = 'APARTMENT' AND p.posted_at >= '2026-01-01' AND p.posted_at < '2027-01-01'
  GROUP BY 1 ORDER BY 1)
INSERT INTO chk SELECT 'R04', (SELECT count(*) FROM a), (SELECT count(*) FROM b),
  (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b) x), (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a) y),
  (SELECT md5(string_agg(a::text, '|')) FROM a) = (SELECT md5(string_agg(b::text, '|')) FROM b), NULL;

-- ---------- R07 ----------
WITH a AS (
  SELECT v.visit_id, v.property_id, v.scheduled_at, u.full_name AS visitor, u.phone
  FROM site_visits v JOIN properties p ON p.property_id = v.property_id JOIN users u ON u.user_id = v.user_id
  WHERE p.listed_by = 4723 AND DATE(v.scheduled_at) = '2026-07-01' ORDER BY v.scheduled_at),
b AS (
  SELECT v.visit_id, v.property_id, v.scheduled_at, u.full_name AS visitor, u.phone
  FROM site_visits v JOIN properties p ON p.property_id = v.property_id JOIN users u ON u.user_id = v.user_id
  WHERE p.listed_by = 4723 AND v.scheduled_at >= '2026-07-01' AND v.scheduled_at < '2026-07-02' ORDER BY v.scheduled_at)
INSERT INTO chk SELECT 'R07', (SELECT count(*) FROM a), (SELECT count(*) FROM b),
  (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b) x), (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a) y),
  (SELECT md5(string_agg(a::text, '|')) FROM a) = (SELECT md5(string_agg(b::text, '|')) FROM b), 'ordered by scheduled_at only; ties possible';

-- ---------- R19 ----------
WITH a AS (
  SELECT p.property_id, p.price,
         (SELECT count(*) FROM enquiries e WHERE e.property_id = p.property_id) AS enquiries,
         (SELECT max(e.created_at) FROM enquiries e WHERE e.property_id = p.property_id) AS last_enquiry_at
  FROM properties p JOIN localities l ON l.locality_id = p.locality_id
  WHERE l.city_id = 1 AND p.listing_type = 'SALE' AND p.status = 'ACTIVE'),
b AS (
  SELECT p.property_id, p.price, e.enquiries, e.last_enquiry_at
  FROM properties p JOIN localities l ON l.locality_id = p.locality_id
  CROSS JOIN LATERAL (SELECT count(*) AS enquiries, max(created_at) AS last_enquiry_at FROM enquiries e WHERE e.property_id = p.property_id) e
  WHERE l.city_id = 1 AND p.listing_type = 'SALE' AND p.status = 'ACTIVE')
INSERT INTO chk SELECT 'R19', (SELECT count(*) FROM a), (SELECT count(*) FROM b),
  (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b) x), (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a) y),
  (SELECT md5(string_agg(a::text, '|' ORDER BY property_id)) FROM a) = (SELECT md5(string_agg(b::text, '|' ORDER BY property_id)) FROM b),
  'ORDER BY enquiries DESC has ties, so compared as sets sorted by property_id';

-- ---------- R20 ----------
WITH a AS (
  SELECT day, listings, sum(listings) OVER (ORDER BY day) AS running_total FROM (
    SELECT posted_at::date AS day, count(*) AS listings FROM properties WHERE posted_at::date BETWEEN '2026-06-01' AND '2026-06-30' GROUP BY 1) d ORDER BY day),
b AS (
  SELECT day, listings, sum(listings) OVER (ORDER BY day) AS running_total FROM (
    SELECT posted_at::date AS day, count(*) AS listings FROM properties WHERE posted_at >= '2026-06-01' AND posted_at < '2026-07-01' GROUP BY 1) d ORDER BY day)
INSERT INTO chk SELECT 'R20', (SELECT count(*) FROM a), (SELECT count(*) FROM b),
  (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b) x), (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a) y),
  (SELECT md5(string_agg(a::text, '|')) FROM a) = (SELECT md5(string_agg(b::text, '|')) FROM b), NULL;

-- ---------- R22 (page 2,001, 25 rows per page) ----------
WITH a AS (
  SELECT property_id, listed_by, listing_type, status, price, posted_at FROM properties ORDER BY posted_at DESC OFFSET 50000 LIMIT 25),
b AS (
  SELECT property_id, listed_by, listing_type, status, price, posted_at FROM properties
  WHERE (posted_at, property_id) < (TIMESTAMPTZ '2025-11-15 11:18:17+00', 70045) ORDER BY posted_at DESC, property_id DESC LIMIT 25)
INSERT INTO chk SELECT 'R22', (SELECT count(*) FROM a), (SELECT count(*) FROM b),
  (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b) x), (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a) y),
  (SELECT md5(string_agg(a::text, '|')) FROM a) = (SELECT md5(string_agg(b::text, '|')) FROM b),
  'posted_at is unique in the seed data (' || (SELECT count(DISTINCT posted_at) FROM properties) || ' distinct of ' || (SELECT count(*) FROM properties) || '), so the OFFSET order is deterministic';

-- ---------- R25 ----------
WITH a AS (
  SELECT l.city_id, count(*) AS shortlists,
         count(*) FILTER (WHERE EXISTS (SELECT 1 FROM enquiries e WHERE e.property_id = s.property_id AND e.user_id = s.user_id)) AS converted
  FROM shortlists s JOIN properties p ON p.property_id = s.property_id JOIN localities l ON l.locality_id = p.locality_id GROUP BY l.city_id ORDER BY l.city_id),
b AS (
  SELECT l.city_id, count(*) AS shortlists, count(e.property_id) AS converted
  FROM shortlists s JOIN properties p ON p.property_id = s.property_id JOIN localities l ON l.locality_id = p.locality_id
  LEFT JOIN (SELECT DISTINCT property_id, user_id FROM enquiries) e ON e.property_id = s.property_id AND e.user_id = s.user_id
  GROUP BY l.city_id ORDER BY l.city_id)
INSERT INTO chk SELECT 'R25', (SELECT count(*) FROM a), (SELECT count(*) FROM b),
  (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b) x), (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a) y),
  (SELECT md5(string_agg(a::text, '|')) FROM a) = (SELECT md5(string_agg(b::text, '|')) FROM b), NULL;

-- ---------- R13: the result is SUPPOSED to change ----------
WITH a AS (SELECT pj.project_id, pj.project_name, pj.possession_status FROM projects pj WHERE pj.project_id NOT IN (SELECT p.project_id FROM properties p)),
b AS (SELECT pj.project_id, pj.project_name, pj.possession_status FROM projects pj WHERE NOT EXISTS (SELECT 1 FROM properties p WHERE p.project_id = pj.project_id)),
c AS (SELECT pj.project_id, pj.project_name, pj.possession_status FROM projects pj LEFT JOIN properties p ON p.project_id = pj.project_id WHERE p.property_id IS NULL)  -- independent third method
INSERT INTO chk SELECT 'R13 (fix)', (SELECT count(*) FROM a), (SELECT count(*) FROM b),
  (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b) x), (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a) y), NULL,
  'ORIGINAL IS WRONG: NULL project_id rows in properties = ' || (SELECT count(*) FROM properties WHERE project_id IS NULL)
  || '; LEFT JOIN anti-join (3rd method) = ' || (SELECT count(*) FROM c) || ' rows, identical to NOT EXISTS: ' || ((SELECT count(*) FROM (SELECT * FROM b EXCEPT SELECT * FROM c) z) = 0 AND (SELECT count(*) FROM b) = (SELECT count(*) FROM c));

-- ---------- R05: LIMIT 200 with no ORDER BY, so ANY 200 qualifying rows are a correct answer ----------
-- The set of 200 rows can legitimately differ between plans. What must hold: 200 distinct rows, every one
-- really an active rental inside the box, and at least 200 qualifying rows exist.
WITH b AS (
  SELECT property_id, latitude, longitude, price, bhk FROM properties
  WHERE listing_type = 'RENT' AND status = 'ACTIVE' AND latitude BETWEEN 12.90 AND 13.00 AND longitude BETWEEN 77.55 AND 77.65 LIMIT 200)
INSERT INTO chk SELECT 'R05 (LIMIT, no ORDER BY)', NULL, (SELECT count(*) FROM b), NULL, NULL, NULL,
  'distinct ids = ' || (SELECT count(DISTINCT property_id) FROM b)
  || '; rows violating the filter = ' || (SELECT count(*) FROM b JOIN properties p USING (property_id)
        WHERE NOT (p.listing_type = 'RENT' AND p.status = 'ACTIVE' AND p.latitude BETWEEN 12.90 AND 13.00 AND p.longitude BETWEEN 77.55 AND 77.65))
  || '; qualifying rows in table = ' || (SELECT count(*) FROM properties WHERE listing_type = 'RENT' AND status = 'ACTIVE' AND latitude BETWEEN 12.90 AND 13.00 AND longitude BETWEEN 77.55 AND 77.65);

SELECT * FROM chk ORDER BY query;
