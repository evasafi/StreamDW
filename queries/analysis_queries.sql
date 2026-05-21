-- ============================================================
-- StreamDW: Analytical Queries
-- File: queries/analysis_queries.sql
--
-- 7 showcase queries that answer real business questions.
-- Each demonstrates advanced SQL techniques.
--
-- Reference date: We use the max event date in our dataset
-- instead of CURDATE() since our data spans 2023-2025.
-- ============================================================

USE stream_dw;

SET @ref_date = (SELECT MAX(DATE(event_timestamp)) FROM fact_viewing_events);


-- ============================================================
-- Q1: 7-DAY AND 30-DAY ROLLING AVERAGE OF DAILY ACTIVE USERS
--
-- Business Question:
--   "What's the DAU trend, smoothed to remove daily noise?"
--
-- SQL Techniques:
--   - CTE for daily aggregation
--   - Window functions: AVG() OVER (ROWS BETWEEN)
--   - Rolling/moving averages
-- ============================================================

WITH daily_active AS (
    SELECT
        DATE(event_timestamp)       AS event_date,
        COUNT(DISTINCT user_id)     AS dau,
        ROUND(SUM(watch_duration_minutes), 0) AS total_minutes
    FROM fact_viewing_events
    GROUP BY DATE(event_timestamp)
)
SELECT
    event_date,
    dau,
    total_minutes,

    -- 7-day rolling average
    ROUND(AVG(dau) OVER (
        ORDER BY event_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 1) AS dau_7d_avg,

    -- 30-day rolling average
    ROUND(AVG(dau) OVER (
        ORDER BY event_date
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ), 1) AS dau_30d_avg,

    -- 7-day rolling total minutes (engagement trend)
    ROUND(SUM(total_minutes) OVER (
        ORDER BY event_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 0) AS minutes_7d_sum

FROM daily_active
ORDER BY event_date DESC
LIMIT 30;


-- ============================================================
-- Q2: CHURN RISK SEGMENTATION WITH USER DETAILS
--
-- Business Question:
--   "Which users are at risk of churning, and what do they
--    have in common? Give me actionable segments."
--
-- SQL Techniques:
--   - Multi-CTE pipeline
--   - CASE for segmentation logic
--   - Conditional aggregation with GROUP BY
--   - Window function: PERCENT_RANK
-- ============================================================

WITH user_activity AS (
    SELECT
        fve.user_id,
        MAX(DATE(fve.event_timestamp))                  AS last_active,
        DATEDIFF(@ref_date, MAX(DATE(fve.event_timestamp))) AS days_inactive,
        COUNT(*)                                         AS total_events,
        ROUND(SUM(fve.watch_duration_minutes), 1)       AS total_minutes,
        COUNT(DISTINCT fve.content_id)                   AS unique_titles,
        SUM(fve.is_completed)                            AS completions
    FROM fact_viewing_events fve
    INNER JOIN dim_users du ON fve.user_id = du.user_id
    GROUP BY fve.user_id
),
segmented AS (
    SELECT
        ua.*,
        du.region,
        du.age_group,
        du.current_plan_type,
        CASE
            WHEN ua.days_inactive <= 14  THEN 'low'
            WHEN ua.days_inactive <= 30  THEN 'medium'
            WHEN ua.days_inactive <= 60  THEN 'high'
            ELSE 'churned'
        END AS risk_level,
        PERCENT_RANK() OVER (ORDER BY ua.total_minutes DESC) AS engagement_percentile
    FROM user_activity ua
    INNER JOIN dim_users du ON ua.user_id = du.user_id
)
SELECT
    risk_level,
    region,
    COUNT(*)                                    AS users,
    ROUND(AVG(days_inactive), 0)                AS avg_days_inactive,
    ROUND(AVG(total_minutes), 0)                AS avg_watch_min,
    ROUND(AVG(unique_titles), 0)                AS avg_titles_watched,
    ROUND(AVG(engagement_percentile) * 100, 1)  AS avg_engagement_pctile,
    SUM(CASE WHEN current_plan_type = 'premium' THEN 1 ELSE 0 END) AS premium_users
FROM segmented
GROUP BY risk_level, region
ORDER BY
    FIELD(risk_level, 'churned', 'high', 'medium', 'low'),
    users DESC;


-- ============================================================
-- Q3: CONTENT COMPLETION RATE BY GENRE AND TYPE
--
-- Business Question:
--   "What's the completion rate across genres and content types?
--    Where are users dropping off?"
--
-- SQL Techniques:
--   - Conditional aggregation (CASE inside SUM)
--   - Multi-level GROUP BY
--   - Derived completion metrics
--   - Sorting by computed column
-- ============================================================

SELECT
    dc.genre,
    dc.content_type,
    COUNT(*)                                    AS total_views,
    SUM(fve.is_completed)                       AS completions,
    SUM(fve.is_abandoned)                       AS abandons,

    -- Completion rate: completed / (completed + abandoned)
    ROUND(
        SUM(fve.is_completed) * 100.0 /
        NULLIF(SUM(fve.is_completed) + SUM(fve.is_abandoned), 0)
    , 1) AS completion_pct,

    -- Average watch time
    ROUND(AVG(fve.watch_duration_minutes), 1)   AS avg_watch_min,

    -- "Stickiness": avg watch / avg content duration
    ROUND(
        AVG(fve.watch_duration_minutes) /
        NULLIF(AVG(dc.duration_minutes), 0) * 100
    , 1) AS stickiness_pct

FROM fact_viewing_events fve
INNER JOIN dim_content dc ON fve.content_id = dc.content_id
GROUP BY dc.genre, dc.content_type
HAVING COUNT(*) >= 50
ORDER BY completion_pct DESC;


-- ============================================================
-- Q4: CUSTOMER LIFETIME VALUE BY PLAN TYPE
--
-- Business Question:
--   "What's the average customer lifetime value by plan?
--    Which plan tier generates the most long-term revenue?"
--
-- SQL Techniques:
--   - Multi-CTE with sequential dependencies
--   - DATEDIFF for duration calculations
--   - CASE for conditional metrics
--   - Aggregate functions on computed columns
-- ============================================================

WITH
-- Step 1: Calculate per-subscription LTV
sub_ltv AS (
    SELECT
        fs.user_id,
        fs.plan_type,
        fs.plan_rank,
        fs.monthly_price,
        fs.status,
        fs.start_date,
        fs.end_date,
        CASE
            WHEN fs.end_date IS NOT NULL
            THEN DATEDIFF(fs.end_date, fs.start_date)
            ELSE DATEDIFF(@ref_date, fs.start_date)
        END AS active_days,
        CASE
            WHEN fs.end_date IS NOT NULL
            THEN ROUND(fs.monthly_price * DATEDIFF(fs.end_date, fs.start_date) / 30.44, 2)
            ELSE ROUND(fs.monthly_price * DATEDIFF(@ref_date, fs.start_date) / 30.44, 2)
        END AS ltv
    FROM fact_subscriptions fs
    WHERE fs.plan_type != 'free_trial'
),

-- Step 2: Aggregate per user (users may have multiple subs)
user_ltv AS (
    SELECT
        user_id,
        SUM(ltv)                AS total_ltv,
        SUM(active_days)        AS total_active_days,
        COUNT(*)                AS sub_count,
        MAX(plan_rank)          AS highest_plan
    FROM sub_ltv
    GROUP BY user_id
)

-- Step 3: Summary by plan type
SELECT
    sl.plan_type,
    COUNT(DISTINCT sl.user_id)                      AS subscribers,
    ROUND(AVG(sl.active_days), 0)                   AS avg_sub_days,
    ROUND(AVG(sl.ltv), 2)                           AS avg_ltv_per_sub,
    ROUND(AVG(ul.total_ltv), 2)                     AS avg_total_ltv_per_user,
    ROUND(SUM(sl.ltv), 2)                           AS total_revenue,
    ROUND(SUM(sl.ltv) / COUNT(DISTINCT sl.user_id), 2) AS revenue_per_subscriber,
    SUM(CASE WHEN sl.status = 'active' THEN 1 ELSE 0 END) AS still_active,
    ROUND(
        SUM(CASE WHEN sl.status = 'active' THEN 1 ELSE 0 END) * 100.0 /
        COUNT(*), 1
    ) AS retention_pct
FROM sub_ltv sl
INNER JOIN user_ltv ul ON sl.user_id = ul.user_id
GROUP BY sl.plan_type
ORDER BY avg_total_ltv_per_user DESC;


-- ============================================================
-- Q5: VIEWING PATTERNS BY TIME OF DAY AND DEVICE
--
-- Business Question:
--   "How do viewing patterns differ by time of day and device?
--    When and where are users watching?"
--
-- SQL Techniques:
--   - Pivot-style conditional aggregation
--   - CASE for time bucketing
--   - Cross-tabulation pattern
--   - ROUND for clean output
-- ============================================================

SELECT
    day_period,

    -- Pivot: count by device type
    SUM(CASE WHEN device_type = 'smart_tv' THEN 1 ELSE 0 END)  AS smart_tv,
    SUM(CASE WHEN device_type = 'mobile'   THEN 1 ELSE 0 END)  AS mobile,
    SUM(CASE WHEN device_type = 'tablet'   THEN 1 ELSE 0 END)  AS tablet,
    SUM(CASE WHEN device_type = 'desktop'  THEN 1 ELSE 0 END)  AS desktop,
    SUM(CASE WHEN device_type = 'console'  THEN 1 ELSE 0 END)  AS console,

    COUNT(*) AS total,

    -- Average session length per period
    ROUND(AVG(watch_duration_minutes), 1) AS avg_min,

    -- Completion rate per period
    ROUND(SUM(is_completed) * 100.0 / NULLIF(SUM(is_completed) + SUM(is_abandoned), 0), 1) AS completion_pct

FROM fact_viewing_events
GROUP BY day_period
ORDER BY FIELD(day_period, 'morning', 'afternoon', 'evening', 'night');


-- ============================================================
-- Q6: MONTHLY COHORT RETENTION ANALYSIS
--
-- Business Question:
--   "For users who signed up in each month, what percentage
--    are still active 1, 2, 3... months later?"
--
-- SQL Techniques:
--   - Self-referencing CTE pipeline
--   - Date truncation for cohort assignment
--   - TIMESTAMPDIFF for period calculation
--   - Conditional aggregation for retention triangle
--   - COUNT(DISTINCT) with CASE
-- ============================================================

WITH
-- Step 1: Assign each user to their signup cohort (month)
user_cohorts AS (
    SELECT
        du.user_id,
        DATE_FORMAT(du.signup_date, '%Y-%m') AS cohort_month
    FROM dim_users du
),

-- Step 2: Get each user's active months
user_active_months AS (
    SELECT DISTINCT
        fve.user_id,
        DATE_FORMAT(fve.event_timestamp, '%Y-%m') AS active_month
    FROM fact_viewing_events fve
    INNER JOIN dim_users du ON fve.user_id = du.user_id
),

-- Step 3: Calculate months since signup for each activity
cohort_activity AS (
    SELECT
        uc.cohort_month,
        uam.active_month,
        uc.user_id,
        TIMESTAMPDIFF(MONTH,
            CONCAT(uc.cohort_month, '-01'),
            CONCAT(uam.active_month, '-01')
        ) AS months_since_signup
    FROM user_cohorts uc
    INNER JOIN user_active_months uam ON uc.user_id = uam.user_id
),

-- Step 4: Count cohort size
cohort_sizes AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT user_id) AS cohort_size
    FROM user_cohorts
    GROUP BY cohort_month
)

