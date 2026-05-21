-- ============================================================
-- StreamDW: Transformation Layer — Dimension Tables
-- File: schema/02_dimensions.sql
--
-- Transforms raw staging data into clean, enriched dimensions.
-- Follows star schema design (Kimball methodology).
--
-- SQL Skills Demonstrated:
--   - CTEs (WITH clauses)
--   - CASE expressions for data bucketing
--   - Window functions (ROW_NUMBER for deduplication)
--   - Date/time functions
--   - Recursive CTE for calendar generation
--   - JOINs for enrichment
--   - Data cleaning patterns (NULL handling, validation)
-- ============================================================

USE stream_dw;


-- ============================================================
-- 1. DIM_DATE — Calendar Dimension
-- 
-- Pre-generated calendar table spanning 2020-2027.
-- Eliminates repeated EXTRACT() and DATE_FORMAT() calls
-- in analytical queries.
--
-- Technique: Recursive CTE to generate date series
-- ============================================================

DROP TABLE IF EXISTS dim_date;

CREATE TABLE dim_date (
    date_key        INT             NOT NULL    COMMENT 'Surrogate key: YYYYMMDD format',
    full_date       DATE            NOT NULL,
    day_of_week     TINYINT         NOT NULL    COMMENT '1=Sunday, 7=Saturday',
    day_name        VARCHAR(10)     NOT NULL,
    day_of_month    TINYINT         NOT NULL,
    day_of_year     SMALLINT        NOT NULL,
    week_of_year    TINYINT         NOT NULL,
    month_number    TINYINT         NOT NULL,
    month_name      VARCHAR(10)     NOT NULL,
    quarter         TINYINT         NOT NULL,
    year            SMALLINT        NOT NULL,
    is_weekend      BOOLEAN         NOT NULL,
    is_month_start  BOOLEAN         NOT NULL,
    is_month_end    BOOLEAN         NOT NULL,
    year_month      VARCHAR(7)      NOT NULL    COMMENT 'YYYY-MM for easy grouping',

    PRIMARY KEY (date_key),
    UNIQUE INDEX idx_dim_date_full (full_date),
    INDEX idx_dim_date_year_month (year, month_number),
    INDEX idx_dim_date_ym (year_month)
) ENGINE=InnoDB
  COMMENT='Calendar dimension table. One row per day, 2020-2027.';

-- Allow the recursive CTE to process all 2922 days
SET @@cte_max_recursion_depth = 5000;

-- Populate using recursive CTE
INSERT INTO dim_date
WITH RECURSIVE date_series AS (
    -- Anchor: start date
    SELECT DATE('2020-01-01') AS d
    UNION ALL
    -- Recursive: add one day until end date
    SELECT DATE_ADD(d, INTERVAL 1 DAY)
    FROM date_series
    WHERE d < '2027-12-31'
)
SELECT
    -- Surrogate key: YYYYMMDD as integer
    CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED)          AS date_key,
    d                                                     AS full_date,
    DAYOFWEEK(d)                                          AS day_of_week,
    DAYNAME(d)                                            AS day_name,
    DAY(d)                                                AS day_of_month,
    DAYOFYEAR(d)                                          AS day_of_year,
    WEEK(d, 1)                                            AS week_of_year,
    MONTH(d)                                              AS month_number,
    MONTHNAME(d)                                          AS month_name,
    QUARTER(d)                                            AS quarter,
    YEAR(d)                                               AS year,
    CASE WHEN DAYOFWEEK(d) IN (1, 7) THEN TRUE ELSE FALSE END AS is_weekend,
    CASE WHEN DAY(d) = 1 THEN TRUE ELSE FALSE END        AS is_month_start,
    CASE WHEN d = LAST_DAY(d) THEN TRUE ELSE FALSE END   AS is_month_end,
    DATE_FORMAT(d, '%Y-%m')                               AS year_month
FROM date_series;



-- ============================================================
-- 2. DIM_DEVICE — Device Dimension
--
-- Simple lookup table for device types.
-- Keeps the star schema clean by giving devices a surrogate key.
-- ============================================================

DROP TABLE IF EXISTS dim_device;

CREATE TABLE dim_device (
    device_key      TINYINT         NOT NULL AUTO_INCREMENT,
    device_type     VARCHAR(30)     NOT NULL,
    device_category VARCHAR(20)     NOT NULL    COMMENT 'mobile, living_room, desktop',

    PRIMARY KEY (device_key),
    UNIQUE INDEX idx_dim_device_type (device_type)
) ENGINE=InnoDB
  COMMENT='Device dimension. Maps device types to broader categories.';

INSERT INTO dim_device (device_type, device_category) VALUES
    ('smart_tv',  'living_room'),
    ('mobile',    'mobile'),
    ('tablet',    'mobile'),
    ('desktop',   'desktop'),
    ('console',   'living_room');


