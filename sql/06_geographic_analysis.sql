
-- ============================================================
-- Project: Brazilian Marketplace Intelligence
-- File: 06_geographic_analysis.sql
-- Purpose: Geographic coverage, delivery distance, and delays
-- Distance method: Haversine straight-line distance in km
-- ============================================================


-- ------------------------------------------------------------
-- SECTION 1: Geographic coordinate coverage
-- Average duplicate coordinates within each ZIP-code prefix.
-- ------------------------------------------------------------

WITH geo_by_zip AS (
    SELECT
        geolocation_zip_code_prefix,
        AVG(geolocation_lat) AS latitude,
        AVG(geolocation_lng) AS longitude
    FROM geolocation
    GROUP BY geolocation_zip_code_prefix
),
customer_coverage AS (
    SELECT
        COUNT(*) AS total_customers,
        COUNT(g.geolocation_zip_code_prefix) AS matched_customers
    FROM customers c
    LEFT JOIN geo_by_zip g
        ON c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
),
seller_coverage AS (
    SELECT
        COUNT(*) AS total_sellers,
        COUNT(g.geolocation_zip_code_prefix) AS matched_sellers
    FROM sellers s
    LEFT JOIN geo_by_zip g
        ON s.seller_zip_code_prefix = g.geolocation_zip_code_prefix
)
SELECT
    'Customers' AS entity,
    total_customers AS total_records,
    matched_customers AS records_with_coordinates,
    total_customers - matched_customers AS records_without_coordinates,
    ROUND(
        100.0 * matched_customers / NULLIF(total_customers, 0),
        2
    ) AS coordinate_coverage_pct
FROM customer_coverage

UNION ALL

SELECT
    'Sellers',
    total_sellers,
    matched_sellers,
    total_sellers - matched_sellers,
    ROUND(
        100.0 * matched_sellers / NULLIF(total_sellers, 0),
        2
    )
FROM seller_coverage;


-- ------------------------------------------------------------
-- SECTION 2: Overall delivery distance
-- One row per delivered order item.
-- Excludes missing coordinates and invalid delivery timestamps.
-- ------------------------------------------------------------

WITH geo_by_zip AS (
    SELECT
        geolocation_zip_code_prefix,
        AVG(geolocation_lat) AS latitude,
        AVG(geolocation_lng) AS longitude
    FROM geolocation
    GROUP BY geolocation_zip_code_prefix
),
item_distances AS (
    SELECT
        oi.order_id,
        oi.order_item_id,
        o.order_delivered_customer_date >
            o.order_estimated_delivery_date AS is_late,
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
    JOIN customers c
        ON o.customer_id = c.customer_id
    JOIN sellers s
        ON oi.seller_id = s.seller_id
    JOIN geo_by_zip cg
        ON c.customer_zip_code_prefix = cg.geolocation_zip_code_prefix
    JOIN geo_by_zip sg
        ON s.seller_zip_code_prefix = sg.geolocation_zip_code_prefix
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
      AND o.order_delivered_customer_date >= o.order_delivered_carrier_date
)
SELECT
    COUNT(*) AS mapped_delivered_item_rows,
    ROUND(AVG(distance_km)::numeric, 2) AS avg_distance_km,
    ROUND(
        (PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY distance_km
        ))::numeric,
        2
    ) AS median_distance_km,
    ROUND(MIN(distance_km)::numeric, 2) AS min_distance_km,
    ROUND(MAX(distance_km)::numeric, 2) AS max_distance_km
FROM item_distances;


-- ------------------------------------------------------------
-- SECTION 3: Delivery lateness by distance band
-- Rates are item-row based, not unique-order based.
-- ------------------------------------------------------------

WITH geo_by_zip AS (
    SELECT
        geolocation_zip_code_prefix,
        AVG(geolocation_lat) AS latitude,
        AVG(geolocation_lng) AS longitude
    FROM geolocation
    GROUP BY geolocation_zip_code_prefix
),
item_distances AS (
    SELECT
        oi.order_id,
        oi.order_item_id,
        o.order_delivered_customer_date >
            o.order_estimated_delivery_date AS is_late,
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
    JOIN customers c
        ON o.customer_id = c.customer_id
    JOIN sellers s
        ON oi.seller_id = s.seller_id
    JOIN geo_by_zip cg
        ON c.customer_zip_code_prefix = cg.geolocation_zip_code_prefix
    JOIN geo_by_zip sg
        ON s.seller_zip_code_prefix = sg.geolocation_zip_code_prefix
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
      AND o.order_delivered_customer_date >= o.order_delivered_carrier_date
),
banded_items AS (
    SELECT
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
    FROM item_distances
)
SELECT
    distance_band,
    COUNT(*) AS delivered_item_rows,
    COUNT(*) FILTER (WHERE is_late) AS late_item_rows,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*), 0),
        2
    ) AS late_item_pct
