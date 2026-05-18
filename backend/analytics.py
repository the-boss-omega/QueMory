"""analytics.py – Compute and cache per-trip analytics for QueMory.

Each public function returns a JSON-serialisable dict.
Heavy CLIP work reuses embeddings already stored in the embeddings DB.
Results are cached in the trip_analytics table and invalidated when new
photos are added to a trip.
"""

import json
import logging
import math
import os
import sqlite3
from collections import defaultdict
from datetime import datetime

import numpy as np

log = logging.getLogger("quemory.analytics")

DB_PATH = os.path.join(os.path.dirname(__file__), "database", "quemory.db")
EMBED_DB_PATH = os.path.join(os.path.dirname(__file__), "database", "embeddings.db")


# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

def _haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Return great-circle distance in km between two WGS-84 points."""
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2
         + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2))
         * math.sin(dlon / 2) ** 2)
    return R * 2 * math.asin(math.sqrt(a))


def _load_trip_photos(trip_id: int) -> list[dict]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """SELECT file_path, file_name, timestamp, latitude, longitude,
                  aesthetic_score, is_key_photo
           FROM trip_photos WHERE trip_id = ? ORDER BY timestamp""",
        (trip_id,),
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


def _load_embeddings(file_paths: list) -> dict:
    """Load cached CLIP embeddings for given paths. Returns {path: np.ndarray}."""
    if not file_paths:
        return {}
    try:
        conn = sqlite3.connect(EMBED_DB_PATH)
        placeholders = ",".join("?" * len(file_paths))
        rows = conn.execute(
            f"SELECT file_path, embedding FROM embeddings WHERE file_path IN ({placeholders})",
            file_paths,
        ).fetchall()
        conn.close()
        result = {}
        for path, blob in rows:
            n = len(blob) // 4
            import struct
            arr = np.array(struct.unpack(f"{n}f", blob), dtype=np.float32)
            norm = np.linalg.norm(arr)
            result[path] = arr / norm if norm > 0 else arr
        return result
    except Exception:
        return {}


def _clip_text_vector(prompt: str):
    """Encode a text prompt with the loaded CLIP model. Returns np.ndarray or None."""
    try:
        import clip
        from clip_embed import model as clip_model, device as clip_device
        import torch
        tokens = clip.tokenize([prompt]).to(clip_device)
        with torch.no_grad():
            vec = clip_model.encode_text(tokens).cpu().numpy().flatten().astype(np.float32)
        norm = np.linalg.norm(vec)
        return vec / norm if norm > 0 else vec
    except Exception:
        log.exception("_clip_text_vector failed for prompt=%r", prompt)
        return None


def _score_photos(embeddings: dict, prompt: str) -> list:
    """Returns [(path, score)] sorted descending by cosine similarity."""
    text_vec = _clip_text_vector(prompt)
    if text_vec is None or not embeddings:
        return []
    scores = [(path, float(np.dot(emb, text_vec))) for path, emb in embeddings.items()]
    scores.sort(key=lambda x: x[1], reverse=True)
    return scores


def _get_camera_name(path: str) -> str:
    """Read camera model from EXIF. Returns 'Make Model' or 'Unknown'."""
    try:
        from metadata import get_exif, extract_camera
        exif = get_exif(path)
        cam = extract_camera(exif)
        make = cam.get("make") or ""
        model = cam.get("model") or ""
        combined = f"{make} {model}".strip()
        return combined if combined else "Unknown"
    except Exception:
        return "Unknown"


# ─────────────────────────────────────────────────────────────────────────────
# Individual analytics functions
# ─────────────────────────────────────────────────────────────────────────────

def analytic_map_of_photos(photos: list) -> dict:
    """All geotagged photos as map markers."""
    points = [
        {
            "lat": p["latitude"],
            "lon": p["longitude"],
            "path": p["file_path"],
            "ts": p["timestamp"],
            "score": p.get("aesthetic_score"),
        }
        for p in photos
        if p.get("latitude") and p.get("longitude")
    ]
    return {"type": "map_of_photos", "points": points}


def analytic_inner_circle(photos: list) -> dict:
    """Top 3 most frequently appearing faces (podium)."""
    try:
        import face as face_mod
        paths = [p["file_path"] for p in photos if os.path.isfile(p["file_path"])]
        if not paths:
            return {"type": "inner_circle", "faces": []}

        all_face_items = []
        for img_path in paths:
            try:
                items = face_mod.extract_faces_for_embedding(img_path)
                embedded = face_mod.faces_to_embeddings(items)
                for item in embedded:
                    item["image_path"] = img_path
                all_face_items.extend(embedded)
            except Exception:
                continue

        if not all_face_items:
            return {"type": "inner_circle", "faces": []}

        # Cluster
        clustered, _, _ = face_mod.cluster_embeddings(all_face_items)
        from collections import Counter
        valid = [item for item in clustered if item.get("cluster_id", -1) != -1]
        counts = Counter(item["cluster_id"] for item in valid)
        top3_clusters = [cid for cid, _ in counts.most_common(3)]

        faces = []
        for rank, cid in enumerate(top3_clusters):
            members = [item for item in valid if item["cluster_id"] == cid]
            best = max(members, key=lambda x: x.get("score", 0))
            faces.append({
                "rank": rank + 1,
                "image_path": best["image_path"],
                "count": counts[cid],
                "bbox": best.get("bbox"),
            })

        return {"type": "inner_circle", "faces": faces}
    except Exception as e:
        return {"type": "inner_circle", "faces": [], "error": str(e)}


def analytic_food_map(photos: list, embeddings: dict) -> dict:
    """Count food photos and identify the most common food type."""
    FOOD_PROMPTS = [
        "a photo of delicious food on a plate",
        "a photo of a restaurant meal",
        "a photo of street food",
    ]
    FOOD_TYPES = {
        "Sushi": "a close-up of sushi rolls and sashimi",
        "Pizza": "a hot pizza with melted cheese",
        "Ramen": "a bowl of ramen noodle soup",
        "Coffee": "a cup of coffee or latte art",
        "Dessert": "a delicious dessert cake ice cream",
        "BBQ": "grilled barbecue meat on a grill",
        "Burger": "a juicy hamburger sandwich",
        "Tacos": "Mexican tacos with toppings",
        "Pasta": "a plate of pasta with sauce",
    }

    # Get food photo scores
    all_food_scores = {}
    for prompt in FOOD_PROMPTS:
        for path, score in _score_photos(embeddings, prompt):
            if path not in all_food_scores or score > all_food_scores[path]:
                all_food_scores[path] = score

    THRESHOLD = 0.22
    food_photos = sorted(
        [(path, score) for path, score in all_food_scores.items() if score > THRESHOLD],
        key=lambda x: x[1], reverse=True
    )

    # Identify top food type
    type_scores = {}
    for food_name, prompt in FOOD_TYPES.items():
        scores = _score_photos(embeddings, prompt)
        if scores:
            top_n = max(1, len(scores) // 10)
            type_scores[food_name] = sum(s for _, s in scores[:top_n]) / top_n
    top_food = max(type_scores, key=type_scores.get) if type_scores else "Food"

    return {
        "type": "food_map",
        "total_food_photos": len(food_photos),
        "top_food": top_food,
        "top_food_photos": [{"path": p, "score": round(s, 3)} for p, s in food_photos[:6]],
    }


def analytic_photographers_growth(photos: list) -> dict:
    """Aesthetic score curve over time with letter grades."""
    def _grade(score: float) -> str:
        if score >= 0.80: return "A+"
        if score >= 0.70: return "A"
        if score >= 0.60: return "B+"
        if score >= 0.50: return "B"
        if score >= 0.40: return "C+"
        if score >= 0.30: return "C"
        return "D"

    scored = [
        (p["timestamp"], float(p["aesthetic_score"]))
        for p in photos
        if p.get("timestamp") and p.get("aesthetic_score") is not None
    ]
    scored.sort(key=lambda x: x[0])

    if not scored:
        return {"type": "photographers_growth", "data": [], "overall_grade": "N/A", "avg_score": 0}

    data = [{"ts": ts, "score": round(s, 3), "grade": _grade(s)} for ts, s in scored]
    avg = sum(s for _, s in scored) / len(scored)

    return {
        "type": "photographers_growth",
        "data": data,
        "overall_grade": _grade(avg),
        "avg_score": round(avg, 3),
    }


def analytic_emotional_timeline(photos: list, embeddings: dict) -> dict:
    """Smile frequency across the trip as a daily timeline."""
    SMILE_PROMPT = "people smiling happily laughing together"
    scored = _score_photos(embeddings, SMILE_PROMPT)
    score_map = {path: score for path, score in scored}

    by_date: dict = defaultdict(list)
    for photo in photos:
        ts = photo.get("timestamp")
        if not ts:
            continue
        try:
            dt = datetime.fromisoformat(ts)
            by_date[dt.strftime("%Y-%m-%d")].append(score_map.get(photo["file_path"], 0.0))
        except Exception:
            continue

    timeline = []
    for date, scores_list in sorted(by_date.items()):
        avg = sum(scores_list) / len(scores_list)
        timeline.append({"date": date, "intensity": round(avg, 3), "count": len(scores_list)})

    happiest_day = ""
    if timeline:
        best = max(timeline, key=lambda x: x["intensity"])
        try:
            dt = datetime.fromisoformat(best["date"])
            happiest_day = dt.strftime("%B %d, %Y")
        except Exception:
            happiest_day = best["date"]

    return {
        "type": "emotional_timeline",
        "timeline": timeline,
        "happiest_day": happiest_day,
    }


def analytic_world_footprint(photos: list) -> dict:
    """Heatmap, total km traveled, and countries visited."""
    pts = [(p["latitude"], p["longitude"])
           for p in photos if p.get("latitude") and p.get("longitude")]
    if not pts:
        return {"type": "world_footprint", "total_km": 0, "pct_earth": 0,
                "heatmap": [], "countries": []}

    total_km = sum(_haversine(*pts[i - 1], *pts[i]) for i in range(1, len(pts)))

    cell_counts: dict = defaultdict(int)
    for lat, lon in pts:
        cell_counts[(round(lat, 1), round(lon, 1))] += 1

    heatmap = [{"lat": lat, "lon": lon, "count": cnt}
               for (lat, lon), cnt in cell_counts.items()]
    avg_lat = sum(lat for lat, _ in pts) / len(pts)
    pct_earth = round(
        len(cell_counts) * 0.01 * math.cos(math.radians(avg_lat)) * 12321 / 510_000_000 * 100,
        6
    )

    return {
        "type": "world_footprint",
        "total_km": round(total_km, 1),
        "pct_earth": pct_earth,
        "heatmap": heatmap,
        "countries": [],   # populated by reverse geocoding if available
    }


def analytic_pet_report_card(photos: list, embeddings: dict) -> dict:
    """Best and worst pet photos."""
    PET_PROMPTS = ["a cute dog pet", "a cute cat pet", "a domestic animal pet"]
    all_scores: dict = {}
    for prompt in PET_PROMPTS:
        for path, score in _score_photos(embeddings, prompt):
            if path not in all_scores or score > all_scores[path]:
                all_scores[path] = score

    THRESHOLD = 0.20
    pet_candidates = [(path, score) for path, score in all_scores.items() if score > THRESHOLD]
    if not pet_candidates:
        return {"type": "pet_report_card", "best": None, "worst": None, "total": 0}

    aesthetic_map = {p["file_path"]: (p.get("aesthetic_score") or 0.5) for p in photos}
    scored = [
        (path, clip_score, aesthetic_map.get(path, 0.5))
        for path, clip_score in pet_candidates
    ]
    best = max(scored, key=lambda x: x[2])
    worst = min(scored, key=lambda x: x[2])

    return {
        "type": "pet_report_card",
        "best": {"path": best[0], "score": round(best[2], 3)},
        "worst": {"path": worst[0], "score": round(worst[2], 3)},
        "total": len(pet_candidates),
    }


def analytic_chasing_sunsets(photos: list, embeddings: dict) -> dict:
    """Top 3 sunset / golden-hour photos ranked by quality."""
    SUNSET_PROMPTS = [
        "a beautiful golden hour sunset sky",
        "sunrise golden light landscape photography",
    ]
    all_scores: dict = {}
    for prompt in SUNSET_PROMPTS:
        for path, score in _score_photos(embeddings, prompt):
            if path not in all_scores or score > all_scores[path]:
                all_scores[path] = score

    def _is_golden(ts_str: str) -> bool:
        try:
            h = datetime.fromisoformat(ts_str).hour
            return (5 <= h <= 8) or (17 <= h <= 20)
        except Exception:
            return False

    ts_map = {p["file_path"]: p.get("timestamp", "") for p in photos}
    aesthetic_map = {p["file_path"]: (p.get("aesthetic_score") or 0.5) for p in photos}

    candidates = []
    for path, clip_score in all_scores.items():
        if clip_score < 0.18:
            continue
        ts = ts_map.get(path, "")
        bonus = 0.05 if _is_golden(ts) else 0.0
        quality = clip_score * 0.5 + aesthetic_map.get(path, 0.5) * 0.4 + bonus
        candidates.append({
            "path": path,
            "clip_score": round(clip_score, 3),
            "quality_score": round(quality, 3),
            "timestamp": ts,
        })
    candidates.sort(key=lambda x: x["quality_score"], reverse=True)

    return {
        "type": "chasing_sunsets",
        "top_sunsets": candidates[:3],
        "total": len(candidates),
    }


def analytic_time_machine() -> dict:
    """Top 3 GPS locations revisited across multiple trips."""
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """SELECT tp.file_path, tp.latitude, tp.longitude, tp.timestamp,
                      t.id AS trip_id, t.name AS trip_name
               FROM trip_photos tp JOIN trips t ON tp.trip_id = t.id
               WHERE tp.latitude IS NOT NULL AND tp.longitude IS NOT NULL
               ORDER BY tp.timestamp"""
        ).fetchall()
        conn.close()
    except Exception:
        return {"type": "time_machine", "locations": []}

    all_photos = [dict(r) for r in rows]
    if not all_photos:
        return {"type": "time_machine", "locations": []}

    # Cluster within ~100 m (≈ 0.001°)
    clusters: list = []
    for photo in all_photos:
        lat, lon = photo["latitude"], photo["longitude"]
        matched = None
        for cluster in clusters:
            clat, clon = cluster["center"]
            if abs(clat - lat) < 0.001 and abs(clon - lon) < 0.001:
                matched = cluster
                break
        if matched:
            matched["photos"].append(photo)
            n = len(matched["photos"])
            matched["center"] = (
                (matched["center"][0] * (n - 1) + lat) / n,
                (matched["center"][1] * (n - 1) + lon) / n,
            )
        else:
            clusters.append({"center": (lat, lon), "photos": [photo]})

    multi_visit = []
    for cluster in clusters:
        dates = set()
        for p in cluster["photos"]:
            ts = p.get("timestamp")
            if ts:
                try:
                    dates.add(datetime.fromisoformat(ts).date())
                except Exception:
                    pass
        if len(dates) >= 2:
            trip_names = list({p["trip_name"] for p in cluster["photos"]})
            sorted_photos = sorted(cluster["photos"], key=lambda x: x.get("timestamp", ""))
            multi_visit.append({
                "lat": round(cluster["center"][0], 5),
                "lon": round(cluster["center"][1], 5),
                "visit_count": len(dates),
                "trips": trip_names,
                "photos": [
                    {"path": p["file_path"], "date": (p.get("timestamp") or "")[:10]}
                    for p in sorted_photos
                ][:6],
            })

    multi_visit.sort(key=lambda x: x["visit_count"], reverse=True)
    return {"type": "time_machine", "locations": multi_visit[:3]}


def analytic_photo_timeline_heatmap(photos: list) -> dict:
    """GitHub contribution graph: photos per day."""
    by_date: dict = defaultdict(int)
    for p in photos:
        ts = p.get("timestamp")
        if ts:
            try:
                by_date[datetime.fromisoformat(ts).strftime("%Y-%m-%d")] += 1
            except Exception:
                pass
    max_count = max(by_date.values(), default=1)
    cells = [
        {"date": d, "count": c, "intensity": round(c / max_count, 2)}
        for d, c in sorted(by_date.items())
    ]
    return {"type": "photo_timeline_heatmap", "cells": cells, "max_count": max_count}


def analytic_hours_of_day_wheel(photos: list) -> dict:
    """Circular clock showing when photos are taken."""
    hour_counts = [0] * 24
    for p in photos:
        ts = p.get("timestamp")
        if ts:
            try:
                hour_counts[datetime.fromisoformat(ts).hour] += 1
            except Exception:
                pass

    def _label(h: int) -> str:
        if h == 0: return "12 AM"
        if h < 12: return f"{h} AM"
        if h == 12: return "12 PM"
        return f"{h - 12} PM"

    best_hour = hour_counts.index(max(hour_counts)) if any(hour_counts) else 12
    return {
        "type": "hours_of_day_wheel",
        "hours": [{"hour": i, "label": _label(i), "count": hour_counts[i]} for i in range(24)],
        "best_hour": best_hour,
        "best_hour_label": _label(best_hour),
    }


def analytic_trip_stats(photos: list) -> dict:
    """Total distance, photo count, and trip duration."""
    pts = [(p["latitude"], p["longitude"])
           for p in photos if p.get("latitude") and p.get("longitude")]
    total_km = sum(_haversine(*pts[i - 1], *pts[i]) for i in range(1, len(pts)))

    timestamps = sorted([p["timestamp"] for p in photos if p.get("timestamp")])
    duration_days = 0
    start_date = end_date = ""
    if len(timestamps) >= 2:
        try:
            start_dt = datetime.fromisoformat(timestamps[0])
            end_dt = datetime.fromisoformat(timestamps[-1])
            duration_days = (end_dt - start_dt).days + 1
            start_date = start_dt.strftime("%b %d, %Y")
            end_date = end_dt.strftime("%b %d, %Y")
        except Exception:
            pass

    return {
        "type": "trip_stats",
        "photo_count": len(photos),
        "distance_km": round(total_km, 1),
        "duration_days": duration_days,
        "start_date": start_date,
        "end_date": end_date,
    }


def analytic_camera_usage(photos: list) -> dict:
    """Which devices were used to take photos."""
    camera_counts: dict = defaultdict(int)
    for photo in photos:
        name = _get_camera_name(photo["file_path"])
        camera_counts[name] += 1

    total = len(photos)
    devices = sorted(
        [
            {"name": name, "count": cnt, "pct": round(cnt / total * 100, 1) if total else 0}
            for name, cnt in camera_counts.items()
        ],
        key=lambda x: x["count"], reverse=True
    )
    return {"type": "camera_usage", "devices": devices}


def analytic_top_locations() -> dict:
    """GPS locations that appear in multiple trips."""
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """SELECT tp.latitude, tp.longitude, tp.timestamp, t.id AS tid, t.name AS tname
               FROM trip_photos tp JOIN trips t ON tp.trip_id = t.id
               WHERE tp.latitude IS NOT NULL AND tp.longitude IS NOT NULL"""
        ).fetchall()
        conn.close()
    except Exception:
        return {"type": "top_locations", "locations": []}

    all_pts = [dict(r) for r in rows]
    clusters: list = []
    for pt in all_pts:
        lat, lon = pt["latitude"], pt["longitude"]
        matched = None
        for cluster in clusters:
            clat, clon = cluster["center"]
            if abs(clat - lat) < 0.0005 and abs(clon - lon) < 0.0005:
                matched = cluster
                break
        if matched:
            matched["entries"].append(pt)
        else:
            clusters.append({"center": (lat, lon), "entries": [pt]})

    multi_trip = []
    for cluster in clusters:
        trip_ids = {e["tid"] for e in cluster["entries"]}
        if len(trip_ids) >= 2:
            multi_trip.append({
                "lat": round(cluster["center"][0], 5),
                "lon": round(cluster["center"][1], 5),
                "trip_count": len(trip_ids),
                "trips": list({e["tname"] for e in cluster["entries"]})[:5],
                "visit_dates": [(e.get("timestamp") or "")[:10]
                                for e in cluster["entries"][:5]],
            })

    multi_trip.sort(key=lambda x: x["trip_count"], reverse=True)
    return {"type": "top_locations", "locations": multi_trip[:5]}


def analytic_trip_duration_ranking() -> dict:
    """Visual ranking of all trips by length."""
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT id, name, start_date, end_date FROM trips ORDER BY start_date"
        ).fetchall()
        conn.close()
    except Exception:
        return {"type": "trip_duration_ranking", "trips": [], "avg_days": 0}

    trip_durations = []
    for r in rows:
        if r["start_date"] and r["end_date"]:
            try:
                days = (datetime.fromisoformat(r["end_date"])
                        - datetime.fromisoformat(r["start_date"])).days + 1
                trip_durations.append({"name": r["name"], "days": days})
            except Exception:
                pass

    if not trip_durations:
        return {"type": "trip_duration_ranking", "trips": [], "avg_days": 0}

    trip_durations.sort(key=lambda x: x["days"], reverse=True)
    avg_days = round(sum(t["days"] for t in trip_durations) / len(trip_durations), 1)
    return {
        "type": "trip_duration_ranking",
        "trips": trip_durations,
        "avg_days": avg_days,
    }


def analytic_photography_dna(photos: list, embeddings: dict) -> dict:
    """CLIP-based vibe percentage profile of the photographer."""
    VIBES = {
        "Peaceful Nature": "a peaceful natural landscape trees greenery",
        "Busy City": "a busy urban city street people buildings",
        "Food": "delicious food on a table restaurant",
        "People & Joy": "people smiling laughing together friends",
        "Architecture": "beautiful building architecture interior design",
        "Water & Ocean": "ocean sea lake river water seascape",
        "Night Life": "nighttime city lights bar party nightlife",
        "Adventure": "hiking mountains adventure outdoor travel",
    }

    vibe_scores = {}
    for vibe_name, prompt in VIBES.items():
        scores = _score_photos(embeddings, prompt)
        if scores:
            top_n = max(1, len(scores) // 5)
            vibe_scores[vibe_name] = sum(s for _, s in scores[:top_n]) / top_n
        else:
            vibe_scores[vibe_name] = 0.0

    total = sum(vibe_scores.values())
    vibes = [
        {"label": name, "pct": round(score / total * 100, 1) if total else 0}
        for name, score in sorted(vibe_scores.items(), key=lambda x: x[1], reverse=True)
    ]
    return {"type": "photography_dna", "vibes": vibes}


def analytic_night_owl(photos: list, embeddings: dict) -> dict:
    """Photos taken between 10 PM and 5 AM — the night owl report."""
    night_photos = []
    for p in photos:
        ts = p.get("timestamp")
        if not ts:
            continue
        try:
            h = datetime.fromisoformat(ts).hour
            if h >= 22 or h < 5:
                night_photos.append(p)
        except Exception:
            pass

    midnight_count = 0
    for p in night_photos:
        try:
            h = datetime.fromisoformat(p["timestamp"]).hour
            if 0 <= h < 5:
                midnight_count += 1
        except Exception:
            pass

    night_sorted = sorted(night_photos, key=lambda x: x.get("aesthetic_score") or 0, reverse=True)

    latest_path = None
    latest_time = ""
    for p in sorted(night_photos, key=lambda x: x.get("timestamp", ""), reverse=True):
        ts = p.get("timestamp", "")
        if ts:
            try:
                dt = datetime.fromisoformat(ts)
                latest_path = p["file_path"]
                latest_time = dt.strftime("%I:%M %p")
                break
            except Exception:
                pass

    return {
        "type": "night_owl",
        "total_count": len(night_photos),
        "midnight_count": midnight_count,
        "best_shots": [{"path": p["file_path"], "timestamp": p.get("timestamp", "")}
                       for p in night_sorted[:3]],
        "latest_photo": {"path": latest_path, "time": latest_time},
    }


def analytic_key_photos(photos: list) -> dict:
    """All trip photos for the gallery view."""
    return {
        "type": "key_photos",
        "photos": [
            {
                "path": p["file_path"],
                "score": p.get("aesthetic_score"),
                "is_key": bool(p.get("is_key_photo")),
                "timestamp": p.get("timestamp"),
            }
            for p in photos
        ],
    }


def analytic_ben_aharon_special(trip_name: str) -> dict:
    """Hero HTML page for the Ben Aharon Marenkov Special card."""
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{trip_name}</title>

  <!-- Google Fonts: Sora (matches app typography) -->
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Sora:wght@400;700;900&display=swap" rel="stylesheet">

  <!-- Animate.css: entrance animation -->
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/animate.css/4.1.1/animate.min.css">

  <style>
    *, *::before, *::after {{ margin: 0; padding: 0; box-sizing: border-box; }}

    body {{
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      background: linear-gradient(135deg, #0f0c29 0%, #302b63 50%, #24243e 100%);
      font-family: 'Sora', sans-serif;
      overflow: hidden;
    }}

    .orb {{
      position: fixed;
      border-radius: 50%;
      filter: blur(80px);
      opacity: 0.25;
      animation: drift 12s ease-in-out infinite alternate;
      pointer-events: none;
    }}
    .orb-1 {{ width: 400px; height: 400px; background: #6366f1; top: -100px; left: -100px; animation-delay: 0s; }}
    .orb-2 {{ width: 300px; height: 300px; background: #22c55e; bottom: -80px; right: -80px; animation-delay: -6s; }}

    @keyframes drift {{
      from {{ transform: translate(0, 0) scale(1); }}
      to   {{ transform: translate(40px, 30px) scale(1.1); }}
    }}

    .card {{
      position: relative;
      z-index: 1;
      text-align: center;
      padding: 3rem 4rem;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 24px;
      background: rgba(255, 255, 255, 0.04);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      max-width: 90vw;
    }}

    .label {{
      font-size: 0.7rem;
      font-weight: 700;
      letter-spacing: 0.25em;
      color: rgba(255, 255, 255, 0.35);
      text-transform: uppercase;
      margin-bottom: 1.2rem;
    }}

    h1 {{
      color: #ffffff;
      font-size: clamp(2.2rem, 8vw, 5.5rem);
      font-weight: 900;
      letter-spacing: 0.03em;
      line-height: 1.1;
      text-shadow: 0 4px 40px rgba(255, 255, 255, 0.15);
    }}

    .sparkle {{
      margin-top: 1.5rem;
      font-size: 1.6rem;
      letter-spacing: 0.3em;
      opacity: 0.6;
    }}
  </style>
</head>
<body>
  <div class="orb orb-1"></div>
  <div class="orb orb-2"></div>

  <div class="card animate__animated animate__fadeInUp">
    <p class="label">The Ben Aharon Marenkov Special ✨</p>
    <h1>{trip_name}</h1>
    <p class="sparkle">✦ &nbsp; ✦ &nbsp; ✦</p>
  </div>
</body>
</html>"""
    css = ""
    javascript = ""
    return {{"type": "ben_aharon_special", "html": html, "css": css, "javascript": javascript, "trip_name": trip_name}}


