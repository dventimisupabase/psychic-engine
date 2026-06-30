-- migtest crawl-stage data model
-- Single size knob: bump :scale for walk/run. Generated entirely server-side.
\set scale 1

\timing on
SET max_parallel_workers_per_gather = 0;  -- keep generation deterministic with setseed
SELECT setseed(0.42);

BEGIN;

DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
SET search_path = shop, public;

-- ---------- dimension tables ----------
CREATE TABLE shop.categories (
  category_id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name        text NOT NULL,
  slug        text NOT NULL UNIQUE
);
INSERT INTO shop.categories (name, slug)
SELECT 'Category ' || g, 'category-' || g
FROM generate_series(1, 25) g;

CREATE TABLE shop.products (
  product_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  category_id int NOT NULL,
  name        text NOT NULL,
  sku         text NOT NULL UNIQUE,
  price       numeric(10,2) NOT NULL,
  in_stock    boolean NOT NULL,
  tags        text[] NOT NULL,
  attributes  jsonb NOT NULL,
  created_at  timestamptz NOT NULL
);
INSERT INTO shop.products (category_id, name, sku, price, in_stock, tags, attributes, created_at)
SELECT
  (floor(random()*25)+1)::int,
  'Product ' || g,
  'SKU-' || lpad(g::text, 8, '0'),
  round((random()*490+10)::numeric, 2),
  random() < 0.85,
  ARRAY[
    (ARRAY['new','sale','popular','clearance','featured'])[(floor(random()*5)+1)::int],
    (ARRAY['small','medium','large'])[(floor(random()*3)+1)::int]
  ],
  jsonb_build_object(
    'color',    (ARRAY['red','green','blue','black','white'])[(floor(random()*5)+1)::int],
    'weight_g', (floor(random()*2000)+50)::int,
    'rating',   round((random()*4+1)::numeric, 1)
  ),
  now() - (random()*interval '730 days')
FROM generate_series(1, (:scale)*500) g;

CREATE TABLE shop.users (
  user_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email      text NOT NULL UNIQUE,
  full_name  text NOT NULL,
  country    text NOT NULL,
  is_active  boolean NOT NULL,
  metadata   jsonb NOT NULL,
  created_at timestamptz NOT NULL
);
INSERT INTO shop.users (email, full_name, country, is_active, metadata, created_at)
SELECT
  'user' || g || '@example.com',
  'User ' || g,
  (ARRAY['US','GB','DE','FR','BR','IN','JP','CA','AU','NG'])[(floor(random()*10)+1)::int],
  random() < 0.9,
  jsonb_build_object(
    'plan',       (ARRAY['free','pro','enterprise'])[(floor(random()*3)+1)::int],
    'newsletter', random() < 0.5
  ),
  now() - power(random(),2)*interval '1095 days'   -- somewhat recent-heavy signups
FROM generate_series(1, (:scale)*5000) g;

-- ---------- fact tables ----------
CREATE TABLE shop.orders (
  order_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    bigint NOT NULL,
  status     text NOT NULL,
  total      numeric(12,2) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL,
  shipping   jsonb NOT NULL
);
INSERT INTO shop.orders (user_id, status, total, created_at, shipping)
SELECT
  (floor(power(random(),2)*(:scale)*5000)+1)::bigint,   -- skew: early-adopter users order more
  (ARRAY['pending','paid','shipped','delivered','cancelled'])[(floor(random()*5)+1)::int],
  0,
  now() - power(random(),3)*interval '365 days',        -- recent-heavy
  jsonb_build_object(
    'country', (ARRAY['US','GB','DE','FR','BR'])[(floor(random()*5)+1)::int],
    'method',  (ARRAY['standard','express','pickup'])[(floor(random()*3)+1)::int]
  )
FROM generate_series(1, (:scale)*25000) g;

