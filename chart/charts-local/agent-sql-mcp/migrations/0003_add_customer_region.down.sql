DROP INDEX IF EXISTS idx_customers_region;
ALTER TABLE customers DROP COLUMN IF EXISTS region;
