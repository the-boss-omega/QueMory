# QueMory Codebase Report

This document is a practical walkthrough of the repo so you can understand:

1. what the app does end-to-end,
2. what every Python, C++ and Dart source file is responsible for,
3. how data moves between the backend, databases and Flutter UI,
4. where to add new features safely.

I focus on the repo's own source code, not third-party packages inside virtual environments or generated build outputs.

## 1. Big Picture

QueMory is a photo-trip app with three major jobs:

1. It ingests a folder of photos.
2. It analyzes and curates those photos using EXIF metadata, image quality checks, CLIP embeddings and some heuristics.
3. It turns the result into trips, analytics dashboards, semantic search results and a "wrapped" style summary.

At a system level there are four layers:

1. Flutter desktop UI in `my_app/my_app/lib`.
2. FastAPI backend in `backend/server.py`.
3. Analysis/business logic modules in `backend/*.py`.
4. SQLite databases in `backend/database/`.

There is also one custom C++ extension in `backend/calc/filter_core.cpp` that speeds up some of the image filtering work.

## 2. Core Runtime Flows

### F. Ben Aharon Marenkov Special flow (new)

This is a dedicated LLM-generated visual page for a single trip. It combines analytics data, real trip photos and a vision model to produce a unique, animated HTML page per trip.

1. The user opens a trip detail page in Flutter.
2. Flutter renders `BenAharonSpecialCard`, which creates a `WebViewController` in `initState`.
3. The WebView immediately GETs `http://localhost:8000/trips/{trip_id}/ben-aharon`.
4. `server.py` `api_ben_aharon_page`:
   - looks up the trip row (gets `name` and `description`),
   - calls `compute_all_analytics(trip_id)` to get the full analytics payload,
   - extracts `image_paths` from `analytics["key_photos"]["photos"]` (only `is_key: true` photos),
   - calls `generate_ben_aharon_html(trip_name, analytics, image_paths, description)`.
5. `generate_ben_aharon_html` in `summarize.py`:
   - builds a rich text prompt with trip stats, GPS points, photography DNA vibes, happiest day, face count, trip description and image count,
   - resizes and base64-encodes up to 5 key photos via `_encode_images()`,
   - POSTs both prompt and images to Ollama (`gemma4:e4b`) with a 180-second timeout,
   - strips markdown fences if the model wraps its output,
   - validates that the response starts with `<!DOCTYPE html>` or `<html>`,
   - falls back to the static CDN HTML from `analytic_ben_aharon_special()` in `analytics.py` if anything fails.
6. `server.py` returns the HTML as an `HTMLResponse`.
7. The WebView renders the page. Once loading is complete, the spinner disappears and the full animated, LLM-generated card is visible.

Key design decisions:

- The endpoint is a separate route so the analytics dashboard loads instantly while the WebView fetches the slow LLM page independently.
- The fallback ensures the feature is never broken from the user's perspective.
- The `?force=true` query parameter bypasses the analytics cache in case new photos were added to the trip.

### A. Manual trip creation flow

1. The user opens the Trips page.
2. Flutter shows a "New Trip" dialog.
3. Flutter sends `POST /trips` with:
   - a trip name,
   - optional notes,
   - optional folder path.
4. `server.py` calls `filter.curate(...)`.
5. `filter.py` scans the folder, rejects unusable images, extracts features, clusters near-duplicates, and returns:
   - `keep`,
   - `rejected_blank`,
   - `rejected_quality`,
   - `suggested_removals`.
6. `server.py` creates a trip row in SQLite via `database.create_trip(...)`.
7. `server.py` saves the kept photos to `trip_photos`.
8. `server.py` picks a cover photo.
9. `server.py` optionally asks `summarize.py` to generate a short natural-language trip summary.
10. Flutter adds the new trip card to its local list and can later open the full trip detail page.

### B. Automatic trip detection flow

1. The user taps the "detect trips" floating button on the Trips page.
2. Flutter sends `POST /detect-trips`.
3. `server.py` loads images from the default image folder.
4. For each image it:
   - rejects clearly bad files,
   - loads EXIF,
   - loads or computes a CLIP embedding,
   - builds a feature dictionary.
5. Those feature dictionaries go to `trips.detect_and_save_all(...)`.
6. `trips.py` groups photos into candidate trips by time gap, home-distance logic and implied travel speed.
7. Each trip is deduplicated again internally.
8. Each trip gets:
   - a generated title,
   - a cover photo,
   - a set of key photos,
   - clustered stop locations.
9. The backend writes the result into SQLite tables.
10. Flutter reloads the trip list and shows a snack bar telling the user how many new trips were created or merged.

### C. Search flow

1. The user types a natural-language query on the Query page.
2. Flutter sends `GET /search?q=...`.
3. `server.py` calls `clip_embed.search_expanded(...)` by default.
4. `clip_embed.py` optionally asks Ollama to rewrite the query into several shorter visual phrases.
5. CLIP text embeddings are compared against stored CLIP image embeddings in `embeddings.db`.
6. The top matching photos are returned to Flutter.
7. Flutter renders those images in a grid.

### D. Analytics flow

1. The user opens a trip.
2. Flutter calls `GET /trips/{trip_id}/analytics`.
3. `analytics.py` checks whether analytics for that trip are already cached in `trip_analytics`.
4. If cached and `force=false`, it returns the cached JSON immediately.
5. Otherwise it:
   - loads the trip's photos,
   - loads the corresponding CLIP embeddings,
   - computes every analytics card payload,
   - caches the final JSON blob,
   - returns it to Flutter.
6. `analytics_widgets.dart` renders that JSON into many visual cards.

### E. Wrapped flow

1. The user opens the Wrapped page.
2. Flutter calls `GET /wrapped/stats`.
3. `analytics.compute_wrapped_stats()` aggregates cross-trip data from SQLite.
4. Flutter animates those global stats as a "year in photos" view.

## 3. Data Model and Storage

There are two main SQLite databases.

### `backend/database/quemory.db`

This is the main application database. Important tables:

1. `images`
   - raw ingested image inventory,
   - remembers assignment status (`unassigned`, `assigned`, `excluded`),
   - links an image to a trip if it gets used.

2. `trips`
   - one row per trip,
   - stores metadata such as title, date range, cover photo, description and some face-summary fields.

3. `trip_photos`
   - one row per photo that belongs to a trip,
   - includes timestamp, GPS, aesthetic score and key-photo flag,
   - unique index on `(trip_id, file_path)` prevents duplicate photo rows inside one trip.

4. `trip_locations`
   - clustered stop points for a trip,
   - stores arrival/departure time windows and photo counts.

5. `home_locations`
   - user-defined "home" zones,
   - used to reduce false positives when auto-detecting trips.

6. `trip_analytics`
   - one cached analytics JSON blob per trip.

### `backend/database/embeddings.db`

This stores CLIP embeddings for individual images:

1. absolute file path,
2. file name,
3. binary embedding blob.

This database lets search and analytics reuse embeddings instead of recomputing them every time.

### `locations.json` (root)

Purpose:
A pre-computed reverse-geocoding lookup table for the photo collection.

Format:
A JSON array of objects. Each object has:

1. `filename` — the image file name.
2. `latitude` — decimal degrees.
3. `longitude` — decimal degrees.
4. `altitude` — metres above sea level.
5. `address` — reverse-geocoded address string (may be empty string).

Why it exists:
Reverse geocoding calls an external Nominatim API with a rate-limit delay. Pre-computing the results and storing them here avoids re-querying on every analytics run. `summarize.py`'s `_reverse_geocode()` caches to a 1-km grid in memory at runtime, but `locations.json` is the persistent on-disk complement.

Note:
This file is not loaded by the current server code at startup — it was likely generated by a one-off script. Its presence is informational; the active geocoding path goes through the in-memory cache in `_reverse_geocode()`.

### Empty scaffolding folders

