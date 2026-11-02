
-- ============================================================
-- Project: Brazilian Marketplace Intelligence
-- File: 07_seller_analysis.sql
-- Purpose: Investigate an unusually high-lateness seller
-- ============================================================

-- Investigated seller:
-- 06a2c3af7b3aee5d69171b0e14f0ee87
-- Seller state: MA
--
-- Method notes:
-- * Core delivery analysis uses delivered orders with valid
--   purchase, carrier handoff, and customer delivery timestamps.
-- * Seller-route analyses use one row per order and seller.
-- * Orders containing multiple sellers can appear in multiple
--   seller-route comparisons.
-- * Findings are observational, not causal.


-- ------------------------------------------------------------
-- PREPARATION: Build seller-order route analysis table
-- ------------------------------------------------------------

DROP TABLE IF EXISTS seller_route_analysis;

CREATE TEMP TABLE seller_route_analysis AS
WITH geo_by_zip AS (
    SELECT
        geolocation_zip_code_prefix,
        AVG(geolocation_lat) AS latitude,
        AVG(geolocation_lng) AS longitude
    FROM geolocation
    GROUP BY geolocation_zip_code_prefix
),
seller_order_rows AS (
    SELECT DISTINCT
        oi.order_id,
        oi.seller_id,
        s.seller_state,
        c.customer_state,
        o.order_purchase_timestamp,
        o.order_approved_at,
        o.order_delivered_carrier_date,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        o.order_delivered_customer_date >
            o.order_estimated_delivery_date AS is_late,
        EXTRACT(
            EPOCH FROM (
                o.order_delivered_customer_date
                - o.order_delivered_carrier_date
            )
        ) / 86400.0 AS transit_days,
        EXTRACT(
            EPOCH FROM (
                o.order_delivered_carrier_date
                - o.order_approved_at
            )
        ) / 86400.0 AS approval_to_carrier_days,
        EXTRACT(
            EPOCH FROM (
                o.order_estimated_delivery_date
                - o.order_purchase_timestamp
            )
        ) / 86400.0 AS estimated_window_days,
        EXTRACT(
            EPOCH FROM (
                o.order_delivered_customer_date
                - o.order_estimated_delivery_date
            )
        ) / 86400.0 AS days_late,
        CASE
            WHEN s.seller_id = '06a2c3af7b3aee5d69171b0e14f0ee87'
                THEN 'Investigated seller'
            ELSE 'Other sellers'
        END AS seller_group,
        6371.0 * 2 * ASIN(
            SQRT(
                LEAST(
                    1.0,
                    GREATEST(
                        0.0,
                        POWER(
                            SIN(
                                RADIANS(cg.latitude - sg.latitude) / 2
                            ),
                            2
                        )
                        + COS(RADIANS(sg.latitude))
                        * COS(RADIANS(cg.latitude))
                        * POWER(
                            SIN(
                                RADIANS(cg.longitude - sg.longitude) / 2
                            ),
                            2
                        )
                    )
                )
            )
        ) AS distance_km
    FROM order_items oi
    JOIN orders o
        ON oi.order_id = o.order_id
    JOIN sellers s
        ON oi.seller_id = s.seller_id
    JOIN customers c
        ON o.customer_id = c.customer_id
    JOIN geo_by_zip cg
        ON c.customer_zip_code_prefix = cg.geolocation_zip_code_prefix
    JOIN geo_by_zip sg
        ON s.seller_zip_code_prefix = sg.geolocation_zip_code_prefix
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_delivered_carrier_date IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
      AND o.order_delivered_customer_date >= o.order_delivered_carrier_date
)
SELECT *
FROM seller_order_rows;


-- ------------------------------------------------------------
-- SECTION 1: Overall late-delivery comparison
-- One row per order, avoiding duplicate counts from multiple
-- items or sellers within the same order.
-- ------------------------------------------------------------

