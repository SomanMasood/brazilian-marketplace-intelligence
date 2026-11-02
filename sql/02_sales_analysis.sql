-- ============================================================
-- Project: Brazilian Marketplace Intelligence
-- File: 02_sales_analysis.sql
-- Purpose: Analyze revenue, order value, freight, and trends
-- Database: marketplace_intel
-- ============================================================

-- SECTION 1: Overall item revenue and order counts
-- Revenue is item price, excluding freight.

SELECT
    ROUND(SUM(price), 2) AS item_revenue,
    COUNT(*) AS item_rows,
    COUNT(DISTINCT order_id) AS orders_with_items
FROM order_items;


-- SECTION 2: Average order value (AOV)
-- Item revenue divided by distinct orders with items.
-- Freight is excluded.

SELECT
    ROUND(
        SUM(price) / NULLIF(COUNT(DISTINCT order_id), 0),
        2
    ) AS average_order_value
FROM order_items;


-- SECTION 3: Freight and combined item-plus-freight charges

SELECT
    ROUND(SUM(price), 2) AS item_revenue,
    ROUND(SUM(freight_value), 2) AS freight_charges,
    ROUND(SUM(price + freight_value), 2) AS item_plus_freight,
    ROUND(
        100.0 * SUM(freight_value) / NULLIF(SUM(price), 0),
        2
    ) AS freight_pct_of_item_revenue
FROM order_items;


-- SECTION 4: Monthly sales trends
-- Missing calendar months do not appear in this result.
-- Interpret incomplete periods at the dataset boundaries cautiously.

SELECT
    DATE_TRUNC('month', o.order_purchase_timestamp)::date AS sales_month,
    COUNT(DISTINCT o.order_id) AS order_count,
    COUNT(*) AS item_count,
    ROUND(SUM(oi.price), 2) AS item_revenue,
    ROUND(
        SUM(oi.price) / NULLIF(COUNT(DISTINCT o.order_id), 0),
        2
    ) AS average_order_value
FROM orders o
JOIN order_items oi
    ON o.order_id = oi.order_id
GROUP BY 1
ORDER BY 1;


-- SECTION 5: Calendar-based month-over-month revenue growth
-- Generates every calendar month between the first and last
-- observed purchase month. Missing months are assigned zero revenue.
-- Growth is NULL when the previous month has zero revenue.
-- Incomplete first/last periods must be interpreted cautiously.

WITH monthly_sales AS (
    SELECT
        DATE_TRUNC('month', o.order_purchase_timestamp)::date AS sales_month,
        SUM(oi.price) AS item_revenue
    FROM orders o
    JOIN order_items oi
        ON o.order_id = oi.order_id
    GROUP BY 1
),
calendar_months AS (
    SELECT GENERATE_SERIES(
        (SELECT MIN(sales_month) FROM monthly_sales),
        (SELECT MAX(sales_month) FROM monthly_sales),
        INTERVAL '1 month'
    )::date AS sales_month
),
complete_monthly_sales AS (
    SELECT
        c.sales_month,
        COALESCE(m.item_revenue, 0) AS item_revenue
    FROM calendar_months c
    LEFT JOIN monthly_sales m
        ON c.sales_month = m.sales_month
),
sales_with_previous_month AS (
    SELECT
        sales_month,
        item_revenue,
        LAG(item_revenue) OVER (ORDER BY sales_month) AS previous_month_revenue
    FROM complete_monthly_sales
)
SELECT
    sales_month,
    ROUND(item_revenue, 2) AS item_revenue,
    ROUND(previous_month_revenue, 2) AS previous_month_revenue,
    ROUND(
        100.0 * (item_revenue - previous_month_revenue)
        / NULLIF(previous_month_revenue, 0),
        2
    ) AS revenue_growth_pct
FROM sales_with_previous_month
ORDER BY sales_month;