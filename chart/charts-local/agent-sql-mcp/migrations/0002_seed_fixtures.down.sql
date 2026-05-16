DELETE FROM order_items;
DELETE FROM orders;
DELETE FROM customers;
ALTER SEQUENCE order_items_id_seq RESTART WITH 1;
ALTER SEQUENCE orders_id_seq RESTART WITH 1;
ALTER SEQUENCE customers_id_seq RESTART WITH 1;
