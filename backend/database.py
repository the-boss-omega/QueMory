import logging
import sqlite3
import os
import face

log = logging.getLogger("quemory.database")

DB_DIR = os.path.join(os.path.dirname(__file__), "database")
DB_PATH = os.path.join(DB_DIR, "quemory.db")


def create_database():
    """Create the database folder and quemory.db with all tables."""
    log.debug("create_database(): ensuring schema at %s", DB_PATH)
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("PRAGMA foreign_keys = ON")
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
            most_frequent_face TEXT,
            top_face_bbox TEXT,
            top_face_count INTEGER,
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
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trip_analytics (
            trip_id INTEGER PRIMARY KEY,
            analytics_json TEXT NOT NULL,
            computed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (trip_id) REFERENCES trips(id) ON DELETE CASCADE
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
    try:
        cursor.execute("ALTER TABLE trips ADD COLUMN most_frequent_face TEXT")
    except sqlite3.OperationalError:
        pass
    cursor.execute("""
        DELETE FROM trip_photos
        WHERE id NOT IN (
            SELECT MIN(id)
            FROM trip_photos
            GROUP BY trip_id, file_path
        )
    """)
    try:
        cursor.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_trip_photos_trip_file
            ON trip_photos (trip_id, file_path)
        """)
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
    log.debug("mark_images_assigned: %d image(s) -> trip_id=%d", len(image_ids), trip_id)
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
    log.debug("mark_images_excluded: %d image(s)", len(image_ids))
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
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT * FROM images").fetchall()
    for row in rows:
        print(dict(row))
    conn.close()


def create_trip(name: str, start_date: str = None, end_date: str = None,
                cover_photo_path: str = None, description: str = None,
                total_photos: int = 0, total_key_photos: int = 0) -> int:
    """Create a new trip and return its id."""
    log.info(
        "create_trip(name=%r, start=%s, end=%s, total_photos=%d, total_key=%d)",
        name, start_date, end_date, total_photos, total_key_photos,
    )
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
        """INSERT OR IGNORE INTO trip_photos
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
                  description, total_photos, total_key_photos, created_at,
                  most_frequent_face, top_face_bbox, top_face_count
           FROM trips ORDER BY start_date DESC""",
    ).fetchall()
    conn.close()
    log.debug("list_trips returned %d trip(s)", len(rows))
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
    log.info(
        "add_home_location lat=%.4f lon=%.4f radius_km=%.1f label=%s",
        latitude, longitude, radius_km, label,
    )
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
    log.debug("update_trip_description(trip_id=%d, chars=%d)", trip_id, len(description or ""))
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "UPDATE trips SET description = ? WHERE id = ?",
        (description, trip_id),
    )
    conn.commit()
    conn.close()


def get_trip_image_paths(trip_id: int) -> list[str]:
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    rows = cursor.execute(
        "SELECT file_path FROM images WHERE trip_id = ?",
        (trip_id,)
    ).fetchall()
    conn.close()
    return [row[0] for row in rows]

def update_frequent_face(trip_id: int) -> None:
    """Detect and store the most frequently appearing face in a trip."""
    log.info("update_frequent_face(trip_id=%d)", trip_id)
    image_paths = get_trip_image_paths(trip_id)
    if not image_paths:
        log.debug("update_frequent_face: no images for trip %d", trip_id)
        return
    results = face.find_top_face(image_paths)
    if not results:
        log.info("update_frequent_face: no top face found for trip %d", trip_id)
        return
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """UPDATE trips
           SET most_frequent_face = ?,
               top_face_bbox      = ?,
               top_face_count     = ?
           WHERE id = ?""",
        (
            results.get("image_path"),
            str(results.get("bbox", "")),
            results.get("count"),
            trip_id,
        ),
    )
    conn.commit()
    conn.close()
    log.info(
        "update_frequent_face: trip_id=%d face_in=%s count=%s",
        trip_id, results.get("image_path"), results.get("count"),
    )


def add_photos_to_trip(trip_id: int, photos: list[dict]) -> int:
    """Append new photos to an existing trip and refresh cover photo.
    Returns number of newly inserted photos.
    """
    log.info("add_photos_to_trip(trip_id=%d, count=%d)", trip_id, len(photos))
    if not photos:
        return 0
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    inserted = 0
    for p in photos:
        try:
            cursor.execute(
                """INSERT OR IGNORE INTO trip_photos
                   (trip_id, file_path, file_name, timestamp, latitude, longitude,
                    aesthetic_score, is_key_photo)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    trip_id, p["path"], p["name"],
                    p.get("timestamp"), p.get("latitude"), p.get("longitude"),
                    p.get("aesthetic_score"), int(p.get("is_key_photo", False)),
                ),
            )
            inserted += cursor.rowcount
        except Exception:
            log.exception("Failed to insert photo into trip_id=%d: %s", trip_id, p.get("path"))
    conn.commit()
    log.info("add_photos_to_trip: %d new rows inserted (trip_id=%d)", inserted, trip_id)

    # Update total_photos count
    conn.execute(
        "UPDATE trips SET total_photos = (SELECT COUNT(*) FROM trip_photos WHERE trip_id = ?) WHERE id = ?",
        (trip_id, trip_id),
    )

    # Update cover photo = best aesthetic_score photo
    best = conn.execute(
        """SELECT file_path FROM trip_photos
           WHERE trip_id = ? AND aesthetic_score IS NOT NULL
           ORDER BY aesthetic_score DESC LIMIT 1""",
        (trip_id,),
    ).fetchone()
    if best:
        conn.execute(
            "UPDATE trips SET cover_photo_path = ? WHERE id = ?",
            (best[0], trip_id),
        )
    conn.commit()
    conn.close()
    return inserted


def update_cover_photo(trip_id: int) -> str | None:
    """Set cover_photo_path to the highest aesthetic_score photo. Returns path or None."""
    conn = sqlite3.connect(DB_PATH)
    row = conn.execute(
        """SELECT file_path FROM trip_photos
           WHERE trip_id = ? AND aesthetic_score IS NOT NULL
           ORDER BY aesthetic_score DESC LIMIT 1""",
        (trip_id,),
    ).fetchone()
    path = row[0] if row else None
    if path:
        conn.execute(
            "UPDATE trips SET cover_photo_path = ? WHERE id = ?",
            (path, trip_id),
        )
        conn.commit()
        log.info("update_cover_photo: trip_id=%d -> %s", trip_id, path)
    else:
        log.debug("update_cover_photo: no candidates for trip_id=%d", trip_id)
    conn.close()
    return path


if __name__ == "__main__":
    fetch_images()
