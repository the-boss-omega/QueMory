import os
import struct
import sqlite3
import numpy as np
from math import log2
from pathlib import Path
from datetime import datetime
from PIL import Image
from pillow_heif import register_heif_opener
from scipy.spatial import KDTree
from sklearn.cluster import DBSCAN

register_heif_opener()

os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"

import torch
import clip

from metadata import (
    get_exif, extract_when, extract_where, extract_camera,
    extract_image_properties, extract_software, compute_phash,
)
from clip_embed import (
    model, preprocess, device, _init_db as init_embed_db,
    _serialize, _deserialize, IMAGES_FOLDER,
)

try:
    import sys as _sys
    _sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'calc'))
    import filter_core as _cpp
    _USE_CPP = True
    print("[filter] C++ acceleration enabled")
except ImportError:
    _USE_CPP = False
    print("[filter] C++ not available, using Python fallback")

VARIANCE_THRESHOLD = 100.0
ENTROPY_THRESHOLD = 3.0
TEMPORAL_GAP_SECONDS = 1800
GEO_EPSILON_DEG = 0.002
GEO_MIN_SAMPLES = 1
VISUAL_SIM_THRESHOLD = 0.92
PHASH_HAMMING_THRESHOLD = 5
VISUAL_KNN = 10
SHARPNESS_MIN = 50
EXPOSURE_MIN = 0.15
TARGET_IMAGES = 30

AESTHETIC_POS = ["a beautiful high quality photograph", "a professional well composed photo"]
AESTHETIC_NEG = ["a blurry ugly low quality photo", "a bad out of focus photograph"]


def _encode_texts(texts: list[str]) -> np.ndarray:
    tokens = clip.tokenize(texts).to(device)
    with torch.no_grad():
        vecs = model.encode_text(tokens).cpu().numpy()
    norms = np.linalg.norm(vecs, axis=1, keepdims=True)
    return vecs / norms


_aesthetic_pos_vecs = None
_aesthetic_neg_vecs = None


def _get_text_embeddings():
    global _aesthetic_pos_vecs, _aesthetic_neg_vecs
    if _aesthetic_pos_vecs is None:
        _aesthetic_pos_vecs = _encode_texts(AESTHETIC_POS)
        _aesthetic_neg_vecs = _encode_texts(AESTHETIC_NEG)
    return _aesthetic_pos_vecs, _aesthetic_neg_vecs


def _hamming_distance(hex_a: str, hex_b: str) -> int:
    a = int(hex_a, 16)
    b = int(hex_b, 16)
    return bin(a ^ b).count("1")


# ═══════════════════════════════════════════════
# PHASE 0 — Early Rejection
# ═══════════════════════════════════════════════

def phase0_reject(image_path: str) -> tuple[bool, str]:
    try:
        img = Image.open(image_path).convert("L")
        img_small = img.resize((256, 256), Image.Resampling.LANCZOS)
        pixels = np.array(img_small, dtype=np.float64)

        if _USE_CPP:
            rejected, variance, entropy = _cpp.phase0_check(
                np.ascontiguousarray(pixels), VARIANCE_THRESHOLD, ENTROPY_THRESHOLD
            )
            if rejected:
                if variance < VARIANCE_THRESHOLD:
                    return True, f"blank (variance={variance:.1f})"
                return True, f"uniform (entropy={entropy:.2f})"
            return False, ""

        variance = float(np.var(pixels))
        if variance < VARIANCE_THRESHOLD:
            return True, f"blank (variance={variance:.1f})"

        hist, _ = np.histogram(pixels, bins=256, range=(0, 256))
        hist = hist / hist.sum()
        hist = hist[hist > 0]
        entropy = -float(np.sum(hist * np.log2(hist)))
        if entropy < ENTROPY_THRESHOLD:
            return True, f"uniform (entropy={entropy:.2f})"

        return False, ""
    except Exception as e:
        return True, f"unreadable ({e})"


# ═══════════════════════════════════════════════
# PHASE 1 — Feature Extraction
# ═══════════════════════════════════════════════

