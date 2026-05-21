-- ============================================================
-- StreamDW: Reporting Layer — Data Marts & Views
-- File: schema/04_reporting.sql
--
-- Pre-aggregated tables and views optimized for dashboards
-- and ad-hoc analysis. These sit on top of the fact and
-- dimension tables and answer common business questions
-- without requiring complex JOINs each time.
--
-- SQL Skills Demonstrated:
--   - Multi-CTE aggregation pipelines
--   - Window functions (LAG, SUM OVER, running totals)
--   - Conditional aggregation (CASE inside SUM/COUNT)
--   - GROUP BY with ROLLUP for subtotals
--   - Views for reusable reporting logic
--   - Subqueries for derived metrics
-- ============================================================

USE stream_dw;


-- ============================================================
-- 1. MART_USER_ENGAGEMENT
--
-- One row per user. Summarizes their entire engagement history.
-- Used for: churn analysis, user segmentation, retention reports.
--
-- Techniques: Multi-CTE pipeline, conditional aggregation,
--             DATEDIFF, CASE for risk segmentation
-- ============================================================

DROP TABLE IF EXISTS mart_user_engagement;

CREATE TABLE mart_user_engagement (
    user_id                 VARCHAR(36)     NOT NULL,
    username                VARCHAR(100)    NOT NULL,
    region                  VARCHAR(30)     NOT NULL,
    age_group               VARCHAR(20)     NULL,
    current_plan            VARCHAR(20)     NULL,
    signup_date             DATE            NOT NULL,
    days_since_signup       INT             NOT NULL,
    total_watch_events      INT             NOT NULL DEFAULT 0,
    total_watch_minutes     DECIMAL(12,2)   NOT NULL DEFAULT 0,
    total_completed         INT             NOT NULL DEFAULT 0,
    total_abandoned         INT             NOT NULL DEFAULT 0,
    completion_rate         DECIMAL(5,2)    NULL        COMMENT 'Percentage of completed views',
    distinct_content_watched INT            NOT NULL DEFAULT 0,
    distinct_days_active    INT             NOT NULL DEFAULT 0,
    favorite_device         VARCHAR(30)     NULL,
    favorite_genre          VARCHAR(50)     NULL,
    avg_daily_watch_min     DECIMAL(8,2)    NULL,
    first_watch_date        DATE            NULL,
    last_watch_date         DATE            NULL,
    days_since_last_watch   INT             NULL,
    churn_risk              VARCHAR(20)     NOT NULL    COMMENT 'low/medium/high/churned/new',

    PRIMARY KEY (user_id),
    INDEX idx_mart_ue_risk (churn_risk),
    INDEX idx_mart_ue_region (region),
    INDEX idx_mart_ue_plan (current_plan),
    INDEX idx_mart_ue_last_watch (days_since_last_watch)
) ENGINE=InnoDB
  COMMENT='User engagement summary mart. One row per user.';


INSERT INTO mart_user_engagement
WITH
-- Step 1: Aggregate viewing metrics per user
user_viewing_stats AS (
    SELECT
        fve.user_id,
        COUNT(*)                                            AS total_watch_events,
        ROUND(SUM(fve.watch_duration_minutes), 2)          AS total_watch_minutes,
        SUM(fve.is_completed)                               AS total_completed,
        SUM(fve.is_abandoned)                               AS total_abandoned,
        COUNT(DISTINCT fve.content_id)                      AS distinct_content_watched,
        COUNT(DISTINCT DATE(fve.event_timestamp))           AS distinct_days_active,
        MIN(DATE(fve.event_timestamp))                      AS first_watch_date,
        MAX(DATE(fve.event_timestamp))                      AS last_watch_date
    FROM fact_viewing_events fve
    GROUP BY fve.user_id
),

-- Step 2: Find each user's most-used device
user_top_device AS (
    SELECT user_id, device_type AS favorite_device
    FROM (
        SELECT
            user_id,
            device_type,
            ROW_NUMBER() OVER (
                PARTITION BY user_id
                ORDER BY COUNT(*) DESC
            ) AS rn
        FROM fact_viewing_events
        GROUP BY user_id, device_type
    ) ranked
    WHERE rn = 1
),

