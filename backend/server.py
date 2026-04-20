import os
import tempfile
from fastapi import FastAPI, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel
from clip_embed import search, save_all_embeddings
from filter import curate
from database import (
    create_trip, save_trip_photos, get_trip_photos, get_trip_locations,
    list_trips, get_home_locations, add_home_location, create_database,
)
from trips import detect_and_save_all
from PIL import Image

app = FastAPI()

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
        img = Image.open(file_path).convert("RGB")
        img.save(tmp_path, "JPEG", quality=85)
    _heic_cache[file_path] = tmp_path
    return tmp_path


@app.get("/search")
def api_search(q: str = Query(...), top_k: int = Query(5)):
    results = search(q, top_k)
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
    save_all_embeddings()
    return {"status": "ok"}


@app.get("/curate")
def api_curate(folder: str = Query(None)):
    result = curate(folder)
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
    result = curate(req.folder)
    trip_id = create_trip(req.name)
    save_trip_photos(trip_id, result["keep"])
    display_photos = []
    for item in result["keep"]:
        display_photos.append({
            "path": _get_display_path(item["path"], item["name"]),
            "name": item["name"],
        })
    try:
        from summerize import generate_summary
        notes = generate_summary(trip_id,user_notes=req.notes)
    except Exception as e:
        print(f"[server] Summary generation failed: {e}")
    return {"trip_id": trip_id, "name": req.name, "photo_count": len(display_photos), "description": description}


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

    results = detect_and_save_all(features_list)
    from database import get_unassigned_images
    return {
        "new_trips": len(results),
        "trips": results,
        "unassigned_remaining": len(get_unassigned_images()),
    }


class HomeLocationRequest(BaseModel):
    latitude: float
    longitude: float
    radius_km: float = 5.0
    label: str | None = None


@app.post("/home-locations")
def api_add_home(req: HomeLocationRequest):
    row_id = add_home_location(req.latitude, req.longitude, req.radius_km, req.label)
    return {"id": row_id}


@app.get("/home-locations")
def api_list_homes():
    return get_home_locations()
