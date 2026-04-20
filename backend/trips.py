"""
Trip detection: merge adjacent photo clusters into coherent trips.

Algorithm
---------
1. Sort all photos by UTC timestamp.
2. Split into initial candidates whenever the gap between consecutive
   photos exceeds INITIAL_GAP_HOURS.
3. Walk the candidates in order and merge two neighbours into one
   whenever ALL of the following hold:
       a. Gap between endpoints ≤ MAX_MERGE_GAP_HOURS.
       b. Neither endpoint sits inside a home cell.
       c. Implied great-circle speed ≤ MAX_SPEED_KMH.
4. Each surviving candidate becomes a trip.  Per trip we pick key photos,
   compute a cover image, extract geographic stops, and persist everything.
"""

import math
from datetime import datetime, timedelta
from collections import defaultdict
import sqlite3
from database import DB_PATH
import numpy as np
from sklearn.cluster import DBSCAN

from database import (
    create_trip, save_trip_photos, save_trip_locations,
    get_home_locations, create_database, list_trips,
)
from filter import (
    compute_composite_score, _normalize,
    cluster_temporal, cluster_geographic, cluster_visual, merge_clusters,
)

# ── tunables ────────────────────────────────────────────────
INITIAL_GAP_HOURS = 4        # hours of silence → new candidate
MAX_MERGE_GAP_HOURS = 120    # max gap allowed when merging
MAX_SPEED_KMH = 1000         # faster than a jet → don't merge
HOME_RADIUS_KM = 5.0         # default home-cell radius
LOCATION_CLUSTER_EPS = 0.01  # ~1.1 km for stop clustering
KEY_PHOTO_FRACTION = 0.20    # top 20% become key photos

EARTH_RADIUS_KM = 6_371.0


# ── geometry helpers ────────────────────────────────────────