-- Step 3: Find each user's favorite genre
user_top_genre AS (
    SELECT user_id, genre AS favorite_genre
    FROM (
        SELECT
            fve.user_id,
            dc.genre,
            ROW_NUMBER() OVER (
                PARTITION BY fve.user_id
                ORDER BY COUNT(*) DESC
            ) AS rn
        FROM fact_viewing_events fve
        INNER JOIN dim_content dc ON fve.content_id = dc.content_id
        GROUP BY fve.user_id, dc.genre
    ) ranked
    WHERE rn = 1
)

-- Final assembly
SELECT
    du.user_id,
    du.username,
    du.region,
    du.age_group,
    du.current_plan_type                                        AS current_plan,
    du.signup_date,
    du.days_since_signup,

    COALESCE(uvs.total_watch_events, 0)                         AS total_watch_events,
    COALESCE(uvs.total_watch_minutes, 0)                        AS total_watch_minutes,
    COALESCE(uvs.total_completed, 0)                            AS total_completed,
    COALESCE(uvs.total_abandoned, 0)                            AS total_abandoned,

    -- Completion rate: completed / (completed + abandoned) × 100
    CASE
        WHEN (COALESCE(uvs.total_completed, 0) + COALESCE(uvs.total_abandoned, 0)) > 0
        THEN ROUND(
            uvs.total_completed * 100.0 /
            (uvs.total_completed + uvs.total_abandoned), 2
        )
        ELSE NULL
    END                                                         AS completion_rate,

    COALESCE(uvs.distinct_content_watched, 0)                   AS distinct_content_watched,
    COALESCE(uvs.distinct_days_active, 0)                       AS distinct_days_active,

    utd.favorite_device,
    utg.favorite_genre,

    -- Average daily watch time (only on days they were active)
    CASE
        WHEN COALESCE(uvs.distinct_days_active, 0) > 0
        THEN ROUND(uvs.total_watch_minutes / uvs.distinct_days_active, 2)
        ELSE NULL
    END                                                         AS avg_daily_watch_min,

    uvs.first_watch_date,
    uvs.last_watch_date,

    CASE
        WHEN uvs.last_watch_date IS NOT NULL
        THEN DATEDIFF(CURDATE(), uvs.last_watch_date)
        ELSE NULL
    END                                                         AS days_since_last_watch,

    -- Churn risk segmentation
    CASE
        WHEN uvs.last_watch_date IS NULL                        THEN 'new'
        WHEN DATEDIFF(CURDATE(), uvs.last_watch_date) > 60      THEN 'churned'
        WHEN DATEDIFF(CURDATE(), uvs.last_watch_date) > 30      THEN 'high'
        WHEN DATEDIFF(CURDATE(), uvs.last_watch_date) > 14      THEN 'medium'
        ELSE 'low'
    END                                                         AS churn_risk

FROM dim_users du
LEFT JOIN user_viewing_stats uvs   ON du.user_id = uvs.user_id
LEFT JOIN user_top_device utd      ON du.user_id = utd.user_id
LEFT JOIN user_top_genre utg       ON du.user_id = utg.user_id;


-- ============================================================
-- 2. MART_CONTENT_PERFORMANCE
--
-- One row per content item. Summarizes viewership and ROI.
-- Used for: content investment decisions, catalog optimization.
--
-- Techniques: Conditional aggregation, computed ROI metrics,
--             percentile-style ranking with window functions
-- ============================================================

DROP TABLE IF EXISTS mart_content_performance;