WITH valid_orders AS (
    SELECT
        o.order_id,
        o.order_approved_at,
        o.order_delivered_carrier_date,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        o.order_purchase_timestamp,
        o.order_delivered_customer_date >
            o.order_estimated_delivery_date AS is_late,
        EXISTS (
            SELECT 1
            FROM order_items oi
            WHERE oi.order_id = o.order_id
              AND oi.seller_id =
                  '06a2c3af7b3aee5d69171b0e14f0ee87'
        ) AS contains_investigated_seller
    FROM orders o
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_delivered_carrier_date IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
      AND o.order_delivered_customer_date >= o.order_delivered_carrier_date
)
SELECT
    CASE
        WHEN contains_investigated_seller
            THEN 'Investigated seller'
        ELSE 'Orders without investigated seller'
    END AS comparison_group,
    COUNT(*) AS delivered_orders,
    COUNT(*) FILTER (WHERE is_late) AS late_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*), 0),
        2
    ) AS late_order_pct,
    ROUND(
        AVG(
            EXTRACT(
                EPOCH FROM (
                    order_delivered_customer_date
                    - order_purchase_timestamp
                )
            ) / 86400.0
        )::numeric,
        2
    ) AS avg_purchase_to_delivery_days
FROM valid_orders
GROUP BY contains_investigated_seller
ORDER BY contains_investigated_seller DESC;


-- ------------------------------------------------------------
-- SECTION 2: Delivery-stage comparison
-- One row per order. Stage averages exclude missing or negative
-- stage durations.
-- ------------------------------------------------------------

WITH valid_orders AS (
    SELECT
        o.order_id,
        o.order_approved_at,
        o.order_delivered_carrier_date,
        o.order_delivered_customer_date,
        EXISTS (
            SELECT 1
            FROM order_items oi
            WHERE oi.order_id = o.order_id
              AND oi.seller_id =
                  '06a2c3af7b3aee5d69171b0e14f0ee87'
        ) AS contains_investigated_seller
    FROM orders o
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_delivered_carrier_date IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
      AND o.order_delivered_customer_date >= o.order_delivered_carrier_date
),
stage_rows AS (
    SELECT
        order_id,
        CASE
            WHEN contains_investigated_seller
                THEN 'Investigated seller'
            ELSE 'Orders without investigated seller'
        END AS comparison_group,
        'Approval to carrier' AS delivery_stage,
        EXTRACT(
            EPOCH FROM (
                order_delivered_carrier_date - order_approved_at
            )
        ) / 86400.0 AS stage_days
    FROM valid_orders
    WHERE order_approved_at IS NOT NULL
      AND order_delivered_carrier_date >= order_approved_at

    UNION ALL

    SELECT
        order_id,
        CASE
            WHEN contains_investigated_seller
                THEN 'Investigated seller'
            ELSE 'Orders without investigated seller'
        END,
        'Carrier to customer',
        EXTRACT(
            EPOCH FROM (
                order_delivered_customer_date
                - order_delivered_carrier_date
            )
        ) / 86400.0
    FROM valid_orders
    WHERE order_delivered_customer_date >= order_delivered_carrier_date
)
SELECT
    comparison_group,
    delivery_stage,
    COUNT(*) AS valid_orders,
    ROUND(AVG(stage_days)::numeric, 2) AS avg_stage_days,
    ROUND(
        (PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY stage_days
        ))::numeric,
        2
    ) AS median_stage_days
FROM stage_rows
GROUP BY comparison_group, delivery_stage
ORDER BY delivery_stage, comparison_group;


-- ------------------------------------------------------------
-- SECTION 3: Average route distance and late-delivery rate
-- One row per seller-order route.
-- ------------------------------------------------------------

