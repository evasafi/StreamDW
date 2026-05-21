-- ============================================================
-- StreamDW: Transformation Layer — Fact Tables
-- File: schema/03_facts.sql
--
-- Fact tables sit at the center of the star schema.
-- They contain measurable events and metrics, linked to
-- dimension tables via foreign keys.
--
-- SQL Skills Demonstrated:
--   - Window functions (ROW_NUMBER, LAG, session detection)
--   - Complex JOINs across multiple dimensions
--   - CASE expressions for derived boolean flags
--   - Date key lookups for star schema joins
--   - Computed columns from raw event data
--   - DATEDIFF for subscription duration calculations
-- ============================================================

USE stream_dw;


-- ============================================================
-- 1. FACT_VIEWING_EVENTS — Enriched Viewing Log
--
-- Each row = one viewing event (play, pause, complete, etc.)
-- Enriched with:
--   - date_key (FK to dim_date)
--   - device_key (FK to dim_device)
--   - watch_duration_minutes (converted from seconds)
--   - is_completed flag (derived from event_type)
--   - hour_of_day (extracted for time analysis)
--   - session_order (rank of views per user per day)
--
-- Techniques: JOIN, CASE, EXTRACT, window functions
-- ============================================================

DROP TABLE IF EXISTS fact_viewing_events;

CREATE TABLE fact_viewing_events (
    event_key               BIGINT          NOT NULL AUTO_INCREMENT,
    event_id                VARCHAR(36)     NOT NULL    COMMENT 'Natural key from source',
    user_id                 VARCHAR(36)     NOT NULL,
    content_id              VARCHAR(36)     NOT NULL,
    date_key                INT             NOT NULL    COMMENT 'FK to dim_date',
    device_key              TINYINT         NOT NULL    COMMENT 'FK to dim_device',
    event_type              VARCHAR(20)     NOT NULL,
    device_type             VARCHAR(30)     NOT NULL,
    watch_duration_sec      INT             NOT NULL,
    watch_duration_minutes  DECIMAL(8,2)    NOT NULL    COMMENT 'Converted from seconds',
    is_completed            BOOLEAN         NOT NULL    COMMENT 'TRUE if event_type = complete',
    is_abandoned            BOOLEAN         NOT NULL    COMMENT 'TRUE if event_type = abandon',
    hour_of_day             TINYINT         NOT NULL    COMMENT '0-23, extracted from timestamp',
    day_period              VARCHAR(15)     NOT NULL    COMMENT 'morning/afternoon/evening/night',
    event_timestamp         DATETIME        NOT NULL,
    session_order           INT             NOT NULL    COMMENT 'Nth viewing event per user per day',

    PRIMARY KEY (event_key),
    UNIQUE INDEX idx_fact_ve_event_id (event_id),
    INDEX idx_fact_ve_user (user_id),
    INDEX idx_fact_ve_content (content_id),
    INDEX idx_fact_ve_date (date_key),
    INDEX idx_fact_ve_device (device_key),
    INDEX idx_fact_ve_type (event_type),
    INDEX idx_fact_ve_hour (hour_of_day),
    INDEX idx_fact_ve_completed (is_completed),

    -- Composite indexes for common analytical patterns
    INDEX idx_fact_ve_user_date (user_id, date_key),
    INDEX idx_fact_ve_content_completed (content_id, is_completed),
    INDEX idx_fact_ve_date_type (date_key, event_type)
) ENGINE=InnoDB
  COMMENT='Enriched viewing event fact table. One row per event.';


