
-- ============================================================
-- Project: Brazilian Marketplace Intelligence
-- File: 03_customer_analysis.sql
-- Purpose: Analyze customer purchasing behavior and retention
-- Database: marketplace_intel
-- ============================================================


-- SECTION 1: Customer population and purchasing frequency

WITH customer_orders AS (
    SELECT DISTINCT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp
    FROM customers c
    JOIN orders o
        ON c.customer_id = o.customer_id
    JOIN order_items oi
        ON o.order_id = oi.order_id
),
customer_frequency AS (
    SELECT
        customer_unique_id,
        COUNT(DISTINCT order_id) AS order_count
    FROM customer_orders
    GROUP BY customer_unique_id
)
SELECT
    COUNT(*) AS customers_with_item_orders,
    COUNT(*) FILTER (WHERE order_count = 1) AS one_order_customers,
    COUNT(*) FILTER (WHERE order_count > 1) AS repeat_customers,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE order_count > 1)
        / NULLIF(COUNT(*), 0),
        2
    ) AS repeat_customer_pct,
    ROUND(AVG(order_count), 2) AS average_orders_per_customer
FROM customer_frequency;


-- SECTION 2: Spending by customer segment
-- Item revenue excludes freight. Descriptive, not causal.

WITH order_spend AS (
    SELECT
        o.order_id,
        c.customer_unique_id,
        SUM(oi.price) AS item_revenue
    FROM orders o
    JOIN customers c
        ON o.customer_id = c.customer_id
    JOIN order_items oi
        ON o.order_id = oi.order_id
    GROUP BY o.order_id, c.customer_unique_id
),
customer_spend AS (
    SELECT
        customer_unique_id,
        COUNT(*) AS order_count,
        SUM(item_revenue) AS lifetime_item_spend,
        AVG(item_revenue) AS customer_average_order_value
    FROM order_spend
    GROUP BY customer_unique_id
),
segmented_spend AS (
    SELECT
        CASE
            WHEN order_count = 1 THEN 'One-time customer'
            ELSE 'Repeat customer'
        END AS customer_segment,
        order_count,
        lifetime_item_spend,
        customer_average_order_value
    FROM customer_spend
)
SELECT
    customer_segment,
    COUNT(*) AS customer_count,
    ROUND(AVG(order_count), 2) AS average_orders_per_customer,
    ROUND(AVG(lifetime_item_spend), 2) AS average_lifetime_item_spend,
    ROUND(AVG(customer_average_order_value), 2)
        AS average_customer_order_value,
    ROUND(SUM(lifetime_item_spend), 2) AS segment_item_revenue
FROM segmented_spend
GROUP BY customer_segment
ORDER BY
    CASE
        WHEN customer_segment = 'One-time customer' THEN 1
        ELSE 2
    END;


-- SECTION 3: Distribution of customer order counts

WITH customer_frequency AS (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id) AS order_count
    FROM customers c
    JOIN orders o
        ON c.customer_id = o.customer_id
    JOIN order_items oi
        ON o.order_id = oi.order_id
    GROUP BY c.customer_unique_id
),
frequency_groups AS (
    SELECT
        CASE
            WHEN order_count = 1 THEN '1 order'
            WHEN order_count = 2 THEN '2 orders'
            WHEN order_count BETWEEN 3 AND 5 THEN '3-5 orders'
            ELSE '6+ orders'
        END AS order_frequency_group,
        CASE
            WHEN order_count = 1 THEN 1
            WHEN order_count = 2 THEN 2
            WHEN order_count BETWEEN 3 AND 5 THEN 3
            ELSE 4
        END AS sort_order
    FROM customer_frequency
)
SELECT
    order_frequency_group,
    COUNT(*) AS customer_count,
    ROUND(
        100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0),
        2
    ) AS percentage_of_customers
FROM frequency_groups
GROUP BY order_frequency_group, sort_order
ORDER BY sort_order;


-- SECTION 4: Monthly customer activity
-- Earlier purchase means any purchase in an earlier month,
-- not necessarily the immediately preceding month.

