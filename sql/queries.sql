-- Payments analytics: queries for Q1 to Q6 (PostgreSQL, database fintech_payments)
-- Tables: customers, merchants, transactions, exchange_rates

-- Q1. Payment methods: success rate and failed value
SELECT COALESCE(t.payment_method, 'Unknown') AS payment_method,
       COUNT(t.transaction_id) AS attempts,
       COUNT(CASE WHEN t.status = 'success' THEN 1 END) AS total_successful_txns,
       ROUND(100.0 * COUNT(CASE WHEN t.status = 'success' THEN 1 END)
             / NULLIF(COUNT(t.transaction_id), 0), 2) AS success_rate,
       ROUND(SUM(CASE WHEN t.status = 'failed' THEN t.amount * r.rate_to_twd END), 2) AS failed_value_twd
FROM transactions t
JOIN exchange_rates r
  ON r.currency = t.currency
 AND r.rate_date = DATE(t.transaction_time)
GROUP BY payment_method
HAVING COUNT(transaction_id) >= 100
ORDER BY success_rate DESC;

-- Q2. Domestic vs. cross-border failure rate
SELECT c.customer_country,
       CASE WHEN c.customer_country = m.merchant_country THEN 'domestic'
            ELSE 'cross-border' END AS transaction_type,
       COUNT(t.transaction_id) AS attempts,
       COUNT(CASE WHEN t.status = 'failed' THEN 1 END) AS failed_txns,
       ROUND(100.0 * COUNT(CASE WHEN t.status = 'failed' THEN 1 END)
             / NULLIF(COUNT(t.transaction_id), 0), 2) AS failure_rate
FROM customers c
JOIN transactions t ON c.customer_id = t.customer_id
JOIN merchants m ON m.merchant_id = t.merchant_id
GROUP BY c.customer_country,
         CASE WHEN c.customer_country = m.merchant_country THEN 'domestic'
              ELSE 'cross-border' END
ORDER BY c.customer_country, transaction_type;

-- Q3. Velocity rule: flagged customers vs. fraud and chargebacks (5-minute window)
WITH with_gap AS (
    SELECT customer_id,
           transaction_time,
           transaction_time - LAG(transaction_time, 4)
               OVER (PARTITION BY customer_id ORDER BY transaction_time) AS gap
    FROM transactions
),
flagged AS (
    SELECT customer_id
    FROM with_gap
    WHERE gap <= INTERVAL '5 minutes'
    GROUP BY customer_id
),
labeled AS (
    SELECT c.customer_id,
           CASE WHEN f.customer_id IS NULL THEN 'no' ELSE 'yes' END AS group_label
    FROM customers c
    LEFT JOIN flagged f ON c.customer_id = f.customer_id
)
SELECT l.group_label,
       COUNT(DISTINCT l.customer_id) AS customers,
       COUNT(*) AS txns,
       COUNT(CASE WHEN t.is_fraud THEN 1 END) AS fraud_txns,
       ROUND(SUM(t.chargeback_value * r.rate_to_twd), 2) AS chargeback_total_twd
FROM labeled l
JOIN transactions t ON l.customer_id = t.customer_id
JOIN exchange_rates r
  ON r.currency = t.currency
 AND r.rate_date = DATE(t.transaction_time)
GROUP BY l.group_label;

-- Q4 part 1. Domestic vs. cross-border volume
SELECT c.customer_country,
       CASE WHEN c.customer_country = m.merchant_country THEN 'domestic'
            ELSE 'cross-border' END AS transaction_type,
       COUNT(t.transaction_id) AS attempts,
       COUNT(CASE WHEN t.status = 'success' THEN 1 END) AS successful_txns,
       ROUND(100.0 * COUNT(CASE WHEN t.status = 'success' THEN 1 END)
             / NULLIF(COUNT(t.transaction_id), 0), 2) AS success_rate,
       ROUND(SUM(CASE WHEN t.status = 'success' THEN t.amount * r.rate_to_twd END), 2) AS success_value_twd
