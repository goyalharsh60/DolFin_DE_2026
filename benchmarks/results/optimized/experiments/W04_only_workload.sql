SET search_path TO housing;
BEGIN;
-- @W04
UPDATE properties
SET status = 'INACTIVE'
WHERE status = 'ACTIVE'
  AND posted_at < TIMESTAMPTZ '2026-07-01 00:00:00+05:30' - interval '120 days';
-- @END
ROLLBACK;