WITH customer_months AS (
    SELECT DISTINCT
        c.customer_unique_id,
        DATE_TRUNC('month', o.order_purchase_timestamp)::date AS order_month
    FROM customers c
    JOIN orders o
        ON c.customer_id = o.customer_id
    JOIN order_items oi
        ON o.order_id = oi.order_id
),
customer_history AS (
    SELECT
        customer_unique_id,
        order_month,
        MIN(order_month) OVER (
            PARTITION BY customer_unique_id
        ) AS first_order_month
    FROM customer_months
)
SELECT
    order_month,
    COUNT(*) AS active_customers,
    COUNT(*) FILTER (
        WHERE order_month > first_order_month
    ) AS customers_with_earlier_purchase,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE order_month > first_order_month
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_active_customers_with_earlier_purchase
FROM customer_history
GROUP BY order_month
ORDER BY order_month;


-- SECTION 5: Cohort repeat purchase within 90 days
-- Excludes customers without a complete 90-day observation window.
-- Uses a join and aggregation instead of a correlated EXISTS lookup.

WITH customer_orders AS (
    SELECT DISTINCT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp
    FROM customers c
    JOIN orders o
        ON c.customer_id = o.customer_id
    JOIN order_items oi
        ON o.order_id = oi.order_id
    WHERE o.order_purchase_timestamp IS NOT NULL
),
first_purchase AS (
    SELECT
        customer_unique_id,
        MIN(order_purchase_timestamp) AS first_purchase_timestamp
    FROM customer_orders
    GROUP BY customer_unique_id
),
eligible_customers AS (
    SELECT
        f.customer_unique_id,
        f.first_purchase_timestamp,
        DATE_TRUNC(
            'month', f.first_purchase_timestamp
        )::date AS cohort_month
    FROM first_purchase f
    WHERE f.first_purchase_timestamp <= (
        SELECT MAX(order_purchase_timestamp) - INTERVAL '90 days'
        FROM customer_orders
    )
),
customer_repeat_flags AS (
    SELECT
        e.customer_unique_id,
        e.cohort_month,
        BOOL_OR(co.order_id IS NOT NULL) AS repeated_within_90_days
    FROM eligible_customers e
    LEFT JOIN customer_orders co
        ON co.customer_unique_id = e.customer_unique_id
       AND co.order_purchase_timestamp > e.first_purchase_timestamp
       AND co.order_purchase_timestamp
            <= e.first_purchase_timestamp + INTERVAL '90 days'
    GROUP BY
        e.customer_unique_id,
        e.cohort_month
)
SELECT
    cohort_month,
    COUNT(*) AS cohort_customers,
    COUNT(*) FILTER (
        WHERE repeated_within_90_days
    ) AS customers_repeating_within_90_days,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE repeated_within_90_days
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS repeat_within_90_days_pct
FROM customer_repeat_flags
GROUP BY cohort_month
ORDER BY cohort_month;


-- SECTION 6: Orders without item records, by order status

WITH item_order_counts AS (
    SELECT
        order_id,
        COUNT(*) AS item_rows
    FROM order_items
    GROUP BY order_id
)
SELECT
    o.order_status,
    COUNT(*) AS total_orders,
    COUNT(*) FILTER (
        WHERE i.order_id IS NULL
    ) AS orders_without_items,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE i.order_id IS NULL
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_orders_without_items
FROM orders o
LEFT JOIN item_order_counts i
    ON o.order_id = i.order_id
GROUP BY o.order_status
ORDER BY total_orders DESC;


-- SECTION 7: Overall reconciliation

SELECT
    (SELECT COUNT(*) FROM orders) AS total_orders,
    (SELECT COUNT(DISTINCT order_id) FROM order_items)
        AS orders_with_items,
    (
        SELECT COUNT(*)
        FROM orders o
        WHERE NOT EXISTS (
            SELECT 1
            FROM order_items oi
            WHERE oi.order_id = o.order_id
        )
    ) AS orders_without_items,
    (SELECT COUNT(*) FROM order_items) AS total_item_rows;
