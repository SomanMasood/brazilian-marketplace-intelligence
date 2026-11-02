
-- ============================================================
-- Project: Brazilian Marketplace Intelligence
-- File: 05_delivery_analysis.sql
-- Purpose: Analyze delivery reliability, lateness, timing,
--          monthly patterns, and geographic differences
-- Database: marketplace_intel
-- ============================================================


-- SECTION 1: Overall delivery performance
-- Unit of analysis: delivered orders.
-- Only orders with valid actual and estimated delivery timestamps.
-- An order is late when actual delivery is after the estimate.

WITH delivered_orders AS (
    SELECT
        order_id,
        order_purchase_timestamp,
        order_delivered_customer_date,
        order_estimated_delivery_date,
        EXTRACT(
            EPOCH FROM (
                order_delivered_customer_date
                - order_purchase_timestamp
            )
        ) / 86400.0 AS actual_delivery_days,
        EXTRACT(
            EPOCH FROM (
                order_estimated_delivery_date
                - order_purchase_timestamp
            )
        ) / 86400.0 AS estimated_delivery_days,
        EXTRACT(
            EPOCH FROM (
                order_delivered_customer_date
                - order_estimated_delivery_date
            )
        ) / 86400.0 AS days_vs_estimate
    FROM orders
    WHERE order_status = 'delivered'
      AND order_purchase_timestamp IS NOT NULL
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date IS NOT NULL
)
SELECT
    COUNT(*) AS valid_delivered_orders,
    COUNT(*) FILTER (
        WHERE days_vs_estimate > 0
    ) AS late_orders,
    COUNT(*) FILTER (
        WHERE days_vs_estimate <= 0
    ) AS on_time_or_early_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE days_vs_estimate > 0
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS late_order_pct,
    ROUND(AVG(actual_delivery_days)::numeric, 2)
        AS avg_actual_delivery_days,
    ROUND(AVG(estimated_delivery_days)::numeric, 2)
        AS avg_estimated_delivery_days,
    ROUND(AVG(days_vs_estimate)::numeric, 2)
        AS avg_days_vs_estimate
FROM delivered_orders;


-- SECTION 2: Severity of late delivery
-- Measures lateness only among orders delivered after the estimate.

WITH late_orders AS (
    SELECT
        EXTRACT(
            EPOCH FROM (
                order_delivered_customer_date
                - order_estimated_delivery_date
            )
        ) / 86400.0 AS days_late
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date IS NOT NULL
      AND order_delivered_customer_date
            > order_estimated_delivery_date
)
SELECT
    COUNT(*) AS late_orders,
    ROUND(AVG(days_late)::numeric, 2) AS average_days_late,
    ROUND(
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY days_late
        )::numeric,
        2
    ) AS median_days_late,
    ROUND(MAX(days_late)::numeric, 2) AS maximum_days_late,
    COUNT(*) FILTER (
        WHERE days_late > 7
    ) AS orders_over_7_days_late,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE days_late > 7
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_late_orders_over_7_days
FROM late_orders;


-- SECTION 3: Late delivery rate by purchase month
-- Purchase month is used to group orders by when they entered
-- the marketplace. Boundary months may be incomplete.

WITH delivered_orders AS (
    SELECT
        DATE_TRUNC(
            'month', order_purchase_timestamp
        )::date AS purchase_month,
        order_delivered_customer_date
            > order_estimated_delivery_date AS is_late
    FROM orders
    WHERE order_status = 'delivered'
      AND order_purchase_timestamp IS NOT NULL
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date IS NOT NULL
)
SELECT
    purchase_month,
    COUNT(*) AS delivered_orders,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF(COUNT(*), 0),
        2
    ) AS late_order_pct
FROM delivered_orders
GROUP BY purchase_month
ORDER BY purchase_month;


-- SECTION 4: Late delivery rate by customer state
-- State-level differences may reflect distance, seller mix,
-- order timing, and other factors. They are not causal estimates.

WITH delivered_orders AS (
    SELECT
        c.customer_state,
        o.order_id,
        o.order_delivered_customer_date
            > o.order_estimated_delivery_date AS is_late
    FROM orders o
    JOIN customers c
        ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
)
SELECT
    customer_state,
    COUNT(*) AS delivered_orders,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF(COUNT(*), 0),
        2
    ) AS late_order_pct
FROM delivered_orders
GROUP BY customer_state
ORDER BY late_order_pct DESC, delivered_orders DESC;


-- SECTION 5: Seller-state to customer-state delivery routes
-- Orders involving multiple sellers may appear on multiple routes.
-- Only routes with at least 100 distinct orders are included.

WITH order_routes AS (
    SELECT DISTINCT
        oi.order_id,
        s.seller_state,
        c.customer_state,
        o.order_delivered_customer_date
            > o.order_estimated_delivery_date AS is_late
    FROM order_items oi
    JOIN sellers s
        ON oi.seller_id = s.seller_id
    JOIN orders o
        ON oi.order_id = o.order_id
    JOIN customers c
        ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
)
SELECT
    seller_state,
    customer_state,
    COUNT(DISTINCT order_id) AS distinct_orders,
    COUNT(DISTINCT order_id) FILTER (
        WHERE is_late
    ) AS late_orders,
    ROUND(
        100.0 * COUNT(DISTINCT order_id) FILTER (
            WHERE is_late
        ) / NULLIF(COUNT(DISTINCT order_id), 0),
        2
    ) AS late_order_pct