def _compute_sharpness(img_gray: np.ndarray) -> float:
    h, w = img_gray.shape
    laplacian = np.zeros_like(img_gray, dtype=np.float64)
    laplacian[1:-1, 1:-1] = (
        img_gray[:-2, 1:-1].astype(np.float64)
        + img_gray[2:, 1:-1].astype(np.float64)
        + img_gray[1:-1, :-2].astype(np.float64)
        + img_gray[1:-1, 2:].astype(np.float64)
        - 4.0 * img_gray[1:-1, 1:-1].astype(np.float64)
    )
    return float(np.var(laplacian))


def _compute_exposure_quality(img_gray: np.ndarray) -> float:
    mean_val = float(np.mean(img_gray))
    center_distance = abs(mean_val - 128.0) / 128.0
    total = img_gray.size
    clipped_dark = float(np.sum(img_gray < 5)) / total
    clipped_bright = float(np.sum(img_gray > 250)) / total
    return max(0.0, 1.0 - center_distance - clipped_dark - clipped_bright)


def _compute_contrast(img_gray: np.ndarray) -> float:
    return float(np.std(img_gray))


def _compute_saturation(img_rgb: np.ndarray) -> float:
    r, g, b = img_rgb[:, :, 0], img_rgb[:, :, 1], img_rgb[:, :, 2]
    max_c = np.maximum(np.maximum(r, g), b).astype(np.float64)
    min_c = np.minimum(np.minimum(r, g), b).astype(np.float64)
    denom = max_c.copy()
    denom[denom == 0] = 1.0
    sat = (max_c - min_c) / denom
    return float(np.mean(sat))


def _compute_noise(img_gray: np.ndarray) -> float:
    h, w = img_gray.shape
    laplacian = np.zeros_like(img_gray, dtype=np.float64)
    laplacian[1:-1, 1:-1] = (
        img_gray[:-2, 1:-1].astype(np.float64)
        + img_gray[2:, 1:-1].astype(np.float64)
        + img_gray[1:-1, :-2].astype(np.float64)
        + img_gray[1:-1, 2:].astype(np.float64)
        - 4.0 * img_gray[1:-1, 1:-1].astype(np.float64)
    )
    return float(np.median(np.abs(laplacian)))


def extract_pixel_features(image_path: str) -> dict:
    img = Image.open(image_path)
    img_small = img.resize((512, 512), Image.Resampling.LANCZOS)
    rgb = np.ascontiguousarray(np.array(img_small.convert("RGB"), dtype=np.uint8))
    gray = np.ascontiguousarray(np.array(img_small.convert("L"), dtype=np.uint8))

    if _USE_CPP:
        return dict(_cpp.compute_all_pixel_features(gray, rgb))

    return {
        "sharpness": _compute_sharpness(gray),
        "exposure_quality": _compute_exposure_quality(gray),
        "contrast": _compute_contrast(gray),
        "saturation": _compute_saturation(rgb),
        "noise": _compute_noise(gray),
    }


def compute_aesthetic_score(embedding: np.ndarray) -> float:
    pos_vecs, neg_vecs = _get_text_embeddings()
    pos_score = float(np.mean(embedding @ pos_vecs.T))
    neg_score = float(np.mean(embedding @ neg_vecs.T))
    return pos_score - neg_score


def extract_all_features(image_path: str, embedding: np.ndarray, exif: dict) -> dict:
    when = extract_when(exif)
    where = extract_where(exif)
    props = extract_image_properties(image_path, exif)
    software = extract_software(exif, image_path)
    pixel = extract_pixel_features(image_path)
    phash = compute_phash(image_path)

    timestamp = None
    for key in ["date_taken", "date_digitized", "date_modified"]:
        if when.get(key):
            try:
                timestamp = datetime.fromisoformat(when[key])
            except ValueError:
                pass
            break

    return {
        "path": image_path,
        "name": Path(image_path).name,
        "timestamp": timestamp,
        "latitude": where.get("latitude"),
        "longitude": where.get("longitude"),
        "megapixels": props.get("megapixels", 0),
        "is_screenshot": software.get("is_screenshot", False),
        "is_downloaded": software.get("is_downloaded", False),
        "origin": software.get("origin", "self"),
        "phash": phash,
        "sharpness": pixel["sharpness"],
        "exposure_quality": pixel["exposure_quality"],
        "contrast": pixel["contrast"],
        "saturation": pixel["saturation"],
        "noise": pixel["noise"],
        "aesthetic_score": compute_aesthetic_score(embedding),
        "embedding": embedding,
    }