Three root-level folders exist as placeholders for future work and contain no source files:

1. `terraform/` — intended for cloud infrastructure-as-code (e.g. Terraform HCL modules for deployment).
2. `web/` — intended for a browser-facing frontend (separate from the Flutter `web/` build target inside `my_app/`).
3. `database/` — a root-level empty folder, distinct from `backend/database/` where the real SQLite files live.

## 4. Backend File-by-File

### `backend/server.py`

Purpose:
This is the FastAPI entrypoint. It exposes HTTP endpoints and glues the UI to the backend logic.

What happens step by step:

1. It creates the FastAPI app.
2. It enables wide-open CORS so the Flutter frontend can call it freely.
3. It calls `create_database()` at import time so tables exist before requests arrive.
4. It keeps a small in-memory cache for converted HEIC/HEIF display files.
5. It defines request models:
   - `CreateTripRequest`
   - `HomeLocationRequest`
6. It exposes these endpoints:
   - `/search`
   - `/embed`
   - `/curate`
   - `/trips` (create and list)
   - `/trips/{id}/photos`
   - `/trips/{id}/locations`
   - `/detect-trips`
   - `/home-locations`
   - `/trips/{id}/analytics`
   - `/trips/{id}/add-photos`
   - `/wrapped/stats`
   - `/image`
   - `/trips/{id}/ben-aharon` ← **new**

Important design detail:
`_get_display_path(...)` converts HEIC/HEIF files to temporary JPEGs for display, but it leaves the original files alone.

#### `/trips/{trip_id}/ben-aharon` endpoint (new)

This endpoint generates and serves the Ben Aharon Marenkov Special page as raw HTML.

Step-by-step:

1. Accepts `trip_id` (path param) and `force` (query param, default false).
2. Looks up the trip row from SQLite via `list_trips()`. Returns 404 if not found.
3. Calls `compute_all_analytics(trip_id, force=force)` to get the full analytics payload.
   - If `force=true`, the analytics cache is bypassed and recomputed.
4. Extracts `image_paths` — only photos marked `is_key: true` from the `key_photos` analytics section.
5. Calls `generate_ben_aharon_html(trip_name, analytics, image_paths, description)` from `summarize.py`.
   - Also passes `trip['description']` (the LLM-generated trip summary) for richer context.
6. Returns the resulting HTML string as an `HTMLResponse`.

Why the endpoint is its own route and not embedded in `/analytics`:
The page generation is slow (180-second LLM timeout) and produces raw HTML rather than JSON. Separating it means the analytics dashboard loads instantly while the WebView card fetches this page independently in the background.

Why `force` matters here:
Key photos and analytics data are cached. If the user adds photos to a trip after the first load, passing `?force=true` ensures the Ben Aharon page reflects the latest data.

Why this file matters for extension work:
If you want a new frontend feature that needs backend data, this is where the new endpoint usually gets added.

### `backend/database.py`

Purpose:
All SQLite schema creation and CRUD-like helpers live here.

What it does:

1. Creates the database folder and all tables.
2. Applies a few lightweight schema migrations for older DBs.
3. Removes duplicate trip photo rows and enforces a uniqueness index.
4. Provides helpers to:
   - mark images assigned/excluded,
   - save new raw images,
   - create trips,
   - save trip photos,
   - save trip locations,
   - list trips,
   - read trip photos/locations,
   - add home locations,
   - update trip description,
   - update frequent face metadata,
   - append new photos to a trip,
   - refresh the trip cover photo.

How to think about it:
This file does not decide what a trip is. It only persists and retrieves the results of decisions made elsewhere.

Important coupling:

1. `trips.py` depends on it for storing detected trips.
2. `analytics.py` depends on the tables it defines.
3. `summarize.py` reads trip photos and locations from here.
4. `server.py` uses these functions for most request handlers.

### `backend/clip_embed.py`

Purpose:
This module owns CLIP image embeddings and semantic image search.

Step-by-step behavior:

1. It loads CLIP (`ViT-B/32`) once at import time.
2. It chooses GPU if available, otherwise CPU.
3. It creates and maintains `embeddings.db`.
4. `save_all_embeddings()`:
   - scans the default image folder,
   - skips files already embedded,
   - preprocesses each image for CLIP,
   - computes a normalized embedding,
   - stores it as a binary blob.
5. `search()`:
   - encodes the raw query with CLIP text encoder,
   - computes cosine similarity against every stored image embedding,
   - returns the top results.
6. `_expand_query()`:
   - calls Ollama,
   - asks it to rewrite a complex query into shorter visual phrases.
7. `search_expanded()`:
   - embeds each rewritten phrase,
   - averages those vectors,
   - scores images using the averaged vector.

Why it exists separately from `filter.py`:
Embeddings are useful for both curation and search, so this file centralizes that shared resource.

### `backend/face.py`

Purpose:
This module handles face detection, face embedding and face clustering.

Step-by-step behavior:

1. It defines absolute paths to two ONNX models in `backend/models`.
2. `_ensure_models_loaded()` lazily loads those models only when face logic is actually used.
3. `extract_faces_for_embedding(...)`:
   - reads an image with OpenCV,
   - detects faces with YuNet,
   - aligns each face crop using SFace,
   - returns face crops and bounding boxes.
4. `faces_to_embeddings(...)`:
   - converts aligned faces into numeric face embeddings.
5. `cluster_embeddings(...)`:
   - normalizes embeddings,
   - runs DBSCAN using cosine distance,
   - annotates each item with a `cluster_id`,
   - returns the dominant face cluster.
6. `find_top_face(...)`:
   - processes all images in a trip,
   - clusters all faces,
   - returns one representative image/bbox/count for the most frequent person.

Important runtime dependency:
This module expects both model files to exist:

1. `face_detection_yunet_2023mar.onnx`
2. `face_recognition_sface_2021dec.onnx`

### `backend/metadata.py`

Purpose:
This is the EXIF and image-metadata toolkit used across the project.

What it extracts:

1. `get_exif()` returns a readable EXIF dict.
2. `extract_when()` returns date and timezone information.
3. `extract_where()` returns GPS, speed, direction and reverse-geocoded address.
4. `extract_camera()` returns make/model/lens/settings.
5. `extract_image_properties()` returns dimensions, megapixels, aspect ratio and color space.
6. `extract_software()` guesses whether an image is:
   - self-shot,
   - edited,
   - received/downloaded,
   - screenshot.
7. `compute_phash()` creates a small perceptual hash for duplicate detection.

Why this file matters:
It provides the non-ML metadata foundation for:

1. filtering,
2. trip detection,
3. analytics,
4. summary generation.

There are also several console helper functions at the bottom for printing or exporting metadata. Those are mostly utility/debug functions rather than core runtime API.

### `backend/filter.py`

Purpose:
This is the curation engine. Given a folder of photos, it decides which photos are worth keeping.

The pipeline is explicitly organized into phases.

#### Phase 0: early rejection

Goal:
Reject obviously bad images before expensive analysis.

How it works:

1. Open image in grayscale.
2. Resize to 256x256.
3. Measure variance and entropy.
4. Reject if too blank, too uniform or unreadable.
5. Use the C++ extension if available, otherwise use Python fallback.

#### Phase 1: feature extraction

For each surviving image:

1. Read EXIF with `metadata.py`.
2. Load cached CLIP embedding if available.
3. If missing, compute CLIP embedding on the fly.
4. Compute:
   - timestamp,
   - latitude/longitude,
   - megapixels,
   - origin classification,
   - pHash,
   - sharpness,
   - exposure quality,
   - contrast,
   - saturation,
   - noise,
   - aesthetic score from CLIP prompt comparisons.

#### Phase 1b: quality gate

It rejects images if:

1. sharpness is too low,
2. exposure quality is too low,
3. timestamp is missing.

#### Phase 2: tri-axis clustering