CREATE TABLE mart_content_performance (
    content_id              VARCHAR(36)     NOT NULL,
    title                   VARCHAR(255)    NOT NULL,
    content_type            VARCHAR(20)     NOT NULL,
    genre                   VARCHAR(50)     NOT NULL,
    release_year            INT             NOT NULL,
    duration_minutes        INT             NOT NULL,
    duration_bucket         VARCHAR(20)     NOT NULL,
    is_original             BOOLEAN         NOT NULL,
    production_cost_usd     DECIMAL(12,2)   NULL,
    cost_tier               VARCHAR(20)     NULL,
    total_views             INT             NOT NULL DEFAULT 0,
    unique_viewers          INT             NOT NULL DEFAULT 0,
    total_completions       INT             NOT NULL DEFAULT 0,
    total_abandons          INT             NOT NULL DEFAULT 0,
    completion_rate         DECIMAL(5,2)    NULL,
    total_watch_minutes     DECIMAL(12,2)   NOT NULL DEFAULT 0,
    avg_watch_minutes       DECIMAL(8,2)    NULL,
    views_per_dollar        DECIMAL(10,6)   NULL        COMMENT 'ROI proxy: total views / cost',
    minutes_per_dollar      DECIMAL(10,6)   NULL        COMMENT 'ROI proxy: watch minutes / cost',
    popularity_rank         INT             NULL        COMMENT 'Ranked by total views',

    PRIMARY KEY (content_id),
    INDEX idx_mart_cp_genre (genre),
    INDEX idx_mart_cp_type (content_type),
    INDEX idx_mart_cp_original (is_original),
    INDEX idx_mart_cp_rank (popularity_rank)
) ENGINE=InnoDB
  COMMENT='Content performance mart. One row per content item.';


INSERT INTO mart_content_performance
SELECT
    dc.content_id,
    dc.title,
    dc.content_type,
    dc.genre,
    dc.release_year,
    dc.duration_minutes,
    dc.duration_bucket,
    dc.is_original,
    dc.production_cost_usd,
    dc.cost_tier,

    COALESCE(stats.total_views, 0)          AS total_views,
    COALESCE(stats.unique_viewers, 0)       AS unique_viewers,
    COALESCE(stats.total_completions, 0)    AS total_completions,
    COALESCE(stats.total_abandons, 0)       AS total_abandons,

    -- Completion rate
    CASE
        WHEN (COALESCE(stats.total_completions, 0) + COALESCE(stats.total_abandons, 0)) > 0
        THEN ROUND(
            stats.total_completions * 100.0 /
            (stats.total_completions + stats.total_abandons), 2
        )
        ELSE NULL
    END                                     AS completion_rate,

    COALESCE(stats.total_watch_minutes, 0)  AS total_watch_minutes,
    stats.avg_watch_minutes,

    -- ROI: views per dollar invested
    CASE
        WHEN dc.production_cost_usd > 0
        THEN ROUND(COALESCE(stats.total_views, 0) / dc.production_cost_usd, 6)
        ELSE NULL
    END                                     AS views_per_dollar,

    -- ROI: minutes watched per dollar invested
    CASE
        WHEN dc.production_cost_usd > 0
        THEN ROUND(COALESCE(stats.total_watch_minutes, 0) / dc.production_cost_usd, 6)
        ELSE NULL
    END                                     AS minutes_per_dollar,

    -- Popularity rank across entire catalog
    RANK() OVER (ORDER BY COALESCE(stats.total_views, 0) DESC) AS popularity_rank

FROM dim_content dc
LEFT JOIN (
    SELECT
        content_id,
        COUNT(*)                                AS total_views,
        COUNT(DISTINCT user_id)                 AS unique_viewers,
        SUM(is_completed)                       AS total_completions,
        SUM(is_abandoned)                       AS total_abandons,
        ROUND(SUM(watch_duration_minutes), 2)   AS total_watch_minutes,
        ROUND(AVG(watch_duration_minutes), 2)   AS avg_watch_minutes
    FROM fact_viewing_events
    GROUP BY content_id
) stats ON dc.content_id = stats.content_id;


-- ============================================================
-- 3. MART_SUBSCRIPTION_METRICS
--
-- Monthly aggregation of subscription KPIs.
-- One row per month. Used for: MRR tracking, churn trends.
--
-- Techniques: Date truncation, conditional COUNT/SUM,
--             window functions for month-over-month change
-- ============================================================

