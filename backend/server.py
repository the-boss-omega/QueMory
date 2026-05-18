import os
import logging
import tempfile

# Logging MUST be configured before any other QueMory module is imported so
# that those modules' module-level log calls (and any work they do at import
# time, e.g. loading CLIP) are captured by the run's log file.
from logging_setup import setup_logging, LOG_FILE_PATH

setup_logging()
log = logging.getLogger("quemory.server")
log.info("Importing server dependencies")

from fastapi import FastAPI, Query, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from pydantic import BaseModel
from clip_embed import search, search_expanded, save_all_embeddings, IMAGES_FOLDER
from filter import curate
from database import (
    create_trip, save_trip_photos, get_trip_photos, get_trip_locations,
    list_trips, get_home_locations, add_home_location, create_database,
    add_photos_to_trip, update_cover_photo,
)
from trips import detect_and_save_all
from PIL import Image

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def _on_startup() -> None:
    log.info("FastAPI startup hook fired")
    log.info("Active log file: %s", LOG_FILE_PATH)


@app.on_event("shutdown")
def _on_shutdown() -> None:
    log.info("FastAPI shutdown hook fired — flushing log handlers")
    logging.shutdown()


log.info("Ensuring SQLite schema exists")
create_database()

# Auto-index any images that don't have embeddings yet.
log.info("Auto-indexing image embeddings on startup")
try:
    from clip_embed import save_all_embeddings
    save_all_embeddings()
except Exception:
    log.exception("Startup embedding index failed — continuing without it")

_heic_cache: dict[str, str] = {}


def _get_display_path(file_path: str, file_name: str) -> str:
    ext = os.path.splitext(file_name)[1].lower()
    if ext not in {".heic", ".heif"}:
        return file_path
    if file_path in _heic_cache:
        return _heic_cache[file_path]
    tmp_path = os.path.join(
        tempfile.gettempdir(),
        f"quemory_{os.path.splitext(file_name)[0]}.jpg",
    )
    if not os.path.exists(tmp_path):
        log.debug("Transcoding HEIC for display: %s -> %s", file_name, tmp_path)
        try:
            img = Image.open(file_path).convert("RGB")
            img.save(tmp_path, "JPEG", quality=85)
        except Exception:
            log.exception("Failed to transcode HEIC file: %s", file_path)
            return file_path
    _heic_cache[file_path] = tmp_path
    return tmp_path


@app.get("/search")
def api_search(q: str = Query(...), top_k: int = Query(5), expand: bool = Query(True)):
    """Semantic image search. Use expand=true (default) for multi-prompt query expansion."""
    log.info("GET /search q=%r top_k=%d expand=%s", q, top_k, expand)
    try:
        results = search_expanded(q, top_k) if expand else search(q, top_k)
    except Exception:
        log.exception("Search failed for query %r", q)
        raise
    log.debug("Search returned %d hits", len(results))
    return [
        {
            "path": _get_display_path(path, name),
            "name": name,
            "score": score,
        }
        for path, name, score in results
    ]



@app.post("/embed")
def api_embed():
    log.info("POST /embed — full re-index requested")
    try:
        save_all_embeddings()
    except Exception:
        log.exception("Embedding index failed")
        raise
    return {"status": "ok"}


@app.get("/curate")
def api_curate(folder: str = Query(None)):
    log.info("GET /curate folder=%s", folder)
    result = curate(folder)
    log.info(
        "Curation result: keep=%d removals=%d blank=%d quality=%d",
        len(result.get("keep", [])),
        len(result.get("suggested_removals", [])),
        len(result.get("rejected_blank", [])),
        len(result.get("rejected_quality", [])),
    )
    for item in result["keep"]:
        item["path"] = _get_display_path(item["path"], item["name"])
    for item in result["suggested_removals"]:
        item["path"] = _get_display_path(item["path"], item["name"])
    for item in result["rejected_blank"]:
        item["path"] = _get_display_path(item["path"], item["name"])
    for item in result.get("rejected_quality", []):
        item["path"] = _get_display_path(item["path"], item["name"])
    return result


class CreateTripRequest(BaseModel):
    name: str
    folder: str | None = None
    notes: str | None = None


