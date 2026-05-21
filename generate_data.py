"""
StreamDW: Sample Data Generator
File: data/generate_data.py

Generates realistic sample data for the streaming platform data warehouse.
Inserts directly into MySQL and also saves CSVs as backup.

Usage:
    python data/generate_data.py

Requirements:
    pip install faker mysql-connector-python
"""

import os
import csv
import uuid
import random
from datetime import datetime, timedelta
from faker import Faker

import mysql.connector

# ============================================================
# CONFIGURATION
# ============================================================

DB_CONFIG = {
    "host": "localhost",
    "user": "root",
    "password": "",           # WampServer default = empty
    "database": "stream_dw",
}

# Data volumes (small but complete)
NUM_USERS = 500
NUM_CONTENT = 200
NUM_SUBSCRIPTIONS = 2000      # multiple per user (upgrades, cancellations)
NUM_VIEWING_EVENTS = 50000

# Date range for the data
DATE_START = datetime(2023, 1, 1)
DATE_END = datetime(2025, 12, 31)

# Seed for reproducibility
SEED = 42
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

# ============================================================
# HELPER DATA
# ============================================================

COUNTRIES = [
    "USA", "GBR", "CAN", "DEU", "FRA", "BRA", "JPN", "AUS",
    "IND", "TUR", "MEX", "KOR", "ITA", "ESP", "NLD", "SWE",
    "NOR", "POL", "ARG", "COL", "EGY", "SAU", "IDN", "THA",
]

PLAN_TYPES = ["free_trial", "basic", "standard", "premium"]
PLAN_PRICES = {
    "free_trial": 0.00,
    "basic": 7.99,
    "standard": 13.99,
    "premium": 19.99,
}

SUB_STATUSES = ["active", "cancelled", "expired", "paused"]

CONTENT_TYPES = ["movie", "series", "documentary", "short"]
GENRES = [
    "Action", "Comedy", "Drama", "Horror", "Sci-Fi", "Romance",
    "Thriller", "Documentary", "Animation", "Fantasy", "Crime",
    "Mystery", "Adventure", "Family", "Music",
]

RATINGS = ["G", "PG", "PG-13", "R", "TV-MA", "TV-14", "TV-PG"]

DEVICE_TYPES = ["smart_tv", "mobile", "tablet", "desktop", "console"]
EVENT_TYPES = ["play", "pause", "resume", "complete", "abandon"]

# Content title templates for realism
TITLE_ADJECTIVES = [
    "Dark", "Lost", "Silent", "Burning", "Frozen", "Hidden",
    "Golden", "Broken", "Wild", "Crimson", "Midnight", "Electric",
    "Savage", "Eternal", "Sacred", "Hollow", "Twisted", "Shattered",
    "Fading", "Rising", "Distant", "Neon", "Velvet", "Iron",
]
TITLE_NOUNS = [
    "Kingdom", "Signal", "Waters", "Forest", "Legacy", "Protocol",
    "Horizon", "Echoes", "Shadows", "Circuit", "Requiem", "Empire",
    "Passage", "Frontier", "Chronicle", "Harbor", "Junction", "Cipher",
    "Vanguard", "Asylum", "Dominion", "Paradox", "Odyssey", "Verdict",
]


def generate_title():
    """Generate a realistic-sounding content title."""
    pattern = random.choice(["adj_noun", "the_adj_noun", "noun_of_noun", "single"])
    if pattern == "adj_noun":
        return f"{random.choice(TITLE_ADJECTIVES)} {random.choice(TITLE_NOUNS)}"
    elif pattern == "the_adj_noun":
        return f"The {random.choice(TITLE_ADJECTIVES)} {random.choice(TITLE_NOUNS)}"
    elif pattern == "noun_of_noun":
        return f"{random.choice(TITLE_NOUNS)} of {random.choice(TITLE_NOUNS)}"
    else:
        return random.choice(TITLE_NOUNS)


def random_date(start, end):
    """Generate a random datetime between start and end."""
    delta = end - start
    random_days = random.randint(0, delta.days)
    random_seconds = random.randint(0, 86399)
    return start + timedelta(days=random_days, seconds=random_seconds)


# ============================================================
# DATA GENERATORS
# ============================================================

def generate_users():
    """Generate raw user records."""
    print(f"  Generating {NUM_USERS} users...")
    users = []
    used_emails = set()

    for _ in range(NUM_USERS):
        user_id = str(uuid.uuid4())
        email = fake.email()

        # Intentionally allow ~3% duplicate emails (dirty data)
        if random.random() < 0.03 and used_emails:
            email = random.choice(list(used_emails))
        used_emails.add(email)

        username = fake.user_name()
        country = random.choice(COUNTRIES)
        signup_date = random_date(DATE_START, DATE_END)

        # birth_year: mostly valid, but ~5% are bad values
        if random.random() < 0.05:
            birth_year = random.choice([1800, 2030, 0, None, 1900])
        else:
            birth_year = random.randint(1960, 2005)

        users.append((user_id, email, username, country, signup_date, birth_year))

    return users