The code clusters images in three different spaces:

1. time (`cluster_temporal`)
2. geography (`cluster_geographic`)
3. visual similarity (`cluster_visual`)

The visual clustering uses either:

1. the C++ accelerated implementation, or
2. a Python union-find implementation using CLIP cosine similarity and pHash Hamming distance.

#### Phase 3: merged cluster keys

The final duplicate-group key is:

`(temporal_cluster, geographic_cluster, visual_cluster)`

So two images are considered together only when they align across all three axes.

#### Phase 4: ranking and selection

For each duplicate group:

1. Normalize sharpness and megapixels.
2. Compute a composite score using:
   - aesthetic score,
   - sharpness,
   - exposure,
   - saturation,
   - megapixels,
   - origin multiplier.
3. Keep the highest-scoring photo.
4. Record the rest as suggested removals.

#### Final binary-search step

If there are still too many photos, the code binary-searches the temporal gap threshold to reduce the result toward `TARGET_IMAGES`.

Final output:

1. `keep`
2. `rejected_blank`
3. `rejected_quality`
4. `suggested_removals`

This is one of the most important files in the whole repo because it decides the input quality of almost every later feature.

### `backend/trips.py`

Purpose:
This module transforms curated photo features into trips.

Core idea:
Trips are inferred from time, travel distance, home zones and merge heuristics.

Step-by-step:

1. `detect_trips(...)`
   - sorts photos by timestamp,
   - splits them into candidates when the time gap is large,
   - merges adjacent candidates if:
     - the gap is not too large,
     - the endpoints are not in a home zone,
     - implied travel speed is reasonable.

2. `_cluster_stops(...)`
   - clusters GPS points inside one trip into stop locations.

3. `_dedup_within_trip(...)`
   - reuses the filter clustering logic to remove near-duplicates inside a trip.

4. `_select_key_photos_diverse(...)`
   - chooses key photos,
   - tries to spread them across stops,
   - falls back to best-scoring photos when no stop structure exists.

5. `_auto_name(...)`
   - generates a date-based trip title when the user did not give one.

6. `save_detected_trip(...)`
   - creates the trip row,
   - stores deduplicated photos,
   - stores locations,
   - stores cover/key-photo counts.

7. `detect_and_save_all(...)`
   - only processes images marked `unassigned`,
   - detects new trips,
   - merges overlapping clusters into existing trips when appropriate,
   - marks leftovers as `excluded`.

Why it matters:
This is the domain layer that turns "a pile of photos" into "a set of trips."

### `backend/summarize.py`

Purpose:
This file has two distinct jobs:

1. Generate a plain-text trip summary with `generate_summary()`.
2. Generate the Ben Aharon Marenkov Special HTML page with `generate_ben_aharon_html()` (new).

Both jobs call the same local Ollama model (`gemma4:e4b`) at `http://localhost:11434/api/generate`.

#### Shared setup

```python
import base64
import io
import time
import urllib.request
import urllib.parse
import json
```

`base64` and `io` are needed for the vision-model image encoding path.
`urllib.request` is used for all Ollama and Nominatim HTTP calls — no third-party HTTP library is required.

```python
OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_MODEL = "gemma4:e4b"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/reverse"
```

All LLM and geocoding endpoints are defined as module-level constants, making them easy to change.

```python
_geocode_cache: dict[tuple[float, float], dict] = {}
```

In-process cache for reverse-geocode results. The key is `(rounded_lat, rounded_lon)` to a ~1 km grid, preventing duplicate Nominatim requests for nearly identical coordinates.

#### `_reverse_geocode(lat, lon)`

Step-by-step:

1. Round both coordinates to 2 decimal places and check the cache.
2. Build a Nominatim request with `format=json` and `zoom=10` (city-level).
3. Parse the response for `city`, `town`, `village`, `county`, or `Unknown`.
4. Sleep 1 second to respect the Nominatim rate limit (1 req/sec).
5. Cache and return the result.

This function is used only by `_build_prompt()` for the plain-text summary path.

#### `_build_prompt(trip, locations, photos, user_notes)` — plain text summary

Assembles everything the LLM needs to write a warm travel summary.

Block-by-block:

1. **Header block** — trip name, date range, total photos, key-photo count.
2. **Duration block** — computed from ISO date strings; skipped if dates are unparseable.
3. **Locations block** — reverse-geocodes each stop and lists arrival/departure times and photo counts.
4. **Distances block** — only appears when there are 2+ stops; computes haversine km between consecutive stops.
5. **Time-of-day block** — counts photos in four buckets (morning 6–12, afternoon 12–17, evening 17–21, night otherwise).
6. **User notes block** — appended verbatim if the user provided notes.
7. **Instruction line** — tells the model to write 3–4 warm sentences mentioning specific places, no bullet points.

#### `generate_summary(trip_id, user_notes)` — plain text summary

Step-by-step:

1. Find the trip row in SQLite.
2. Load stop locations and all trip photos.
3. Call `_build_prompt(...)` to produce the text prompt.
4. POST to Ollama with `stream: false` and a 120-second timeout.
5. Extract `response` from the JSON reply.
6. Save the result to the `trips.description` column via `update_trip_description()`.
7. Return the summary string (or `None` on failure).

This is called automatically on `/trips` POST (trip creation).

---

#### Ben Aharon Marenkov Special (new)

These three functions implement the LLM-generated visual HTML page feature.

#### `_build_ben_aharon_prompt(trip_name, analytics, image_paths, description)` (new)

Builds the text portion of the vision-model request. Unlike `_build_prompt()`, this one reads pre-computed analytics payloads instead of raw DB rows, so it does not need to touch the database or do geocoding.

Block-by-block:

1. **Trip name** — always first line.
2. **Description block** — the LLM-generated trip summary (if it exists), added immediately after the name. This gives the model the full narrative context before it sees any stats.
3. **Trip stats block** — reads `analytics["trip_stats"]` for duration days, date range, photo count and distance in km.
4. **Locations block** — reads `analytics["map_of_photos"]["points"]` and samples up to 5 GPS coordinates. The model uses these to infer the region and shape the color palette.
5. **Photography DNA block** — reads `analytics["photography_dna"]["vibes"]` and sends the top 3 CLIP-derived vibe labels (e.g. `"Golden hour, Architecture, Forest"`). This is the richest creative hint for gradient colors and the tagline.
6. **Emotional tone block** — reads `analytics["emotional_timeline"]["happiest_day"]`. Influences the tagline tone.
7. **Inner circle block** — reads `analytics["inner_circle"]["faces"]` and tells the model whether this was a solo or group trip.
8. **Image count hint** — if `image_paths` is non-empty, tells the model in text how many photos are attached. The actual pixels arrive separately in the Ollama `images` field, not inline in this text block.
9. **Instruction block** — the full creative brief:
   - dark cinematic gradient,
   - large trip name using only system/inline fonts (NO CDN links),
   - 2–3 CSS animations (orbs, shimmer, fade-in),
   - one poetic tagline derived from the data,
   - all CSS in a `<style>` block,
   - return ONLY raw `<!DOCTYPE html>` — no markdown, no explanation.

#### `_encode_images(paths, max_images=5, max_px=512)` (new)

Converts real photo files into base64 strings suitable for the Ollama `images` field.

Step-by-step for each path:

1. Open with Pillow and convert to RGB (handles HEIC alpha channels and palette modes).
2. `img.thumbnail((512, 512))` — shrinks the longest side to 512px while preserving aspect ratio. In-place, non-destructive to the file.
3. Write to an in-memory `io.BytesIO` buffer as JPEG at quality 75.
4. `base64.b64encode(buf.getvalue()).decode("utf-8")` — produces a plain ASCII string.
5. Append to the result list.

