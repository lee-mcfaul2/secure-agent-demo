-- Deterministic seed: setseed gives reproducible random()s for fixture generation.
SELECT setseed(0.42);

-- 100 customers.
INSERT INTO customers (name, email, phone, address, created_at)
SELECT
    'Customer ' || lpad(g::text, 3, '0'),
    'cust' || g || '@example.com',
    CASE WHEN g % 3 = 0 THEN NULL ELSE '+1-555-' || lpad((1000 + g)::text, 4, '0') END,
    CASE WHEN g % 4 = 0 THEN NULL ELSE g || ' Main St, Anytown' END,
    now() - ((100 - g) || ' days')::interval
FROM generate_series(1, 100) AS g;

-- ~500 orders, distributed across customers.
INSERT INTO orders (customer_id, status, total_cents, currency, placed_at)
SELECT
    1 + (g * 7) % 100,
    (ARRAY['placed','paid','shipped','delivered','cancelled'])[1 + (g % 5)],
    1000 + (g * 13) % 50000,
    'USD',
    now() - ((500 - g) || ' hours')::interval
FROM generate_series(1, 500) AS g;

-- ~2000 line items, distributed across orders.
INSERT INTO order_items (order_id, sku, quantity, unit_cents)
SELECT
    1 + (g % 500),
    'SKU-' || lpad((1 + (g % 50))::text, 3, '0'),
    1 + (g % 5),
    500 + (g * 17) % 9500
FROM generate_series(1, 2000) AS g;