FROM order_routes
GROUP BY seller_state, customer_state
HAVING COUNT(DISTINCT order_id) >= 100
ORDER BY late_order_pct DESC, distinct_orders DESC;


-- SECTION 6: Late delivery rate by purchase weekday
-- Weekday differences should be interpreted alongside monthly
-- patterns because order volume and lateness vary over time.

WITH delivered_orders AS (
    SELECT
        EXTRACT(
            ISODOW FROM order_purchase_timestamp
        )::integer AS weekday_number,
        TO_CHAR(order_purchase_timestamp, 'FMDay') AS weekday_name,
        order_delivered_customer_date
            > order_estimated_delivery_date AS is_late
    FROM orders
    WHERE order_status = 'delivered'
      AND order_purchase_timestamp IS NOT NULL
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date IS NOT NULL
)
SELECT
    weekday_number,
    weekday_name,
    COUNT(*) AS delivered_orders,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late)
        / NULLIF(COUNT(*), 0),
        2
    ) AS late_order_pct
FROM delivered_orders
GROUP BY weekday_number, weekday_name
ORDER BY weekday_number;


-- SECTION 7: Delivery timing by stage
-- Compares approval-to-carrier and carrier-to-customer durations.
-- Valid timestamps are required for each stage.
-- These comparisons do not establish responsibility for delays.

SELECT
    'Approval to carrier' AS delivery_stage,
    COUNT(*) AS valid_orders,
    ROUND(
        AVG(
            EXTRACT(
                EPOCH FROM (
                    order_delivered_carrier_date
                    - order_approved_at
                )
            ) / 86400.0
        )::numeric,
        2
    ) AS average_days,
    ROUND(
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY EXTRACT(
                EPOCH FROM (
                    order_delivered_carrier_date
                    - order_approved_at
                )
            ) / 86400.0
        )::numeric,
        2
    ) AS median_days
FROM orders
WHERE order_status = 'delivered'
  AND order_approved_at IS NOT NULL
  AND order_delivered_carrier_date IS NOT NULL
  AND order_delivered_carrier_date >= order_approved_at

UNION ALL

SELECT
    'Carrier to customer' AS delivery_stage,
    COUNT(*) AS valid_orders,
    ROUND(
        AVG(
            EXTRACT(
                EPOCH FROM (
                    order_delivered_customer_date
                    - order_delivered_carrier_date
                )
            ) / 86400.0
        )::numeric,
        2
    ) AS average_days,
    ROUND(
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY EXTRACT(
                EPOCH FROM (
                    order_delivered_customer_date
                    - order_delivered_carrier_date
                )
            ) / 86400.0
        )::numeric,
        2
    ) AS median_days
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_carrier_date IS NOT NULL
  AND order_delivered_customer_date IS NOT NULL
  AND order_delivered_customer_date >= order_delivered_carrier_date;

  -- BUSINESS OBSERVATION:
-- Carrier-to-customer delivery averages 9.33 days,
-- compared with 2.85 days from approval to carrier handover.
-- The downstream stage therefore represents the longer
-- portion of the measured delivery timeline.
-- This is observational and does not establish the cause
-- of delays or carrier responsibility.


-- ============================================================
-- SECTION 8: DELIVERY PERFORMANCE BY BRAZILIAN MACROREGION
-- ============================================================

WITH delivery_data AS (
    SELECT
        o.order_id,
        c.customer_state,

        EXTRACT(
            EPOCH FROM (
                o.order_delivered_customer_date
                - o.order_estimated_delivery_date
            )
        ) / 86400.0 AS days_vs_estimate,

        CASE
            WHEN c.customer_state IN
                ('AC','AP','AM','PA','RO','RR','TO')
                THEN 'North'

            WHEN c.customer_state IN
                ('AL','BA','CE','MA','PB','PE','PI','RN','SE')
                THEN 'Northeast'

            WHEN c.customer_state IN
                ('DF','GO','MT','MS')
                THEN 'Central-West'

            WHEN c.customer_state IN
                ('ES','MG','RJ','SP')
                THEN 'Southeast'

            WHEN c.customer_state IN
                ('PR','RS','SC')
                THEN 'South'
        END AS brazil_region

    FROM orders o
    JOIN customers c
        ON o.customer_id = c.customer_id

    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
      AND o.order_purchase_timestamp IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
)

SELECT
    brazil_region,

    COUNT(*) AS delivered_orders,

    COUNT(*) FILTER (
        WHERE days_vs_estimate > 0
    ) AS late_orders,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE days_vs_estimate > 0
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS late_delivery_pct,

    ROUND(
        AVG(days_vs_estimate)::numeric,
        2
    ) AS avg_days_vs_estimate,

    ROUND(
        AVG(days_vs_estimate)
        FILTER (WHERE days_vs_estimate > 0)::numeric,
        2
    ) AS avg_days_late,

    ROUND(
        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY days_vs_estimate)
        FILTER (WHERE days_vs_estimate > 0)::numeric,
        2
    ) AS median_days_late

FROM delivery_data
GROUP BY brazil_region
ORDER BY late_delivery_pct DESC;