@app.post("/trips")
def api_create_trip(req: CreateTripRequest):
    log.info("POST /trips name=%r folder=%s", req.name, req.folder)
    result = curate(req.folder)
    trip_id = create_trip(req.name, total_photos=len(result["keep"]))
    log.info("Created trip id=%d with %d kept photos", trip_id, len(result["keep"]))
    save_trip_photos(trip_id, result["keep"])
    update_cover_photo(trip_id)
    description = ""
    try:
        from summarize import generate_summary
        description = generate_summary(trip_id, user_notes=req.notes) or ""
    except Exception:
        log.exception("Summary generation failed for trip_id=%d", trip_id)
    display_photos = [
        {"path": _get_display_path(item["path"], item["name"]), "name": item["name"]}
        for item in result["keep"]
    ]
    return {
        "trip_id": trip_id,
        "name": req.name,
        "photo_count": len(display_photos),
        "description": description,
    }


@app.get("/trips")
def api_list_trips():
    return list_trips()


@app.get("/trips/{trip_id}/photos")
def api_trip_photos(trip_id: int):
    photos = get_trip_photos(trip_id)
    return [
        {"path": _get_display_path(p["path"], p["name"]), "name": p["name"],
         "timestamp": p.get("timestamp"), "latitude": p.get("latitude"),
         "longitude": p.get("longitude"),
         "aesthetic_score": p.get("aesthetic_score"),
         "is_key_photo": p.get("is_key_photo", False)}
        for p in photos
    ]


@app.get("/trips/{trip_id}/locations")
def api_trip_locations(trip_id: int):
    return get_trip_locations(trip_id)


@app.post("/detect-trips")
def api_detect_trips(folder: str = Query(None)):
    """Run the full curation pipeline then detect and save trips."""
    log.info("POST /detect-trips folder=%s", folder)
    from filter import (
        phase0_reject, extract_all_features, IMAGES_FOLDER,
    )
    from clip_embed import (
        _init_db as init_embed_db, _deserialize,
        model as clip_model, preprocess as clip_preprocess, device as clip_device,
    )
    from metadata import get_exif
    from pathlib import Path
    import torch, numpy as np

    folder = folder or IMAGES_FOLDER
    extensions = {".jpg", ".jpeg", ".png", ".heic", ".heif"}
    images = [p for p in Path(folder).iterdir()
              if p.suffix.lower() in extensions and p.is_file()]

    conn = init_embed_db()
    embed_rows = conn.execute(
        "SELECT file_path, embedding FROM embeddings"
    ).fetchall()
    embed_map = {row[0]: _deserialize(row[1]) for row in embed_rows}
    conn.close()

    features_list = []
    for img_path in images:
        abs_path = str(img_path.resolve())
        is_rejected, _ = phase0_reject(abs_path)
        if is_rejected:
            continue
        try:
            exif = get_exif(abs_path)
        except Exception:
            exif = {}
        embedding = embed_map.get(abs_path)
        if embedding is None:
            try:
                from PIL import Image as PILImage
                img_tensor = clip_preprocess(
                    PILImage.open(abs_path).convert("RGB")
                ).unsqueeze(0).to(clip_device)
                with torch.no_grad():
                    vec = clip_model.encode_image(img_tensor).cpu().numpy().flatten()
                embedding = vec / np.linalg.norm(vec)
            except Exception:
                continue
        features = extract_all_features(abs_path, embedding, exif)
        if features.get("timestamp") is not None:
            features_list.append(features)

    log.info("Built feature list of %d photos for trip detection", len(features_list))
    detection = detect_and_save_all(features_list)
    from database import get_unassigned_images
    remaining = len(get_unassigned_images())
    log.info(
        "Detection done: new=%d merged=%d excluded=%d unassigned_remaining=%d",
        len(detection["trips"]), detection["merged"], detection["excluded"], remaining,
    )
    return {
        "new_trips": len(detection["trips"]),
        "trips": detection["trips"],
        "merged": detection["merged"],
        "excluded": detection["excluded"],
        "unassigned_remaining": remaining,
    }


class HomeLocationRequest(BaseModel):
    latitude: float
    longitude: float
    radius_km: float = 5.0
    label: str | None = None