DROP TABLE IF EXISTS mart_subscription_metrics;

CREATE TABLE mart_subscription_metrics (
    year_month              VARCHAR(7)      NOT NULL    COMMENT 'YYYY-MM',
    new_subscriptions       INT             NOT NULL DEFAULT 0,
    ended_subscriptions     INT             NOT NULL DEFAULT 0,
    net_change              INT             NOT NULL DEFAULT 0,
    active_free_trial       INT             NOT NULL DEFAULT 0,
    active_basic            INT             NOT NULL DEFAULT 0,
    active_standard         INT             NOT NULL DEFAULT 0,
    active_premium          INT             NOT NULL DEFAULT 0,
    total_active            INT             NOT NULL DEFAULT 0,
    monthly_revenue         DECIMAL(12,2)   NOT NULL DEFAULT 0  COMMENT 'Sum of monthly prices for active subs',
    avg_revenue_per_user    DECIMAL(8,2)    NULL        COMMENT 'ARPU for paying subscribers',
    revenue_mom_change      DECIMAL(8,2)    NULL        COMMENT 'Month-over-month revenue change %',

    PRIMARY KEY (year_month)
) ENGINE=InnoDB
  COMMENT='Monthly subscription KPI mart. One row per month.';


INSERT INTO mart_subscription_metrics
WITH
-- Generate a list of all months in our data range
month_series AS (
    SELECT DISTINCT year_month
    FROM dim_date
    WHERE full_date BETWEEN '2023-01-01' AND '2025-12-31'
),

-- Count new subscriptions per month
new_subs AS (
    SELECT
        DATE_FORMAT(start_date, '%Y-%m') AS year_month,
        COUNT(*) AS new_count
    FROM fact_subscriptions
    GROUP BY DATE_FORMAT(start_date, '%Y-%m')
),

-- Count ended subscriptions per month
ended_subs AS (
    SELECT
        DATE_FORMAT(end_date, '%Y-%m') AS year_month,
        COUNT(*) AS ended_count
    FROM fact_subscriptions
    WHERE end_date IS NOT NULL
    GROUP BY DATE_FORMAT(end_date, '%Y-%m')
),

-- For each month, count active subscriptions by plan type
-- A subscription is active in a month if start_date <= month_end AND (end_date >= month_start OR end_date IS NULL)
monthly_active AS (
    SELECT
        ms.year_month,
        SUM(CASE WHEN fs.plan_type = 'free_trial' THEN 1 ELSE 0 END) AS active_free_trial,
        SUM(CASE WHEN fs.plan_type = 'basic'      THEN 1 ELSE 0 END) AS active_basic,
        SUM(CASE WHEN fs.plan_type = 'standard'   THEN 1 ELSE 0 END) AS active_standard,
        SUM(CASE WHEN fs.plan_type = 'premium'    THEN 1 ELSE 0 END) AS active_premium,
        COUNT(*)                                                       AS total_active,
        SUM(fs.monthly_price)                                          AS monthly_revenue
    FROM month_series ms
    CROSS JOIN fact_subscriptions fs
    WHERE fs.start_date <= LAST_DAY(CONCAT(ms.year_month, '-01'))
      AND (fs.end_date >= CONCAT(ms.year_month, '-01') OR fs.end_date IS NULL)
    GROUP BY ms.year_month
)

SELECT
    ma.year_month,
    COALESCE(ns.new_count, 0)                                   AS new_subscriptions,
    COALESCE(es.ended_count, 0)                                 AS ended_subscriptions,
    COALESCE(ns.new_count, 0) - COALESCE(es.ended_count, 0)    AS net_change,
    ma.active_free_trial,
    ma.active_basic,
    ma.active_standard,
    ma.active_premium,
    ma.total_active,
    ROUND(ma.monthly_revenue, 2)                                AS monthly_revenue,

    -- ARPU: revenue / paying subscribers (exclude free trial)
    CASE
        WHEN (ma.total_active - ma.active_free_trial) > 0
        THEN ROUND(
            ma.monthly_revenue / (ma.total_active - ma.active_free_trial), 2
        )
        ELSE NULL
    END                                                         AS avg_revenue_per_user,

    -- Month-over-month revenue change (uses LAG window function)
    ROUND(
        (ma.monthly_revenue - LAG(ma.monthly_revenue) OVER (ORDER BY ma.year_month))
        / NULLIF(LAG(ma.monthly_revenue) OVER (ORDER BY ma.year_month), 0) * 100
    , 2)                                                        AS revenue_mom_change

