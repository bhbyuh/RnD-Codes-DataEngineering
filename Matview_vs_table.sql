-- =====================================================================
--  Materialized View vs Table : hands-on comparison in PostgreSQL
--  Run with:  psql -d <your_database> -a -f mv_vs_table_demo.sql
--  (-a echoes each statement so you can read output next to the SQL)
--  Some statements are EXPECTED to fail - that is part of the demo.
-- =====================================================================

\timing on
SET search_path TO public;

-- ---------------------------------------------------------------------
-- 0. SETUP : a 1M-row source table
-- ---------------------------------------------------------------------
\echo '===== 0. SETUP ====='
DROP MATERIALIZED VIEW IF EXISTS mv_daily_sales;
DROP TABLE IF EXISTS tbl_daily_sales;
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    order_id   bigserial PRIMARY KEY,
    order_date date          NOT NULL,
    region     text          NOT NULL,
    amount     numeric(10,2) NOT NULL
);

INSERT INTO orders (order_date, region, amount)
SELECT DATE '2026-01-01' + (random() * 89)::int,
       (ARRAY['North','South','East','West'])[1 + floor(random() * 4)::int],
       round((random() * 500)::numeric, 2)
FROM generate_series(1, 1000000);

ANALYZE orders;

-- The "expensive" query we want to pre-compute (note the time)
\echo '----- Raw aggregation on 1M rows (slow path) -----'
SELECT order_date, region, SUM(amount) AS total_amount, COUNT(*) AS orders
FROM orders
GROUP BY order_date, region
ORDER BY order_date, region
LIMIT 5;

-- ---------------------------------------------------------------------
-- 1. CREATE BOTH : same query, two storage approaches
-- ---------------------------------------------------------------------
\echo '===== 1. CREATE TABLE vs MATERIALIZED VIEW ====='
CREATE TABLE tbl_daily_sales AS
SELECT order_date, region, SUM(amount) AS total_amount, COUNT(*) AS orders
FROM orders
GROUP BY order_date, region;

CREATE MATERIALIZED VIEW mv_daily_sales AS
SELECT order_date, region, SUM(amount) AS total_amount, COUNT(*) AS orders
FROM orders
GROUP BY order_date, region;

CREATE UNIQUE INDEX ON tbl_daily_sales (order_date, region);
CREATE UNIQUE INDEX ON mv_daily_sales  (order_date, region);  -- needed for CONCURRENTLY later

-- ---------------------------------------------------------------------
-- 2. READ BOTH : identical results, both fast (this is what you noticed)
-- ---------------------------------------------------------------------
\echo '===== 2. READS LOOK IDENTICAL ====='
SELECT * FROM tbl_daily_sales ORDER BY order_date, region LIMIT 5;
SELECT * FROM mv_daily_sales  ORDER BY order_date, region LIMIT 5;

\echo '----- Rows that differ between them (expect 0) -----'
SELECT COUNT(*) AS differences FROM (
    (SELECT * FROM tbl_daily_sales EXCEPT SELECT * FROM mv_daily_sales)
    UNION ALL
    (SELECT * FROM mv_daily_sales  EXCEPT SELECT * FROM tbl_daily_sales)
) d;

-- ---------------------------------------------------------------------
-- 3. NEW DATA ARRIVES : both go stale
-- ---------------------------------------------------------------------
\echo '===== 3. NEW SOURCE DATA -> BOTH STALE ====='
INSERT INTO orders (order_date, region, amount)
SELECT DATE '2026-04-15', 'North', 100 FROM generate_series(1, 10);

SELECT 'table' AS src, * FROM tbl_daily_sales WHERE order_date = '2026-04-15'
UNION ALL
SELECT 'mv',           * FROM mv_daily_sales  WHERE order_date = '2026-04-15';
\echo '^^ 0 rows: neither knows about the new orders yet'

-- ---------------------------------------------------------------------
-- 4. REFRESH : the first real difference
-- ---------------------------------------------------------------------
\echo '===== 4. REFRESHING ====='

\echo '----- MV: one command, query is already stored -----'
REFRESH MATERIALIZED VIEW mv_daily_sales;

