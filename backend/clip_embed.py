import logging
import os
import sqlite3
import struct
import numpy as np
from pathlib import Path
from PIL import Image
from pillow_heif import register_heif_opener

register_heif_opener()

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

import torch
import clip

log = logging.getLogger("quemory.clip_embed")

DB_DIR = os.path.join(os.path.dirname(__file__), "database")
DB_PATH = os.path.join(DB_DIR, "embeddings.db")
IMAGES_FOLDER = os.path.join(os.path.dirname(__file__), "..", "assets", "images1")
OLLAMA_MODEL = "gemma4:e4b"

device = "cuda" if torch.cuda.is_available() else "cpu"
log.info("Loading CLIP ViT-B/32 on device=%s", device)
model, preprocess = clip.load("ViT-B/32", device=device)
log.info("CLIP model loaded")


def _serialize(vec: np.ndarray) -> bytes:
    return struct.pack(f"{len(vec)}f", *vec.tolist())


def _deserialize(blob: bytes) -> np.ndarray:
    n = len(blob) // 4
    return np.array(struct.unpack(f"{n}f", blob), dtype=np.float32)


def _init_db():
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS embeddings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            embedding BLOB NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.commit()
    return conn


def save_all_embeddings():
    log.info("save_all_embeddings(): scanning %s", IMAGES_FOLDER)
    conn = _init_db()
    extensions = {".jpg", ".jpeg", ".png", ".heic", ".heif"}
    images = [
        p for p in Path(IMAGES_FOLDER).iterdir()
        if p.suffix.lower() in extensions and p.is_file()
    ]

    log.info("Found %d image(s) in %s", len(images), IMAGES_FOLDER)
    print(f"Found {len(images)} images in {IMAGES_FOLDER}")
    saved = 0
    skipped_existing = 0
    failed = 0

    for img_path in images:
        abs_path = str(img_path.resolve())
        existing = conn.execute(
            "SELECT id FROM embeddings WHERE file_path = ?", (abs_path,)
        ).fetchone()
        if existing:
            skipped_existing += 1
            continue

        try:
            img = preprocess(Image.open(img_path).convert("RGB")).unsqueeze(0).to(device)
            with torch.no_grad():
                embedding = model.encode_image(img)
            vec = embedding.cpu().numpy().flatten()
            vec = vec / np.linalg.norm(vec)

            conn.execute(
                "INSERT INTO embeddings (file_path, file_name, embedding) VALUES (?, ?, ?)",
                (abs_path, img_path.name, _serialize(vec)),
            )
            saved += 1
            log.debug("Embedded [%d] %s", saved, img_path.name)
            print(f"  [{saved}] {img_path.name}")
        except Exception:
            failed += 1
            log.exception("Failed to embed %s", img_path.name)
            print(f"  SKIP {img_path.name}")

    conn.commit()
    conn.close()
    log.info(
        "save_all_embeddings done: saved=%d skipped_existing=%d failed=%d",
        saved, skipped_existing, failed,
    )
    print(f"Done. Saved {saved} new embeddings to {DB_PATH}")


def search(query: str, top_k: int = 5):
    log.info("CLIP search query=%r top_k=%d", query, top_k)
    conn = _init_db()
    rows = conn.execute("SELECT file_path, file_name, embedding FROM embeddings").fetchall()
    if not rows:
        log.warning("search(): no embeddings in DB; run save_all_embeddings() first")
        print("No embeddings in database. Run save_all_embeddings() first.")
        conn.close()
        return []

    text_tokens = clip.tokenize([query]).to(device)
    with torch.no_grad():
        text_vec = model.encode_text(text_tokens).cpu().numpy().flatten()
    text_vec = text_vec / np.linalg.norm(text_vec)

    results = []
    for file_path, file_name, blob in rows:
        img_vec = _deserialize(blob)
        score = float(np.dot(text_vec, img_vec))
        results.append((file_path, file_name, score))

    results.sort(key=lambda x: x[2], reverse=True)
    top = results[:top_k]

    print(f"Top {len(top)} results for '{query}':")
    for path, name, score in top:
        print(f"  {score:.4f}  {name}")

    conn.close()
    return top


def _expand_query(query: str, n: int = 4) -> list[str]:
    """Use Ollama to expand a complex query into simpler CLIP-friendly sub-phrases."""
    log.debug("Expanding query via Ollama: %r", query)
    try:
        import ollama
        resp = ollama.generate(
            model=OLLAMA_MODEL,
            prompt=(
                f'Given this photo search query: "{query}"\n\n'
                f"Generate {n} shorter, visually descriptive phrases (3–7 words each) "
                f"that together cover what someone would search for to find these photos.\n"
                f"Output ONLY the phrases, one per line, no numbers or explanation."
            ),
        )
        phrases = [
            line.strip()
            for line in resp["response"].split("\n")
            if line.strip() and len(line.strip()) > 3
        ]
        log.debug("Ollama expanded %r into %d phrase(s)", query, len(phrases))
        return (phrases[:n] if phrases else [query])
    except Exception:
        log.exception("Ollama query expansion failed; falling back to raw query")
        return [query]


def search_expanded(query: str, top_k: int = 5) -> list:
    """Search using multi-prompt query expansion for better recall on complex queries."""
    conn = _init_db()
    rows = conn.execute(
        "SELECT file_path, file_name, embedding FROM embeddings"
    ).fetchall()
    if not rows:
        conn.close()
        return []

    sub_queries = _expand_query(query)
    print(f"[search_expanded] Expanded '{query}' → {sub_queries}")

    # Average text embeddings across all sub-queries
    text_vecs = []
    for q in sub_queries:
        tokens = clip.tokenize([q]).to(device)
        with torch.no_grad():
            vec = model.encode_text(tokens).cpu().numpy().flatten()
        norm = np.linalg.norm(vec)
        text_vecs.append(vec / norm if norm > 0 else vec)

    avg_vec = np.mean(text_vecs, axis=0)
    avg_vec = avg_vec / np.linalg.norm(avg_vec)

    results = []
    for file_path, file_name, blob in rows:
        img_vec = _deserialize(blob)
        score = float(np.dot(avg_vec, img_vec))
        results.append((file_path, file_name, score))

    results.sort(key=lambda x: x[2], reverse=True)
    conn.close()
    return results[:top_k]


if __name__ == "__main__":
    import sys
    import json
    import tempfile
    if len(sys.argv) > 1 and sys.argv[1] == "search":
        query = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else "food"
        results = search(query)
        output = []
        for file_path, file_name, score in results:
            ext = os.path.splitext(file_name)[1].lower()
            if ext in {".heic", ".heif"}:
                tmp_path = os.path.join(
                    tempfile.gettempdir(),
                    f"quemory_{os.path.splitext(file_name)[0]}.jpg",
                )
                if not os.path.exists(tmp_path):
                    img = Image.open(file_path).convert("RGB")
                    img.save(tmp_path, "JPEG", quality=85)
                display_path = tmp_path
            else:
                display_path = file_path
            output.append({"path": display_path, "name": file_name, "score": score})
        print("RESULTS_JSON:" + json.dumps(output))
    else:
        save_all_embeddings()