# ─────────────────────────────────────────────────────────────────────────────
# Cache management
# ─────────────────────────────────────────────────────────────────────────────

def get_cached_analytics(trip_id: int) -> dict | None:
    try:
        conn = sqlite3.connect(DB_PATH)
        row = conn.execute(
            "SELECT analytics_json FROM trip_analytics WHERE trip_id = ?",
            (trip_id,),
        ).fetchone()
        conn.close()
        if row:
            return json.loads(row[0])
    except Exception:
        pass
    return None


def cache_analytics(trip_id: int, analytics: dict) -> None:
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.execute(
            """INSERT INTO trip_analytics (trip_id, analytics_json, computed_at)
               VALUES (?, ?, CURRENT_TIMESTAMP)
               ON CONFLICT(trip_id) DO UPDATE SET
                   analytics_json = excluded.analytics_json,
                   computed_at    = excluded.computed_at""",
            (trip_id, json.dumps(analytics)),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"[analytics] Cache write error: {e}")


def invalidate_cache(trip_id: int) -> None:
    """Delete cached analytics for a trip (call when photos change)."""
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.execute("DELETE FROM trip_analytics WHERE trip_id = ?", (trip_id,))
        conn.commit()
        conn.close()
        log.info("Invalidated analytics cache for trip_id=%d", trip_id)
    except Exception:
        log.exception("Failed to invalidate analytics cache for trip_id=%d", trip_id)