# ═══════════════════════════════════════════════
# PHASE 2 — Tri-Axis Clustering
# ═══════════════════════════════════════════════

def cluster_temporal(features_list: list[dict], gap_seconds: float = TEMPORAL_GAP_SECONDS) -> list[int]:
    n = len(features_list)
    labels = [-1] * n

    indexed = []
    for i, f in enumerate(features_list):
        if f["timestamp"] is not None:
            indexed.append((i, f["timestamp"]))

    if not indexed:
        return labels

    indexed.sort(key=lambda x: x[1])

    group_id = 0
    labels[indexed[0][0]] = group_id

    for k in range(1, len(indexed)):
        prev_time = indexed[k - 1][1]
        curr_time = indexed[k][1]
        gap = (curr_time - prev_time).total_seconds()
        if gap > gap_seconds:
            group_id += 1
        labels[indexed[k][0]] = group_id

    return labels


def cluster_geographic(features_list: list[dict]) -> list[int]:
    n = len(features_list)
    labels = [-1] * n

    indexed = []
    coords = []
    for i, f in enumerate(features_list):
        if f["latitude"] is not None and f["longitude"] is not None:
            indexed.append(i)
            coords.append([f["latitude"], f["longitude"]])

    if len(coords) < 2:
        if len(coords) == 1:
            labels[indexed[0]] = 0
        return labels

    coords_arr = np.array(coords)
    db = DBSCAN(eps=GEO_EPSILON_DEG, min_samples=GEO_MIN_SAMPLES, metric="euclidean")
    cluster_ids = db.fit_predict(coords_arr)

    for k, orig_idx in enumerate(indexed):
        labels[orig_idx] = int(cluster_ids[k])

    return labels


def cluster_visual(features_list: list[dict]) -> list[int]:
    n = len(features_list)
    if n == 0:
        return []

    if _USE_CPP:
        embeddings = np.ascontiguousarray(
            np.stack([f["embedding"] for f in features_list]).astype(np.float32)
        )
        phashes = np.array(
            [int(f["phash"], 16) for f in features_list], dtype=np.uint64
        )
        labels = _cpp.cluster_visual(
            embeddings, phashes,
            VISUAL_SIM_THRESHOLD, PHASH_HAMMING_THRESHOLD, VISUAL_KNN
        )
        return labels.tolist()

    embeddings = np.stack([f["embedding"] for f in features_list])
    phashes = [f["phash"] for f in features_list]

    sim_matrix = embeddings @ embeddings.T

    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    k = min(VISUAL_KNN, n - 1)
    if k > 0:
        for i in range(n):
            sims_i = sim_matrix[i]
            top_k = np.argpartition(sims_i, -k)[-k:]
            for j in top_k:
                if j == i:
                    continue
                if sims_i[j] > VISUAL_SIM_THRESHOLD:
                    union(i, j)
                elif _hamming_distance(phashes[i], phashes[j]) < PHASH_HAMMING_THRESHOLD:
                    union(i, j)

    root_to_id = {}
    labels = []
    for i in range(n):
        root = find(i)
        if root not in root_to_id:
            root_to_id[root] = len(root_to_id)
        labels.append(root_to_id[root])

    return labels


# ═══════════════════════════════════════════════
# PHASE 3 — Merge Clusters
# ═══════════════════════════════════════════════

def merge_clusters(
    temporal: list[int], geographic: list[int], visual: list[int]
) -> dict[tuple, list[int]]:
    n = len(temporal)
    groups: dict[tuple, list[int]] = {}

    for i in range(n):
        key = (temporal[i], geographic[i], visual[i])
        groups.setdefault(key, []).append(i)

    return groups


# ═══════════════════════════════════════════════
# PHASE 4 — Ranking & Selection
# ═══════════════════════════════════════════════

def _normalize(values: list[float]) -> list[float]:
    if not values:
        return []
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return [0.5] * len(values)
    return [(v - lo) / (hi - lo) for v in values]


_ORIGIN_MULTIPLIER = {
    "self": 1.0,
    "edited": 1.0,
    "received": 0.5,
    "screenshot": 0.2,
}