INSERT INTO fact_viewing_events (
    event_id, user_id, content_id, date_key, device_key,
    event_type, device_type, watch_duration_sec, watch_duration_minutes,
    is_completed, is_abandoned, hour_of_day, day_period,
    event_timestamp, session_order
)
SELECT
    rve.event_id,
    rve.user_id,
    rve.content_id,

    -- Link to dim_date via computed date key
    CAST(DATE_FORMAT(rve.event_timestamp, '%Y%m%d') AS UNSIGNED) AS date_key,

    -- Link to dim_device
    dd.device_key,

    rve.event_type,
    rve.device_type,
    rve.watch_duration_sec,

    -- Convert seconds to minutes (2 decimal places)
    ROUND(rve.watch_duration_sec / 60.0, 2) AS watch_duration_minutes,

    -- Derive completion flag
    CASE WHEN rve.event_type = 'complete' THEN TRUE ELSE FALSE END AS is_completed,

    -- Derive abandonment flag
    CASE WHEN rve.event_type = 'abandon' THEN TRUE ELSE FALSE END AS is_abandoned,

    -- Extract hour for time-of-day analysis
    HOUR(rve.event_timestamp) AS hour_of_day,

    -- Categorize into day periods
    CASE
        WHEN HOUR(rve.event_timestamp) BETWEEN 6  AND 11 THEN 'morning'
        WHEN HOUR(rve.event_timestamp) BETWEEN 12 AND 17 THEN 'afternoon'
        WHEN HOUR(rve.event_timestamp) BETWEEN 18 AND 22 THEN 'evening'
        ELSE 'night'
    END AS day_period,

    rve.event_timestamp,

    -- Session order: what number viewing event is this per user per day?
    -- Uses ROW_NUMBER window function
    ROW_NUMBER() OVER (
        PARTITION BY rve.user_id, DATE(rve.event_timestamp)
        ORDER BY rve.event_timestamp ASC
    ) AS session_order

FROM raw_viewing_events rve
INNER JOIN dim_device dd
    ON rve.device_type = dd.device_type;


-- ============================================================
-- 2. FACT_SUBSCRIPTIONS — Subscription State Changes
--
-- Each row = one subscription record (state change).
-- Tracks the full lifecycle: trial → active → cancelled/expired.
--
-- Enriched with:
--   - start_date_key / end_date_key (FK to dim_date)
--   - duration_days (how long the subscription lasted)
--   - is_active flag
--   - lifetime_value (monthly_price × months active)
--   - plan_rank (ordering of plans by tier)
--
-- Techniques: DATEDIFF, CASE, computed metrics, JOINs
-- ============================================================

DROP TABLE IF EXISTS fact_subscriptions;

CREATE TABLE fact_subscriptions (
    subscription_key    BIGINT          NOT NULL AUTO_INCREMENT,
    subscription_id     VARCHAR(36)     NOT NULL    COMMENT 'Natural key from source',
    user_id             VARCHAR(36)     NOT NULL,
    plan_type           VARCHAR(20)     NOT NULL,
    plan_rank           TINYINT         NOT NULL    COMMENT '1=free, 2=basic, 3=standard, 4=premium',
    status              VARCHAR(20)     NOT NULL,
    is_active           BOOLEAN         NOT NULL,
    start_date          DATE            NOT NULL,
    start_date_key      INT             NOT NULL    COMMENT 'FK to dim_date',
    end_date            DATE            NULL,
    end_date_key        INT             NULL        COMMENT 'FK to dim_date, NULL if active',
    monthly_price       DECIMAL(6,2)    NOT NULL,
    duration_days       INT             NULL        COMMENT 'NULL if still active',
    duration_months     DECIMAL(5,1)    NULL        COMMENT 'Approximate months active',
    estimated_ltv       DECIMAL(10,2)   NULL        COMMENT 'monthly_price × months (for ended subs)',

    PRIMARY KEY (subscription_key),
    UNIQUE INDEX idx_fact_subs_id (subscription_id),
    INDEX idx_fact_subs_user (user_id),
    INDEX idx_fact_subs_plan (plan_type),
    INDEX idx_fact_subs_status (status),
    INDEX idx_fact_subs_active (is_active),
    INDEX idx_fact_subs_start (start_date_key),
    INDEX idx_fact_subs_end (end_date_key),

    -- Composite for common queries
    INDEX idx_fact_subs_user_plan (user_id, plan_type),
    INDEX idx_fact_subs_plan_status (plan_type, status)
) ENGINE=InnoDB
  COMMENT='Subscription fact table tracking lifecycle and estimated LTV.';


