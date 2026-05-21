-- ============================================================
-- StreamDW: Staging Layer (Raw Data)
-- File: schema/01_staging.sql
-- 
-- These tables hold unmodified data from source systems.
-- Rules:
--   - Never transform data in place
--   - Append-only (no UPDATEs)
--   - loaded_at tracks when each row was ingested
-- ============================================================

CREATE DATABASE IF NOT EXISTS stream_dw
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE stream_dw;

-- ============================================================
-- 1. RAW_USERS
-- Source: Signup/registration system
-- Notes: May contain duplicate emails, invalid birth years
-- ============================================================

DROP TABLE IF EXISTS raw_viewing_events;
DROP TABLE IF EXISTS raw_subscriptions;
DROP TABLE IF EXISTS raw_content;
DROP TABLE IF EXISTS raw_users;

CREATE TABLE raw_users (
    user_id         VARCHAR(36)     NOT NULL,
    email           VARCHAR(255)    NOT NULL,
    username        VARCHAR(100)    NOT NULL,
    country         VARCHAR(3)      NULL        COMMENT 'ISO 3166-1 alpha-3 country code',
    signup_date     DATETIME        NOT NULL,
    birth_year      INT             NULL        COMMENT 'May contain invalid values like 1800 or 2030',
    loaded_at       TIMESTAMP       NOT NULL    DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (user_id),
    INDEX idx_raw_users_email (email),
    INDEX idx_raw_users_signup (signup_date),
    INDEX idx_raw_users_country (country)
) ENGINE=InnoDB
  COMMENT='Raw user data from signup system. May contain duplicates and bad values.';


-- ============================================================
-- 2. RAW_SUBSCRIPTIONS
-- Source: Billing/payment system
-- Notes: One user can have multiple subscription records
--        (upgrades, cancellations, reactivations)
-- ============================================================

CREATE TABLE raw_subscriptions (
    subscription_id VARCHAR(36)     NOT NULL,
    user_id         VARCHAR(36)     NOT NULL,
    plan_type       VARCHAR(20)     NOT NULL    COMMENT 'free_trial, basic, standard, premium',
    status          VARCHAR(20)     NOT NULL    COMMENT 'active, cancelled, expired, paused',
    start_date      DATE            NOT NULL,
    end_date        DATE            NULL        COMMENT 'NULL if subscription is currently active',
    monthly_price   DECIMAL(6,2)    NOT NULL    COMMENT 'Price in USD at time of record',
    loaded_at       TIMESTAMP       NOT NULL    DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (subscription_id),
    INDEX idx_raw_subs_user (user_id),
    INDEX idx_raw_subs_status (status),
    INDEX idx_raw_subs_dates (start_date, end_date),

    CONSTRAINT fk_raw_subs_user
        FOREIGN KEY (user_id) REFERENCES raw_users(user_id)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB
  COMMENT='Raw subscription records from billing system. One user may have many records.';


-- ============================================================
-- 3. RAW_CONTENT
-- Source: Content Management System (CMS)
-- Notes: Catalog of all available movies, series, docs, shorts
-- ============================================================

CREATE TABLE raw_content (
    content_id          VARCHAR(36)     NOT NULL,
    title               VARCHAR(255)    NOT NULL,
    content_type        VARCHAR(20)     NOT NULL    COMMENT 'movie, series, documentary, short',
    genre               VARCHAR(50)     NOT NULL    COMMENT 'Primary genre',
    release_year        INT             NOT NULL,
    duration_minutes    INT             NOT NULL    COMMENT 'Runtime in minutes (for series: avg episode length)',
    rating              VARCHAR(10)     NULL        COMMENT 'PG, PG-13, R, TV-MA, etc.',
    is_original         BOOLEAN         NOT NULL    DEFAULT FALSE COMMENT 'TRUE if platform-produced content',
    production_cost_usd DECIMAL(12,2)   NULL        COMMENT 'Estimated production or licensing cost',
    loaded_at           TIMESTAMP       NOT NULL    DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (content_id),
    INDEX idx_raw_content_type (content_type),
    INDEX idx_raw_content_genre (genre),
    INDEX idx_raw_content_year (release_year),
    INDEX idx_raw_content_original (is_original)
) ENGINE=InnoDB
  COMMENT='Raw content catalog from CMS. All titles currently on the platform.';


-- ============================================================
-- 4. RAW_VIEWING_EVENTS
-- Source: Video player / streaming backend
-- Notes: High-volume event log. One viewing session can
--        generate multiple events (play, pause, resume, etc.)
-- ============================================================

CREATE TABLE raw_viewing_events (
    event_id            VARCHAR(36)     NOT NULL,
    user_id             VARCHAR(36)     NOT NULL,
    content_id          VARCHAR(36)     NOT NULL,
    event_type          VARCHAR(20)     NOT NULL    COMMENT 'play, pause, resume, complete, abandon',
    device_type         VARCHAR(30)     NOT NULL    COMMENT 'smart_tv, mobile, tablet, desktop, console',
    watch_duration_sec  INT             NOT NULL    DEFAULT 0 COMMENT 'Seconds watched in this event',
    event_timestamp     DATETIME        NOT NULL,
    loaded_at           TIMESTAMP       NOT NULL    DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (event_id),
    INDEX idx_raw_events_user (user_id),
    INDEX idx_raw_events_content (content_id),
    INDEX idx_raw_events_type (event_type),
    INDEX idx_raw_events_timestamp (event_timestamp),
    INDEX idx_raw_events_device (device_type),

    -- Composite index for common analytical queries
    INDEX idx_raw_events_user_time (user_id, event_timestamp),
    INDEX idx_raw_events_content_type (content_id, event_type),

    CONSTRAINT fk_raw_events_user
        FOREIGN KEY (user_id) REFERENCES raw_users(user_id)
        ON DELETE CASCADE ON UPDATE CASCADE,

    CONSTRAINT fk_raw_events_content
        FOREIGN KEY (content_id) REFERENCES raw_content(content_id)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB
  COMMENT='Raw viewing events from streaming backend. High-volume append-only log.';


-- ============================================================
-- VERIFICATION
-- ============================================================

SELECT 
    TABLE_NAME,
    TABLE_COMMENT
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'stream_dw'
ORDER BY TABLE_NAME;