Why max 5 images:
Each 512px JPEG is roughly 50–200 KB of base64 data. At 5 images the payload is ~1–3 MB — within Ollama's context window and well inside the 180-second timeout. The model's creative output (gradient, tagline) does not meaningfully improve past 5 representative photos. The limit is a default parameter and can be overridden.

Why resize:
Vision models encode images into hundreds of tokens each. Sending full-resolution photos (3–12 MB) would exhaust the context window and cause timeouts.

#### `generate_ben_aharon_html(trip_name, analytics, image_paths, description)` (new)

The orchestrator. Calls the prompt builder and image encoder, sends both to Ollama, and handles the response.

Step-by-step:

1. Call `_build_ben_aharon_prompt(...)` to get the text prompt string.
2. Call `_encode_images(image_paths)` to get the base64 image list.
3. Assemble the Ollama payload:
   ```json
   { "model": "gemma4:e4b", "prompt": "...", "images": [...], "stream": false }
   ```
   The `images` list is what activates the vision pathway — the model receives text + pixels simultaneously.
4. POST to Ollama with a 180-second timeout.
5. Extract `data["response"]` and strip leading/trailing whitespace.

**Markdown fence stripping:**
```python
if html.startswith("```"):
    html = html.split("```", 2)[1]
    if html.startswith("html"):
        html = html[4:]
    html = html.rsplit("```", 1)[0].strip()
```
Models often wrap code blocks in ` ```html ... ``` `. This block surgically removes those fences so only raw HTML remains.

**Sanity check:**
```python
if not html.lower().startswith("<!doctype") and not html.startswith("<html"):
    raise ValueError(...)
```
If what came back is not HTML (e.g. the model apologized or explained instead of generating), this intentionally raises so the except block fires immediately.

**Fallback:**
```python
except Exception as e:
    from analytics import analytic_ben_aharon_special
    html = analytic_ben_aharon_special(trip_name)["html"]
```
If anything fails — timeout, network error, bad output — the function silently falls back to the hardcoded CDN HTML template in `analytics.py`. The Flutter app never sees an error; it just gets the static fallback instead of the LLM-generated page.

### `backend/analytics.py`

Purpose:
Compute all per-trip analytics cards and cache them.

Structure:

1. helper functions
2. one function per analytics card
3. cache management
4. one main entry point
5. one global wrapped-stats entry point

How analytics are built:

1. load trip photos,
2. load CLIP embeddings,
3. run each `analytic_*` function,
4. assemble the full result map,
5. cache it.

Important analytics functions:

1. `analytic_map_of_photos`
   - all geotagged photos as map markers.

2. `analytic_inner_circle`
   - dominant recurring faces across the trip.

3. `analytic_food_map`
   - food count plus "top food type" based on CLIP prompts.

4. `analytic_photographers_growth`
   - aesthetic score trend over time with letter grades.

5. `analytic_emotional_timeline`
   - smile-likelihood trend by day.

6. `analytic_world_footprint`
   - total travel distance and a coarse GPS heatmap.

7. `analytic_pet_report_card`
   - best and worst pet photos.

8. `analytic_chasing_sunsets`
   - sunset/golden-hour leaderboard.

9. `analytic_time_machine`
   - places revisited across separate trips.

10. `analytic_photo_timeline_heatmap`
    - contribution-graph style photo counts by day.

11. `analytic_hours_of_day_wheel`
    - what times of day photos are usually taken.

12. `analytic_trip_stats`
    - distance, count, duration and date range.

13. `analytic_camera_usage`
    - device usage percentages.

14. `analytic_top_locations`
    - repeat locations across multiple trips.

15. `analytic_trip_duration_ranking`
    - compare durations across trips.

16. `analytic_photography_dna`
    - CLIP-prompt-based vibe distribution.

17. `analytic_night_owl`
    - late-night photo report.

18. `analytic_key_photos`
    - gallery payload for key/all trip photos.

19. `analytic_ben_aharon_special`
    - generates the **static fallback HTML template** used when the LLM call in `summarize.generate_ben_aharon_html()` fails.
    - returns `{"type": "ben_aharon_special", "html": html, "trip_name": trip_name}`.
    - the HTML uses Sora (Google Fonts CDN), Animate.css, floating CSS orbs and glassmorphism card styling.
    - under normal operation this function is never called directly from the endpoint — it is only called from the `except` block in `generate_ben_aharon_html()`.

Cache logic:

1. `get_cached_analytics(...)`
2. `cache_analytics(...)`
3. `invalidate_cache(...)`

Main entry points:

1. `compute_all_analytics(trip_id, force=False)`
2. `compute_wrapped_stats()`

This file is the backend partner of `analytics_widgets.dart`.

## 5. C++ Extension

### `backend/calc/setup.py`

Purpose:
Build configuration for the C++ extension.

What it does:

1. imports `Pybind11Extension`,
2. chooses compiler flags based on platform,
3. builds the `filter_core` extension from `filter_core.cpp`.

### `backend/calc/filter_core.cpp`

Purpose:
This is a pybind11 module that accelerates expensive numeric work from `filter.py`.

What it implements:

1. `phase0_check(...)`
   - computes variance and entropy in C++,
   - returns whether an image should be rejected early.

2. pixel feature functions:
   - `compute_sharpness`
   - `compute_noise`
   - `compute_exposure_quality`
   - `compute_contrast`
   - `compute_saturation`
   - `compute_all_pixel_features`

3. `cluster_visual_cpp(...)`
   - computes a full similarity matrix for embeddings,
   - uses union-find to merge visually similar items,
   - also uses perceptual hash Hamming distance,
   - returns sequential cluster labels.

4. `PYBIND11_MODULE(filter_core, m)`
   - exposes the C++ functions as Python-callable functions.

Why this matters:
Without this extension, the app still works, but `filter.py` falls back to slower Python implementations.

## 6. Flutter File-by-File

### `my_app/my_app/pubspec.yaml`

Purpose:
The Flutter package manifest. Declares the app version, SDK constraints and all dependencies.

Key fields:

1. `version: 1.0.0+1` — app version number.
2. `environment: sdk: ^3.11.0` — requires Dart 3.11+.

Dependencies (direct):

| Package | Version | Purpose |
|---------|---------|----------|
| `google_fonts` | `^6.3.2` | Sora font used throughout the app |
| `flutter_map` | `^7.0.2` | OpenStreetMap tile maps for `MapOfPhotosCard` and trip routes |
| `latlong2` | `^0.9.1` | Lat/lon point type required by `flutter_map` |
| `http` | `^1.2.2` | All backend API calls |
| `file_picker` | `^8.0.0` | Folder selection dialog in the "New Trip" flow |
| `url_launcher` | `^6.3.0` | Opens external links (e.g. Instagram share) |
| `share_plus` | `^10.0.0` | Native OS share sheet for exporting trip content |
| `path_provider` | `^2.1.0` | Platform-safe temp directory access |
| `webview_flutter` | `^4.10.0` | Embeds `BenAharonSpecialCard`'s WebView on all platforms |

Note:
`share_plus` and `path_provider` are not currently used in any active code path — they were added in preparation for a future share-as-image feature.

### `my_app/my_app/lib/main.dart`

Purpose:
Flutter app entrypoint and landing page.

What it does:

1. `main()` calls `runApp`.
2. `MyApp` builds the top-level `MaterialApp`.
3. The app theme uses Google Sora fonts and a seeded color scheme.
4. `MyHomePage` is a simple welcome screen.
5. Pressing "Proceed" pushes `AppShell`.

This file is small and mostly about bootstrapping and first impression.

### `my_app/my_app/lib/app_shell.dart`

Purpose:
Bottom-navigation shell for the whole app.

What it does:

1. Keeps `_currentIndex` state.
2. Builds an `IndexedStack` so tabs stay alive when switching.
3. Defines five tabs:
   - Share placeholder
   - Trips
   - Query
   - Wrapped
   - Settings placeholder
4. Renders the bottom navigation bar.

This is the top-level navigation coordinator for the Flutter app.

### `my_app/my_app/lib/query.dart`

Purpose:
Semantic search screen.

Main responsibilities:

1. Hold the search text controller.
2. Send the query to `/search`.
3. Show loading state.
4. Display search result images.
5. Animate a decorative rotating globe background.

Step-by-step:

1. `initState()` starts a repeating animation controller.
2. `_performSearch()`:
   - trims text,
   - calls backend search,
   - parses JSON,
   - updates `_searchResults`.
3. The page layout shows:
   - a huge "Query" title,
   - a text field,
   - a gradient search button,
   - a custom-painted globe,
   - a wrap/grid of returned images.

Interesting custom logic:

1. `_Point3D` is a tiny data class.
2. `GlobePainter` procedurally generates 3D points on a sphere.
3. It rotates them, projects them into 2D and colors them to resemble land/water.

This file mixes business behavior (search) with a strong decorative visual effect.

### `my_app/my_app/lib/wrapped.dart`

Purpose:
Global "year in photos" summary page.

What it does:

1. Loads `/wrapped/stats` from the backend.
2. Stores:
   - `_stats`
   - `_loading`
   - `_error`
3. Animates the page in with an `AnimationController`.
4. Shows:
   - headline,
   - four animated stat cards,
   - best photo card.

Key class:

1. `_StatCard`
   - reusable animated card used in the stat grid.

This file is a narrow UI wrapper around `analytics.compute_wrapped_stats()`.

### `my_app/my_app/lib/trips.dart`

Purpose:
This is the biggest interactive screen in the app. It handles trip discovery, trip creation, trip details, analytics display and the mini wrapped-story experience.

Main classes:

1. `TripsPage`
2. `_TripsPageState`
3. `_BigSquareButton`
4. `_TripDetailPage`
5. `_EmptyState`
6. `_QuickActionsState`
7. `_DefaultEmptyState`
8. `_RoutePainter`
9. `_TripWrappedStory`

#### `TripsPage` and `_TripsPageState`

Responsibilities:

1. load trip list from `/trips`,
2. trigger automatic trip detection with `/detect-trips`,
3. show two FAB-like actions:
   - detect trips
   - add trip

The "new trip" dialog flow:

1. collects title,
2. lets the user choose a folder,
3. accepts freeform notes,
4. posts to `/trips`,
5. appends the newly created trip to `_trips`,
6. closes the dialog.

#### `_BigSquareButton`

Purpose:
Visual tile for one trip in the grid/wrap list.

Behavior:

1. renders cover photo or fallback gradient,
2. renders trip name,
3. opens `_TripDetailPage` with a custom slide/fade transition.

#### `_TripDetailPage`

Purpose:
This is the trip detail and analytics dashboard page.

Main behaviors:

1. loads trip analytics from `/trips/{id}/analytics`,
2. can force-refresh analytics,
3. can add more photos to the trip through `/trips/{id}/add-photos`,
4. can open an Instagram share intent,
5. can launch the wrapped-story view,
6. renders:
   - collapsing hero header with cover image,
   - optional notes panel,
   - analytics section,
   - status-update CTA.

Important helper:

`_buildAnalyticsCards(...)` maps backend JSON sections directly to the corresponding widgets in `analytics_widgets.dart`.

#### `_EmptyState`, `_QuickActionsState`, `_DefaultEmptyState`

These classes decide what Trips page body to show:

1. empty illustration/instructions when there are no trips,
2. a wrapping list of trip tiles otherwise.

#### `_RoutePainter`

This is the decorative dashed route graphic used in the empty state.

#### `_TripWrappedStory`

Purpose:
A lightweight Instagram-style story view for one trip.

Step-by-step:

1. page 1 shows the intro title.
2. page 2 shows:
   - a route map,
   - stop markers,
   - a photo viewer with metadata.
3. tapping advances the story.
4. finishing closes the route/story screen.

This class is a pure frontend storytelling layer built from analytics data.

### `my_app/my_app/lib/analytics_widgets.dart`

#### `BenAharonSpecialCard` (new, detailed)

This is the only card that is **not** a pure rendering widget. It owns live network I/O via a `WebViewController`.

```dart
class BenAharonSpecialCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final int tripId;
  ...
}
```

It accepts both the analytics payload `data` (for potential future use) and `tripId` (the actual trip ID integer needed to build the URL).

**`initState()` block:**
```dart
_controller = WebViewController()
  ..setJavaScriptMode(JavaScriptMode.unrestricted)
  ..setNavigationDelegate(
    NavigationDelegate(
      onPageFinished: (_) => setState(() => _loading = false),
    ),
  )
  ..loadRequest(
    Uri.parse('http://localhost:8000/trips/\${widget.tripId}/ben-aharon'),
  );