# ─────────────────────────────────────────────────────────────────────────────
# Main entry point
# ─────────────────────────────────────────────────────────────────────────────

def compute_all_analytics(trip_id: int, force: bool = False) -> dict:
    """Return analytics dict for a trip (from cache or freshly computed)."""
    log.info("compute_all_analytics(trip_id=%d, force=%s)", trip_id, force)
    if not force:
        cached = get_cached_analytics(trip_id)
        if cached:
            log.debug("Returning cached analytics for trip_id=%d", trip_id)
            return cached

    photos = _load_trip_photos(trip_id)
    file_paths = [p["file_path"] for p in photos]
    embeddings = _load_embeddings(file_paths)
    log.debug(
        "compute_all_analytics: trip_id=%d photos=%d embeddings=%d",
        trip_id, len(photos), len(embeddings),
    )

    conn = sqlite3.connect(DB_PATH)
    row = conn.execute("SELECT name FROM trips WHERE id = ?", (trip_id,)).fetchone()
    conn.close()
    trip_name = row[0] if row else f"Trip {trip_id}"

    result = {
        "trip_id": trip_id,
        "generated_at": datetime.now().isoformat(),
        "map_of_photos": analytic_map_of_photos(photos),
        "inner_circle": analytic_inner_circle(photos),
        "food_map": analytic_food_map(photos, embeddings),
        "photographers_growth": analytic_photographers_growth(photos),
        "emotional_timeline": analytic_emotional_timeline(photos, embeddings),
        "world_footprint": analytic_world_footprint(photos),
        "pet_report_card": analytic_pet_report_card(photos, embeddings),
        "chasing_sunsets": analytic_chasing_sunsets(photos, embeddings),
        "time_machine": analytic_time_machine(),
        "photo_timeline_heatmap": analytic_photo_timeline_heatmap(photos),
        "hours_of_day_wheel": analytic_hours_of_day_wheel(photos),
        "trip_stats": analytic_trip_stats(photos),
        "camera_usage": analytic_camera_usage(photos),
        "top_locations": analytic_top_locations(),
        "trip_duration_ranking": analytic_trip_duration_ranking(),
        "photography_dna": analytic_photography_dna(photos, embeddings),
        "night_owl": analytic_night_owl(photos, embeddings),
        "key_photos": analytic_key_photos(photos),
        "ben_aharon_special": analytic_ben_aharon_special(trip_name),
    }

    cache_analytics(trip_id, result)
    log.info("compute_all_analytics done for trip_id=%d (%d analytics)", trip_id, len(result))
    return result


