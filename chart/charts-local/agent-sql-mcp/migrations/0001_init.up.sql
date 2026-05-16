-- Required for ILIKE-trigram + UUID generation if ever needed
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE customers (
    id         BIGSERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    email      TEXT NOT NULL UNIQUE,
    phone      TEXT,
    address    TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX customers_name_trgm_idx ON customers USING gin (name gin_trgm_ops);
CREATE INDEX customers_email_idx     ON customers (email);

CREATE TABLE orders (
    id          BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(id),
    status      TEXT NOT NULL CHECK (status IN ('placed','paid','shipped','delivered','cancelled')),
    total_cents BIGINT NOT NULL,
    currency    TEXT NOT NULL CHECK (length(currency) = 3),
    placed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE INDEX orders_placed_at_idx ON orders (placed_at DESC);

CREATE TABLE order_items (
    id         BIGSERIAL PRIMARY KEY,
    order_id   BIGINT NOT NULL REFERENCES orders(id),
    sku        TEXT NOT NULL,
    quantity   INT NOT NULL CHECK (quantity > 0),
    unit_cents BIGINT NOT NULL CHECK (unit_cents >= 0)
);
CREATE INDEX order_items_order_idx ON order_items (order_id);

CREATE TABLE mcp_audit (
    id          BIGSERIAL PRIMARY KEY,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_sub    TEXT,
    tool        TEXT,
    outcome     TEXT,
    duration_ms INT,
    reason      TEXT
);
CREATE INDEX mcp_audit_ts_idx       ON mcp_audit (ts DESC);
CREATE INDEX mcp_audit_user_sub_idx ON mcp_audit (user_sub, ts DESC);

-- Runtime role: SELECT-only on data tables + INSERT-only on mcp_audit.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'agent_sql_mcp_runtime') THEN
        CREATE ROLE agent_sql_mcp_runtime;
    END IF;
END
$$;

GRANT SELECT ON customers, orders, order_items TO agent_sql_mcp_runtime;
GRANT INSERT ON mcp_audit TO agent_sql_mcp_runtime;
GRANT USAGE, SELECT ON SEQUENCE mcp_audit_id_seq TO agent_sql_mcp_runtime;
