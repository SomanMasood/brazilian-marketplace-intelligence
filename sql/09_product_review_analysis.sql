
-- ============================================================
-- Project: Brazilian Marketplace Intelligence
-- File: 09_product_review_analysis.sql
-- Purpose: Product ratings, category satisfaction, review text
-- ============================================================


-- ------------------------------------------------------------
-- SECTION 1: Review text availability
-- Review records and text fields, not unique orders.
-- ------------------------------------------------------------

SELECT
    COUNT(*) AS total_review_records,
    COUNT(review_comment_title) AS reviews_with_title,
    COUNT(review_comment_message) AS reviews_with_message,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(review_comment_title), '') IS NOT NULL
           OR NULLIF(TRIM(review_comment_message), '') IS NOT NULL
    ) AS reviews_with_any_text,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(review_comment_title), '') IS NULL
          AND NULLIF(TRIM(review_comment_message), '') IS NULL
    ) AS reviews_without_text,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE NULLIF(TRIM(review_comment_title), '') IS NOT NULL
               OR NULLIF(TRIM(review_comment_message), '') IS NOT NULL
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_with_any_text
FROM reviews;


-- ------------------------------------------------------------
-- SECTION 2: Category satisfaction scorecard
-- Each order must contain products from exactly one category.
-- Multiple reviews for an order are averaged before aggregation.
-- Categories with fewer than 100 reviewed orders are excluded
-- from the ranked scorecard to reduce small-sample distortion.
-- ------------------------------------------------------------

WITH review_by_order AS (
    SELECT
        order_id,
        AVG(review_score::numeric) AS avg_review_score,
        COUNT(*) AS review_count
    FROM reviews
    WHERE review_score BETWEEN 1 AND 5
    GROUP BY order_id
),
order_categories AS (
    SELECT
        oi.order_id,
        COUNT(
            DISTINCT COALESCE(p.product_category_name, 'unknown')
        ) AS distinct_categories,
        MIN(
            COALESCE(p.product_category_name, 'unknown')
        ) AS category
    FROM order_items oi
    JOIN products p
        ON oi.product_id = p.product_id
    GROUP BY oi.order_id
),
category_reviews AS (
    SELECT
        oc.category,
        r.order_id,
        r.avg_review_score
    FROM order_categories oc
    JOIN review_by_order r
        ON oc.order_id = r.order_id
    WHERE oc.distinct_categories = 1
)
SELECT
    COALESCE(
        ct.product_category_name_english,
        cr.category
    ) AS category,
    COUNT(*) AS reviewed_orders,
    ROUND(AVG(cr.avg_review_score)::numeric, 2)
        AS avg_review_score,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE cr.avg_review_score <= 2
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_low_rated_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE cr.avg_review_score = 5
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_five_star_orders
FROM category_reviews cr
LEFT JOIN category_translation ct
    ON cr.category = ct.product_category_name
GROUP BY
    COALESCE(ct.product_category_name_english, cr.category)
HAVING COUNT(*) >= 100
ORDER BY avg_review_score DESC, reviewed_orders DESC;


-- ------------------------------------------------------------
-- SECTION 3: Individual product satisfaction
-- Attribute a review to a product only when the order contains
-- exactly one distinct product_id.
-- Products require at least 20 reviewed orders.
-- ------------------------------------------------------------

