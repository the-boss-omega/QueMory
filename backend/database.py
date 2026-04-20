import sqlite3
import os

DB_DIR = os.path.join(os.path.dirname(__file__), "database")
DB_PATH = os.path.join(DB_DIR, "quemory.db")


def create_database():
    """Create the database folder and quemory.db with all tables."""
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS images (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            trip_id INTEGER,
            trip_status TEXT DEFAULT 'unassigned',
            added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            start_date TEXT,
            end_date TEXT,
            cover_photo_path TEXT,
            description TEXT,
            total_photos INTEGER DEFAULT 0,
            total_key_photos INTEGER DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trip_photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            file_path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            timestamp TEXT,
            latitude REAL,
            longitude REAL,
            aesthetic_score REAL,
            is_key_photo INTEGER DEFAULT 0,
            FOREIGN KEY (trip_id) REFERENCES trips(id) ON DELETE CASCADE
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trip_locations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            label TEXT,
            arrival TEXT,
            departure TEXT,
            photo_count INTEGER DEFAULT 0,
            FOREIGN KEY (trip_id) REFERENCES trips(id) ON DELETE CASCADE
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS home_locations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            radius_km REAL NOT NULL DEFAULT 5.0,
            label TEXT
        )
    """)
        # Migration: add columns if they don't exist yet
    try:
        cursor.execute("ALTER TABLE images ADD COLUMN trip_id INTEGER")
    except sqlite3.OperationalError:
        pass  # column already exists
    try:
        cursor.execute("ALTER TABLE images ADD COLUMN trip_status TEXT DEFAULT 'unassigned'")
    except sqlite3.OperationalError:
        pass
    conn.commit()
    conn.close()

def get_unassigned_images():
    """Get only images that haven't been checked for trips yet."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("""
        SELECT id, file_path, file_name
        FROM images
        WHERE trip_status = 'unassigned'
        ORDER BY file_name
    """).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def mark_images_assigned(image_ids: list, trip_id: int):
    """Mark images as belonging to a trip."""
    if not image_ids:
        return
    conn = sqlite3.connect(DB_PATH)
    placeholders = ','.join('?' * len(image_ids))
    conn.execute(f"""
        UPDATE images
        SET trip_id = ?, trip_status = 'assigned'
        WHERE id IN ({placeholders})
    """, [trip_id] + image_ids)
    conn.commit()
    conn.close()


def mark_images_excluded(image_ids: list):
    """Mark images as checked but not part of any trip (daily life)."""
    if not image_ids:
        return
    conn = sqlite3.connect(DB_PATH)
    placeholders = ','.join('?' * len(image_ids))
    conn.execute(f"""
        UPDATE images
        SET trip_status = 'excluded'
        WHERE id IN ({placeholders})
    """, image_ids)
    conn.commit()
    conn.close()


def get_image_ids_by_paths(file_paths: list) -> dict:
    """Given file paths, return a dict of {file_path: image_id}."""
    if not file_paths:
        return {}
    conn = sqlite3.connect(DB_PATH)
    placeholders = ','.join('?' * len(file_paths))
    rows = conn.execute(f"""
        SELECT id, file_path FROM images
        WHERE file_path IN ({placeholders})
    """, file_paths).fetchall()
    conn.close()
    return {row[1]: row[0] for row in rows}


def save_image(file_path: str):
    """Save an image file path to the database. Returns the row id."""
    if not os.path.isfile(file_path):
        raise FileNotFoundError(f"Image not found: {file_path}")

    file_path = os.path.abspath(file_path)
    file_name = os.path.basename(file_path)

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "INSERT OR IGNORE INTO images (file_path, file_name) VALUES (?, ?)",
        (file_path, file_name),
    )
    conn.commit()
    row_id = cursor.lastrowid
    conn.close()
    return row_id

def fetch_images():
    conn = sqlite3.connect(r"D:\\Proj\\QueMory2\\backend\\database\\quemory.db")
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT * FROM images").fetchall()
    for row in rows:
        print(dict(row))
    conn.close()


def create_trip(name: str, start_date: str = None, end_date: str = None,
                cover_photo_path: str = None, description: str = None,
                total_photos: int = 0, total_key_photos: int = 0) -> int:
    """Create a new trip and return its id."""
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
        INSERT INTO trips (name, start_date, end_date, cover_photo_path,
                           description, total_photos, total_key_photos)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """, (name, start_date, end_date, cover_photo_path, description,
          total_photos, total_key_photos))
    trip_id = cursor.lastrowid
    conn.commit()
    conn.close()
    return trip_id


def save_trip_photos(trip_id: int, photos: list[dict]):
    """Save photos for a trip.

    Each photo dict can have:
        path, name, timestamp, latitude, longitude, aesthetic_score, is_key_photo
    """
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.executemany(
        """INSERT INTO trip_photos
           (trip_id, file_path, file_name, timestamp, latitude, longitude,
            aesthetic_score, is_key_photo)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        [(trip_id, p["path"], p["name"],
          p.get("timestamp"), p.get("latitude"), p.get("longitude"),
          p.get("aesthetic_score"), int(p.get("is_key_photo", False)))
         for p in photos],
    )
    conn.commit()
    conn.close()


def save_trip_locations(trip_id: int, locations: list[dict]):
    """Save geographic stops for a trip."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.executemany(
        """INSERT INTO trip_locations
           (trip_id, latitude, longitude, label, arrival, departure, photo_count)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        [(trip_id, loc["latitude"], loc["longitude"],
          loc.get("label"), loc.get("arrival"), loc.get("departure"),
          loc.get("photo_count", 0))
         for loc in locations],
    )
    conn.commit()
    conn.close()


def get_trip_photos(trip_id: int) -> list[dict]:
    """Load saved photos for a trip."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """SELECT file_path, file_name, timestamp, latitude, longitude,
                  aesthetic_score, is_key_photo
           FROM trip_photos WHERE trip_id = ? ORDER BY timestamp""",
        (trip_id,),
    ).fetchall()
    conn.close()
    return [{"path": r["file_path"], "name": r["file_name"],
             "timestamp": r["timestamp"], "latitude": r["latitude"],
             "longitude": r["longitude"],
             "aesthetic_score": r["aesthetic_score"],
             "is_key_photo": bool(r["is_key_photo"])} for r in rows]


def get_trip_locations(trip_id: int) -> list[dict]:
    """Load geographic stops for a trip."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """SELECT latitude, longitude, label, arrival, departure, photo_count
           FROM trip_locations WHERE trip_id = ? ORDER BY arrival""",
        (trip_id,),
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def list_trips() -> list[dict]:
    """List all trips."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """SELECT id, name, start_date, end_date, cover_photo_path,
                  description, total_photos, total_key_photos, created_at
           FROM trips ORDER BY start_date DESC""",
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_home_locations() -> list[dict]:
    """Return all configured home locations."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT id, latitude, longitude, radius_km, label FROM home_locations"
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def add_home_location(latitude: float, longitude: float,
                      radius_km: float = 5.0, label: str = None) -> int:
    """Add a home location. Returns the row id."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        """INSERT INTO home_locations (latitude, longitude, radius_km, label)
           VALUES (?, ?, ?, ?)""",
        (latitude, longitude, radius_km, label),
    )
    row_id = cursor.lastrowid
    conn.commit()
    conn.close()
    return row_id

def update_trip_description(trip_id: int, description: str) -> None:
    """Update the description column for a trip."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "UPDATE trips SET description = ? WHERE id = ?",
        (description, trip_id),
    )
    conn.commit()
    conn.close()

if __name__ == "__main__":
    fetch_images()