CREATE TABLE shop.order_items (
  order_item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id      bigint NOT NULL,
  product_id    bigint NOT NULL,
  quantity      int NOT NULL,
  unit_price    numeric(10,2) NOT NULL,
  line_total    numeric(12,2) NOT NULL,
  UNIQUE (order_id, product_id)
);
-- 1..5 items per order. A per-row random() count column drives the fan-out via
-- LATERAL generate_series; random() in a LIMIT is evaluated ONCE per query, so it
-- cannot vary the count per order. DISTINCT ON dedups for the UNIQUE(order_id,product_id).
WITH order_counts AS (
  SELECT order_id, (floor(random()*5)+1)::int AS n_items
  FROM shop.orders
),
picks AS (
  SELECT oc.order_id,
         (floor(random()*((:scale)*500))+1)::bigint AS product_id,
         (floor(random()*5)+1)::int                 AS quantity
  FROM order_counts oc
  CROSS JOIN LATERAL generate_series(1, oc.n_items) gs
),
deduped AS (
  SELECT DISTINCT ON (order_id, product_id) order_id, product_id, quantity
  FROM picks
  ORDER BY order_id, product_id, quantity
)
INSERT INTO shop.order_items (order_id, product_id, quantity, unit_price, line_total)
SELECT d.order_id, d.product_id, d.quantity, p.price,
       round(d.quantity * p.price, 2)
FROM deduped d
JOIN shop.products p ON p.product_id = d.product_id;

-- backfill order totals from the line items
UPDATE shop.orders o
SET total = s.t
FROM (SELECT order_id, sum(line_total) AS t FROM shop.order_items GROUP BY order_id) s
WHERE o.order_id = s.order_id;

CREATE TABLE shop.events (
  event_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    bigint NOT NULL,
  event_type text NOT NULL,
  ts         timestamptz NOT NULL,
  payload    jsonb NOT NULL
);
INSERT INTO shop.events (user_id, event_type, ts, payload)
SELECT
  (floor(power(random(),3)*(:scale)*5000)+1)::bigint,   -- Zipfian-ish: few users dominate traffic
  (ARRAY['page_view','click','add_to_cart','purchase','search','login','logout'])[(floor(random()*7)+1)::int],
  now() - power(random(),5)*interval '365 days',        -- strongly recent-heavy
  jsonb_build_object(
    'session', md5(random()::text),
    'ip',  (floor(random()*255))::int||'.'||(floor(random()*255))::int||'.'||(floor(random()*255))::int||'.'||(floor(random()*255))::int,
    'ua',  (ARRAY['Chrome','Firefox','Safari','Edge'])[(floor(random()*4)+1)::int],
    'props', jsonb_build_object('a', (floor(random()*100))::int, 'b', md5(random()::text))
  )
FROM generate_series(1, (:scale)*150000) g;

-- ---------- constraints + indexes (after bulk load) ----------
ALTER TABLE shop.products    ADD CONSTRAINT fk_products_category FOREIGN KEY (category_id) REFERENCES shop.categories(category_id);
ALTER TABLE shop.orders      ADD CONSTRAINT fk_orders_user       FOREIGN KEY (user_id)     REFERENCES shop.users(user_id);
ALTER TABLE shop.order_items ADD CONSTRAINT fk_items_order       FOREIGN KEY (order_id)    REFERENCES shop.orders(order_id);
ALTER TABLE shop.order_items ADD CONSTRAINT fk_items_product     FOREIGN KEY (product_id)  REFERENCES shop.products(product_id);
ALTER TABLE shop.events      ADD CONSTRAINT fk_events_user       FOREIGN KEY (user_id)     REFERENCES shop.users(user_id);

CREATE INDEX idx_products_category ON shop.products(category_id);
CREATE INDEX idx_orders_user       ON shop.orders(user_id);
CREATE INDEX idx_orders_created    ON shop.orders(created_at);
CREATE INDEX idx_items_product     ON shop.order_items(product_id);
CREATE INDEX idx_events_user       ON shop.events(user_id);
CREATE INDEX idx_events_ts         ON shop.events(ts);
CREATE INDEX idx_events_payload    ON shop.events USING gin (payload);

COMMIT;

ANALYZE shop.categories, shop.products, shop.users, shop.orders, shop.order_items, shop.events;