WITH review_by_order AS (
    SELECT
        order_id,
        AVG(review_score::numeric) AS avg_review_score
    FROM reviews
    WHERE review_score BETWEEN 1 AND 5
    GROUP BY order_id
),
order_products AS (
    SELECT
        order_id,
        COUNT(DISTINCT product_id) AS distinct_products,
        MIN(product_id) AS product_id
    FROM order_items
    GROUP BY order_id
),
single_product_reviews AS (
    SELECT
        op.product_id,
        r.order_id,
        r.avg_review_score
    FROM order_products op
    JOIN review_by_order r
        ON op.order_id = r.order_id
    WHERE op.distinct_products = 1
),
product_scorecard AS (
    SELECT
        spr.product_id,
        p.product_category_name,
        COUNT(*) AS reviewed_orders,
        AVG(spr.avg_review_score) AS avg_review_score,
        COUNT(*) FILTER (
            WHERE spr.avg_review_score <= 2
        ) AS low_rated_orders,
        COUNT(*) FILTER (
            WHERE spr.avg_review_score = 5
        ) AS five_star_orders
    FROM single_product_reviews spr
    JOIN products p
        ON spr.product_id = p.product_id
    GROUP BY spr.product_id, p.product_category_name
    HAVING COUNT(*) >= 20
)
SELECT
    ps.product_id,
    COALESCE(
        ct.product_category_name_english,
        ps.product_category_name,
        'unknown'
    ) AS category,
    ps.reviewed_orders,
    ROUND(ps.avg_review_score::numeric, 2) AS avg_review_score,
    ROUND(
        100.0 * ps.low_rated_orders / NULLIF(ps.reviewed_orders, 0),
        2
    ) AS pct_low_rated_orders,
    ROUND(
        100.0 * ps.five_star_orders / NULLIF(ps.reviewed_orders, 0),
        2
    ) AS pct_five_star_orders
FROM product_scorecard ps
LEFT JOIN category_translation ct
    ON ps.product_category_name = ct.product_category_name
ORDER BY avg_review_score DESC, reviewed_orders DESC
LIMIT 50;


-- ------------------------------------------------------------
-- SECTION 4: Category satisfaction by delivery outcome
-- Includes only orders with products from one distinct category.
-- Late delivery means actual delivery was after the estimate.
-- ------------------------------------------------------------

WITH review_by_order AS (
    SELECT
        order_id,
        AVG(review_score::numeric) AS avg_review_score
    FROM reviews
    WHERE review_score BETWEEN 1 AND 5
    GROUP BY order_id
),
order_categories AS (
    SELECT
        oi.order_id,
        COUNT(
            DISTINCT COALESCE(p.product_category_name, 'unknown')
        ) AS distinct_categories,
        MIN(
            COALESCE(p.product_category_name, 'unknown')
        ) AS category
    FROM order_items oi
    JOIN products p
        ON oi.product_id = p.product_id
    GROUP BY oi.order_id
),
category_order_reviews AS (
    SELECT
        oc.category,
        r.avg_review_score,
        o.order_delivered_customer_date >
            o.order_estimated_delivery_date AS is_late
    FROM order_categories oc
    JOIN review_by_order r
        ON oc.order_id = r.order_id
    JOIN orders o
        ON oc.order_id = o.order_id
    WHERE oc.distinct_categories = 1
      AND o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
)
SELECT
    COALESCE(
        ct.product_category_name_english,
        cor.category
    ) AS category,
    CASE
        WHEN cor.is_late THEN 'Late'
        ELSE 'On time or early'
    END AS delivery_group,
    COUNT(*) AS reviewed_orders,
    ROUND(AVG(cor.avg_review_score)::numeric, 2)
        AS avg_review_score,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE cor.avg_review_score <= 2
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_low_rated_orders
FROM category_order_reviews cor
LEFT JOIN category_translation ct
    ON cor.category = ct.product_category_name
GROUP BY
    COALESCE(ct.product_category_name_english, cor.category),
    cor.is_late
HAVING COUNT(*) >= 50
ORDER BY category, delivery_group;


-- ------------------------------------------------------------
-- SECTION 5: Written review samples
-- Return actual comments for qualitative inspection in Python.
-- This is a sample for investigation, not a theme classification.
-- ------------------------------------------------------------

SELECT
    r.review_id,
    r.order_id,
    r.review_score,
    NULLIF(TRIM(r.review_comment_title), '') AS review_title,
    NULLIF(TRIM(r.review_comment_message), '') AS review_message,
    o.order_delivered_customer_date >
        o.order_estimated_delivery_date AS was_late
FROM reviews r
JOIN orders o
    ON r.order_id = o.order_id
WHERE (
        NULLIF(TRIM(r.review_comment_title), '') IS NOT NULL
     OR NULLIF(TRIM(r.review_comment_message), '') IS NOT NULL
)
AND r.review_score BETWEEN 1 AND 5
ORDER BY
    CASE WHEN r.review_score <= 2 THEN 0 ELSE 1 END,
    r.review_score,
    r.review_creation_date DESC
LIMIT 200;
