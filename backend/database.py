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

if __name__ == "__main__":
    fetch_images()