-- ============================================================
-- 3. DIM_USERS — User Dimension (Cleaned & Enriched)
--
-- Cleans raw user data:
--   - Deduplicates by email (keeps earliest signup)
--   - Validates birth_year (removes outliers)
--   - Derives age_group and region
--   - Joins latest subscription info
--
-- Techniques: CTE, ROW_NUMBER, CASE, LEFT JOIN, subquery
-- ============================================================

DROP TABLE IF EXISTS dim_users;

CREATE TABLE dim_users (
    user_key            INT             NOT NULL AUTO_INCREMENT,
    user_id             VARCHAR(36)     NOT NULL    COMMENT 'Natural key from source',
    email               VARCHAR(255)    NOT NULL,
    username            VARCHAR(100)    NOT NULL,
    country             VARCHAR(3)      NULL,
    signup_date         DATE            NOT NULL,
    signup_date_key     INT             NOT NULL    COMMENT 'FK to dim_date',
    birth_year          INT             NULL        COMMENT 'Cleaned: NULL if invalid',
    age_group           VARCHAR(20)     NULL        COMMENT 'Derived from birth_year',
    region              VARCHAR(30)     NOT NULL    COMMENT 'Derived from country code',
    days_since_signup   INT             NOT NULL    COMMENT 'As of ETL run date',
    current_plan_type   VARCHAR(20)     NULL        COMMENT 'From latest subscription',
    current_plan_status VARCHAR(20)     NULL        COMMENT 'From latest subscription',

    PRIMARY KEY (user_key),
    UNIQUE INDEX idx_dim_users_id (user_id),
    INDEX idx_dim_users_signup (signup_date_key),
    INDEX idx_dim_users_region (region),
    INDEX idx_dim_users_age (age_group),
    INDEX idx_dim_users_plan (current_plan_type)
) ENGINE=InnoDB
  COMMENT='Cleaned user dimension. Deduplicated, validated, enriched.';


-- Populate with CTE pipeline
INSERT INTO dim_users (
    user_id, email, username, country, signup_date, signup_date_key,
    birth_year, age_group, region, days_since_signup,
    current_plan_type, current_plan_status
)
WITH
-- Step 1: Deduplicate by email, keeping the earliest signup
deduplicated_users AS (
    SELECT
        user_id,
        email,
        username,
        country,
        signup_date,
        birth_year,
        ROW_NUMBER() OVER (
            PARTITION BY email
            ORDER BY signup_date ASC
        ) AS rn
    FROM raw_users
),

-- Step 2: Get each user's latest subscription
latest_subscriptions AS (
    SELECT
        user_id,
        plan_type,
        status,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY start_date DESC, subscription_id DESC
        ) AS rn
    FROM raw_subscriptions
),

-- Step 3: Clean and enrich
cleaned_users AS (
    SELECT
        du.user_id,
        du.email,
        du.username,
        du.country,
        DATE(du.signup_date)    AS signup_date,

        -- Clean birth_year: NULL if outside reasonable range
        CASE
            WHEN du.birth_year BETWEEN 1930 AND 2010 THEN du.birth_year
            ELSE NULL
        END AS clean_birth_year,

        -- Derive age group from cleaned birth_year
        CASE
            WHEN du.birth_year BETWEEN 1930 AND 1964 THEN '60+'
            WHEN du.birth_year BETWEEN 1965 AND 1980 THEN '45-59'
            WHEN du.birth_year BETWEEN 1981 AND 1996 THEN '28-44'
            WHEN du.birth_year BETWEEN 1997 AND 2005 THEN '18-27'
            WHEN du.birth_year BETWEEN 2006 AND 2010 THEN 'Under 18'
            ELSE 'Unknown'
        END AS age_group,

        -- Map country codes to regions
        CASE
            WHEN du.country IN ('USA', 'CAN', 'MEX') THEN 'North America'
            WHEN du.country IN ('GBR', 'DEU', 'FRA', 'ITA', 'ESP', 'NLD', 'SWE', 'NOR', 'POL')
                THEN 'Europe'
            WHEN du.country IN ('BRA', 'ARG', 'COL') THEN 'South America'
            WHEN du.country IN ('JPN', 'KOR', 'IDN', 'THA', 'IND') THEN 'Asia Pacific'
            WHEN du.country IN ('TUR', 'EGY', 'SAU') THEN 'Middle East'
            WHEN du.country IN ('AUS') THEN 'Oceania'
            ELSE 'Other'
        END AS region,

        -- Days since signup (relative to now)
        DATEDIFF(CURDATE(), DATE(du.signup_date)) AS days_since_signup,

        -- Latest subscription info
        ls.plan_type    AS current_plan_type,
        ls.status       AS current_plan_status

    FROM deduplicated_users du
    LEFT JOIN latest_subscriptions ls
        ON du.user_id = ls.user_id AND ls.rn = 1
    WHERE du.rn = 1   -- keep only first occurrence per email
)

