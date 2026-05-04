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

Important design detail:
`_get_display_path(...)` converts HEIC/HEIF files to temporary JPEGs for display, but it leaves the original files alone.

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
Generate a human-readable trip summary using Ollama.

Step-by-step:

1. Load the trip row, locations and photos from SQLite.
2. Reverse geocode the stop coordinates with Nominatim.
3. Build a prompt containing:
   - trip name,
   - date range,
   - duration,
   - locations,
   - distances between stops,
   - time-of-day distribution,
   - user notes.
4. Send the prompt to a local Ollama model.
5. Save the resulting summary back into the `trips` table.

Important design note:
This file does not do trip analysis itself. It just turns already-derived data into text.

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
    - HTML-like aesthetic hero payload for a custom card.

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

Purpose:
This file is the visual analytics library for trip detail pages.

It contains one widget per analytics card, a shared base card, and two custom painters.

#### `AnalyticCard`

Purpose:
Base card wrapper used by every analytics card. Provides consistent padding, rounded corners, and a title header.

#### Individual analytics card widgets

Each of the following widgets corresponds to one analytic function in `analytics.py`. Each receives a `Map<String, dynamic>` payload and renders the appropriate UI.

1. `MapOfPhotosCard` — renders geotagged photo pins on a `flutter_map` tile layer.
2. `InnerCircleCard` — shows the top recurring faces, each with a thumbnail, face-count, and similarity score.
3. `FoodMapCard` — shows food count and top food type estimate from CLIP prompts.
4. `PhotographersGrowthCard` — line chart of aesthetic score by day with letter-grade overlay.
5. `EmotionalTimelineCard` — smile-likelihood trend rendered as a sparkline.
6. `WorldFootprintCard` — total distance label plus a coarse GPS heatmap.
7. `PetReportCard` — shows best and worst-scoring pet photo.
8. `ChasingSunsetsCard` — sunset and golden-hour leaderboard.
9. `TimeMachineCard` — spots revisited in multiple trips.
10. `PhotoTimelineHeatmapCard` — GitHub-style contribution graph of daily photo counts.
11. `HoursOfDayWheelCard` — polar/clock chart of shooting times; uses `_ClockChartPainter`.
12. `TripStatsCard` — headline numbers: photo count, distance, duration, date range.
13. `CameraUsageCard` — device percentage breakdown.
14. `TopLocationsCard` — repeat locations across trips.
15. `TripDurationRankingCard` — bar-style comparison of trip durations.
16. `PhotographyDNACard` — vibe distribution from CLIP prompts as a pie/bar chart.
17. `NightOwlReportCard` — late-night shooting stats.
18. `KeyPhotosCard` — scrollable gallery of key photos plus all-photos toggle.
19. `BenAharonSpecialCard` — hero aesthetic card with gradient overlay and large photo.

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

Important widgets in order:

1. `MapOfPhotosCard`
   - map of geotagged photos.

2. `InnerCircleCard`
   - podium layout of most frequent faces.

3. `FoodMapCard`
   - food count, dominant food type and thumbnails.

4. `PhotographersGrowthCard`
   - average score and sparkline.

5. `EmotionalTimelineCard`
   - happiest day plus sparkline of smile intensity.

6. `WorldFootprintCard`
   - travel distance, Earth percentage and map markers.

7. `PetReportCard`
   - best/worst pet photo side by side.

8. `ChasingSunsetsCard`
   - ranked sunset thumbnails.

9. `TimeMachineCard`
   - before/after style repeated-location photos.

10. `PhotoTimelineHeatmapCard`
    - GitHub-style contribution heatmap.

11. `HoursOfDayWheelCard`
    - radial clock chart of photo timing.

12. `TripStatsCard`
    - large summary stats for one trip.

13. `CameraUsageCard`
    - per-device usage bars.

14. `TopLocationsCard`
    - repeat-location callouts across trips.

15. `TripDurationRankingCard`
    - horizontal progress bars for trip length ranking.

16. `PhotographyDNACard`
    - vibe percentages shown as filled bars.

17. `NightOwlReportCard`
    - late-night stats and thumbnails.

18. `KeyPhotosCard`
    - gallery of trip photos with star badges for key images.

19. `BenAharonSpecialCard`
    - stylized title card for one custom analytics payload.

Helper pieces:

1. `_statPill(...)`
   - colored pill label used by many cards.

2. `_SparklinePainter`
   - draws a filled line chart with a peak dot.

3. `_ClockChartPainter`
   - draws the circular "hours of day" chart.

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
