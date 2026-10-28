-- =====================================================================
--  Functions vs Stored Procedures : hands-on practice in PostgreSQL
--  Run with:
--    docker exec -i some-postgres psql -U postgres -a < functions_procedures_demo.sql
--  (-a echoes each statement so you can read output next to the SQL)
--
--  Reuses public.orders (1M rows) from mv_vs_table_demo.sql - READ ONLY.
--  Everything new lives in schema "practice"; the script drops and
--  recreates it, so you can re-run it any time.
--  Some statements are EXPECTED to fail - that is part of the demo.
-- =====================================================================

\set VERBOSITY terse
DROP SCHEMA IF EXISTS practice CASCADE;
CREATE SCHEMA practice;
SET search_path TO practice, public;


-- =====================================================================
--  PART A : FUNCTIONS
--  A function RETURNS a value, is used inside SELECT/WHERE/JOIN,
--  and always runs inside the caller's transaction.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Simplest function: LANGUAGE sql, default parameter
-- ---------------------------------------------------------------------
\echo '===== 1. SQL function + default / named parameters ====='
CREATE FUNCTION add_tax(amount numeric, rate numeric DEFAULT 0.17)
RETURNS numeric
LANGUAGE sql
IMMUTABLE              -- same input -> same output, never reads tables
AS $$
    SELECT round(amount * (1 + rate), 2)
$$;

SELECT add_tax(100)                         AS default_rate;
SELECT add_tax(100, 0.05)                   AS positional;
SELECT add_tax(rate => 0.10, amount => 100) AS named_notation;
SELECT order_id, amount, add_tax(amount) AS with_tax FROM orders LIMIT 3;


-- ---------------------------------------------------------------------
-- 2. PL/pgSQL: variables, SELECT INTO, IF, RAISE
-- ---------------------------------------------------------------------
\echo '===== 2. PL/pgSQL: variables, IF, RAISE ====='
CREATE FUNCTION region_revenue(p_region text)
RETURNS numeric
LANGUAGE plpgsql
STABLE                 -- reads tables, but no writes; same result within one query
AS $$
DECLARE
    v_total numeric;
BEGIN
    SELECT SUM(amount) INTO v_total
    FROM orders
    WHERE region = p_region;

    IF v_total IS NULL THEN
        RAISE EXCEPTION 'Unknown region: %', p_region;
    END IF;

    RAISE NOTICE 'Region % revenue = %', p_region, v_total;
    RETURN v_total;
END;
$$;

SELECT region_revenue('North');
SELECT region_revenue('Mars');          -- EXPECTED ERROR: Unknown region


-- ---------------------------------------------------------------------
-- 3. Function used inside a query (row by row)
-- ---------------------------------------------------------------------
\echo '===== 3. Classifier function used in GROUP BY ====='
CREATE FUNCTION order_size(p_amount numeric)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN CASE
        WHEN p_amount >= 400 THEN 'large'
        WHEN p_amount >= 100 THEN 'medium'
        ELSE 'small'
    END;
END;
$$;

SELECT order_size(amount) AS bucket, COUNT(*) AS orders
FROM orders
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 4. Table-returning function = "parameterized view"
-- ---------------------------------------------------------------------
\echo '===== 4. RETURNS TABLE ====='
CREATE FUNCTION sales_summary(p_from date, p_to date)
RETURNS TABLE (region text, total_amount numeric, order_count bigint, avg_amount numeric)
LANGUAGE sql
STABLE
AS $$
    SELECT o.region, SUM(o.amount), COUNT(*), round(AVG(o.amount), 2)
    FROM orders o
    WHERE o.order_date BETWEEN p_from AND p_to
    GROUP BY o.region
    ORDER BY 2 DESC
$$;

SELECT * FROM sales_summary('2026-01-01', '2026-01-31');
-- you can filter / join it like a table:
SELECT region, total_amount
FROM sales_summary('2026-02-01', '2026-02-28')
WHERE avg_amount > 249;


-- ---------------------------------------------------------------------
-- 5. OUT parameters: return several values as one row
-- ---------------------------------------------------------------------
\echo '===== 5. OUT parameters ====='
CREATE FUNCTION region_stats(p_region text,
                             OUT min_amt numeric,
                             OUT max_amt numeric,
                             OUT avg_amt numeric)
LANGUAGE sql
STABLE
AS $$
    SELECT MIN(amount), MAX(amount), round(AVG(amount), 2)
    FROM orders
    WHERE region = p_region
$$;

SELECT * FROM region_stats('East');


-- ---------------------------------------------------------------------
-- 6. FOR loop + RETURN NEXT (row-by-row building of a result)
-- ---------------------------------------------------------------------
\echo '===== 6. Loop + RETURN NEXT : running total ====='
CREATE FUNCTION running_total(p_region text, p_month int)
RETURNS TABLE (day date, daily numeric, cumulative numeric)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    r     record;
    v_sum numeric := 0;