FROM customers c
JOIN transactions t ON c.customer_id = t.customer_id
JOIN merchants m ON m.merchant_id = t.merchant_id
JOIN exchange_rates r
  ON r.currency = t.currency
 AND r.rate_date = DATE(t.transaction_time)
GROUP BY c.customer_country,
         CASE WHEN c.customer_country = m.merchant_country THEN 'domestic'
              ELSE 'cross-border' END
ORDER BY c.customer_country;

-- Q4 part 2. Taiwan customers' spend by currency
SELECT r.currency,
       COUNT(t.transaction_id) AS attempts,
       COUNT(CASE WHEN t.status = 'success' THEN 1 END) AS successful_txns,
       ROUND(100.0 * COUNT(CASE WHEN t.status = 'success' THEN 1 END)
             / NULLIF(COUNT(t.transaction_id), 0), 2) AS success_rate,
       ROUND(SUM(CASE WHEN t.status = 'success' THEN t.amount END), 2) AS spend_original,
       ROUND(SUM(CASE WHEN t.status = 'success' THEN t.amount * r.rate_to_twd END), 2) AS spend_twd
FROM customers c
JOIN transactions t ON c.customer_id = t.customer_id
JOIN exchange_rates r
  ON r.currency = t.currency
 AND r.rate_date = DATE(t.transaction_time)
WHERE c.customer_country = 'Taiwan'
GROUP BY r.currency
ORDER BY r.currency;

-- Q5. Fees as a share of volume
SELECT COALESCE(t.payment_method, 'Unknown') AS payment_method,
       CASE WHEN c.customer_country = m.merchant_country THEN 'domestic'
            ELSE 'cross-border' END AS transaction_type,
       COUNT(*) AS txns,
       ROUND(SUM(t.fee * r.rate_to_twd), 2) AS fees_twd,
       ROUND(SUM(t.amount * r.rate_to_twd), 2) AS volume_twd,
       ROUND(100.0 * SUM(t.fee * r.rate_to_twd)
             / NULLIF(SUM(t.amount * r.rate_to_twd), 0), 2) AS fee_pct
FROM customers c
JOIN transactions t ON c.customer_id = t.customer_id
JOIN merchants m ON m.merchant_id = t.merchant_id
JOIN exchange_rates r
  ON r.currency = t.currency
 AND r.rate_date = DATE(t.transaction_time)
WHERE t.status = 'success'
  AND t.fee IS NOT NULL
  AND t.amount IS NOT NULL
GROUP BY payment_method,
         CASE WHEN c.customer_country = m.merchant_country THEN 'domestic'
              ELSE 'cross-border' END
ORDER BY payment_method, transaction_type;

-- Q6. Top 5 merchants per customer country
WITH merchant_totals AS (
    SELECT c.customer_country, m.merchant_id, m.merchant_name,
           ROUND(SUM(CASE WHEN t.status = 'success' THEN t.amount * r.rate_to_twd END), 2) AS success_value_twd,
           ROUND(SUM(CASE WHEN t.status = 'failed'  THEN t.amount * r.rate_to_twd END), 2) AS failed_value_twd
    FROM customers c
    JOIN transactions t ON c.customer_id = t.customer_id
    JOIN merchants m ON t.merchant_id = m.merchant_id
    JOIN exchange_rates r
      ON r.currency = t.currency
     AND r.rate_date = DATE(t.transaction_time)
    GROUP BY m.merchant_id, m.merchant_name, c.customer_country
),
ranked AS (
    SELECT customer_country, merchant_id, merchant_name,
           success_value_twd, failed_value_twd,
           RANK() OVER (PARTITION BY customer_country ORDER BY success_value_twd DESC) AS rnk
    FROM merchant_totals
)
SELECT customer_country, rnk, merchant_id, merchant_name, success_value_twd, failed_value_twd
FROM ranked
WHERE rnk <= 5
ORDER BY customer_country, rnk;