```

1. A `WebViewController` is created once in `initState` — it lives for the lifetime of the widget.
2. JavaScript is enabled (`unrestricted`) so CSS animations in the LLM-generated HTML work correctly.
3. `onPageFinished` flips `_loading` to false, which removes the loading spinner from the stack.
4. `loadRequest` immediately fires the HTTP GET to the backend. The backend call triggers the full analytics + LLM pipeline for this trip.

**`build()` block:**
```dart
SizedBox(
  height: 300,
  child: ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Stack(
      children: [
        WebViewWidget(controller: _controller),
        if (_loading)
          const Center(child: CircularProgressIndicator(color: Colors.white54)),
      ],
    ),
  ),
)
```

1. The card is fixed at 300px tall inside the standard `AnalyticCard` frame.
2. `ClipRRect` clips the WebView to match the card's rounded corners.
3. A `Stack` overlays the spinner on top of the WebView until the page finishes loading.
4. Once `_loading` becomes false the spinner disappears and the full LLM-generated page is visible — dark gradient, trip name, CSS animations and all.

#### `_SparklinePainter`

Custom `CustomPainter` that draws a simple line chart from a `List<double>` of values. Used by `EmotionalTimelineCard` and `PhotographersGrowthCard`.

#### `_ClockChartPainter`

Custom `CustomPainter` that draws a 24-segment radial chart for `HoursOfDayWheelCard`. Each segment's radius is proportional to the shot count for that hour.

This file is a pure rendering layer. It contains no HTTP calls and no business logic.

## 7. Bugs Found and Fixes Applied

Six bugs were identified and fixed during this review. Each fix is described below with the file, the problem and the resolution.

---

### Fix 1 — `backend/filter.py`: missing fields in curated output

**File:** `backend/filter.py`, function `curate()`

**Problem:**
The `keep` list was built with only `path` and `name`. The caller (`server.py`) then tried to read `timestamp`, `latitude`, `longitude` and `aesthetic_score` from each kept-photo dict. Those keys were absent, silently producing `None` values for every kept photo's metadata when saving to the database.

**Fix:**
Extended the list comprehension so that each dict in `keep` now includes `timestamp`, `latitude`, `longitude` and `aesthetic_score`, pulled from the corresponding entry in `features_list`.

---

### Fix 2 — `backend/summarize.py`: dead code block in `_build_prompt()`

**File:** `backend/summarize.py`, function `_build_prompt()`

**Problem:**
A dead block computed `origin_counts` but the variable was never used in the prompt or returned. It iterated over all photos on every summary call for no reason.

**Fix:**
Removed the dead `origin_counts` accumulation block.

---

### Fix 3 — `backend/database.py`: hardcoded absolute path in `fetch_images()`

**File:** `backend/database.py`, function `fetch_images()`

**Problem:**
The function connected to a hardcoded path `r"D:\\Proj\\QueMory2\\backend\\database\\quemory.db"` instead of using the module-level `DB_PATH` constant. This meant the function would silently fail or error on any machine or path other than the original developer's setup.

**Fix:**
Replaced the hardcoded string with `DB_PATH`.

---

### Fix 4 — `my_app/my_app/lib/trips.dart`: `notes` / `description` field mismatch

**File:** `my_app/my_app/lib/trips.dart`

**Problem:**
The backend `list_trips()` returns a `description` field (the LLM-generated summary). The Flutter code was reading `t['notes']` when loading the trip list and `data['notes']` after creating a new trip. The `_TripDetailPage` was also reading `tripData['notes']` to show the description in the UI. These keys did not match the backend response, so the description was always null and was never displayed.

**Note:** The POST body to `/trips` correctly sends `'notes': notes` as the user's input notes. That was not changed — it is intentional; the server reads `req.notes` as the Ollama prompt input.

**Fix:**
Three locations updated:
- `_loadTrips()`: `t['notes']` → `t['description']`
- Post-creation handler: `data['notes']` → `data['description']`
- `_TripDetailPage.build()`: `tripData['notes']` → `tripData['description']`

---

### Fix 5 — `my_app/my_app/lib/trips.dart`: dead commented method

**File:** `my_app/my_app/lib/trips.dart`

**Problem:**
A large commented-out `_detectTrips()` method was left in the file. Its logic had been superseded by the active `_runDetectTrips()` method. The dead code added noise and could confuse future readers.

**Fix:**
Removed the entire commented-out block.

---

### Fix 6 — `my_app/my_app/lib/query.dart`: `print()` calls in release code

**File:** `my_app/my_app/lib/query.dart`, function `_performSearch()`

**Problem:**
Four bare `print()` calls were used for debug output. In Flutter, `print()` bypasses the framework logging infrastructure and is a lint violation (`avoid_print`). It also means log output appears in production builds without any filtering mechanism.

**Fix:**
All four `print()` calls replaced with `debugPrint()`, which is the Flutter-idiomatic alternative and is automatically a no-op in release mode.

---

## 8. Known Issues Not Fixed

### Missing SFace model file

**File:** `backend/face.py`, function `_ensure_models_loaded()`

**Issue:**
The code loads two ONNX model files:

1. `face_detection_yunet_2023mar.onnx` — confirmed present in `backend/models/`.
2. `face_recognition_sface_2021dec.onnx` — **not confirmed present**.

If this file is absent, `_ensure_models_loaded()` will raise a `cv2.error` at runtime the first time any analytics card that calls `analytic_inner_circle` is requested.

**Resolution:**
Download `face_recognition_sface_2021dec.onnx` from the OpenCV model zoo and place it in `backend/models/`.

---

### `_heic_cache` is unbounded

**File:** `backend/server.py`

**Issue:**
`_heic_cache` is a plain Python `dict` that grows without limit. In a long-running process with many unique HEIC files this is a memory leak.

**Resolution (not applied):**
Replace with a size-bounded LRU structure such as `functools.lru_cache` or `cachetools.LRUCache`.

---

### `display_photos` computed but not returned

**File:** `backend/server.py`, `api_create_trip()`

**Issue:**
The variable `display_photos` is computed after curation but is not included in the response body. This is dead work on every trip creation call.

**Resolution (not applied):**
Either include `display_photos` in the response, or remove the computation.


Architecture:

1. `AnalyticCard` provides the shared card frame.
2. `_noData(...)` provides consistent empty-state text.
3. each analytics card widget corresponds to one backend analytics payload.
4. helper widgets and custom painters support the cards.

Design observation:
This file is intentionally coupled to `analytics.py` by payload shape. If you add a new analytics backend section, this is where its card would usually be added.

### `my_app/my_app/test/widget_test.dart`

Purpose:
Default Flutter sample test.

What it currently does:

1. pumps `MyApp`,
2. expects counter-app behavior (`0`, `1`, plus button).

Reality:
The actual app is no longer a counter app, so this file is stale boilerplate and does not describe the current UI.

## 7. Native Flutter Runner Files

These files are not your app logic. They are platform-host bootstrap code created by Flutter and lightly customized by the platform templates.

### Linux runner

#### `my_app/my_app/linux/runner/main.cc`

Very small entrypoint that creates `MyApplication` and runs it.

#### `my_app/my_app/linux/runner/my_application.h`

Declares the GTK application class used by the runner.

#### `my_app/my_app/linux/runner/my_application.cc`

What it does:

1. creates a GTK application window,
2. configures header bar behavior,
3. sets default size,
4. creates a Flutter view,
5. registers plugins,
6. shows the window after the first rendered frame.

This is standard Flutter Linux host code.

#### `my_app/my_app/linux/flutter/generated_plugin_registrant.h`
#### `my_app/my_app/linux/flutter/generated_plugin_registrant.cc`

Generated files that register Linux plugins. In this repo they register the Linux `url_launcher` plugin.

### Windows runner

#### `my_app/my_app/windows/runner/main.cpp`

Windows desktop entrypoint.

What it does:

1. attaches or creates a console,
2. initializes COM,
3. creates `flutter::DartProject`,
4. passes command-line args into Flutter,
5. creates `FlutterWindow`,
6. enters the Windows message loop.

#### `my_app/my_app/windows/runner/flutter_window.h`
#### `my_app/my_app/windows/runner/flutter_window.cpp`

Purpose:
Host the Flutter engine inside a Win32 window.

What it does:

1. creates `FlutterViewController`,
2. registers plugins,
3. embeds the Flutter view as child content,
4. shows the window after first frame,
5. forwards window messages to Flutter,
6. reloads fonts on `WM_FONTCHANGE`.

#### `my_app/my_app/windows/runner/win32_window.h`
#### `my_app/my_app/windows/runner/win32_window.cpp`

Purpose:
Generic high-DPI-aware Win32 window abstraction.

What it does:

1. registers/unregisters a window class,
2. creates and destroys native window resources,
3. handles DPI changes,
4. handles resize, focus and theme updates,
5. hosts a child window for Flutter content.

This is reusable runner infrastructure rather than app-specific logic.

#### `my_app/my_app/windows/runner/utils.h`
#### `my_app/my_app/windows/runner/utils.cpp`

Utility helpers for:

1. attaching/creating a console,
2. converting UTF-16 strings to UTF-8,
3. extracting command-line args for the Flutter engine.

#### `my_app/my_app/windows/flutter/generated_plugin_registrant.h`
#### `my_app/my_app/windows/flutter/generated_plugin_registrant.cc`

Generated Windows plugin registration files. In this repo they register `url_launcher_windows`.

## 8. Cross-File Contracts You Should Know

These are the most important payload contracts in the codebase.

### Search result contract

Backend returns:

1. `path`
2. `name`
3. `score`

Flutter `QueryPage` expects exactly that.

### Trip list contract

Backend trip rows include fields like:

1. `id`
2. `name`
3. `start_date`
4. `end_date`
5. `cover_photo_path`
6. `description`
7. `total_photos`
8. `total_key_photos`

Flutter currently uses only a subset when rendering trip cards.

### Analytics contract

`analytics.py` returns a top-level object with keys such as:

1. `map_of_photos`
2. `inner_circle`
3. `food_map`
4. `photographers_growth`
5. `emotional_timeline`
6. `world_footprint`
7. `pet_report_card`
8. `chasing_sunsets`
9. `time_machine`
10. `photo_timeline_heatmap`
11. `hours_of_day_wheel`
12. `trip_stats`
13. `camera_usage`
14. `top_locations`
15. `trip_duration_ranking`
16. `photography_dna`
17. `night_owl`
18. `key_photos`
19. `ben_aharon_special`
    - the static fallback HTML payload computed by `analytic_ben_aharon_special()`.
    - **note:** `BenAharonSpecialCard` in Flutter does NOT read this key from the analytics JSON. It loads the Ben Aharon page by firing a separate WebView request to `/trips/{id}/ben-aharon`, which runs the full LLM pipeline. This key is only kept in the payload as a fallback reference.

`analytics_widgets.dart` is hard-wired to those keys.

## 9. Where To Add New Features

If you want to extend the app, here is the easiest mental map.

### Add a new backend-only calculation

Best place:
`backend/analytics.py` or `backend/filter.py` depending on whether it is:

1. trip analytics,
2. curation/filtering logic.

### Add a new API endpoint

Best place:
`backend/server.py`

Then call into the correct domain module rather than writing large logic directly in the endpoint.

### Add a new analytics card

You normally touch two files:

1. `backend/analytics.py`
2. `my_app/my_app/lib/analytics_widgets.dart`

Then wire it into `_buildAnalyticsCards(...)` inside `trips.dart`.

### Add a new trip-level database field

You normally touch:

1. `backend/database.py` schema/migration,
2. the code that writes it,
3. the code that reads it,
4. the Flutter UI if it needs to be visible.

### Add a new curation heuristic

Best place:
`backend/filter.py`

Typical choices:

1. add a new feature in Phase 1,
2. add a new hard reject in Phase 1b,
3. change the composite score,
4. change cluster thresholds.

### Add a new visual trip experience

Best place:
`my_app/my_app/lib/trips.dart`

That file already hosts:

1. trip list,
2. trip detail,
3. story-style wrapped trip flow.

## 10. Final Mental Model

If you remember only one model of the project, use this:

1. `metadata.py` explains the files.
2. `clip_embed.py` gives the files semantic meaning.
3. `filter.py` decides which files are worth keeping.
4. `trips.py` groups the good files into trips.
5. `database.py` persists everything.
6. `analytics.py` turns persisted trips into rich derived stories.
7. `server.py` exposes all of that over HTTP.
8. Flutter pages call those endpoints and visualize the results.

That is the full shape of the app.

If you want, the next best follow-up document would be a "change guide" showing exactly where to modify the code for features like:

1. new analytics ideas,
2. new trip detection rules,
3. new UI pages,
4. user settings,
5. cloud sync or multi-user support.



---

## 11. Logging Architecture

This project ships with a centralised, file-based logging subsystem that
captures every meaningful event the backend performs. It is designed to make
post-mortem debugging trivial: when something goes wrong, you open the latest
log file under `D:\Proj\QueMory2\logging\` and read top-to-bottom.

### 11.1 Goals

The logging layer was built with these specific goals in mind:

1. **Zero third-party dependencies.** Only Python's stdlib `logging` module
   is used. No `loguru`, no `structlog`. This keeps the venv lean and avoids
   surprising behavioural differences between dev and production environments.
2. **One file per process run.** Each time `server.py` (or any other entry
   point) starts, a new timestamped log file is created. This makes it easy
   to bisect "what changed between runs" without piping through `grep`.
3. **Same content visible in two channels.** A short, INFO-and-above stream
   goes to the terminal so `uvicorn` users get live feedback; the full DEBUG
   stream goes to disk for later analysis.
4. **No business-logic change.** Every existing `print()` was either left in
   place alongside a `log.*` call or replaced; **no control flow was altered**
   in service of logging.
5. **No sensitive payloads.** We log lengths and counts of LLM prompts, but
   never the prompt text itself; we log image *paths* but never decoded
   pixel buffers; we never log API keys (the project has none currently,
   but the rule applies to future additions).

### 11.2 The `logging_setup` module

File: [backend/logging_setup.py](backend/logging_setup.py)

This is the single source of truth for log configuration. It exposes one
public function:

```python
from logging_setup import setup_logging
log_path = setup_logging()           # uses defaults
log_path = setup_logging(file_level=logging.DEBUG,
                         console_level=logging.INFO)