def generate_content():
    """Generate raw content catalog."""
    print(f"  Generating {NUM_CONTENT} content items...")
    content = []
    used_titles = set()

    for _ in range(NUM_CONTENT):
        content_id = str(uuid.uuid4())

        # Ensure unique titles
        title = generate_title()
        while title in used_titles:
            title = generate_title()
        used_titles.add(title)

        content_type = random.choice(CONTENT_TYPES)
        genre = random.choice(GENRES)
        release_year = random.randint(2015, 2025)

        # Duration depends on content type
        if content_type == "movie":
            duration = random.randint(80, 180)
        elif content_type == "series":
            duration = random.randint(25, 60)     # avg episode length
        elif content_type == "documentary":
            duration = random.randint(45, 120)
        else:  # short
            duration = random.randint(5, 25)

        rating = random.choice(RATINGS)
        is_original = random.random() < 0.30      # 30% are originals

        # Production cost: originals cost more
        if is_original:
            cost = round(random.uniform(500_000, 50_000_000), 2)
        else:
            cost = round(random.uniform(10_000, 2_000_000), 2)

        content.append((
            content_id, title, content_type, genre, release_year,
            duration, rating, is_original, cost
        ))

    return content


def generate_subscriptions(users):
    """Generate raw subscription records."""
    print(f"  Generating {NUM_SUBSCRIPTIONS} subscriptions...")
    subs = []
    user_ids = [u[0] for u in users]
    user_signups = {u[0]: u[4] for u in users}   # user_id -> signup_date

    for _ in range(NUM_SUBSCRIPTIONS):
        sub_id = str(uuid.uuid4())
        user_id = random.choice(user_ids)

        plan_type = random.choices(
            PLAN_TYPES,
            weights=[15, 35, 35, 15],   # most are basic/standard
            k=1
        )[0]

        # Start date: after user signup
        signup = user_signups[user_id]
        start_date = random_date(signup, DATE_END).date()

        # Status distribution
        status = random.choices(
            SUB_STATUSES,
            weights=[45, 25, 20, 10],   # 45% active
            k=1
        )[0]

        # End date: only if not active
        if status == "active":
            end_date = None
        else:
            days_active = random.randint(14, 365)
            end_date = start_date + timedelta(days=days_active)
            if end_date > DATE_END.date():
                end_date = DATE_END.date()

        price = PLAN_PRICES[plan_type]

        subs.append((sub_id, user_id, plan_type, status, start_date, end_date, price))

    return subs


def generate_viewing_events(users, content):
    """Generate raw viewing event records."""
    print(f"  Generating {NUM_VIEWING_EVENTS} viewing events...")
    events = []
    user_ids = [u[0] for u in users]
    content_data = [(c[0], c[5]) for c in content]   # (content_id, duration_minutes)

    # Some users are heavy watchers, some are light
    heavy_users = random.sample(user_ids, k=int(NUM_USERS * 0.2))

    for _ in range(NUM_VIEWING_EVENTS):
        event_id = str(uuid.uuid4())

        # 60% of events come from heavy users (20% of users)
        if random.random() < 0.6:
            user_id = random.choice(heavy_users)
        else:
            user_id = random.choice(user_ids)

        # Content selection: some content is more popular
        content_id, content_duration = random.choice(content_data)

        # Event type distribution
        event_type = random.choices(
            EVENT_TYPES,
            weights=[40, 15, 15, 20, 10],   # 40% play, 20% complete
            k=1
        )[0]

        device_type = random.choices(
            DEVICE_TYPES,
            weights=[30, 30, 15, 15, 10],   # TV and mobile dominant
            k=1
        )[0]

        # Watch duration depends on event type
        max_seconds = content_duration * 60
        if event_type == "complete":
            watch_sec = max_seconds
        elif event_type == "abandon":
            watch_sec = random.randint(30, int(max_seconds * 0.3))
        elif event_type == "play":
            watch_sec = random.randint(60, int(max_seconds * 0.8))
        else:   # pause, resume
            watch_sec = random.randint(10, int(max_seconds * 0.5))

        watch_sec = max(watch_sec, 1)   # ensure positive

        # Timestamp with realistic viewing patterns
        event_ts = random_date(DATE_START, DATE_END)

        # Skew toward evening hours (more realistic)
        hour = event_ts.hour
        if random.random() < 0.6:
            # Push toward 18:00-23:59
            new_hour = random.randint(18, 23)
            event_ts = event_ts.replace(hour=new_hour)

        events.append((
            event_id, user_id, content_id, event_type,
            device_type, watch_sec, event_ts
        ))

    return events


# ============================================================
# DATABASE INSERT
# ============================================================