SELECT
    seller_group,
    COUNT(*) AS seller_order_routes,
    COUNT(DISTINCT order_id) AS distinct_orders,
    ROUND(AVG(distance_km)::numeric, 2) AS avg_distance_km,
    ROUND(
        (PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY distance_km
        ))::numeric,
        2
    ) AS median_distance_km,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*), 0),
        2
    ) AS late_route_pct,
    ROUND(AVG(transit_days)::numeric, 2) AS avg_transit_days,
    ROUND(AVG(estimated_window_days)::numeric, 2)
        AS avg_estimated_window_days
FROM seller_route_analysis
GROUP BY seller_group
ORDER BY seller_group;


-- ------------------------------------------------------------
-- SECTION 4: Late-delivery rate by route-distance band
-- Compare the investigated seller with other seller routes.
-- Small samples in individual bands should be interpreted
-- cautiously.
-- ------------------------------------------------------------

WITH banded_routes AS (
    SELECT
        seller_group,
        CASE
            WHEN distance_km < 100 THEN '0-99 km'
            WHEN distance_km < 300 THEN '100-299 km'
            WHEN distance_km < 600 THEN '300-599 km'
            WHEN distance_km < 1000 THEN '600-999 km'
            ELSE '1000+ km'
        END AS distance_band,
        CASE
            WHEN distance_km < 100 THEN 1
            WHEN distance_km < 300 THEN 2
            WHEN distance_km < 600 THEN 3
            WHEN distance_km < 1000 THEN 4
            ELSE 5
        END AS band_order,
        is_late
    FROM seller_route_analysis
)
SELECT
    distance_band,
    seller_group,
    COUNT(*) AS seller_order_routes,
    COUNT(*) FILTER (WHERE is_late) AS late_routes,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*), 0),
        2
    ) AS late_route_pct
FROM banded_routes
GROUP BY distance_band, band_order, seller_group
ORDER BY band_order, seller_group;


-- ------------------------------------------------------------
-- SECTION 5: Late-delivery rate by estimated delivery window
-- This tests whether shorter promised windows are associated
-- with more lateness for the investigated seller.
-- ------------------------------------------------------------

WITH banded_routes AS (
    SELECT
        seller_group,
        CASE
            WHEN estimated_window_days < 20 THEN 'Under 20 days'
            WHEN estimated_window_days < 25 THEN '20-24 days'
            WHEN estimated_window_days < 30 THEN '25-29 days'
            WHEN estimated_window_days < 35 THEN '30-34 days'
            ELSE '35+ days'
        END AS estimated_window_band,
        CASE
            WHEN estimated_window_days < 20 THEN 1
            WHEN estimated_window_days < 25 THEN 2
            WHEN estimated_window_days < 30 THEN 3
            WHEN estimated_window_days < 35 THEN 4
            ELSE 5
        END AS band_order,
        is_late
    FROM seller_route_analysis
)
SELECT
    estimated_window_band,
    seller_group,
    COUNT(*) AS seller_order_routes,
    COUNT(*) FILTER (WHERE is_late) AS late_routes,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*), 0),
        2
    ) AS late_route_pct
FROM banded_routes
GROUP BY estimated_window_band, band_order, seller_group
ORDER BY band_order, seller_group;


-- ------------------------------------------------------------
-- SECTION 6: Monthly variation in late-delivery rates
-- This checks whether the seller's performance is consistently
-- elevated or varies substantially by month.
-- ------------------------------------------------------------

SELECT
    DATE_TRUNC('month', order_purchase_timestamp)::date AS purchase_month,
    seller_group,
    COUNT(*) AS seller_order_routes,
    COUNT(*) FILTER (WHERE is_late) AS late_routes,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*), 0),
        2
    ) AS late_route_pct
FROM seller_route_analysis
GROUP BY
    DATE_TRUNC('month', order_purchase_timestamp)::date,
    seller_group
ORDER BY purchase_month, seller_group;


-- ------------------------------------------------------------
-- CLEANUP
-- The temporary table is automatically removed when the
-- PostgreSQL session ends.
-- ------------------------------------------------------------

DROP TABLE IF EXISTS seller_route_analysis;
