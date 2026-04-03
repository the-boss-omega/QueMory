import os
import tempfile
from fastapi import FastAPI, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel
from clip_embed import search, save_all_embeddings
from filter import curate
from database import create_trip, save_trip_photos, get_trip_photos, list_trips
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


@app.post("/trips")
def api_create_trip(req: CreateTripRequest):
    result = curate()
    trip_id = create_trip(req.name)
    save_trip_photos(trip_id, result["keep"])
    display_photos = []
    for item in result["keep"]:
        display_photos.append({
            "path": _get_display_path(item["path"], item["name"]),
            "name": item["name"],
        })
    return {"trip_id": trip_id, "name": req.name, "photo_count": len(display_photos)}


@app.get("/trips")
def api_list_trips():
    return list_trips()


@app.get("/trips/{trip_id}/photos")
def api_trip_photos(trip_id: int):
    photos = get_trip_photos(trip_id)
    return [
        {"path": _get_display_path(p["path"], p["name"]), "name": p["name"]}
        for p in photos
    ]