-- Step 5: Build retention triangle (months 0-6)
SELECT
    ca.cohort_month,
    cs.cohort_size,
    COUNT(DISTINCT CASE WHEN ca.months_since_signup = 0 THEN ca.user_id END) AS m0,
    COUNT(DISTINCT CASE WHEN ca.months_since_signup = 1 THEN ca.user_id END) AS m1,
    COUNT(DISTINCT CASE WHEN ca.months_since_signup = 2 THEN ca.user_id END) AS m2,
    COUNT(DISTINCT CASE WHEN ca.months_since_signup = 3 THEN ca.user_id END) AS m3,
    COUNT(DISTINCT CASE WHEN ca.months_since_signup = 4 THEN ca.user_id END) AS m4,
    COUNT(DISTINCT CASE WHEN ca.months_since_signup = 5 THEN ca.user_id END) AS m5,
    COUNT(DISTINCT CASE WHEN ca.months_since_signup = 6 THEN ca.user_id END) AS m6,

    -- Retention percentage at month 3
    ROUND(
        COUNT(DISTINCT CASE WHEN ca.months_since_signup = 3 THEN ca.user_id END) * 100.0 /
        cs.cohort_size
    , 1) AS retention_m3_pct

FROM cohort_activity ca
INNER JOIN cohort_sizes cs ON ca.cohort_month = cs.cohort_month
WHERE ca.cohort_month BETWEEN '2023-01' AND '2025-06'
GROUP BY ca.cohort_month, cs.cohort_size
ORDER BY ca.cohort_month;


