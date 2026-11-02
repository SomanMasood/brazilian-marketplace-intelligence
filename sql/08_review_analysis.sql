
-- ============================================================
-- Project: Brazilian Marketplace Intelligence
-- File: 08_review_analysis.sql
-- Purpose: Customer review scores and delivery performance
-- ============================================================


-- ------------------------------------------------------------
-- SECTION 1: Overall review-score distribution
-- Uses the original review-record grain.
-- ------------------------------------------------------------

SELECT
    review_score,
    COUNT(*) AS review_records,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (),
        2
    ) AS pct_of_reviews
FROM reviews
GROUP BY review_score
ORDER BY review_score;


-- ------------------------------------------------------------
-- SECTION 2: Review scores by delivery performance
-- One average review score per order.
-- Includes delivered orders with valid delivery timestamps.
-- ------------------------------------------------------------

WITH review_by_order AS (
    SELECT
        order_id,
        AVG(review_score::numeric) AS avg_review_score,
        COUNT(*) AS review_count,
        COUNT(*) FILTER (WHERE review_score <= 2) AS low_score_reviews,
        COUNT(*) FILTER (WHERE review_score = 5) AS five_star_reviews
    FROM reviews
    GROUP BY order_id
),
delivery_orders AS (
    SELECT
        order_id,
        order_delivered_customer_date >
            order_estimated_delivery_date AS is_late
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_delivered_customer_date >= order_purchase_timestamp
)
SELECT
    CASE
        WHEN d.is_late THEN 'Late'
        ELSE 'On time or early'
    END AS delivery_group,
    COUNT(*) AS reviewed_orders,
    ROUND(AVG(r.avg_review_score)::numeric, 2) AS avg_review_score,
    ROUND(
        (PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY r.avg_review_score
        ))::numeric,
        2
    ) AS median_order_review_score,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE r.avg_review_score <= 2
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_orders_with_avg_score_le_2,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE r.avg_review_score = 5
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_orders_with_5_star_reviews
FROM delivery_orders d
JOIN review_by_order r
    ON d.order_id = r.order_id
GROUP BY d.is_late
ORDER BY d.is_late;


-- ------------------------------------------------------------
-- SECTION 3: Review scores by severity of delivery delay
-- Late-day bands use actual delivery date minus estimated date.
-- Non-late orders are included as a comparison group.
-- ------------------------------------------------------------

WITH review_by_order AS (
    SELECT
        order_id,
        AVG(review_score::numeric) AS avg_review_score
    FROM reviews
    GROUP BY order_id
),
delivery_orders AS (
    SELECT
        order_id,
        EXTRACT(
            EPOCH FROM (
                order_delivered_customer_date
                - order_estimated_delivery_date
            )
        ) / 86400.0 AS days_vs_estimate
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_delivered_customer_date >= order_purchase_timestamp
),
banded_orders AS (
    SELECT
        d.order_id,
        r.avg_review_score,
        d.days_vs_estimate,
        CASE
            WHEN d.days_vs_estimate <= 0 THEN 'On time or early'
            WHEN d.days_vs_estimate <= 3 THEN '1-3 days late'
            WHEN d.days_vs_estimate <= 7 THEN '4-7 days late'
            WHEN d.days_vs_estimate <= 14 THEN '8-14 days late'
            ELSE '15+ days late'
        END AS delay_band,
        CASE
            WHEN d.days_vs_estimate <= 0 THEN 1
            WHEN d.days_vs_estimate <= 3 THEN 2
            WHEN d.days_vs_estimate <= 7 THEN 3
            WHEN d.days_vs_estimate <= 14 THEN 4
            ELSE 5
        END AS band_order
    FROM delivery_orders d
    JOIN review_by_order r
        ON d.order_id = r.order_id
)
SELECT
    delay_band,
    COUNT(*) AS reviewed_orders,
    ROUND(AVG(avg_review_score)::numeric, 2) AS avg_review_score,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE avg_review_score <= 2
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_orders_with_avg_score_le_2,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE avg_review_score = 5
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_orders_with_5_star_reviews
FROM banded_orders
GROUP BY delay_band, band_order
ORDER BY band_order;