```

Internals:

- `_REPO_ROOT` is computed as the parent of `backend/` so that the log
  directory always resolves to `D:\Proj\QueMory2\logging\` regardless of
  where Python was invoked from.
- `LOG_DIR = _REPO_ROOT / "logging"` is created on first call
  (`mkdir(parents=True, exist_ok=True)`).
- The filename pattern is `run_%Y-%m-%d_%H-%M-%S.log`, e.g.
  `run_2026-05-17_09-12-07.log`. Seconds-resolution is enough since only
  one process per host writes to this directory at a time.
- A module-level `_INITIALIZED` flag makes `setup_logging()` idempotent.
  This matters because `uvicorn --reload` re-imports `server.py`, which
  would otherwise install duplicate handlers and produce double-printed
  log lines.
- Two handlers are installed on the **root logger**:
  - `FileHandler` at `DEBUG`, encoding UTF-8, with the verbose format
    `%(asctime)s.%(msecs)03d | %(levelname)-8s | %(name)s | %(filename)s:%(lineno)d | %(message)s`.
  - `StreamHandler` at `INFO`, writing to `stderr`, with the shorter format
    `%(asctime)s | %(levelname)-8s | %(message)s`.
- Several noisy third-party loggers are forcibly clamped to `WARNING`:
  `PIL`, `urllib3`, `matplotlib`, `asyncio`, `uvicorn.access`, `watchfiles`.
  These libraries are useful when they fail but generate enormous DEBUG
  traffic during normal operation; suppressing them keeps the log file
  scannable.
- After installing the handlers, the function emits a banner with the
  Python version, PID, and CWD. This makes it easy to confirm the right
  process is being inspected and to correlate logs with system metrics.

### 11.3 Where logs go

- **Directory:** `D:\Proj\QueMory2\logging\` (sibling of `backend/`, NOT
  inside `backend/`). Created automatically on first run.
- **Filename:** `run_YYYY-MM-DD_HH-MM-SS.log` — one per process run.
- **Console:** Same process's `stderr`, filtered to INFO+.
- **Retention:** None — old log files accumulate indefinitely. If disk usage
  becomes a concern, add a `RotatingFileHandler` or a periodic cleanup. The
  current design treats logs as forensic evidence to be archived manually.

### 11.4 Logger naming convention

Every backend module uses a logger named `quemory.<module>`:

| File | Logger name |
|---|---|
| [backend/server.py](backend/server.py) | `quemory.server` |
| [backend/database.py](backend/database.py) | `quemory.database` |
| [backend/trips.py](backend/trips.py) | `quemory.trips` |
| [backend/clip_embed.py](backend/clip_embed.py) | `quemory.clip_embed` |
| [backend/filter.py](backend/filter.py) | `quemory.filter` |
| [backend/analytics.py](backend/analytics.py) | `quemory.analytics` |
| [backend/summarize.py](backend/summarize.py) | `quemory.summarize` |
| [backend/face.py](backend/face.py) | `quemory.face` |
| [backend/metadata.py](backend/metadata.py) | `quemory.metadata` |

This means you can isolate one subsystem with one regex, e.g.
`grep "quemory\.trips" logging/run_*.log`.

The dotted prefix also means that setting `logging.getLogger("quemory").setLevel(...)`
in the future would change every module at once, while leaving third-party
loggers untouched.

### 11.5 Log level conventions

The project follows a deliberate, narrow set of conventions so that grepping
by level returns predictable categories of events:

| Level | When to use it | Examples in this codebase |
|---|---|---|
| `DEBUG` | Hot-path detail, per-photo state, cache hit/miss | `geocode cache hit`, `Detected 3 face(s) in IMG_0123.HEIC`, `list_trips returned 12 trip(s)` |
| `INFO` | State change, endpoint entry, external call start/finish, business event | `create_trip name='Iceland 2025' photos=128`, `Nominatim reverse geocode lat=…`, `Saved NEW trip id=7` |
| `WARNING` | Unexpected but handled; fallback path taken; validation rejection | `no homes configured; skipping`, `Ollama returned empty summary`, `Cannot read image for face detection` |
| `ERROR` | Caught and continued, want to flag | Rare. Reserved for cases where `log.exception` would be wrong (no traceback available). |
| `CRITICAL` | Service unable to continue | Used for missing required model files (`Missing face detector model`) before the matching `raise`. |
| `log.exception` | Inside an `except` block | Auto-attaches traceback. Used wherever a bare `except` swallowed an error before. |

The single most important rule: **inside an `except` block we use
`log.exception(...)`, never `log.error(str(e))`**. The former captures the
full traceback automatically; the latter loses it.

### 11.6 What each module logs

#### `server.py` — `quemory.server`

- **Startup hook** logs FastAPI lifecycle entry, with PID, host, port, and
  registered route count. This runs *after* the module-level CLIP/face
  model loads, so it confirms full readiness.
- **Shutdown hook** logs lifecycle exit with shutdown reason if available.
- **Every endpoint** logs entry at INFO with relevant parameters
  (`trip_id`, `query`, `top_k`, etc.).
- **403/404/400 paths** log at WARNING with the rejected resource so we
  can spot client bugs.
- **HEIC transcoding** in `_get_display_path` logs at DEBUG on success
  and `log.exception` on failure (previously was a bare except).
- The analytics and ben-aharon endpoints log `log.exception` on any
  failure since these involve external LLM I/O.

#### `database.py` — `quemory.database`

- `create_database`, `create_trip`, `add_home_location`,
  `update_cover_photo`, `update_frequent_face` log at INFO with their key
  arguments (trip name, lat/lon, etc.).
- Bulk operations (`add_photos_to_trip`, `mark_images_excluded`) log a
  summary line with the row count *after* the commit.
- Per-row insert failures inside `add_photos_to_trip` now go through
  `log.exception` instead of `except: pass`.
- Pure-CRUD reads (`list_trips`, `get_trip_photos`) log at DEBUG with
  the returned count.

#### `trips.py` — `quemory.trips`

- `detect_trips` logs the input feature count, the home count, and the
  candidate-vs-merged count at INFO.
- `detect_and_save_all` logs each major step: how many images were
  already assigned (so skipped), how many new ones are being processed,
  every NEW trip saved (with photo/key/stop counts), every merge into
  an existing trip, and the final excluded count.
- A WARNING is emitted when there are no homes configured — this is
  legal but produces lower-quality trip boundaries.

#### `clip_embed.py` — `quemory.clip_embed`

- Module-load INFO line records the device choice (`cpu` vs `cuda`).
  This is one of the first things to check when a model is slower than
  expected.
- `save_all_embeddings` logs the folder scanned, per-image DEBUG embed
  lines, and a final `saved=… skipped_existing=… failed=…` summary.
- `search` logs the query, top_k, and a WARNING when the embeddings DB
  is empty.
- `_expand_query` now logs `log.exception` when Ollama is unreachable
  and falls back to the raw query (previously a silent failure).

#### `filter.py` — `quemory.filter`

- Module-load reports whether the C++ accelerator was loaded
  (`C++ acceleration enabled (filter_core)`) or whether the Python
  fallback is in use. This is the single most important line for
  diagnosing performance regressions.
- `curate()` logs entry with folder + max_images, phase-0 outcome
  (rejected vs surviving counts), and emits a WARNING if everything
  was filtered out.

#### `analytics.py` — `quemory.analytics`

- `compute_all_analytics` logs entry with `trip_id` + `force`, then
  reports cache hit/miss at DEBUG, then the photo/embedding counts, then
  a final summary with the number of sub-analytics produced.
- `_clip_text_vector` failures (previously `except: return None`) now
  emit `log.exception` so we know when a prompt failed to encode.
- `invalidate_cache` logs each invalidation at INFO.

#### `summarize.py` — `quemory.summarize`

- `_reverse_geocode` logs DEBUG on cache hit and INFO on each actual
  Nominatim HTTP call (with lat/lon rounded to 4 decimals — this is
  intentionally coarser than the cache key). Failures use
  `log.exception`.
- `generate_summary` logs the Ollama call with model name and prompt
  length (NOT prompt content), and `log.exception` on HTTP failure.
- `generate_ben_aharon_html` logs trip name, image count, and prompt
  length; on failure emits `log.exception` and falls back to the static
  CDN HTML.

#### `face.py` — `quemory.face`

- `_ensure_models_loaded` logs each model file path being loaded, with
  `log.error` before raising `FileNotFoundError` on missing files.
- `extract_faces_for_embedding` logs the face count at DEBUG and emits
  a WARNING if the image cannot be read.
- `cluster_embeddings` logs the final cluster summary at INFO.

#### `metadata.py` — `quemory.metadata`

- `get_exif` now catches arbitrary read failures with `log.exception`
  instead of letting them propagate silently into the caller.
- The many narrow `except ValueError` and `except (TypeError, ValueError)`
  blocks in `extract_when`, `extract_where` etc. are intentionally NOT
  instrumented — they fire for every photo missing a given tag and would
  produce thousands of noise lines per run. This is a deliberate
  signal-to-noise decision.

### 11.7 Exception handling pattern

Every `except` block that previously swallowed an error has been changed
to either:

1. `log.exception("descriptive message with context", arg1, arg2)` —
   when the project intends to continue (e.g. "skip this photo, try the
   next one"), or
2. `log.error(...)` followed by `raise` — when the project intends to
   propagate.

The message string always starts with the function name or the operation
being attempted, so a search for `log.exception` lines reads like a
chronological narrative of "where the program almost died".

### 11.8 Debugging a Failed Run — Recommended Workflow

1. Reproduce the failure (e.g. open the trips page in Flutter, click
   "Detect Trips", see the spinner hang).
2. Open the latest log: in PowerShell,
   `Get-ChildItem D:\Proj\QueMory2\logging | Sort-Object LastWriteTime -Descending | Select-Object -First 1`.
3. Read backwards from the end: errors usually live in the last few
   hundred lines.
4. `grep` (or `Select-String`) for `ERROR|CRITICAL|Traceback` to land
   on the failure site.
5. Look at the **logger name** in the failed line — that tells you which
   subsystem to investigate next.
6. Use the **file:line** column to jump straight to the source line.
7. Read the 50 preceding lines to see what state was set up before the
   failure. `quemory.server` INFO lines bracket every endpoint, so you
   can find the request boundary.
8. If the failure was in an LLM call, also check whether the prompt
   length and image count were sensible (logged at INFO without leaking
   content).

### 11.9 Smoke-Testing the Logging Layer

A successful smoke test was performed during installation:

```powershell
PS> cd D:\Proj\QueMory2\backend
PS> .\.venv\Scripts\python.exe -c "from logging_setup import setup_logging; setup_logging(); import database, trips, analytics, summarize, face, metadata, filter, clip_embed; print('ALL MODULES IMPORTED OK')"
```

This:

1. Installs the handlers via `setup_logging()`.
2. Imports every backend module — exercising module-level work (CLIP
   model load, C++ extension probe, etc.).
3. Confirms no syntax errors and that each module's `log = logging.getLogger("quemory.…")`
   handle works.
4. Produces a fresh `run_*.log` in `D:\Proj\QueMory2\logging\`.

If this command ever fails, the logging subsystem is broken and that is
the first thing to fix.

### 11.10 Future Extensions

These were intentionally NOT done now to avoid scope creep, but are
documented here so future maintainers know they are easy additions:

- **Log rotation:** swap `FileHandler` for `RotatingFileHandler` with a
  size cap. Currently each run creates a new file so unbounded growth
  is per-file, not per-run.
- **JSON structured logs:** swap the formatter for `python-json-logger`
  if log aggregation tooling is added.
- **Request ID propagation:** add a FastAPI middleware that generates a
  UUID per request and attaches it via `logging.LoggerAdapter` so cross-
  module log lines can be correlated to a single API call.
- **Frontend log shipping:** Flutter does not currently send its own
  logs to the backend. If desired, add `POST /client-logs` to ingest
  Flutter `developer.log` lines into the same run file.
- **CLI verbosity flag:** expose `setup_logging(console_level=…)` as a
  `--verbose` argument on the uvicorn entrypoint.