def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in km."""
    lat1, lon1, lat2, lon2 = map(math.radians, (lat1, lon1, lat2, lon2))
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(a))


def _speed_kmh(photo_a: dict, photo_b: dict) -> float | None:
    """Implied speed (km/h) between two photos.
    Returns None if either lacks GPS or the time gap is zero."""
    lat_a, lon_a = photo_a.get("latitude"), photo_a.get("longitude")
    lat_b, lon_b = photo_b.get("latitude"), photo_b.get("longitude")
    if None in (lat_a, lon_a, lat_b, lon_b):
        return None
    ts_a, ts_b = photo_a["timestamp"], photo_b["timestamp"]
    gap_h = (ts_b - ts_a).total_seconds() / 3600
    if gap_h <= 0:
        return None
    return _haversine_km(lat_a, lon_a, lat_b, lon_b) / gap_h


def _is_home(photo: dict, homes: list[dict]) -> bool:
    """True if the photo falls within any home cell."""
    lat, lon = photo.get("latitude"), photo.get("longitude")
    if lat is None or lon is None:
        return False
    for h in homes:
        if _haversine_km(lat, lon, h["latitude"], h["longitude"]) <= h.get("radius_km", HOME_RADIUS_KM):
            return True
    return False


# ── core detection ──────────────────────────────────────────

def detect_trips(features_list: list[dict],
                 homes: list[dict] | None = None,
                 initial_gap_hours: float = INITIAL_GAP_HOURS,
                 max_merge_gap_hours: float = MAX_MERGE_GAP_HOURS,
                 max_speed_kmh: float = MAX_SPEED_KMH) -> list[list[dict]]:
    """Return a list of trips, each a list of feature dicts sorted by timestamp."""
    if homes is None:
        homes = get_home_locations()

    timed = sorted(
        [f for f in features_list if f.get("timestamp") is not None],
        key=lambda f: f["timestamp"],
    )
    if not timed:
        return []

    # Step 1 — split at large gaps
    initial_gap = timedelta(hours=initial_gap_hours)
    candidates: list[list[dict]] = [[timed[0]]]
    for f in timed[1:]:
        if f["timestamp"] - candidates[-1][-1]["timestamp"] > initial_gap:
            candidates.append([f])
        else:
            candidates[-1].append(f)

    # Step 2 — merge neighbours that look like one continuous trip
    merged: list[list[dict]] = [candidates[0]]
    for candidate in candidates[1:]:
        prev = merged[-1]
        tail = prev[-1]
        head = candidate[0]

        gap_h = (head["timestamp"] - tail["timestamp"]).total_seconds() / 3600

        if _is_home(tail, homes) or _is_home(head, homes):
            merged.append(candidate)
            continue

        if gap_h > max_merge_gap_hours:
            merged.append(candidate)
            continue

        speed = _speed_kmh(tail, head)
        if speed is not None and speed > max_speed_kmh:
            merged.append(candidate)
            continue

        merged[-1].extend(candidate)

    return merged


# ── per-trip enrichment ─────────────────────────────────────

def _cluster_stops(photos: list[dict]) -> list[dict]:
    """DBSCAN on GPS to find distinct geographic stops within a trip."""
    geo_photos = [p for p in photos
                  if p.get("latitude") is not None and p.get("longitude") is not None]
    if not geo_photos:
        return []

    coords = np.array([[p["latitude"], p["longitude"]] for p in geo_photos])

    if len(coords) < 2:
        p = geo_photos[0]
        return [{
            "latitude": p["latitude"],
            "longitude": p["longitude"],
            "label": None,
            "arrival": p["timestamp"].isoformat() if p.get("timestamp") else None,
            "departure": p["timestamp"].isoformat() if p.get("timestamp") else None,
            "photo_count": 1,
        }]

    db = DBSCAN(eps=LOCATION_CLUSTER_EPS, min_samples=1, metric="euclidean")
    labels = db.fit_predict(coords)

    clusters: dict[int, list[dict]] = defaultdict(list)
    for label, p in zip(labels, geo_photos):
        if label == -1:
            continue
        clusters[label].append(p)

    stops = []
    for members in clusters.values():
        lats = [m["latitude"] for m in members]
        lons = [m["longitude"] for m in members]
        times = sorted([m["timestamp"] for m in members if m.get("timestamp")])
        stops.append({
            "latitude": sum(lats) / len(lats),
            "longitude": sum(lons) / len(lons),
            "label": None,
            "arrival": times[0].isoformat() if times else None,
            "departure": times[-1].isoformat() if times else None,
            "photo_count": len(members),
        })

    stops.sort(key=lambda s: s["arrival"] or "")
    return stops


def _dedup_within_trip(photos: list[dict]) -> list[dict]:
    """Remove near-duplicates within a trip using tri-axis clustering.
    Keeps the best-scored photo per group."""
    if len(photos) < 2:
        return photos

    temporal = cluster_temporal(photos)
    geographic = cluster_geographic(photos)
    visual = cluster_visual(photos)
    groups = merge_clusters(temporal, geographic, visual)

    all_sharpness = [p.get("sharpness", 0) for p in photos]
    all_mp = [p.get("megapixels", 0) for p in photos]
    norm_sharp = _normalize(all_sharpness)
    norm_mp = _normalize(all_mp)

    keep_indices: set[int] = set()
    for members in groups.values():
        if len(members) == 1:
            keep_indices.add(members[0])
            continue
        best_idx = max(
            members,
            key=lambda i: compute_composite_score(photos[i], norm_sharp[i], norm_mp[i]),
        )
        keep_indices.add(best_idx)

    return [photos[i] for i in sorted(keep_indices)]


def _select_key_photos_diverse(photos: list[dict], stops: list[dict],
                                fraction: float = KEY_PHOTO_FRACTION) -> set[str]:
    """Pick key photos with diversity across stop-locations."""
    budget = max(1, int(len(photos) * fraction))

    if not stops:
        # fallback: top by composite score
        all_sharp = [p.get("sharpness", 0) for p in photos]
        all_mp = [p.get("megapixels", 0) for p in photos]
        ns = _normalize(all_sharp)
        nm = _normalize(all_mp)
        scored = sorted(
            range(len(photos)),
            key=lambda i: compute_composite_score(photos[i], ns[i], nm[i]),
            reverse=True,
        )
        return {photos[i]["path"] for i in scored[:budget]}

    # Assign each photo to its nearest stop
    stop_coords = [(s["latitude"], s["longitude"]) for s in stops]
    stop_buckets: dict[int, list[tuple[int, float]]] = {i: [] for i in range(len(stops))}

    all_sharp = [p.get("sharpness", 0) for p in photos]
    all_mp = [p.get("megapixels", 0) for p in photos]
    ns = _normalize(all_sharp)
    nm = _normalize(all_mp)

    for pi, p in enumerate(photos):
        lat, lon = p.get("latitude"), p.get("longitude")
        score = compute_composite_score(p, ns[pi], nm[pi])
        if lat is None or lon is None:
            # No GPS — assign to first stop
            stop_buckets[0].append((pi, score))
            continue
        best_si = min(
            range(len(stop_coords)),
            key=lambda si: _haversine_km(lat, lon, stop_coords[si][0], stop_coords[si][1]),
        )
        stop_buckets[best_si].append((pi, score))

    # Sort each bucket by score descending
    for bucket in stop_buckets.values():
        bucket.sort(key=lambda x: x[1], reverse=True)

    # Round-robin across stops
    key_paths: set[str] = set()
    pointers = {si: 0 for si in stop_buckets}
    while len(key_paths) < budget:
        added_any = False
        for si in range(len(stops)):
            if len(key_paths) >= budget:
                break
            bucket = stop_buckets[si]
            ptr = pointers[si]
            if ptr < len(bucket):
                key_paths.add(photos[bucket[ptr][0]]["path"])
                pointers[si] = ptr + 1
                added_any = True
        if not added_any:
            break

    return key_paths


def _auto_name(photos: list[dict]) -> str:
    """Generate a fallback trip name from dates."""
    times = sorted([p["timestamp"] for p in photos if p.get("timestamp")])
    if not times:
        return "Untitled Trip"
    start, end = times[0], times[-1]
    if start.date() == end.date():
        return f"{start.strftime('%b')} {start.day}, {start.year}"
    if start.year == end.year and start.month == end.month:
        return f"{start.strftime('%b')} {start.day} \u2013 {end.day}, {end.year}"
    if start.year == end.year:
        return f"{start.strftime('%b')} {start.day} \u2013 {end.strftime('%b')} {end.day}, {end.year}"
    return f"{start.strftime('%b')} {start.day}, {start.year} \u2013 {end.strftime('%b')} {end.day}, {end.year}"


def save_detected_trip(photos: list[dict], name: str | None = None) -> dict:
    """Persist a single detected trip and all of its data."""
    create_database()

    if not name:
        name = _auto_name(photos)

    # Deduplicate near-identical photos
    deduped = _dedup_within_trip(photos)

    stops = _cluster_stops(deduped)

    # Diverse key photo selection across locations
    key_paths = _select_key_photos_diverse(deduped, stops)

    # Cover photo by composite score
    all_sharp = [p.get("sharpness", 0) for p in deduped]
    all_mp = [p.get("megapixels", 0) for p in deduped]
    ns = _normalize(all_sharp)
    nm = _normalize(all_mp)
    cover_idx = max(
        range(len(deduped)),
        key=lambda i: compute_composite_score(deduped[i], ns[i], nm[i]),
    )
    cover = deduped[cover_idx]

    times = sorted([p["timestamp"] for p in deduped if p.get("timestamp")])
    start_date = times[0].isoformat() if times else None
    end_date = times[-1].isoformat() if times else None

    trip_id = create_trip(
        name=name,
        start_date=start_date,
        end_date=end_date,
        cover_photo_path=cover["path"],
        total_photos=len(deduped),
        total_key_photos=len(key_paths),
    )

    photo_rows = []
    for p in deduped:
        photo_rows.append({
            "path": p["path"],
            "name": p["name"],
            "timestamp": p["timestamp"].isoformat() if p.get("timestamp") else None,
            "latitude": p.get("latitude"),
            "longitude": p.get("longitude"),
            "aesthetic_score": p.get("aesthetic_score"),
            "is_key_photo": p["path"] in key_paths,
        })

    save_trip_photos(trip_id, photo_rows)
    save_trip_locations(trip_id, stops)

    return {
        "trip_id": trip_id,
        "name": name,
        "start_date": start_date,
        "end_date": end_date,
        "total_photos": len(deduped),
        "total_key_photos": len(key_paths),
        "locations": len(stops),
        "cover_photo": cover["path"],
    }


def _overlaps_existing(start_iso: str | None, end_iso: str | None,
                       existing: list[dict]) -> bool:
    """True if a candidate trip's date range overlaps any existing trip."""
    if not start_iso or not end_iso:
        return False
    for t in existing:
        ex_start = t.get("start_date")
        ex_end = t.get("end_date")
        if not ex_start or not ex_end:
            continue
        # two ranges overlap when each starts before the other ends
        if start_iso <= ex_end and end_iso >= ex_start:
            return True
    return False


