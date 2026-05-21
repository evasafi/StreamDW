-- ============================================================
-- StreamDW: Reporting Layer — Data Marts & Views
-- File: schema/04_reporting.sql
--
-- Pre-aggregated tables and views optimized for dashboards
-- and ad-hoc analysis.
--
-- SQL Skills Demonstrated:
--   - Multi-CTE aggregation pipelines
--   - Window functions (LAG, SUM OVER, running totals)
--   - Conditional aggregation (CASE inside SUM/COUNT)
--   - Views for reusable reporting logic
--   - Subqueries for derived metrics
--   - Temporary tables for complex multi-step ETL
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
        SELECT user_id, device_type,
            ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY COUNT(*) DESC) AS rn
        FROM fact_viewing_events
        GROUP BY user_id, device_type
    ) ranked
    WHERE rn = 1
),

-- Step 3: Find each user's favorite genre
user_top_genre AS (
    SELECT user_id, genre AS favorite_genre
    FROM (
        SELECT fve.user_id, dc.genre,
            ROW_NUMBER() OVER (PARTITION BY fve.user_id ORDER BY COUNT(*) DESC) AS rn
        FROM fact_viewing_events fve
        INNER JOIN dim_content dc ON fve.content_id = dc.content_id
        GROUP BY fve.user_id, dc.genre
    ) ranked
    WHERE rn = 1
)

-- Final assembly
SELECT
    du.user_id, du.username, du.region, du.age_group,
    du.current_plan_type AS current_plan,
    du.signup_date, du.days_since_signup,

    COALESCE(uvs.total_watch_events, 0),
    COALESCE(uvs.total_watch_minutes, 0),
    COALESCE(uvs.total_completed, 0),
    COALESCE(uvs.total_abandoned, 0),

    CASE
        WHEN (COALESCE(uvs.total_completed, 0) + COALESCE(uvs.total_abandoned, 0)) > 0
        THEN ROUND(uvs.total_completed * 100.0 / (uvs.total_completed + uvs.total_abandoned), 2)
        ELSE NULL
    END AS completion_rate,

    COALESCE(uvs.distinct_content_watched, 0),
    COALESCE(uvs.distinct_days_active, 0),
    utd.favorite_device,
    utg.favorite_genre,

    CASE
        WHEN COALESCE(uvs.distinct_days_active, 0) > 0
        THEN ROUND(uvs.total_watch_minutes / uvs.distinct_days_active, 2)
        ELSE NULL
    END AS avg_daily_watch_min,

    uvs.first_watch_date,
    uvs.last_watch_date,

    CASE
        WHEN uvs.last_watch_date IS NOT NULL
        THEN DATEDIFF(CURDATE(), uvs.last_watch_date)
        ELSE NULL
    END AS days_since_last_watch,

    CASE
        WHEN uvs.last_watch_date IS NULL                    THEN 'new'
        WHEN DATEDIFF(CURDATE(), uvs.last_watch_date) > 60  THEN 'churned'
        WHEN DATEDIFF(CURDATE(), uvs.last_watch_date) > 30  THEN 'high'
        WHEN DATEDIFF(CURDATE(), uvs.last_watch_date) > 14  THEN 'medium'
        ELSE 'low'
    END AS churn_risk

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
--             RANK() window function
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
    dc.content_id, dc.title, dc.content_type, dc.genre, dc.release_year,
    dc.duration_minutes, dc.duration_bucket, dc.is_original,
    dc.production_cost_usd, dc.cost_tier,

    COALESCE(s.total_views, 0),
    COALESCE(s.unique_viewers, 0),
    COALESCE(s.total_completions, 0),
    COALESCE(s.total_abandons, 0),

    CASE
        WHEN (COALESCE(s.total_completions, 0) + COALESCE(s.total_abandons, 0)) > 0
        THEN ROUND(s.total_completions * 100.0 / (s.total_completions + s.total_abandons), 2)
        ELSE NULL
    END AS completion_rate,

    COALESCE(s.total_watch_minutes, 0),
    s.avg_watch_minutes,

    CASE
        WHEN dc.production_cost_usd > 0
        THEN ROUND(COALESCE(s.total_views, 0) / dc.production_cost_usd, 6)
        ELSE NULL
    END AS views_per_dollar,

    CASE
        WHEN dc.production_cost_usd > 0
        THEN ROUND(COALESCE(s.total_watch_minutes, 0) / dc.production_cost_usd, 6)
        ELSE NULL
    END AS minutes_per_dollar,

    RANK() OVER (ORDER BY COALESCE(s.total_views, 0) DESC) AS popularity_rank