-- ============================================================
-- Q7: ORIGINAL CONTENT ROI LEADERBOARD
--
-- Business Question:
--   "Which original content has the best ROI? Are our
--    big-budget originals paying off in viewership?"
--
-- SQL Techniques:
--   - Multi-table JOIN
--   - Derived ROI metrics
--   - RANK() and DENSE_RANK() window functions
--   - HAVING for minimum threshold filtering
--   - CASE for conditional labeling
-- ============================================================

WITH content_roi AS (
    SELECT
        dc.title,
        dc.content_type,
        dc.genre,
        dc.duration_bucket,
        dc.production_cost_usd,
        dc.cost_tier,
        COUNT(*)                                    AS total_views,
        COUNT(DISTINCT fve.user_id)                 AS unique_viewers,
        SUM(fve.is_completed)                       AS completions,
        ROUND(SUM(fve.watch_duration_minutes), 0)   AS total_watch_min,
        ROUND(AVG(fve.watch_duration_minutes), 1)   AS avg_watch_min,

        -- ROI metrics
        ROUND(COUNT(*) / (dc.production_cost_usd / 1000000), 1)
            AS views_per_million,
        ROUND(SUM(fve.watch_duration_minutes) / (dc.production_cost_usd / 1000000), 0)
            AS minutes_per_million,

        -- Completion rate
        ROUND(
            SUM(fve.is_completed) * 100.0 /
            NULLIF(SUM(fve.is_completed) + SUM(fve.is_abandoned), 0)
        , 1) AS completion_pct

    FROM dim_content dc
    INNER JOIN fact_viewing_events fve ON dc.content_id = fve.content_id
    WHERE dc.is_original = 1
    GROUP BY dc.content_id, dc.title, dc.content_type, dc.genre,
             dc.duration_bucket, dc.production_cost_usd, dc.cost_tier
    HAVING COUNT(*) >= 10
)
SELECT
    RANK() OVER (ORDER BY views_per_million DESC) AS roi_rank,
    title,
    content_type,
    genre,
    cost_tier,
    CONCAT('$', FORMAT(production_cost_usd, 0)) AS budget,
    total_views,
    unique_viewers,
    total_watch_min,
    completion_pct,
    views_per_million,
    minutes_per_million,

    -- ROI verdict
    CASE
        WHEN views_per_million >= 500 THEN 'STRONG'
        WHEN views_per_million >= 200 THEN 'GOOD'
        WHEN views_per_million >= 100 THEN 'MODERATE'
        ELSE 'UNDERPERFORMING'
    END AS roi_verdict

FROM content_roi
ORDER BY roi_rank
LIMIT 20;