\echo '----- Table: YOU must re-type (and keep in sync) the logic -----'
BEGIN;
TRUNCATE tbl_daily_sales;
INSERT INTO tbl_daily_sales
SELECT order_date, region, SUM(amount), COUNT(*)
FROM orders
GROUP BY order_date, region;
COMMIT;

SELECT 'table' AS src, * FROM tbl_daily_sales WHERE order_date = '2026-04-15'
UNION ALL
SELECT 'mv',           * FROM mv_daily_sales  WHERE order_date = '2026-04-15';

-- ---------------------------------------------------------------------
-- 5. SELF-DOCUMENTING : MV remembers where its data came from
-- ---------------------------------------------------------------------
\echo '===== 5. WHERE DID THE DATA COME FROM? ====='
SELECT matviewname, definition
FROM pg_matviews
WHERE matviewname = 'mv_daily_sales';

SELECT tablename, '(no definition - Postgres has no idea how this was built)' AS definition
FROM pg_tables
WHERE tablename = 'tbl_daily_sales';

-- ---------------------------------------------------------------------
-- 6. WRITE PROTECTION : table can silently drift, MV cannot
-- ---------------------------------------------------------------------
\echo '===== 6. ACCIDENTAL WRITES ====='
UPDATE tbl_daily_sales SET total_amount = 0 WHERE order_date = '2026-01-01';
\echo '^^ table accepted a wrong value - it now disagrees with orders'

UPDATE mv_daily_sales SET total_amount = 0 WHERE order_date = '2026-01-01';
\echo '^^ EXPECTED ERROR: cannot change materialized view'

\echo '----- Rows where each object disagrees with the source -----'
WITH truth AS (
    SELECT order_date, region, SUM(amount) AS total_amount, COUNT(*) AS orders
    FROM orders GROUP BY order_date, region
)
SELECT 'table' AS src, COUNT(*) AS wrong_rows FROM
    (SELECT * FROM tbl_daily_sales EXCEPT SELECT * FROM truth) t
UNION ALL
SELECT 'mv', COUNT(*) FROM
    (SELECT * FROM mv_daily_sales  EXCEPT SELECT * FROM truth) m;

-- ---------------------------------------------------------------------
-- 7. DEPENDENCY TRACKING : MV is linked to its source
-- ---------------------------------------------------------------------
\echo '===== 7. DEPENDENCIES ====='
ALTER TABLE orders DROP COLUMN amount;
\echo '^^ EXPECTED ERROR: mv_daily_sales depends on column amount'
\echo '   (tbl_daily_sales would never stop you - it would just break your ETL later)'

-- ---------------------------------------------------------------------
-- 8. WHERE THE TABLE WINS : incremental refresh
--    Postgres REFRESH always recomputes EVERYTHING (1M rows).
--    A table lets you update only what changed.
-- ---------------------------------------------------------------------
\echo '===== 8. INCREMENTAL UPDATE (table advantage) ====='
INSERT INTO orders (order_date, region, amount)
SELECT DATE '2026-04-16', 'South', 50 FROM generate_series(1, 5);

\echo '----- MV: full recompute of all 1M rows (note the time) -----'
REFRESH MATERIALIZED VIEW mv_daily_sales;

\echo '----- Table: upsert only the changed day (note the time) -----'
INSERT INTO tbl_daily_sales
SELECT order_date, region, SUM(amount), COUNT(*)
FROM orders
WHERE order_date = '2026-04-16'
GROUP BY order_date, region
ON CONFLICT (order_date, region)
DO UPDATE SET total_amount = EXCLUDED.total_amount,
              orders       = EXCLUDED.orders;

-- ---------------------------------------------------------------------
-- 9. REFRESH WITHOUT BLOCKING READERS
-- ---------------------------------------------------------------------
\echo '===== 9. CONCURRENT REFRESH ====='
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_sales;
\echo '^^ readers keep reading the old data while this runs (needs the unique index)'
\echo '   Plain REFRESH, or TRUNCATE on the table, locks readers out until done.'

\echo '===== DONE ====='