def detect_and_save_all(features_list: list[dict],
                        homes: list[dict] | None = None) -> list[dict]:
    """Run trip detection only on unassigned images. Mark everything after."""
    from database import (
        get_unassigned_images, get_image_ids_by_paths,
        mark_images_assigned, mark_images_excluded,
    )

    create_database()

    # Step 1: Get only unassigned image paths
    unassigned = get_unassigned_images()
    unassigned_paths = {img['file_path'] for img in unassigned}

    if not unassigned_paths:
        print("[trips] No new images to process.")
        return []

    # Step 2: Filter features_list to only unassigned photos
    new_features = [f for f in features_list if f.get("path") in unassigned_paths]

    if not new_features:
        print("[trips] No unassigned photos with features found.")
        return []

    print(f"[trips] Processing {len(new_features)} new images (skipping {len(features_list) - len(new_features)} already processed)")

    # Step 3: Run trip detection on new photos only
    existing = list_trips()
    trips = detect_trips(new_features, homes)

    # Build path → image_id lookup
    all_new_paths = [f["path"] for f in new_features]
    path_to_id = get_image_ids_by_paths(all_new_paths)

    results = []
    assigned_paths = set()
    skipped = 0

    for trip_photos in trips:
        times = sorted([p["timestamp"] for p in trip_photos if p.get("timestamp")])
        start_date = times[0].isoformat() if times else None
        end_date = times[-1].isoformat() if times else None

        trip_paths = [p["path"] for p in trip_photos]
        trip_image_ids = [path_to_id[p] for p in trip_paths if p in path_to_id]

        # Check if this overlaps an existing trip
        matched_existing = None
        for ex in existing:
            if _overlaps_existing(start_date, end_date, [ex]):
                matched_existing = ex
                break

        if matched_existing:
            # Add new photos to the existing trip
            mark_images_assigned(trip_image_ids, matched_existing["id"])
            assigned_paths.update(trip_paths)

            # Also save the photo rows to trip_photos table
            photo_rows = []
            for p in trip_photos:
                photo_rows.append({
                    "path": p["path"],
                    "name": p.get("name", ""),
                    "timestamp": p["timestamp"].isoformat() if p.get("timestamp") else None,
                    "latitude": p.get("latitude"),
                    "longitude": p.get("longitude"),
                    "aesthetic_score": p.get("aesthetic_score"),
                    "is_key_photo": False,
                })
            save_trip_photos(matched_existing["id"], photo_rows)

            # Update trip photo count
            conn = sqlite3.connect(DB_PATH)
            conn.execute("""
                UPDATE trips SET total_photos = (
                    SELECT COUNT(*) FROM trip_photos WHERE trip_id = ?
                ) WHERE id = ?
            """, (matched_existing["id"], matched_existing["id"]))
            conn.commit()
            conn.close()

            print(f"[trips] Added {len(trip_image_ids)} photos to existing trip '{matched_existing['name']}'")
            skipped += 1
            continue

        # Save as new trip
        summary = save_detected_trip(trip_photos)
        results.append(summary)

        # Mark images as assigned to the new trip
        mark_images_assigned(trip_image_ids, summary["trip_id"])
        assigned_paths.update(trip_paths)

        print(f"[trips] Saved NEW trip '{summary['name']}': "
              f"{summary['total_photos']} photos, "
              f"{summary['total_key_photos']} key, "
              f"{summary['locations']} stops")

    # Step 4: Mark remaining unassigned images as excluded (near home / too few)
    excluded_paths = unassigned_paths - assigned_paths
    excluded_ids = [path_to_id[p] for p in excluded_paths if p in path_to_id]
    if excluded_ids:
        mark_images_excluded(excluded_ids)
        print(f"[trips] Excluded {len(excluded_ids)} images (daily life / too few)")

    if skipped:
        print(f"[trips] {skipped} cluster(s) merged into existing trips")

    return results