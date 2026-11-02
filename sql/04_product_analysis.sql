
-- ============================================================
-- Project: Brazilian Marketplace Intelligence
-- File: 04_product_analysis.sql
-- Purpose: Analyze product category revenue, pricing, freight,
--          and delivery performance
-- Database: marketplace_intel
-- ============================================================


-- SECTION 1: Revenue and performance by product category
-- Revenue means item price, excluding freight.
-- Untranslated categories are labeled 'unknown'.

WITH category_sales AS (
    SELECT
        COALESCE(
            ct.product_category_name_english,
            'unknown'
        ) AS category,
        COUNT(*) AS item_rows,
        COUNT(DISTINCT oi.order_id) AS orders,
        SUM(oi.price) AS item_revenue,
        SUM(oi.freight_value) AS freight_charges,
        AVG(oi.price) AS average_item_price
    FROM order_items oi
    JOIN products p
        ON oi.product_id = p.product_id
    LEFT JOIN category_translation ct
        ON p.product_category_name = ct.product_category_name
    GROUP BY 1
)
SELECT
    category,
    item_rows,
    orders,
    ROUND(item_revenue, 2) AS item_revenue,
    ROUND(
        100.0 * item_revenue
        / NULLIF(SUM(item_revenue) OVER (), 0),
        2
    ) AS revenue_share_pct,
    ROUND(average_item_price, 2) AS average_item_price,
    ROUND(freight_charges, 2) AS freight_charges,
    ROUND(
        100.0 * freight_charges / NULLIF(item_revenue, 0),
        2
    ) AS freight_pct_of_item_revenue
FROM category_sales
ORDER BY item_revenue DESC;


-- SECTION 2: Top 10 categories by item revenue
-- Revenue share is calculated against total item revenue
-- across all categories, not just the top 10.

WITH category_sales AS (
    SELECT
        COALESCE(
            ct.product_category_name_english,
            'unknown'
        ) AS category,
        SUM(oi.price) AS item_revenue
    FROM order_items oi
    JOIN products p
        ON oi.product_id = p.product_id
    LEFT JOIN category_translation ct
        ON p.product_category_name = ct.product_category_name
    GROUP BY 1
),
ranked_categories AS (
    SELECT
        category,
        item_revenue,
        ROW_NUMBER() OVER (
            ORDER BY item_revenue DESC, category
        ) AS revenue_rank,
        SUM(item_revenue) OVER () AS total_revenue
    FROM category_sales
)
SELECT
    revenue_rank,
    category,
    ROUND(item_revenue, 2) AS item_revenue,
    ROUND(
        100.0 * item_revenue / NULLIF(total_revenue, 0),
        2
    ) AS revenue_share_pct,
    ROUND(
        100.0 * SUM(item_revenue) OVER (
            ORDER BY revenue_rank
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) / NULLIF(total_revenue, 0),
        2
    ) AS cumulative_revenue_share_pct
FROM ranked_categories
WHERE revenue_rank <= 10
ORDER BY revenue_rank;


-- SECTION 3: Category pricing and freight comparison
-- Freight is the freight_value recorded in order_items.
-- It is not a measure of actual shipping cost or profit.

SELECT
    COALESCE(
        ct.product_category_name_english,
        'unknown'
    ) AS category,
    COUNT(*) AS item_rows,
    ROUND(AVG(oi.price), 2) AS average_item_price,
    ROUND(
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY oi.price
        )::numeric,
        2
    ) AS median_item_price,
    ROUND(AVG(oi.freight_value), 2) AS average_freight_value,
    ROUND(SUM(oi.freight_value), 2) AS total_freight_charges,
    ROUND(SUM(oi.price), 2) AS item_revenue,
    ROUND(
        100.0 * SUM(oi.freight_value)
        / NULLIF(SUM(oi.price), 0),
        2
    ) AS freight_pct_of_item_revenue