FROM dim_content dc
LEFT JOIN (
    SELECT
        content_id,
        COUNT(*) AS total_views,
        COUNT(DISTINCT user_id) AS unique_viewers,
        SUM(is_completed) AS total_completions,
        SUM(is_abandoned) AS total_abandons,
        ROUND(SUM(watch_duration_minutes), 2) AS total_watch_minutes,
        ROUND(AVG(watch_duration_minutes), 2) AS avg_watch_minutes
    FROM fact_viewing_events
    GROUP BY content_id
) s ON dc.content_id = s.content_id;


-- ============================================================
-- 3. MART_SUBSCRIPTION_METRICS
--
-- Monthly aggregation of subscription KPIs.
-- One row per month. Uses temporary tables for clean multi-step ETL.
--
-- Techniques: Temp tables, conditional COUNT/SUM,
--             date range overlap logic for active subscriptions
-- ============================================================

DROP TABLE IF EXISTS mart_subscription_metrics;

CREATE TABLE mart_subscription_metrics (
    ym                      VARCHAR(7)      NOT NULL    COMMENT 'YYYY-MM',
    new_subscriptions       INT             NOT NULL DEFAULT 0,
    ended_subscriptions     INT             NOT NULL DEFAULT 0,
    net_change              INT             NOT NULL DEFAULT 0,
    active_free_trial       INT             NOT NULL DEFAULT 0,
    active_basic            INT             NOT NULL DEFAULT 0,
    active_standard         INT             NOT NULL DEFAULT 0,
    active_premium          INT             NOT NULL DEFAULT 0,
    total_active            INT             NOT NULL DEFAULT 0,
    monthly_revenue         DECIMAL(12,2)   NOT NULL DEFAULT 0,
    avg_revenue_per_user    DECIMAL(8,2)    NULL        COMMENT 'ARPU for paying subscribers',
    PRIMARY KEY (ym)
) ENGINE=InnoDB
  COMMENT='Monthly subscription KPI mart. One row per month.';

-- Step-by-step with temp tables (avoids MySQL subquery limitations)
DROP TEMPORARY TABLE IF EXISTS tmp_months;
CREATE TEMPORARY TABLE tmp_months AS
SELECT DISTINCT ym_label AS ym FROM dim_date
WHERE full_date BETWEEN '2023-01-01' AND '2025-12-31';

DROP TEMPORARY TABLE IF EXISTS tmp_new;
CREATE TEMPORARY TABLE tmp_new AS
SELECT DATE_FORMAT(start_date, '%Y-%m') AS ym, COUNT(*) AS cnt
FROM fact_subscriptions
GROUP BY DATE_FORMAT(start_date, '%Y-%m');

DROP TEMPORARY TABLE IF EXISTS tmp_ended;
CREATE TEMPORARY TABLE tmp_ended AS
SELECT DATE_FORMAT(end_date, '%Y-%m') AS ym, COUNT(*) AS cnt
FROM fact_subscriptions
WHERE end_date IS NOT NULL
GROUP BY DATE_FORMAT(end_date, '%Y-%m');

DROP TEMPORARY TABLE IF EXISTS tmp_active;
CREATE TEMPORARY TABLE tmp_active AS
SELECT
    m.ym,
    SUM(CASE WHEN fs.plan_type = 'free_trial' THEN 1 ELSE 0 END) AS ft,
    SUM(CASE WHEN fs.plan_type = 'basic'      THEN 1 ELSE 0 END) AS ba,
    SUM(CASE WHEN fs.plan_type = 'standard'   THEN 1 ELSE 0 END) AS st,
    SUM(CASE WHEN fs.plan_type = 'premium'    THEN 1 ELSE 0 END) AS pr,
    COUNT(*) AS total_active,
    SUM(fs.monthly_price) AS revenue
