import sqlite3
import os

DB_DIR = os.path.join(os.path.dirname(__file__), "database")
DB_PATH = os.path.join(DB_DIR, "quemory.db")


def create_database():
    """Create the database folder and quemory.db with an images table."""
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS images (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trip_photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            file_path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
        )
    """)
    conn.commit()
    conn.close()


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


def create_trip(name: str) -> int:
    """Create a new trip and return its id."""
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trip_photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            file_path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
        )
    """)
    cursor.execute("INSERT INTO trips (name) VALUES (?)", (name,))
    trip_id = cursor.lastrowid
    conn.commit()
    conn.close()
    return trip_id


def save_trip_photos(trip_id: int, photos: list[dict]):
    """Save curated photos for a trip. Each photo is {'path': ..., 'name': ...}."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.executemany(
        "INSERT INTO trip_photos (trip_id, file_path, file_name) VALUES (?, ?, ?)",
        [(trip_id, p["path"], p["name"]) for p in photos],
    )
    conn.commit()
    conn.close()


def get_trip_photos(trip_id: int) -> list[dict]:
    """Load saved photos for a trip."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT file_path, file_name FROM trip_photos WHERE trip_id = ?",
        (trip_id,),
    ).fetchall()
    conn.close()
    return [{"path": r["file_path"], "name": r["file_name"]} for r in rows]


def list_trips() -> list[dict]:
    """List all trips."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT id, name, created_at FROM trips ORDER BY created_at DESC").fetchall()
    conn.close()
    return [dict(r) for r in rows]

if __name__ == "__main__":
    fetch_images()
