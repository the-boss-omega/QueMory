"""
Trip summarization: reverse-geocode stops, build a structured prompt,
call Ollama (Gemma 4) to generate a short personal summary.
"""

import time
import urllib.request
import urllib.parse
import json
from collections import defaultdict
from datetime import datetime

from database import (
    get_trip_photos, get_trip_locations, list_trips,
    update_trip_description,
)

OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_MODEL = "gemma4:e4b"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/reverse"

_geocode_cache: dict[tuple[float, float], dict] = {}


def _reverse_geocode(lat: float, lon: float) -> dict:
    """Resolve lat/lon to city + country via Nominatim. Cached by ~1 km grid."""
    key = (round(lat, 2), round(lon, 2))
    if key in _geocode_cache:
        return _geocode_cache[key]

    params = urllib.parse.urlencode({
        "lat": lat, "lon": lon, "format": "json", "zoom": 10,
    })
    url = f"{NOMINATIM_URL}?{params}"
    req = urllib.request.Request(url, headers={"User-Agent": "QueMory/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
        addr = data.get("address", {})
        city = (addr.get("city") or addr.get("town")
                or addr.get("village") or addr.get("county") or "Unknown")
        country = addr.get("country", "Unknown")
        result = {"city": city, "country": country}
    except Exception:
        result = {"city": "Unknown", "country": "Unknown"}

    _geocode_cache[key] = result
    time.sleep(1)  # Nominatim rate limit
    return result


def _build_prompt(trip: dict, locations: list[dict], photos: list[dict],
                  user_notes: str | None = None) -> str:
    """Assemble a structured text prompt for the LLM."""
    lines = []

    # Header
    name = trip.get("name", "Untitled Trip")
    start = trip.get("start_date", "?")
    end = trip.get("end_date", "?")
    total = trip.get("total_photos", len(photos))
    key_count = trip.get("total_key_photos", 0)
    lines.append(f"Trip: \"{name}\"")
    lines.append(f"Dates: {start} to {end}")
    lines.append(f"Photos: {total} total, {key_count} key photos")

    # Duration
    try:
        dt_start = datetime.fromisoformat(start)
        dt_end = datetime.fromisoformat(end)
        days = (dt_end - dt_start).days + 1
        lines.append(f"Duration: {days} day{'s' if days != 1 else ''}")
    except (ValueError, TypeError):
        pass

    # Locations with geocoding
    if locations:
        lines.append("")
        lines.append("Locations visited:")
        for loc in locations:
            lat, lon = loc["latitude"], loc["longitude"]
            geo = _reverse_geocode(lat, lon)
            place = f"{geo['city']}, {geo['country']}"
            arrival = loc.get("arrival", "?")
            departure = loc.get("departure", "?")
            count = loc.get("photo_count", 0)
            lines.append(f"- {place} ({arrival} to {departure}, {count} photos)")

    # Distances between consecutive stops
    if len(locations) >= 2:
        lines.append("")
        lines.append("Travel between stops:")
        for i in range(len(locations) - 1):
            a, b = locations[i], locations[i + 1]
            geo_a = _reverse_geocode(a["latitude"], a["longitude"])
            geo_b = _reverse_geocode(b["latitude"], b["longitude"])
            from trips import _haversine_km
            dist = _haversine_km(a["latitude"], a["longitude"],
                                 b["latitude"], b["longitude"])
            lines.append(f"- {geo_a['city']} → {geo_b['city']}: {dist:.0f} km")

    # Origin breakdown
    origin_counts: dict[str, int] = defaultdict(int)
    for p in photos:
        origin_counts["total"] += 1
    # Time-of-day breakdown
    time_buckets = {"morning": 0, "afternoon": 0, "evening": 0, "night": 0}
    for p in photos:
        ts = p.get("timestamp")
        if ts:
            try:
                h = datetime.fromisoformat(ts).hour
            except (ValueError, TypeError):
                continue
            if 6 <= h < 12:
                time_buckets["morning"] += 1
            elif 12 <= h < 17:
                time_buckets["afternoon"] += 1
            elif 17 <= h < 21:
                time_buckets["evening"] += 1
            else:
                time_buckets["night"] += 1
    if any(time_buckets.values()):
        lines.append("")
        parts = [f"{k}: {v}" for k, v in time_buckets.items() if v > 0]
        lines.append(f"Photo timing: {', '.join(parts)}")

    # User notes
    if user_notes and user_notes.strip():
        lines.append("")
        lines.append(f"Personal notes from the traveler: \"{user_notes.strip()}\"")

    lines.append("")
    lines.append("Generate a warm, personal trip summary in 3-4 sentences. "
                 "Mention specific places visited. Do not list bullet points.")

    return "\n".join(lines)


def generate_summary(trip_id: int, user_notes: str | None = None) -> str | None:
    """Build prompt from DB data, call Ollama, save result. Returns the summary."""
    # Find trip metadata
    all_trips = list_trips()
    trip = None
    for t in all_trips:
        if t["id"] == trip_id:
            trip = t
            break
    if not trip:
        print(f"[summarize] Trip {trip_id} not found")
        return None

    locations = get_trip_locations(trip_id)
    photos = get_trip_photos(trip_id)
    prompt = _build_prompt(trip, locations, photos, user_notes)

    print(f"[summarize] Generating summary for trip '{trip['name']}'...")

    payload = json.dumps({
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
    }).encode()

    req = urllib.request.Request(
        OLLAMA_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode())
        summary = data.get("response", "").strip()
    except Exception as e:
        print(f"[summarize] Ollama call failed: {e}")
        return None

    if summary:
        update_trip_description(trip_id, summary)
        print(f"[summarize] Saved summary ({len(summary)} chars)")

    return summary