def compute_wrapped_stats() -> dict:
    """Aggregate stats across ALL trips for the Wrapped page."""
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row

        trips = conn.execute(
            "SELECT id, name, start_date, end_date FROM trips"
        ).fetchall()
        total_photos = conn.execute("SELECT COUNT(*) FROM trip_photos").fetchone()[0]

        # Best photo overall
        best_row = conn.execute(
            """SELECT file_path, aesthetic_score FROM trip_photos
               WHERE aesthetic_score IS NOT NULL
               ORDER BY aesthetic_score DESC LIMIT 1"""
        ).fetchone()

        all_photos = conn.execute(
            "SELECT latitude, longitude, timestamp FROM trip_photos"
        ).fetchall()
        conn.close()

        # Total distance
        pts = [(r["latitude"], r["longitude"])
               for r in all_photos if r["latitude"] and r["longitude"]]
        total_km = sum(_haversine(*pts[i - 1], *pts[i]) for i in range(1, len(pts)))

        # Total days
        total_days = 0
        for t in trips:
            if t["start_date"] and t["end_date"]:
                try:
                    total_days += (
                        datetime.fromisoformat(t["end_date"])
                        - datetime.fromisoformat(t["start_date"])
                    ).days + 1
                except Exception:
                    pass

        return {
            "total_photos": total_photos,
            "total_trips": len(trips),
            "total_distance_km": round(total_km, 1),
            "total_days_traveled": total_days,
            "best_photo_path": dict(best_row)["file_path"] if best_row else None,
            "best_photo_score": round(dict(best_row)["aesthetic_score"], 3) if best_row else None,
        }
    except Exception as e:
        return {"error": str(e)}
