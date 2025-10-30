-- Question 1,2 merged

CREATE OR REPLACE VIEW kpi_category AS
SELECT 
    p.product_category_name_english AS category,
    
    -- Sales Metrics
    COUNT(oi.order_id) AS total_orders,
    ROUND(SUM(oi.price), 2) AS total_sales,
    ROUND(SUM(oi.freight_value), 2) AS total_freight,
    
    -- Delivery Metrics
    ROUND(AVG(TIMESTAMPDIFF(SECOND, o.order_purchase_timestamp, o.order_delivered_customer_date)) / (60*60*24), 2) AS avg_delivery_time_days,
    
    -- Avg Distance between seller & customer
    ROUND(AVG(
        SQRT(
            POWER(111.32 * (cg.lat - sg.lat), 2) +
            POWER(111.32 * COS(RADIANS((cg.lat + sg.lat)/2)) * (cg.lng - sg.lng), 2)
        )
    ), 2) AS avg_distance_km,
    
    -- Avg Freight per Order
    ROUND(SUM(oi.freight_value) / COUNT(DISTINCT o.order_id), 2) AS avg_freight_per_order

FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN orders o ON oi.order_id = o.order_id
JOIN customers c ON o.customer_id = c.customer_id
JOIN sellers s ON oi.seller_id = s.seller_id
JOIN vw_zipcode_location cg ON c.customer_zip_code_prefix = cg.zip_prefix
JOIN vw_zipcode_location sg ON s.seller_zip_code_prefix = sg.zip_prefix

WHERE o.order_status = 'delivered'

GROUP BY p.product_category_name_english
ORDER BY total_sales DESC;



-- Question 3,6,8 merged
CREATE OR REPLACE VIEW kpi_seller_category AS
SELECT
    s.seller_name,
    p.product_category_name_english AS category,
    
    -- Sales Metrics
    COUNT(oi.product_id) AS total_sales_volume,
    FLOOR(SUM(oi.price)) AS total_sales,
    
    -- Review Metrics
    ROUND(AVG(orr.review_score), 2) AS avg_review_score,
    COUNT(orr.review_id) AS total_reviews,
    
    -- Cancellation Metrics
    COUNT(o.order_id) AS total_orders,
    SUM(CASE WHEN o.order_status = 'canceled' THEN 1 ELSE 0 END) AS canceled_orders,
    ROUND(
        (SUM(CASE WHEN o.order_status = 'canceled' THEN 1 ELSE 0 END) * 100.0) / COUNT(o.order_id),
        2
    ) AS cancellation_rate_pct

FROM order_items oi
JOIN sellers s ON oi.seller_id = s.seller_id
JOIN products p ON oi.product_id = p.product_id
JOIN orders o ON oi.order_id = o.order_id
LEFT JOIN order_reviews orr ON o.order_id = orr.order_id

GROUP BY s.seller_name, p.product_category_name_english
ORDER BY total_sales DESC;


-- Question 11,16,17 merged