FROM order_items oi
JOIN products p
    ON oi.product_id = p.product_id
LEFT JOIN category_translation ct
    ON p.product_category_name = ct.product_category_name
GROUP BY 1
ORDER BY item_revenue DESC;


-- SECTION 4: Delivery lateness by product category
-- Unit of analysis: delivered order-item rows.
-- Late means the order was delivered after its estimated date.
-- Only categories with at least 500 valid delivered item rows
-- are included to reduce noise from small samples.
-- Category differences may reflect seller and destination mix.

WITH category_delivery AS (
    SELECT
        COALESCE(
            ct.product_category_name_english,
            'unknown'
        ) AS category,
        oi.order_id,
        oi.order_item_id,
        o.order_purchase_timestamp,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        (
            o.order_delivered_customer_date
            > o.order_estimated_delivery_date
        ) AS is_late,
        EXTRACT(
            EPOCH FROM (
                o.order_delivered_customer_date
                - o.order_estimated_delivery_date
            )
        ) / 86400.0 AS days_late
    FROM order_items oi
    JOIN orders o
        ON oi.order_id = o.order_id
    JOIN products p
        ON oi.product_id = p.product_id
    LEFT JOIN category_translation ct
        ON p.product_category_name = ct.product_category_name
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
),
category_summary AS (
    SELECT
        category,
        COUNT(*) AS delivered_item_rows,
        COUNT(*) FILTER (WHERE is_late) AS late_item_rows,
        AVG(days_late) FILTER (WHERE is_late) AS avg_days_late_when_late,
        AVG(
            EXTRACT(
                EPOCH FROM (
                    order_delivered_customer_date
                    - order_purchase_timestamp
                )
            ) / 86400.0
        ) AS avg_purchase_to_delivery_days
    FROM category_delivery
    GROUP BY category
)
SELECT
    category,
    delivered_item_rows,
    late_item_rows,
    ROUND(
        100.0 * late_item_rows
        / NULLIF(delivered_item_rows, 0),
        2
    ) AS late_item_row_pct,
    ROUND(avg_days_late_when_late::numeric, 2)
        AS avg_days_late_when_late,
    ROUND(avg_purchase_to_delivery_days::numeric, 2)
        AS avg_purchase_to_delivery_days
FROM category_summary
WHERE delivered_item_rows >= 500
ORDER BY late_item_row_pct DESC, delivered_item_rows DESC;


-- SECTION 5: Category revenue concentration
-- Measures how much of total item revenue comes from the
-- highest-revenue categories.

WITH category_sales AS (
    SELECT
        COALESCE(
            ct.product_category_name_english,
            'unknown'
        ) AS category,
        SUM(oi.price) AS item_revenue
    FROM order_items oi
    JOIN products p
        ON oi.product_id = p.product_id
    LEFT JOIN category_translation ct
        ON p.product_category_name = ct.product_category_name
    GROUP BY 1
),
ranked_categories AS (
    SELECT
        category,
        item_revenue,
        ROW_NUMBER() OVER (
            ORDER BY item_revenue DESC, category
        ) AS revenue_rank,
        SUM(item_revenue) OVER () AS total_revenue
    FROM category_sales
)
SELECT
    COUNT(*) FILTER (WHERE revenue_rank <= 5) AS top_5_categories,
    ROUND(
        100.0 * SUM(item_revenue) FILTER (
            WHERE revenue_rank <= 5
        ) / NULLIF(MAX(total_revenue), 0),
        2
    ) AS top_5_revenue_share_pct,
    COUNT(*) FILTER (WHERE revenue_rank <= 10) AS top_10_categories,
    ROUND(
        100.0 * SUM(item_revenue) FILTER (
            WHERE revenue_rank <= 10
        ) / NULLIF(MAX(total_revenue), 0),
        2
    ) AS top_10_revenue_share_pct,
    COUNT(*) AS total_categories
FROM ranked_categories;