def insert_data(conn, users, content, subscriptions, events):
    """Insert all generated data into MySQL."""
    cursor = conn.cursor()

    print("\n[Inserting into MySQL]")

    # Users
    print("  Inserting users...")
    cursor.executemany(
        """INSERT INTO raw_users 
           (user_id, email, username, country, signup_date, birth_year)
           VALUES (%s, %s, %s, %s, %s, %s)""",
        users
    )
    conn.commit()
    print(f"    ✓ {cursor.rowcount} users inserted")

    # Content
    print("  Inserting content...")
    cursor.executemany(
        """INSERT INTO raw_content 
           (content_id, title, content_type, genre, release_year,
            duration_minutes, rating, is_original, production_cost_usd)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)""",
        content
    )
    conn.commit()
    print(f"    ✓ {cursor.rowcount} content items inserted")

    # Subscriptions
    print("  Inserting subscriptions...")
    cursor.executemany(
        """INSERT INTO raw_subscriptions 
           (subscription_id, user_id, plan_type, status, 
            start_date, end_date, monthly_price)
           VALUES (%s, %s, %s, %s, %s, %s, %s)""",
        subscriptions
    )
    conn.commit()
    print(f"    ✓ {cursor.rowcount} subscriptions inserted")

    # Viewing events (batch insert for performance)
    print("  Inserting viewing events (this may take a moment)...")
    BATCH_SIZE = 5000
    for i in range(0, len(events), BATCH_SIZE):
        batch = events[i:i + BATCH_SIZE]
        cursor.executemany(
            """INSERT INTO raw_viewing_events 
               (event_id, user_id, content_id, event_type,
                device_type, watch_duration_sec, event_timestamp)
               VALUES (%s, %s, %s, %s, %s, %s, %s)""",
            batch
        )
        conn.commit()
        print(f"    ... {min(i + BATCH_SIZE, len(events)):,}/{len(events):,}")

    print(f"    ✓ {len(events):,} viewing events inserted")
    cursor.close()


# ============================================================
# CSV BACKUP
# ============================================================

def save_csvs(users, content, subscriptions, events):
    """Save generated data as CSV files for portability."""
    csv_dir = os.path.join(os.path.dirname(__file__), "csv")
    os.makedirs(csv_dir, exist_ok=True)

    print("\n[Saving CSV backups]")

    with open(os.path.join(csv_dir, "raw_users.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["user_id", "email", "username", "country", "signup_date", "birth_year"])
        w.writerows(users)
    print(f"  ✓ csv/raw_users.csv")

    with open(os.path.join(csv_dir, "raw_content.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["content_id", "title", "content_type", "genre", "release_year",
                     "duration_minutes", "rating", "is_original", "production_cost_usd"])
        w.writerows(content)
    print(f"  ✓ csv/raw_content.csv")

    with open(os.path.join(csv_dir, "raw_subscriptions.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["subscription_id", "user_id", "plan_type", "status",
                     "start_date", "end_date", "monthly_price"])
        w.writerows(subscriptions)
    print(f"  ✓ csv/raw_subscriptions.csv")

    with open(os.path.join(csv_dir, "raw_viewing_events.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["event_id", "user_id", "content_id", "event_type",
                     "device_type", "watch_duration_sec", "event_timestamp"])
        w.writerows(events)
    print(f"  ✓ csv/raw_viewing_events.csv")


# ============================================================
# MAIN
# ============================================================

def main():
    print("=" * 60)
    print("  StreamDW — Sample Data Generator")
    print("=" * 60)

    # Generate data
    print("\n[Generating data]")
    users = generate_users()
    content = generate_content()
    subscriptions = generate_subscriptions(users)
    events = generate_viewing_events(users, content)

    # Connect to MySQL
    print("\n[Connecting to MySQL]")
    try:
        conn = mysql.connector.connect(**DB_CONFIG)
        print(f"  ✓ Connected to {DB_CONFIG['database']}")
    except mysql.connector.Error as err:
        print(f"  ✗ Connection failed: {err}")
        print("  Check DB_CONFIG at the top of this script.")
        print("  Make sure WampServer is running and stream_dw database exists.")
        return

    # Insert into MySQL
    insert_data(conn, users, content, subscriptions, events)

    # Save CSV backups
    save_csvs(users, content, subscriptions, events)

    # Summary
    print("\n" + "=" * 60)
    print("  ✓ DATA GENERATION COMPLETE")
    print("=" * 60)
    print(f"  Users:            {len(users):>10,}")
    print(f"  Content:          {len(content):>10,}")
    print(f"  Subscriptions:    {len(subscriptions):>10,}")
    print(f"  Viewing Events:   {len(events):>10,}")
    print(f"  Total rows:       {sum([len(users), len(content), len(subscriptions), len(events)]):>10,}")
    print("=" * 60)

    # Verify in MySQL
    cursor = conn.cursor()
    cursor.execute("""
        SELECT TABLE_NAME, TABLE_ROWS 
        FROM INFORMATION_SCHEMA.TABLES 
        WHERE TABLE_SCHEMA = 'stream_dw'
        ORDER BY TABLE_NAME
    """)
    print("\n  MySQL row counts (approximate):")
    for table, rows in cursor.fetchall():
        print(f"    {table:<30} {rows:>10,}")

    cursor.close()
    conn.close()
    print("\n  Done! Your staging layer is loaded. 🎬")


if __name__ == "__main__":
    main()
