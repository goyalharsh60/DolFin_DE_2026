-- =====================================================================
-- sql/02_load_data.sql : load the 12 seed CSV files into schema housing
--
-- Run from the project folder (paths are relative), after 01_schema.sql:
--     psql -d <your_database> -f sql/01_schema.sql
--     unzip seed_data.zip            # creates seed_data/ (do NOT commit it)
--     psql -d <your_database> -f sql/02_load_data.sql
--
-- For the large dataset change only the folder name (seed_data -> large_data).
-- Tables are loaded parents-before-children so every foreign key is satisfied.
-- =====================================================================
\set ON_ERROR_STOP on
SET search_path TO housing;

\copy cities            FROM 'seed_data/cities.csv'            WITH (FORMAT csv, HEADER true)
\copy localities        FROM 'seed_data/localities.csv'        WITH (FORMAT csv, HEADER true)
\copy builders          FROM 'seed_data/builders.csv'          WITH (FORMAT csv, HEADER true)
\copy amenities         FROM 'seed_data/amenities.csv'         WITH (FORMAT csv, HEADER true)
\copy projects          FROM 'seed_data/projects.csv'          WITH (FORMAT csv, HEADER true)
\copy project_amenities FROM 'seed_data/project_amenities.csv' WITH (FORMAT csv, HEADER true)
\copy users             FROM 'seed_data/users.csv'             WITH (FORMAT csv, HEADER true)
\copy properties        FROM 'seed_data/properties.csv'        WITH (FORMAT csv, HEADER true)
\copy price_changes     FROM 'seed_data/price_changes.csv'     WITH (FORMAT csv, HEADER true)
\copy enquiries         FROM 'seed_data/enquiries.csv'         WITH (FORMAT csv, HEADER true)
\copy site_visits       FROM 'seed_data/site_visits.csv'       WITH (FORMAT csv, HEADER true)
\copy shortlists        FROM 'seed_data/shortlists.csv'        WITH (FORMAT csv, HEADER true)

ANALYZE;

-- ---------------------------------------------------------------------
-- Verification 1: row counts must match the project brief (expected = seed_data; on large_data compare with the faculty counts)
-- ---------------------------------------------------------------------
SELECT t.table_name, t.loaded, t.expected,
       CASE WHEN t.loaded = t.expected THEN 'OK' ELSE 'MISMATCH' END AS result
FROM (
    SELECT 'cities' AS table_name,            (SELECT count(*) FROM cities)            AS loaded,         10 AS expected UNION ALL
    SELECT 'localities',                      (SELECT count(*) FROM localities),                         100 UNION ALL
    SELECT 'builders',                        (SELECT count(*) FROM builders),                           150 UNION ALL
    SELECT 'projects',                        (SELECT count(*) FROM projects),                          1200 UNION ALL
    SELECT 'amenities',                       (SELECT count(*) FROM amenities),                           15 UNION ALL
    SELECT 'project_amenities',               (SELECT count(*) FROM project_amenities),                 6806 UNION ALL
    SELECT 'users',                           (SELECT count(*) FROM users),                            40000 UNION ALL
    SELECT 'properties',                      (SELECT count(*) FROM properties),                      120060 UNION ALL
    SELECT 'price_changes',                   (SELECT count(*) FROM price_changes),                    23425 UNION ALL
    SELECT 'enquiries',                       (SELECT count(*) FROM enquiries),                       100000 UNION ALL
    SELECT 'site_visits',                     (SELECT count(*) FROM site_visits),                      35120 UNION ALL
    SELECT 'shortlists',                      (SELECT count(*) FROM shortlists),                       69999
) t
ORDER BY t.table_name;

-- ---------------------------------------------------------------------
-- Verification 2: integrity checks of our own (each must return 0 rows / 0)
-- ---------------------------------------------------------------------

-- I1. A property inside a project is in the project's locality.
SELECT 'I1 property locality differs from project locality' AS check_name, count(*) AS violations
FROM properties p JOIN projects pj ON pj.project_id = p.project_id
WHERE p.locality_id <> pj.locality_id;

-- I2. The current price equals the latest price change (where a change exists).
-- (one pass with DISTINCT ON; the first version probed price_changes once per property with no index
--  and took >11 minutes on the 20x data. See docs/05_scalability_report.md, 'What broke at scale'.)
SELECT 'I2 price differs from latest price_change.new_price' AS check_name, count(*) AS violations
FROM properties p
JOIN (SELECT DISTINCT ON (property_id) property_id, new_price
      FROM price_changes
      ORDER BY property_id, changed_at DESC) lc USING (property_id)
WHERE p.price <> lc.new_price;

-- I3. Only owners and agents list properties.
SELECT 'I3 listing by a seeker' AS check_name, count(*) AS violations
FROM properties p JOIN users u ON u.user_id = p.listed_by
WHERE u.user_type NOT IN ('OWNER', 'AGENT');

-- I4. Only seekers send enquiries, book visits and shortlist.
SELECT 'I4 enquiry/visit/shortlist by a non-seeker' AS check_name,
       (SELECT count(*) FROM enquiries  e JOIN users u USING (user_id) WHERE u.user_type <> 'SEEKER')
     + (SELECT count(*) FROM site_visits v JOIN users u USING (user_id) WHERE u.user_type <> 'SEEKER')
     + (SELECT count(*) FROM shortlists  s JOIN users u USING (user_id) WHERE u.user_type <> 'SEEKER') AS violations;

-- I5. Every site visit has an earlier or equal enquiry by the same user for the same property.
SELECT 'I5 site visit without enquiry by same user+property' AS check_name, count(*) AS violations
FROM site_visits v
WHERE NOT EXISTS (SELECT 1 FROM enquiries e WHERE e.property_id = v.property_id AND e.user_id = v.user_id);

-- I6. No enquiry or shortlist is dated before the property was posted.
SELECT 'I6 enquiry/shortlist before listing was posted' AS check_name,
       (SELECT count(*) FROM enquiries e  JOIN properties p USING (property_id) WHERE e.created_at < p.posted_at)
     + (SELECT count(*) FROM shortlists s JOIN properties p USING (property_id) WHERE s.added_at   < p.posted_at) AS violations;

-- I7. Every price change is a price cut, and happened after the listing was posted.
SELECT 'I7 price change that is not a cut or predates posting' AS check_name, count(*) AS violations
FROM price_changes c JOIN properties p USING (property_id)
WHERE c.new_price >= c.old_price OR c.changed_at < p.posted_at;

-- I8. Listings with no project (NULL project_id) -- the trap behind R13 (NOT IN + NULL).
SELECT 'I8 info only: listings with NULL project_id' AS check_name, count(*) AS rows_found
FROM properties WHERE project_id IS NULL;

-- I9. Projects without RERA id (NULL is allowed under UNIQUE).
SELECT 'I9 info only: projects with NULL rera_id' AS check_name, count(*) AS rows_found
FROM projects WHERE rera_id IS NULL;