def compute_composite_score(f: dict, norm_sharp: float, norm_mp: float,
                            origin: str | None = None) -> float:
    raw = (
        0.30 * f["aesthetic_score"]
        + 0.25 * norm_sharp
        + 0.20 * f["exposure_quality"]
        + 0.15 * f["saturation"]
        + 0.10 * norm_mp
    )
    if origin is None:
        origin = f.get("origin", "self")
    return raw * _ORIGIN_MULTIPLIER.get(origin, 1.0)


def rank_and_select(
    groups: dict[tuple, list[int]], features_list: list[dict]
) -> tuple[list[int], list[dict]]:
    keep_indices = set()
    removals = []

    all_sharpness = [f["sharpness"] for f in features_list]
    all_mp = [f["megapixels"] for f in features_list]
    norm_sharp = _normalize(all_sharpness)
    norm_mp = _normalize(all_mp)

    for key, members in groups.items():
        if len(members) == 1:
            keep_indices.add(members[0])
            continue

        scored = []
        for idx in members:
            s = compute_composite_score(features_list[idx], norm_sharp[idx], norm_mp[idx])
            scored.append((idx, s))

        scored.sort(key=lambda x: x[1], reverse=True)

        top_k = 1
        for rank, (idx, score) in enumerate(scored):
            if rank < top_k:
                keep_indices.add(idx)
            else:
                best_idx, best_score = scored[0]
                best_f = features_list[best_idx]

                sim = float(
                    features_list[idx]["embedding"]
                    @ features_list[best_idx]["embedding"]
                )

                removals.append({
                    "path": features_list[idx]["path"],
                    "name": features_list[idx]["name"],
                    "score": round(score, 4),
                    "reason": (
                        f"near-duplicate of {best_f['name']} "
                        f"(similarity={sim:.2f}, "
                        f"score={score:.3f} vs {best_score:.3f})"
                    ),
                    "kept_alternative": best_f["name"],
                })

    return sorted(keep_indices), removals


# ═══════════════════════════════════════════════
# MAIN PIPELINE
# ═══════════════════════════════════════════════

def _run_phases_2_to_4(features_list, gap_seconds):
    """Run clustering + ranking with a given temporal gap. Returns (keep_indices, removals)."""
    temporal_labels = cluster_temporal(features_list, gap_seconds)
    geo_labels = cluster_geographic(features_list)
    visual_labels = cluster_visual(features_list)
    merged = merge_clusters(temporal_labels, geo_labels, visual_labels)
    return rank_and_select(merged, features_list)