FROM tmp_months m
INNER JOIN fact_subscriptions fs
    ON fs.start_date <= LAST_DAY(CONCAT(m.ym, '-01'))
    AND (fs.end_date >= CONCAT(m.ym, '-01') OR fs.end_date IS NULL)
GROUP BY m.ym;

INSERT INTO mart_subscription_metrics
SELECT
    m.ym,
    COALESCE(n.cnt, 0),
    COALESCE(e.cnt, 0),
    COALESCE(n.cnt, 0) - COALESCE(e.cnt, 0),
    COALESCE(a.ft, 0),
    COALESCE(a.ba, 0),
    COALESCE(a.st, 0),
    COALESCE(a.pr, 0),
    COALESCE(a.total_active, 0),
    ROUND(COALESCE(a.revenue, 0), 2),
    CASE
        WHEN (COALESCE(a.total_active, 0) - COALESCE(a.ft, 0)) > 0
        THEN ROUND(COALESCE(a.revenue, 0) / (a.total_active - a.ft), 2)
        ELSE NULL
    END
FROM tmp_months m
LEFT JOIN tmp_new n     ON m.ym = n.ym
LEFT JOIN tmp_ended e   ON m.ym = e.ym
LEFT JOIN tmp_active a  ON m.ym = a.ym
ORDER BY m.ym;

DROP TEMPORARY TABLE IF EXISTS tmp_months;
DROP TEMPORARY TABLE IF EXISTS tmp_new;
DROP TEMPORARY TABLE IF EXISTS tmp_ended;
DROP TEMPORARY TABLE IF EXISTS tmp_active;


-- ============================================================
-- 4. REUSABLE VIEWS
-- ============================================================

-- View: Daily Active Users (DAU) time series
DROP VIEW IF EXISTS v_daily_active_users;

CREATE VIEW v_daily_active_users AS
SELECT
    dd.full_date,
    dd.day_name,
    dd.ym_label,
    dd.is_weekend,
    COUNT(DISTINCT fve.user_id) AS daily_active_users,
    SUM(fve.watch_duration_minutes) AS total_watch_minutes,
    COUNT(*) AS total_events
FROM dim_date dd
LEFT JOIN fact_viewing_events fve ON dd.date_key = fve.date_key
WHERE dd.full_date BETWEEN '2023-01-01' AND '2025-12-31'
GROUP BY dd.full_date, dd.day_name, dd.ym_label, dd.is_weekend;


-- View: Content leaderboard
DROP VIEW IF EXISTS v_content_leaderboard;

CREATE VIEW v_content_leaderboard AS
SELECT
    popularity_rank, title, content_type, genre, is_original,
    total_views, unique_viewers, completion_rate,
    total_watch_minutes, views_per_dollar, cost_tier
FROM mart_content_performance
ORDER BY popularity_rank;


-- View: Churn risk summary
DROP VIEW IF EXISTS v_churn_risk_summary;

CREATE VIEW v_churn_risk_summary AS
SELECT
    churn_risk, current_plan, region,
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

SELECT 'mart_user_engagement' AS tbl, COUNT(*) AS cnt FROM mart_user_engagement
UNION ALL SELECT 'mart_content_performance', COUNT(*) FROM mart_content_performance
UNION ALL SELECT 'mart_subscription_metrics', COUNT(*) FROM mart_subscription_metrics;

SELECT churn_risk, COUNT(*) AS users FROM mart_user_engagement GROUP BY churn_risk ORDER BY users DESC;

SELECT popularity_rank, title, total_views FROM mart_content_performance ORDER BY popularity_rank LIMIT 5;

SELECT ym, total_active, monthly_revenue FROM mart_subscription_metrics ORDER BY ym DESC LIMIT 5;