CREATE OR REPLACE VIEW kpi_customer_lifecycle AS
WITH order_values AS (
    SELECT
        c.customer_unique_id,
        c.customer_name,
        c.customer_city,
        c.customer_state,
        o.order_id,
        SUM(op.payment_value) AS order_total_value
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    JOIN order_payments op ON o.order_id = op.order_id
    GROUP BY c.customer_unique_id, c.customer_name, c.customer_city, c.customer_state, o.order_id
),
customer_ltv AS (
    SELECT
        ov.customer_unique_id,
        ov.customer_name,
        ov.customer_city,
        ov.customer_state,
        ROUND(SUM(ov.order_total_value)/NULLIF(COUNT(DISTINCT ov.order_id),0), 2) AS avg_order_value,
        SUM(ov.order_total_value) AS total_revenue,
        COUNT(DISTINCT ov.order_id) AS total_orders,
        DATEDIFF(MAX(o.order_purchase_timestamp), MIN(o.order_purchase_timestamp)) AS total_stay_days
    FROM order_values ov
    JOIN orders o ON ov.order_id = o.order_id
    GROUP BY ov.customer_unique_id, ov.customer_name, ov.customer_city, ov.customer_state
),
rfm_base AS (
    SELECT
        c.customer_unique_id,
        DATEDIFF(MAX(o.order_purchase_timestamp), MIN(o.order_purchase_timestamp)) AS recency,
        COUNT(DISTINCT o.order_id) AS frequency,
        ROUND(AVG(oi.price + oi.freight_value), 2) AS monetary
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    JOIN order_items oi ON o.order_id = oi.order_id
    GROUP BY c.customer_unique_id
),
rfm_ranked AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency ASC) AS recency_rank,
        NTILE(5) OVER (ORDER BY frequency DESC) AS frequency_rank,
        NTILE(5) OVER (ORDER BY monetary DESC) AS monetary_rank
    FROM rfm_base
),
rfm_scored AS (
    SELECT *,
        CONCAT(recency_rank, '-', frequency_rank, '-', monetary_rank) AS rfm_score_string,
        CASE
            WHEN frequency = 1 THEN 'One-Time Buyer'
            ELSE 'Repeat Buyer'
        END AS buyer_type,
        CASE
            WHEN recency_rank = 5 AND frequency_rank = 5 AND monetary_rank = 5 THEN 'Champions'
            WHEN recency_rank = 5 AND frequency_rank >= 4 THEN 'Loyal Customers'
            WHEN recency_rank >= 4 AND frequency_rank <= 3 THEN 'Potential Loyalist'
            WHEN recency_rank >= 3 AND frequency_rank >= 3 AND monetary_rank >= 3 THEN 'Need Attention'
            WHEN recency_rank = 1 AND frequency_rank = 1 AND monetary_rank = 1 THEN 'Lost'
            WHEN recency_rank <= 2 AND frequency_rank <= 2 THEN 'At Risk'
            ELSE 'Others'
        END AS rfm_segment
    FROM rfm_ranked
)
SELECT 
    ltv.customer_unique_id,
    ltv.customer_name,
    ltv.customer_city,
    ltv.customer_state,
    ltv.avg_order_value AS AOV,
    ltv.total_revenue,
    ltv.total_orders,
    ltv.total_stay_days,
    rfm.recency,
    rfm.frequency,
    rfm.monetary,
    rfm.rfm_score_string,
    rfm.buyer_type,
    rfm.rfm_segment
FROM customer_ltv ltv
JOIN rfm_scored rfm ON ltv.customer_unique_id = rfm.customer_unique_id
ORDER BY ltv.total_revenue DESC;


-- QUestion -- 4
CREATE OR REPLACE VIEW vwm_busiest_order_months_or_seasonal_sales AS
SELECT 
    DATE_FORMAT(o.order_purchase_timestamp, '%b-%Y') AS Month_Year,   -- e.g. Jan-2018
    COUNT(o.order_id) AS No_of_orders,
    FLOOR(SUM(oic.price + oic.freight_value)) AS Total_Revenue
FROM orders o
JOIN order_items oic
    USING (order_id)
WHERE o.order_status = 'delivered'
GROUP BY 
    DATE_FORMAT(o.order_purchase_timestamp, '%b-%Y'),
    YEAR(o.order_purchase_timestamp),
    MONTH(o.order_purchase_timestamp)
ORDER BY
    YEAR(o.order_purchase_timestamp),
    MONTH(o.order_purchase_timestamp);

-- QUestion -- 5
CREATE OR REPLACE VIEW vwm_geographic_distribution_customer_city AS
SELECT 
    c.customer_state,
    c.customer_city,
    COUNT(DISTINCT c.customer_unique_id) AS Total_Customers,
    COUNT(DISTINCT o.order_id) AS Total_Orders,
    FLOOR(SUM(oi.price + oi.freight_value)) AS Total_Revenue
FROM customers c
JOIN orders o 
    ON c.customer_id = o.customer_id
JOIN order_items oi
    ON o.order_id = oi.order_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state, c.customer_city
ORDER BY Total_Revenue DESC;


-- QUestion -- 9
CREATE OR REPLACE VIEW vwm_delivery_delay_vs_review_score AS
SELECT 
    o.order_id,
    DATEDIFF(o.order_delivered_customer_date, o.order_estimated_delivery_date) AS delivery_delay_days,
    orc.review_score
FROM orders o
JOIN order_reviews orc 
    ON o.order_id = orc.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date != '0000-00-00 00:00:00'
  AND o.order_estimated_delivery_date != '0000-00-00 00:00:00';