def curate(folder: str = None, max_images: int = TARGET_IMAGES) -> dict:
    folder = folder or IMAGES_FOLDER
    extensions = {".jpg", ".jpeg", ".png", ".heic", ".heif"}
    images = [
        p for p in Path(folder).iterdir()
        if p.suffix.lower() in extensions and p.is_file()
    ]

    print(f"\n[curate] Found {len(images)} images in {folder}")

    conn = init_embed_db()
    embed_rows = conn.execute(
        "SELECT file_path, embedding FROM embeddings"
    ).fetchall()
    embed_map = {row[0]: _deserialize(row[1]) for row in embed_rows}
    conn.close()

    rejected_blank = []
    surviving = []

    # Phase 0
    print("[curate] Phase 0 — Early Rejection")
    for img_path in images:
        abs_path = str(img_path.resolve())
        is_rejected, reason = phase0_reject(abs_path)
        if is_rejected:
            rejected_blank.append({"path": abs_path, "name": img_path.name, "reason": reason})
            print(f"  REJECT {img_path.name}: {reason}")
        else:
            surviving.append(abs_path)

    print(f"  {len(rejected_blank)} rejected, {len(surviving)} surviving")

    if not surviving:
        return {
            "keep": [],
            "rejected_blank": rejected_blank,
            "rejected_quality": [],
            "suggested_removals": [],
        }

    # Phase 1
    print("[curate] Phase 1 — Feature Extraction")
    features_list = []
    for abs_path in surviving:
        name = Path(abs_path).name
        try:
            exif = get_exif(abs_path)
        except Exception:
            exif = {}

        embedding = embed_map.get(abs_path)
        if embedding is None:
            try:
                img_tensor = preprocess(
                    Image.open(abs_path).convert("RGB")
                ).unsqueeze(0).to(device)
                with torch.no_grad():
                    vec = model.encode_image(img_tensor).cpu().numpy().flatten()
                embedding = vec / np.linalg.norm(vec)
            except Exception as e:
                print(f"  SKIP {name}: {e}")
                continue

        features = extract_all_features(abs_path, embedding, exif)
        features_list.append(features)
        print(f"  {name}: aesthetic={features['aesthetic_score']:.3f} "
              f"sharp={features['sharpness']:.0f}")

    n = len(features_list)
    print(f"  Extracted features for {n} images")

    if n == 0:
        return {
            "keep": [],
            "rejected_blank": rejected_blank,
            "rejected_quality": [],
            "suggested_removals": [],
        }

    # Quality gate
    print("[curate] Phase 1b \u2014 Quality Gate")
    rejected_quality = []
    quality_pass = []
    for f in features_list:
        reasons = []
        if f["sharpness"] < SHARPNESS_MIN:
            reasons.append(f"sharpness={f['sharpness']:.0f}<{SHARPNESS_MIN}")
        if f["exposure_quality"] < EXPOSURE_MIN:
            reasons.append(f"exposure={f['exposure_quality']:.2f}<{EXPOSURE_MIN}")
        if f["timestamp"] is None:
            reasons.append("no EXIF data")
        if reasons:
            rejected_quality.append({
                "path": f["path"], "name": f["name"],
                "reason": "low quality: " + ", ".join(reasons),
            })
            print(f"  REJECT {f['name']}: {', '.join(reasons)}")
        else:
            quality_pass.append(f)
    features_list = quality_pass
    n = len(features_list)
    print(f"  {len(rejected_quality)} rejected, {n} surviving")

    if n == 0:
        return {
            "keep": [],
            "rejected_blank": rejected_blank,
            "rejected_quality": rejected_quality,
            "suggested_removals": [],
        }

    # Phases 2-4 with binary search on temporal gap
    print("[curate] Phase 2-4 — Binary search for optimal temporal gap")

    if n <= max_images:
        # Already under target, use default gap
        gap = TEMPORAL_GAP_SECONDS
        keep_indices, removals = _run_phases_2_to_4(features_list, gap)
        print(f"  {n} images ≤ {max_images} target, using default gap={gap}s")
    else:
        lo, hi = 1.0, TEMPORAL_GAP_SECONDS
        best_gap = hi
        best_keep = None
        best_removals = None

        for iteration in range(20):
            mid = (lo + hi) / 2
            ki, rm = _run_phases_2_to_4(features_list, mid)
            count = len(ki)
            print(f"  iter={iteration} gap={mid:.0f}s → {count} images")

            if count <= max_images:
                best_gap = mid
                best_keep = ki
                best_removals = rm
                lo = mid
            else:
                hi = mid

            if hi - lo < 1.0:
                break

        if best_keep is None:
            best_keep, best_removals = _run_phases_2_to_4(features_list, 1.0)
            best_gap = 1.0

        keep_indices = best_keep
        removals = best_removals
        print(f"  Final gap={best_gap:.0f}s → {len(keep_indices)} images")

    keep = [
        {"path": features_list[i]["path"], "name": features_list[i]["name"]}
        for i in keep_indices
    ]

    print(f"  Keep: {len(keep)} | Remove: {len(removals)} | Blank: {len(rejected_blank)} | Low quality: {len(rejected_quality)}")

    for r in removals:
        print(f"  REMOVE {r['name']}: {r['reason']}")

    result = {
        "keep": keep,
        "rejected_blank": rejected_blank,
        "rejected_quality": rejected_quality,
        "suggested_removals": removals,
    }

    print(f"[curate] Done.\n")
    return result


if __name__ == "__main__":
    import json
    result = curate()
    print(json.dumps({
        "keep_count": len(result["keep"]),
        "rejected_blank_count": len(result["rejected_blank"]),
        "rejected_quality_count": len(result["rejected_quality"]),
        "removal_count": len(result["suggested_removals"]),
        "keep": [r["name"] for r in result["keep"]],
        "rejected_blank": [r["name"] for r in result["rejected_blank"]],
        "rejected_quality": [r["name"] for r in result["rejected_quality"]],
        "removals": result["suggested_removals"],
    }, indent=2))