FROM banded_items
GROUP BY distance_band, band_order
ORDER BY band_order;


-- ------------------------------------------------------------
-- SECTION 4: Transit duration by distance band
-- Transit = carrier handoff to customer delivery.
-- ------------------------------------------------------------

WITH geo_by_zip AS (
    SELECT
        geolocation_zip_code_prefix,
        AVG(geolocation_lat) AS latitude,
        AVG(geolocation_lng) AS longitude
    FROM geolocation
    GROUP BY geolocation_zip_code_prefix
),
item_distances AS (
    SELECT
        oi.order_id,
        oi.order_item_id,
        EXTRACT(
            EPOCH FROM (
                o.order_delivered_customer_date
                - o.order_delivered_carrier_date
            )
        ) / 86400.0 AS transit_days,
        o.order_delivered_customer_date >
            o.order_estimated_delivery_date AS is_late,
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
    JOIN customers c
        ON o.customer_id = c.customer_id
    JOIN sellers s
        ON oi.seller_id = s.seller_id
    JOIN geo_by_zip cg
        ON c.customer_zip_code_prefix = cg.geolocation_zip_code_prefix
    JOIN geo_by_zip sg
        ON s.seller_zip_code_prefix = sg.geolocation_zip_code_prefix
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_delivered_carrier_date IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_delivered_carrier_date
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
),
banded_items AS (
    SELECT
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
        transit_days,
        is_late
    FROM item_distances
)
SELECT
    distance_band,
    COUNT(*) AS delivered_item_rows,
    ROUND(AVG(transit_days)::numeric, 2) AS avg_transit_days,
    ROUND(
        (PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY transit_days
        ))::numeric,
        2
    ) AS median_transit_days,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*), 0),
        2
    ) AS late_item_pct
FROM banded_items
GROUP BY distance_band, band_order
ORDER BY band_order;


-- ------------------------------------------------------------
-- SECTION 5: Estimated delivery window by distance band
-- Window = estimated date minus purchase timestamp.
-- ------------------------------------------------------------

WITH geo_by_zip AS (
    SELECT
        geolocation_zip_code_prefix,
        AVG(geolocation_lat) AS latitude,
        AVG(geolocation_lng) AS longitude
    FROM geolocation
    GROUP BY geolocation_zip_code_prefix
),
item_distances AS (
    SELECT
        oi.order_id,
        oi.order_item_id,
        EXTRACT(
            EPOCH FROM (
                o.order_estimated_delivery_date
                - o.order_purchase_timestamp
            )
        ) / 86400.0 AS estimated_window_days,
        o.order_delivered_customer_date >
            o.order_estimated_delivery_date AS is_late,
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
    JOIN customers c
        ON o.customer_id = c.customer_id
    JOIN sellers s
        ON oi.seller_id = s.seller_id
    JOIN geo_by_zip cg
        ON c.customer_zip_code_prefix = cg.geolocation_zip_code_prefix
    JOIN geo_by_zip sg
        ON s.seller_zip_code_prefix = sg.geolocation_zip_code_prefix
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_delivered_customer_date >= o.order_purchase_timestamp
      AND o.order_delivered_customer_date >= o.order_delivered_carrier_date
),
banded_items AS (
    SELECT
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
        estimated_window_days,
        is_late
    FROM item_distances
)
SELECT
    distance_band,
    COUNT(*) AS delivered_item_rows,
    ROUND(AVG(estimated_window_days)::numeric, 2)
        AS avg_estimated_window_days,
    ROUND(
        (PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY estimated_window_days
        ))::numeric,
        2
    ) AS median_estimated_window_days,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_late) / NULLIF(COUNT(*), 0),
        2
    ) AS late_item_pct
FROM banded_items
GROUP BY distance_band, band_order
ORDER BY band_order;
