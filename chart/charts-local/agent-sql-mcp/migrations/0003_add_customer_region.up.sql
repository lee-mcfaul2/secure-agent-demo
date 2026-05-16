-- Adds a region tag to customers for row-level authz partitioning.
-- The customer tools (search_customer, lookup_customer) gate region='atlantis'
-- rows behind the customers:atlantis:read permission. See
-- ai_security_hybrid_authz workspace note and Task 29 in the demo plan.
ALTER TABLE customers ADD COLUMN IF NOT EXISTS region TEXT NOT NULL DEFAULT 'unknown';
CREATE INDEX IF NOT EXISTS idx_customers_region ON customers(region);