INSERT INTO fact_subscriptions (
    subscription_id, user_id, plan_type, plan_rank, status, is_active,
    start_date, start_date_key, end_date, end_date_key,
    monthly_price, duration_days, duration_months, estimated_ltv
)
SELECT
    rs.subscription_id,
    rs.user_id,
    rs.plan_type,

    -- Rank plans for ordering in queries
    CASE rs.plan_type
        WHEN 'free_trial' THEN 1
        WHEN 'basic'      THEN 2
        WHEN 'standard'   THEN 3
        WHEN 'premium'    THEN 4
    END AS plan_rank,

    rs.status,

    -- Active flag
    CASE WHEN rs.status = 'active' THEN TRUE ELSE FALSE END AS is_active,

    rs.start_date,
    CAST(DATE_FORMAT(rs.start_date, '%Y%m%d') AS UNSIGNED) AS start_date_key,

    rs.end_date,
    CASE
        WHEN rs.end_date IS NOT NULL
        THEN CAST(DATE_FORMAT(rs.end_date, '%Y%m%d') AS UNSIGNED)
        ELSE NULL
    END AS end_date_key,

    rs.monthly_price,

    -- Duration in days (NULL if active — still ongoing)
    CASE
        WHEN rs.end_date IS NOT NULL
        THEN DATEDIFF(rs.end_date, rs.start_date)
        ELSE NULL
    END AS duration_days,

    -- Approximate months (for LTV calculation)
    CASE
        WHEN rs.end_date IS NOT NULL
        THEN ROUND(DATEDIFF(rs.end_date, rs.start_date) / 30.44, 1)
        ELSE NULL
    END AS duration_months,

    -- Estimated lifetime value = price × months subscribed
    CASE
        WHEN rs.end_date IS NOT NULL AND rs.monthly_price > 0
        THEN ROUND(rs.monthly_price * (DATEDIFF(rs.end_date, rs.start_date) / 30.44), 2)
        ELSE NULL
    END AS estimated_ltv

FROM raw_subscriptions rs;


-- ============================================================
-- VERIFICATION
-- ============================================================

SELECT '--- FACT TABLES LOADED ---' AS status;

SELECT 'fact_viewing_events' AS table_name, COUNT(*) AS row_count FROM fact_viewing_events
UNION ALL
SELECT 'fact_subscriptions', COUNT(*) FROM fact_subscriptions;

-- Quick quality checks
SELECT '--- VIEWING EVENTS BY DAY PERIOD ---' AS status;
SELECT day_period, COUNT(*) AS event_count,
       ROUND(AVG(watch_duration_minutes), 1) AS avg_watch_min
FROM fact_viewing_events
GROUP BY day_period
ORDER BY event_count DESC;

SELECT '--- SUBSCRIPTIONS BY PLAN & STATUS ---' AS status;
SELECT plan_type, status, COUNT(*) AS sub_count,
       ROUND(AVG(duration_days), 0) AS avg_duration_days,
       ROUND(AVG(estimated_ltv), 2) AS avg_ltv
FROM fact_subscriptions
GROUP BY plan_type, status
ORDER BY plan_rank, status;

SELECT '--- SESSION DEPTH (views per user per day) ---' AS status;
SELECT
    CASE
        WHEN session_order = 1  THEN '1 view'
        WHEN session_order <= 3 THEN '2-3 views'
        WHEN session_order <= 5 THEN '4-5 views'
        ELSE '6+ views'
    END AS session_depth,
    COUNT(*) AS event_count
FROM fact_viewing_events
GROUP BY
    CASE
        WHEN session_order = 1  THEN '1 view'
        WHEN session_order <= 3 THEN '2-3 views'
        WHEN session_order <= 5 THEN '4-5 views'
        ELSE '6+ views'
    END
ORDER BY MIN(session_order);