BEGIN
    FOR r IN
        SELECT order_date, SUM(amount) AS s
        FROM orders
        WHERE region = p_region
          AND extract(month FROM order_date) = p_month
        GROUP BY order_date
        ORDER BY order_date
    LOOP
        v_sum      := v_sum + r.s;
        day        := r.order_date;
        daily      := r.s;
        cumulative := v_sum;
        RETURN NEXT;              -- emit the current values as one output row
    END LOOP;
END;
$$;

SELECT * FROM running_total('West', 1) LIMIT 5;
-- (A window function SUM(...) OVER (ORDER BY ...) does the same thing
--  faster; the loop is here to learn the syntax.)


-- ---------------------------------------------------------------------
-- 7. Overloading: same name, different argument list
-- ---------------------------------------------------------------------
\echo '===== 7. Overloading ====='
CREATE FUNCTION region_revenue(p_region text, p_month int)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
    SELECT SUM(amount) FROM orders
    WHERE region = p_region AND extract(month FROM order_date) = p_month
$$;

SELECT region_revenue('North') AS all_months, region_revenue('North', 1) AS january;
\df practice.region_revenue


-- ---------------------------------------------------------------------
-- 8. Exception handling inside a function
-- ---------------------------------------------------------------------
\echo '===== 8. EXCEPTION block ====='
CREATE FUNCTION safe_divide(a numeric, b numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN a / b;
EXCEPTION
    WHEN division_by_zero THEN
        RAISE NOTICE 'division by zero -> returning NULL';
        RETURN NULL;
END;
$$;

SELECT safe_divide(10, 4) AS ok, safe_divide(10, 0) AS caught;


-- ---------------------------------------------------------------------
-- 9. Volatility matters: only IMMUTABLE functions can be indexed
-- ---------------------------------------------------------------------
\echo '===== 9. Volatility: IMMUTABLE vs VOLATILE in an index ====='
CREATE TABLE small_orders AS SELECT * FROM orders WHERE order_id <= 100000;

CREATE INDEX idx_small_orders_size ON small_orders (order_size(amount));   -- works

-- same logic, only the label differs.
-- (plpgsql on purpose: a one-line LANGUAGE sql function gets INLINED by the
--  planner into a plain CASE expression, and then the label is never checked)
CREATE FUNCTION order_size_volatile(p numeric)
RETURNS text LANGUAGE plpgsql VOLATILE
AS $$ BEGIN RETURN order_size(p); END $$;

CREATE INDEX ON small_orders (order_size_volatile(amount));  -- EXPECTED ERROR: must be IMMUTABLE


-- =====================================================================
--  PART B : STORED PROCEDURES
--  A procedure is run with CALL, returns nothing (except INOUT/OUT
--  params), and can COMMIT / ROLLBACK inside its body.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 10. Basic procedure: money transfer (all-or-nothing)
-- ---------------------------------------------------------------------
\echo '===== 10. Procedure: transfer ====='
CREATE TABLE accounts (
    id      int PRIMARY KEY,
    owner   text NOT NULL,
    balance numeric(12,2) NOT NULL CHECK (balance >= 0)
);
INSERT INTO accounts VALUES (1, 'Ali', 1000), (2, 'Sara', 500);

CREATE TABLE transfer_log (
    id      serial PRIMARY KEY,
    from_id int,
    to_id   int,
    amount  numeric(12,2),
    at      timestamptz DEFAULT now()
);

CREATE PROCEDURE transfer(p_from int, p_to int, p_amount numeric)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive, got %', p_amount;
    END IF;

    UPDATE accounts SET balance = balance - p_amount WHERE id = p_from;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % not found', p_from;
    END IF;

    UPDATE accounts SET balance = balance + p_amount WHERE id = p_to;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % not found', p_to;   -- the debit above is undone too
    END IF;

    INSERT INTO transfer_log (from_id, to_id, amount) VALUES (p_from, p_to, p_amount);
END;
$$;

CALL transfer(1, 2, 200);
SELECT * FROM accounts ORDER BY id;          -- 800 / 700

CALL transfer(1, 2, 5000);                   -- EXPECTED ERROR: CHECK (balance >= 0)
CALL transfer(1, 99, 10);                    -- EXPECTED ERROR: account 99 not found
SELECT * FROM accounts ORDER BY id;          -- still 800 / 700: failed calls left no trace
SELECT id, from_id, to_id, amount FROM transfer_log;

SELECT transfer(1, 2, 10);                   -- EXPECTED ERROR: procedures are CALLed, not SELECTed


-- ---------------------------------------------------------------------
-- 11. Getting a value back from a procedure: INOUT parameter
-- ---------------------------------------------------------------------
\echo '===== 11. INOUT parameter ====='
CREATE PROCEDURE count_region(p_region text, INOUT p_count bigint DEFAULT NULL)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT COUNT(*) INTO p_count FROM orders WHERE region = p_region;
END;
$$;

CALL count_region('South');


-- ---------------------------------------------------------------------
-- 12. THE key difference: COMMIT inside a procedure (batch processing)
-- ---------------------------------------------------------------------
\echo '===== 12. COMMIT per batch inside a procedure ====='
-- work on a copy so public.orders is never touched
CREATE TABLE orders_work    AS SELECT * FROM orders WHERE order_date < '2026-01-15';
CREATE TABLE orders_archive (LIKE orders_work);
SELECT COUNT(*) AS rows_to_archive FROM orders_work;

CREATE PROCEDURE archive_in_batches(p_batch int DEFAULT 50000)
LANGUAGE plpgsql
AS $$
DECLARE
    v_moved int;
    v_total int := 0;
BEGIN
    LOOP
        WITH moved AS (
            DELETE FROM orders_work
            WHERE order_id IN (SELECT order_id FROM orders_work LIMIT p_batch)
            RETURNING *
        )
        INSERT INTO orders_archive SELECT * FROM moved;

        GET DIAGNOSTICS v_moved = ROW_COUNT;
        EXIT WHEN v_moved = 0;

        v_total := v_total + v_moved;
        COMMIT;   -- each batch is its own transaction: locks released, progress kept
        RAISE NOTICE 'batch committed: % rows (total %)', v_moved, v_total;
    END LOOP;
END;
$$;

CALL archive_in_batches();
SELECT (SELECT COUNT(*) FROM orders_work)    AS left_in_work,
       (SELECT COUNT(*) FROM orders_archive) AS archived;

-- Same COMMIT inside a FUNCTION is not allowed:
CREATE FUNCTION try_commit() RETURNS void LANGUAGE plpgsql AS $$ BEGIN COMMIT; END $$;
SELECT try_commit();                         -- EXPECTED ERROR: invalid transaction termination

-- And a procedure cannot COMMIT if YOU already opened a transaction:
BEGIN;
INSERT INTO orders_work SELECT * FROM orders WHERE order_id <= 10;
CALL archive_in_batches();                   -- EXPECTED ERROR: invalid transaction termination
ROLLBACK;


-- ---------------------------------------------------------------------
-- 13. Inspecting what you created
-- ---------------------------------------------------------------------
\echo '===== 13. Catalog: functions (f) vs procedures (p) ====='
SELECT proname,
       CASE prokind WHEN 'f' THEN 'function' WHEN 'p' THEN 'procedure' END AS kind,
       CASE provolatile WHEN 'i' THEN 'immutable' WHEN 's' THEN 'stable' WHEN 'v' THEN 'volatile' END AS volatility,
       pg_get_function_arguments(oid) AS args
FROM pg_proc
WHERE pronamespace = 'practice'::regnamespace
ORDER BY kind, proname;

\sf practice.add_tax


-- =====================================================================
--  CHEAT SHEET
--  ---------------------------------------------------------------------
--                         FUNCTION                 PROCEDURE
--  invoked with           SELECT f(...)            CALL p(...)
--  usable in a query      yes (SELECT/WHERE/JOIN)  no
--  return value           yes (scalar/row/table)   only via INOUT/OUT params
--  COMMIT / ROLLBACK      never                    yes (if not called inside BEGIN...)
--  volatility label       IMMUTABLE/STABLE/VOLATILE  n/a
--  typical use            calculations, reusable   multi-step jobs, batch loads,
--                         queries, index exprs     ETL, admin tasks
--
--  EXERCISES (write them yourself, then compare with Claude)
--  1. Function top_days(p_region text, p_n int) RETURNS TABLE(...) giving
--     the p_n highest-revenue days for a region.
--  2. Function month_growth(p_region text, p_month int) returning the
--     % change in revenue vs the previous month (use safe_divide).
--  3. Procedure refresh_reports() that rebuilds public.tbl_daily_sales
--     (TRUNCATE + INSERT) and REFRESHes public.mv_daily_sales, with a
--     COMMIT between the two steps and RAISE NOTICE timings.
--  4. Procedure add_order(p_region, p_amount, INOUT p_order_id) that
--     validates the region (must already exist) and returns the new id.
--  5. Rewrite transfer() so it locks both rows with SELECT ... FOR UPDATE
--     in id order (avoids deadlocks when two transfers cross).
--  Reset everything:  DROP SCHEMA practice CASCADE;
-- =====================================================================