SELECT
    cu.user_id,
    cu.email,
    cu.username,
    cu.country,
    cu.signup_date,
    CAST(DATE_FORMAT(cu.signup_date, '%Y%m%d') AS UNSIGNED) AS signup_date_key,
    cu.clean_birth_year,
    cu.age_group,
    cu.region,
    cu.days_since_signup,
    cu.current_plan_type,
    cu.current_plan_status
FROM cleaned_users cu;


-- ============================================================
-- 4. DIM_CONTENT — Content Dimension (Enriched)
--
-- Adds derived categorizations:
--   - duration_bucket (short/medium/long/feature)
--   - cost_tier (low/medium/high/premium)
--   - decade (from release_year)
--
-- Techniques: CASE expressions, computed categories
-- ============================================================

DROP TABLE IF EXISTS dim_content;

CREATE TABLE dim_content (
    content_key         INT             NOT NULL AUTO_INCREMENT,
    content_id          VARCHAR(36)     NOT NULL    COMMENT 'Natural key from source',
    title               VARCHAR(255)    NOT NULL,
    content_type        VARCHAR(20)     NOT NULL,
    genre               VARCHAR(50)     NOT NULL,
    release_year        INT             NOT NULL,
    decade              VARCHAR(5)      NOT NULL    COMMENT 'e.g., 2020s',
    duration_minutes    INT             NOT NULL,
    duration_bucket     VARCHAR(20)     NOT NULL    COMMENT 'short/medium/long/feature',
    rating              VARCHAR(10)     NULL,
    is_original         BOOLEAN         NOT NULL,
    production_cost_usd DECIMAL(12,2)   NULL,
    cost_tier           VARCHAR(20)     NULL        COMMENT 'low/medium/high/premium',

    PRIMARY KEY (content_key),
    UNIQUE INDEX idx_dim_content_id (content_id),
    INDEX idx_dim_content_type (content_type),
    INDEX idx_dim_content_genre (genre),
    INDEX idx_dim_content_decade (decade),
    INDEX idx_dim_content_bucket (duration_bucket),
    INDEX idx_dim_content_tier (cost_tier),
    INDEX idx_dim_content_original (is_original)
) ENGINE=InnoDB
  COMMENT='Enriched content dimension with derived categories.';


INSERT INTO dim_content (
    content_id, title, content_type, genre, release_year, decade,
    duration_minutes, duration_bucket, rating, is_original,
    production_cost_usd, cost_tier
)
SELECT
    content_id,
    title,
    content_type,
    genre,
    release_year,

    -- Derive decade label
    CONCAT(FLOOR(release_year / 10) * 10, 's') AS decade,

    duration_minutes,

    -- Categorize by duration
    CASE
        WHEN duration_minutes <= 15  THEN 'short'
        WHEN duration_minutes <= 45  THEN 'medium'
        WHEN duration_minutes <= 90  THEN 'long'
        ELSE 'feature'
    END AS duration_bucket,

    rating,
    is_original,
    production_cost_usd,

    -- Categorize by production cost
    CASE
        WHEN production_cost_usd IS NULL        THEN NULL
        WHEN production_cost_usd < 100000       THEN 'low'
        WHEN production_cost_usd < 1000000      THEN 'medium'
        WHEN production_cost_usd < 10000000     THEN 'high'
        ELSE 'premium'
    END AS cost_tier

FROM raw_content;


-- ============================================================
-- VERIFICATION
-- ============================================================

SELECT '--- DIMENSION TABLES LOADED ---' AS status;

SELECT 'dim_date' AS table_name, COUNT(*) AS row_count FROM dim_date
UNION ALL
SELECT 'dim_device', COUNT(*) FROM dim_device
UNION ALL
SELECT 'dim_users', COUNT(*) FROM dim_users
UNION ALL
SELECT 'dim_content', COUNT(*) FROM dim_content;

-- Quick data quality check
SELECT '--- DATA QUALITY CHECKS ---' AS status;

-- Check age group distribution
SELECT age_group, COUNT(*) AS user_count
FROM dim_users
GROUP BY age_group
ORDER BY user_count DESC;

-- Check region distribution
SELECT region, COUNT(*) AS user_count
FROM dim_users
GROUP BY region
ORDER BY user_count DESC;

-- Check content distribution
SELECT content_type, duration_bucket, COUNT(*) AS content_count
FROM dim_content
GROUP BY content_type, duration_bucket
ORDER BY content_type, duration_bucket;

-- Check cost tier distribution
SELECT cost_tier, COUNT(*) AS content_count
FROM dim_content
WHERE cost_tier IS NOT NULL
GROUP BY cost_tier
ORDER BY content_count DESC;