-- BUSINESS OBSERVATIONS:
-- 1. Average review scores decline as delivery delays increase.
-- 2. Scores fall from 4.29 for on-time/early orders
--    to 2.32 for orders delayed by 4-7 days.
-- 3. For orders delayed by 15+ days, 78.66% have
--    average review scores of 2 or lower.
-- 4. Five-star reviews decline from 62.38% for on-time/
--    early orders to 6.98% for orders delayed by 15+ days.
--
-- INTERPRETATION:
-- Delivery delays are strongly associated with lower
-- customer satisfaction. This analysis does not establish
-- that delivery delays alone caused lower review scores.

-- ------------------------------------------------------------
-- SECTION 4: Monthly review scores by delivery performance
-- This helps assess whether the overall pattern varies over time.
-- Months with small samples should be interpreted cautiously.
-- ------------------------------------------------------------

WITH review_by_order AS (
    SELECT
        order_id,
        AVG(review_score::numeric) AS avg_review_score
    FROM reviews
    GROUP BY order_id
),
delivery_orders AS (
    SELECT
        order_id,
        DATE_TRUNC('month', order_purchase_timestamp)::date
            AS purchase_month,
        order_delivered_customer_date >
            order_estimated_delivery_date AS is_late
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_delivered_customer_date >= order_purchase_timestamp
)
SELECT
    d.purchase_month,
    CASE
        WHEN d.is_late THEN 'Late'
        ELSE 'On time or early'
    END AS delivery_group,
    COUNT(*) AS reviewed_orders,
    ROUND(AVG(r.avg_review_score)::numeric, 2) AS avg_review_score,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE r.avg_review_score <= 2
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_orders_with_avg_score_le_2
FROM delivery_orders d
JOIN review_by_order r
    ON d.order_id = r.order_id
GROUP BY d.purchase_month, d.is_late
ORDER BY d.purchase_month, d.is_late;


-- ============================================================
-- SECTION 5: CUSTOMER SATISFACTION BY DELIVERY DELAY BAND
-- ============================================================

WITH order_delivery AS (
    SELECT
        o.order_id,
        EXTRACT(
            EPOCH FROM (
                o.order_delivered_customer_date
                - o.order_estimated_delivery_date
            )
        ) / 86400.0 AS days_vs_estimate
    FROM orders o
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
      AND o.order_purchase_timestamp IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
),

review_per_order AS (
    SELECT
        order_id,
        AVG(review_score) AS avg_review_score
    FROM reviews
    GROUP BY order_id
),

combined AS (
    SELECT
        d.order_id,
        d.days_vs_estimate,
        r.avg_review_score,
        CASE
            WHEN d.days_vs_estimate <= 0
                THEN 'On time or early'
            WHEN d.days_vs_estimate <= 3
                THEN '1-3 days late'
            WHEN d.days_vs_estimate <= 7
                THEN '4-7 days late'
            WHEN d.days_vs_estimate <= 14
                THEN '8-14 days late'
            ELSE '15+ days late'
        END AS delay_band,
        CASE
            WHEN d.days_vs_estimate <= 0 THEN 1
            WHEN d.days_vs_estimate <= 3 THEN 2
            WHEN d.days_vs_estimate <= 7 THEN 3
            WHEN d.days_vs_estimate <= 14 THEN 4
            ELSE 5
        END AS delay_sort
    FROM order_delivery d
    JOIN review_per_order r
        ON d.order_id = r.order_id
)

SELECT
    delay_band,
    delay_sort,
    COUNT(*) AS reviewed_orders,
    ROUND(AVG(avg_review_score)::numeric, 2)
        AS avg_review_score,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE avg_review_score <= 2
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_orders_with_avg_score_le_2,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE avg_review_score = 5
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_orders_with_5_star_reviews
FROM combined
GROUP BY delay_band, delay_sort
ORDER BY delay_sort;
