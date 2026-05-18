# face_logic.py
import logging
import cv2
import cv2 as cv
import numpy as np
import os
from sklearn.preprocessing import normalize
from sklearn.cluster import DBSCAN
from collections import Counter

log = logging.getLogger("quemory.face")

MODELS_DIR = os.path.join(os.path.dirname(__file__), "models")
YUNET_MODEL = os.path.join(MODELS_DIR, "face_detection_yunet_2023mar.onnx")
SFACE_MODEL = os.path.join(MODELS_DIR, "face_recognition_sface_2021dec.onnx")

detector = None
recognizer = None


def _ensure_models_loaded():
    global detector, recognizer
    if detector is not None and recognizer is not None:
        return detector, recognizer

    if not os.path.exists(YUNET_MODEL):
        log.error("Missing face detector model: %s", YUNET_MODEL)
        raise FileNotFoundError(f"Missing face detector model: {YUNET_MODEL}")
    if not os.path.exists(SFACE_MODEL):
        log.error("Missing face recognizer model: %s", SFACE_MODEL)
        raise FileNotFoundError(f"Missing face recognizer model: {SFACE_MODEL}")

    log.info("Loading face models (YuNet + SFace) from %s", MODELS_DIR)
    detector = cv.FaceDetectorYN.create(
        YUNET_MODEL, "", (320, 320), 0.9, 0.3, 5000
    )
    recognizer = cv.FaceRecognizerSF.create(SFACE_MODEL, "")
    log.info("Face models loaded")
    return detector, recognizer

def extract_faces_for_embedding(imgPath: str) -> list[dict]:
    detector, recognizer = _ensure_models_loaded()
    img = cv2.imread(imgPath)
    if img is None:
        log.warning("Cannot read image for face detection: %s", imgPath)
        raise ValueError(f"Cannot read image: {imgPath}")

    h, w = img.shape[:2]
    detector.setInputSize((w, h))
    _, faces = detector.detect(img)

    results = []
    if faces is None:
        log.debug("No faces detected in %s", imgPath)
        return results

    for f in faces:
        aligned = recognizer.alignCrop(img, f)
        results.append({
            "bbox": f[:4].tolist(),
            "score": float(f[14]),
            "aligned_face": aligned
        })
    log.debug("Detected %d face(s) in %s", len(results), imgPath)
    return results

def faces_to_embeddings(face_items: list[dict]) -> list[dict]:
    _, recognizer = _ensure_models_loaded()
    results = []
    for item in face_items:
        emb = recognizer.feature(item["aligned_face"]).flatten().astype(np.float32)
        results.append({
            "bbox": item["bbox"],
            "score": item["score"],
            "embedding": emb
        })
    return results

def cluster_embeddings(face_items, eps=0.30, min_samples=2) -> tuple[list[dict], int | None, int]:
    if not face_items:
        log.debug("cluster_embeddings: empty input")
        return [], None, 0

    X = np.vstack([item["embedding"] for item in face_items]).astype(np.float32)
    X = normalize(X, norm="l2", axis=1)

    clustering = DBSCAN(
        eps=eps,
        min_samples=min_samples,
        metric="cosine"
    ).fit(X)

    labels = clustering.labels_
    for item, label in zip(face_items, labels):
        item["cluster_id"] = int(label)

    valid = [x for x in labels if x != -1]
    if not valid:
        log.info("cluster_embeddings: %d face(s), no cluster found", len(face_items))
        return face_items, None, 0

    counts = Counter(valid)
    top_cluster, top_count = counts.most_common(1)[0]
    log.info(
        "cluster_embeddings: %d face(s) -> %d cluster(s); top cluster=%d size=%d",
        len(face_items), len(counts), top_cluster, top_count,
    )
    return face_items, int(top_cluster), int(top_count)

def find_top_face(image_paths: list[str]) -> dict | None:
    all_face_items = []

    for image_path in image_paths:
        face_items = extract_faces_for_embedding(image_path)
        embedded_items = faces_to_embeddings(face_items)

        for item in embedded_items:
            item["image_path"] = image_path
        all_face_items.extend(embedded_items)

    clustered_items, top_cluster, top_count = cluster_embeddings(
        all_face_items,
        eps=0.30,
        min_samples=2
    )

    if top_cluster is None:
        return None

    most_frequent_faces = [
        item for item in clustered_items
        if item["cluster_id"] == top_cluster
    ]

    # choose one representative face to save in the trip row
    # here: highest detection score
    best_face = max(most_frequent_faces, key=lambda x: x["score"])

    return {
        "image_path": best_face["image_path"],
        "bbox": best_face["bbox"],
        "count": top_count
    }