@app.post("/home-locations")
def api_add_home(req: HomeLocationRequest):
    log.info(
        "POST /home-locations lat=%.4f lon=%.4f radius_km=%.1f label=%s",
        req.latitude, req.longitude, req.radius_km, req.label,
    )
    row_id = add_home_location(req.latitude, req.longitude, req.radius_km, req.label)
    log.debug("Home location row_id=%d", row_id)
    return {"id": row_id}


@app.get("/home-locations")
def api_list_homes():
    homes = get_home_locations()
    log.debug("GET /home-locations -> %d rows", len(homes))
    return homes


# ─── Analytics ────────────────────────────────────────────────────────────────

@app.get("/trips/{trip_id}/analytics")
def api_trip_analytics(trip_id: int, force: bool = Query(False)):
    """Return (cached) analytics for a trip. Use ?force=true to recompute."""
    log.info("GET /trips/%d/analytics force=%s", trip_id, force)
    from analytics import compute_all_analytics
    try:
        data = compute_all_analytics(trip_id, force=force)
        log.debug("Analytics keys: %s", list(data.keys()) if isinstance(data, dict) else type(data).__name__)
        return JSONResponse(content=data)
    except Exception as e:
        log.exception("Analytics computation failed for trip_id=%d", trip_id)
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.post("/trips/{trip_id}/add-photos")
def api_add_photos(trip_id: int, req: CreateTripRequest, background_tasks: BackgroundTasks):
    """Add photos from a folder to an existing trip."""
    log.info("POST /trips/%d/add-photos folder=%s", trip_id, req.folder)
    from analytics import invalidate_cache
    if not req.folder:
        log.warning("Add-photos rejected: missing folder for trip_id=%d", trip_id)
        return JSONResponse(status_code=400, content={"error": "folder required"})
    result = curate(req.folder)
    inserted = add_photos_to_trip(trip_id, result["keep"])
    log.info("Inserted %d new photos into trip_id=%d", inserted, trip_id)
    update_cover_photo(trip_id)
    # Invalidate analytics cache so next fetch recomputes
    background_tasks.add_task(invalidate_cache, trip_id)
    return {"trip_id": trip_id, "inserted": inserted}


# ─── Wrapped stats ────────────────────────────────────────────────────────────

@app.get("/wrapped/stats")
def api_wrapped_stats():
    """Aggregate statistics across all trips for the Wrapped page."""
    from analytics import compute_wrapped_stats
    return JSONResponse(content=compute_wrapped_stats())

@app.get("/image")
def api_get_image(path: str = Query(...)):
    from pathlib import Path
    resolved = Path(path).resolve()
    allowed_roots = [
        Path(IMAGES_FOLDER).resolve(),
        Path(tempfile.gettempdir()).resolve(),
    ]
    if not any(str(resolved).startswith(str(root)) for root in allowed_roots):
        log.warning("Rejected /image request outside allowed roots: %s", resolved)
        return JSONResponse(status_code=403, content={"error": "forbidden"})
    display = _get_display_path(path, os.path.basename(path))
    return FileResponse(display)

@app.get("/trips/{trip_id}/ben-aharon")
def api_ben_aharon_page(trip_id: int, force: bool = Query(False)):
    """Serve the Ben Aharon Marenkov Special as a standalone LLM-generated HTML page."""
    log.info("GET /trips/%d/ben-aharon force=%s", trip_id, force)
    from analytics import compute_all_analytics
    from summarize import generate_ben_aharon_html

    all_trips = list_trips()
    trip = next((t for t in all_trips if t["id"] == trip_id), None)
    if trip is None:
        log.warning("Ben-Aharon requested for unknown trip_id=%d", trip_id)
        return JSONResponse(status_code=404, content={"error": "trip not found"})

    try:
        analytics = compute_all_analytics(trip_id, force=force)
    except Exception as e:
        log.exception("Ben-Aharon: analytics compute failed for trip_id=%d", trip_id)
        return JSONResponse(status_code=500, content={"error": str(e)})

    key_photos = analytics.get("key_photos", {}).get("photos", [])
    image_paths = [p["path"] for p in key_photos if p.get("is_key")]
    log.debug("Ben-Aharon: passing %d key photos to LLM", len(image_paths))

    try:
        html = generate_ben_aharon_html(trip["name"], analytics, image_paths, trip.get("description"))
    except Exception:
        log.exception("Ben-Aharon HTML generation failed for trip_id=%d", trip_id)
        raise
    return HTMLResponse(content=html)