-- QUestion -- 18
CREATE OR REPLACE VIEW vwm_churn_and_retention AS
WITH quarter_periods AS (
    SELECT 
        c.customer_unique_id,
        CONCAT(YEAR(o.order_purchase_timestamp), '-Q', CEIL(MONTH(o.order_purchase_timestamp) / 3)) AS quarter
    FROM orders o
    JOIN customers c USING(customer_id)
    WHERE o.order_status != 'canceled'
    GROUP BY c.customer_unique_id, YEAR(o.order_purchase_timestamp), CEIL(MONTH(o.order_purchase_timestamp)/3)
),

customer_movement AS (
    SELECT 
        qp1.quarter AS period_start,
        COUNT(DISTINCT qp1.customer_unique_id) AS customers_start,
        COUNT(DISTINCT qp2.customer_unique_id) AS customers_next
    FROM quarter_periods qp1
    LEFT JOIN quarter_periods qp2
        ON qp1.customer_unique_id = qp2.customer_unique_id
        AND (
            -- Q1 → Q2 same year
            (RIGHT(qp1.quarter, 2) = 'Q1' 
             AND qp2.quarter = CONCAT(LEFT(qp1.quarter, 4), '-Q2'))
            -- Q2 → Q3 same year
            OR (RIGHT(qp1.quarter, 2) = 'Q2' 
             AND qp2.quarter = CONCAT(LEFT(qp1.quarter, 4), '-Q3'))
            -- Q3 → Q4 same year
            OR (RIGHT(qp1.quarter, 2) = 'Q3' 
             AND qp2.quarter = CONCAT(LEFT(qp1.quarter, 4), '-Q4'))
            -- Q4 → Q1 next year
            OR (RIGHT(qp1.quarter, 2) = 'Q4' 
             AND qp2.quarter = CONCAT(LEFT(qp1.quarter, 4) + 1, '-Q1'))
        )
    GROUP BY qp1.quarter
)

SELECT 
    period_start,
    customers_start,
    COALESCE(customers_next, 0) AS customers_retained,
    (customers_start - COALESCE(customers_next, 0)) AS customers_lost,
    ROUND((COALESCE(customers_next, 0) * 100.0) / customers_start, 2) AS retention_rate_pct,
    ROUND(((customers_start - COALESCE(customers_next, 0)) * 100.0) / customers_start, 2) AS churn_rate_pct
FROM customer_movement
ORDER BY period_start;

-- QUestion -- 19
CREATE OR REPLACE VIEW vwm_state_cohort_revenue AS
WITH first_purchase AS (
    SELECT
        c.customer_unique_id,
        c.customer_state,
        MIN(YEAR(o.order_purchase_timestamp)) AS cohort_year
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status != 'canceled'
	-- AND o.order_purchase_timestamp != '0000-00-00 00:00:00'
	AND o.order_purchase_timestamp != '0000-00-00 00:00:00'
    GROUP BY c.customer_unique_id, c.customer_state
),
cohort_revenue AS (
    SELECT
        fp.customer_state,
        fp.cohort_year,
        YEAR(o.order_purchase_timestamp) AS order_year,
        (YEAR(o.order_purchase_timestamp) - fp.cohort_year) AS years_since_cohort,
        ROUND(SUM(oi.price + oi.freight_value), 2) AS total_revenue
    FROM first_purchase fp
    JOIN customers c ON fp.customer_unique_id = c.customer_unique_id
    JOIN orders o ON c.customer_id = o.customer_id
    JOIN order_items oi ON o.order_id = oi.order_id
	WHERE YEAR(o.order_purchase_timestamp) >= fp.cohort_year
    GROUP BY
        fp.customer_state,
        fp.cohort_year,
        order_year,
        years_since_cohort
),
cohort_with_pct AS (
    SELECT
        cr.*,
        ROUND(
            100.0 * cr.total_revenue /
            MAX(CASE WHEN cr.years_since_cohort = 0 THEN cr.total_revenue END)
                OVER (PARTITION BY cr.customer_state, cr.cohort_year),
            2
        ) AS pct_of_initial_revenue
    FROM cohort_revenue cr
)
SELECT *
FROM cohort_with_pct
ORDER BY customer_state, cohort_year, years_since_cohort;
