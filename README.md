# StreamDW — Streaming Platform Data Warehouse

A scaled-down data warehouse modeled after a streaming platform (Netflix/Disney+), demonstrating the full lifecycle of analytical data engineering: raw data ingestion → transformation → reporting.

Built with **MySQL 8** and **Python**, following the **medallion architecture** pattern with star schema dimensional modeling.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  STAGING LAYER (Raw Data)                               │
│  raw_users · raw_subscriptions · raw_content            │
│  raw_viewing_events                                     │
│  ── Unmodified, append-only data from source systems    │
└──────────────────────────┬──────────────────────────────┘
                           │  ETL: clean, deduplicate, enrich
                           ▼
┌─────────────────────────────────────────────────────────┐
│  TRANSFORMATION LAYER (Star Schema)                     │
│  dim_date · dim_users · dim_content · dim_device        │
│  fact_viewing_events · fact_subscriptions                │
│  ── Validated dimensions + immutable fact tables         │
└──────────────────────────┬──────────────────────────────┘
                           │  Aggregate, rank, segment
                           ▼
┌─────────────────────────────────────────────────────────┐
│  REPORTING LAYER (Analytics)                            │
│  mart_user_engagement · mart_content_performance        │
│  mart_subscription_metrics · reusable views             │
│  ── Pre-aggregated marts for dashboards & ad-hoc SQL    │
└─────────────────────────────────────────────────────────┘
```

## Dataset

| Table | Rows | Description |
|-------|------|-------------|
| raw_users | 500 | User signups with intentional dirty data (duplicate emails, invalid birth years) |
| raw_subscriptions | 2,000 | Subscription lifecycle events (trials, upgrades, cancellations) |
| raw_content | 200 | Content catalog (movies, series, documentaries, shorts) |
| raw_viewing_events | 50,000 | Playback events with realistic patterns (evening-heavy, device distribution) |

All data is generated with Python's Faker library using a fixed seed for reproducibility.

## SQL Skills Demonstrated

| Skill | Where | Example |
|-------|-------|---------|
| **Window functions** | Queries Q1, Q2, Q6, Q7 | `ROW_NUMBER`, `RANK`, `LAG`, `PERCENT_RANK`, rolling `AVG OVER (ROWS BETWEEN)` |
| **CTEs** | All transformation + reporting | Multi-step pipelines, recursive date generation |
| **Complex JOINs** | Transformation layer | Multi-table enrichment, self-joins for session analysis |
| **Conditional aggregation** | Queries Q3, Q5 | `CASE` inside `SUM`/`COUNT` for pivot-style crosstabs |
| **Date/time functions** | Calendar dimension, Q6 | `DATEDIFF`, `TIMESTAMPDIFF`, `DATE_FORMAT`, cohort assignment |
| **Subqueries** | Dimension deduplication | Correlated subqueries, derived tables |
| **Star schema design** | Transformation layer | Fact/dimension tables following Kimball methodology |
| **Indexing** | All layers | Composite indexes, covering indexes for analytical patterns |
| **Views** | Reporting layer | `v_daily_active_users`, `v_content_leaderboard`, `v_churn_risk_summary` |
| **Data cleaning** | `dim_users` | Deduplication with `ROW_NUMBER`, birth year validation, region mapping |

## 7 Analytical Queries

Each query answers a real business question a streaming platform's data team would face:

| # | Business Question | Key Techniques |
|---|-------------------|---------------|
| Q1 | What is the 7-day and 30-day rolling average of daily active users? | Window functions, rolling averages |
| Q2 | Which users are at risk of churning, segmented by region? | Multi-CTE, `PERCENT_RANK`, `FIELD()` |
| Q3 | What is the content completion rate by genre and content type? | Conditional aggregation, `HAVING`, stickiness metric |
| Q4 | What is customer lifetime value by plan type? | Multi-CTE pipeline, `DATEDIFF`, LTV calculation |
| Q5 | How do viewing patterns differ by time of day and device? | Pivot-style `CASE`, cross-tabulation |
| Q6 | What is the monthly cohort retention rate? | `TIMESTAMPDIFF`, retention triangle, cohort analysis |
| Q7 | Which original content has the best ROI? | `RANK()`, derived ROI metrics, cost-tier analysis |

## Project Structure

```
StreamDW/
├── README.md
├── schema/
│   ├── 01_staging.sql          # Raw table DDL + constraints
│   ├── 02_dimensions.sql       # Dimension tables + ETL logic
│   ├── 03_facts.sql            # Fact tables + enrichment
│   └── 04_reporting.sql        # Data marts + views
├── queries/
│   └── analysis_queries.sql    # 7 showcase analytical queries
├── data/
│   └── generate_data.py        # Faker-based data generator
└── docs/
    └── project_plan.docx       # Full project specification
```

## Quick Start

**Prerequisites:** MySQL 8.0+, Python 3.9+, pip

```bash
# 1. Clone
git clone https://github.com/evasafi/StreamDW.git
cd StreamDW

# 2. Install Python dependencies
pip install faker mysql-connector-python

# 3. Create database (in MySQL console)
# CREATE DATABASE stream_dw CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

# 4. Generate and load sample data
python data/generate_data.py

# 5. Build the warehouse (run in order in MySQL console)
# SOURCE schema/01_staging.sql;
# SOURCE schema/02_dimensions.sql;
# SOURCE schema/03_facts.sql;
# SOURCE schema/04_reporting.sql;

# 6. Run analytical queries
# SOURCE queries/analysis_queries.sql;
```

The entire warehouse builds from scratch in under 2 minutes.

## Key Insights from the Data

Some findings from the analytical queries:

- **Evening dominates viewing** — 58% of all events happen between 6-10 PM, split evenly between smart TVs and mobile
- **Mid-budget originals win on ROI** — Content in the $500K-$700K range delivers 3-5x better views-per-dollar than $10M+ productions
- **Premium subscribers retain best** — 50.6% still active vs 43.5% for standard, with highest LTV at $358/user
- **Churn is predictable** — Users who go 14+ days inactive watch 75% fewer titles on average; low-risk users watch 5x more content

## Tech Stack

- **Database:** MySQL 8.0 (InnoDB)
- **Data Generation:** Python 3, Faker
- **Methodology:** Kimball dimensional modeling, medallion architecture
- **Version Control:** Git + GitHub

## Future: Phase 2 — Data Science Integration

This warehouse is designed to extend into ML/data science:

- **Churn prediction:** Use `mart_user_engagement` features for classification models
- **Time series forecasting:** Apply SARIMA/Prophet to DAU trends from `v_daily_active_users`
- **Content recommendations:** Build collaborative filtering from `fact_viewing_events`
- **Jupyter integration:** Python reads from MySQL, runs analysis, writes results back

---

Built by [Eva Safi](https://github.com/evasafi) as a SQL portfolio project demonstrating data warehouse design, ETL patterns, and advanced analytical queries.