FROM monthly_active ma
LEFT JOIN new_subs ns   ON ma.year_month = ns.year_month
LEFT JOIN ended_subs es ON ma.year_month = es.year_month
ORDER BY ma.year_month;


-- ============================================================
-- 4. REUSABLE VIEWS
--
-- Views encapsulate common query patterns so analysts
-- don't have to write complex JOINs each time.
-- ============================================================

-- View: Daily Active Users (DAU) time series
DROP VIEW IF EXISTS v_daily_active_users;

CREATE VIEW v_daily_active_users AS
SELECT
    dd.full_date,
    dd.day_name,
    dd.year_month,
    dd.is_weekend,
    COUNT(DISTINCT fve.user_id) AS daily_active_users,
    SUM(fve.watch_duration_minutes) AS total_watch_minutes,
    COUNT(*) AS total_events
FROM dim_date dd
LEFT JOIN fact_viewing_events fve
    ON dd.date_key = fve.date_key
WHERE dd.full_date BETWEEN '2023-01-01' AND '2025-12-31'
GROUP BY dd.full_date, dd.day_name, dd.year_month, dd.is_weekend;


-- View: Content leaderboard (top content by views)
DROP VIEW IF EXISTS v_content_leaderboard;

CREATE VIEW v_content_leaderboard AS
SELECT
    mcp.popularity_rank,
    mcp.title,
    mcp.content_type,
    mcp.genre,
    mcp.is_original,
    mcp.total_views,
    mcp.unique_viewers,
    mcp.completion_rate,
    mcp.total_watch_minutes,
    mcp.views_per_dollar,
    mcp.cost_tier
FROM mart_content_performance mcp
ORDER BY mcp.popularity_rank;


-- View: Churn risk summary
DROP VIEW IF EXISTS v_churn_risk_summary;

CREATE VIEW v_churn_risk_summary AS
SELECT
    churn_risk,
    current_plan,
    region,
    COUNT(*) AS user_count,
    ROUND(AVG(total_watch_minutes), 1) AS avg_watch_minutes,
    ROUND(AVG(distinct_days_active), 1) AS avg_days_active,
    ROUND(AVG(days_since_last_watch), 0) AS avg_days_since_watch
FROM mart_user_engagement
GROUP BY churn_risk, current_plan, region;


-- ============================================================
-- VERIFICATION
-- ============================================================

SELECT '--- REPORTING LAYER LOADED ---' AS status;

SELECT 'mart_user_engagement' AS table_name, COUNT(*) AS row_count FROM mart_user_engagement
UNION ALL
SELECT 'mart_content_performance', COUNT(*) FROM mart_content_performance
UNION ALL
SELECT 'mart_subscription_metrics', COUNT(*) FROM mart_subscription_metrics;

-- Churn risk distribution
SELECT '--- CHURN RISK DISTRIBUTION ---' AS status;
SELECT churn_risk, COUNT(*) AS users,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM mart_user_engagement
GROUP BY churn_risk
ORDER BY users DESC;

-- Top 5 content by views
SELECT '--- TOP 5 CONTENT ---' AS status;
SELECT popularity_rank, title, content_type, total_views, completion_rate
FROM v_content_leaderboard
LIMIT 5;

-- Latest 3 months of subscription metrics
SELECT '--- RECENT SUBSCRIPTION TRENDS ---' AS status;
SELECT year_month, total_active, monthly_revenue, revenue_mom_change
FROM mart_subscription_metrics
ORDER BY year_month DESC
LIMIT 3;
