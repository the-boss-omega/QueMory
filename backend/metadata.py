"""
Complete Photo Metadata Extractor
==================================
Extracts ALL available EXIF data from every photo in a folder.

Usage:
    pip install Pillow geopy
    python extract_all_metadata.py

Put your photos in a folder called "photos" next to this script.
"""

from pathlib import Path
from PIL import Image
from PIL.ExifTags import TAGS, GPSTAGS
from datetime import datetime
import hashlib
import os
import struct
import json

PHOTOS_FOLDER = "D:/Proj/QueMory2/assets/images1"


# ═══════════════════════════════════════════════
# EXIF READING
# ═══════════════════════════════════════════════

def get_exif(image_path: str) -> dict:
    """Extract all EXIF tags as a readable dictionary."""
    img = Image.open(image_path)
    raw = img._getexif()
    if not raw:
        return {}
    exif = {}
    for tag_id, value in raw.items():
        name = TAGS.get(tag_id, tag_id)
        exif[name] = value
    return exif


def get_gps_dict(exif: dict) -> dict:
    """Parse GPSInfo into named fields."""
    gps_raw = exif.get("GPSInfo")
    if not gps_raw:
        return {}
    gps = {}
    for key, val in gps_raw.items():
        name = GPSTAGS.get(key, key)
        gps[name] = val
    return gps


# ═══════════════════════════════════════════════
# WHEN — date and time
# ═══════════════════════════════════════════════

def extract_when(exif: dict) -> dict:
    result = {
        "date_taken": None,
        "date_digitized": None,
        "date_modified": None,
        "timezone": None,
    }

    if "DateTimeOriginal" in exif:
        try:
            result["date_taken"] = datetime.strptime(exif["DateTimeOriginal"], "%Y:%m:%d %H:%M:%S").isoformat()
        except ValueError:
            result["date_taken"] = str(exif["DateTimeOriginal"])

    if "DateTimeDigitized" in exif:
        try:
            result["date_digitized"] = datetime.strptime(exif["DateTimeDigitized"], "%Y:%m:%d %H:%M:%S").isoformat()
        except ValueError:
            result["date_digitized"] = str(exif["DateTimeDigitized"])

    if "DateTime" in exif:
        try:
            result["date_modified"] = datetime.strptime(exif["DateTime"], "%Y:%m:%d %H:%M:%S").isoformat()
        except ValueError:
            result["date_modified"] = str(exif["DateTime"])

    if "OffsetTimeOriginal" in exif:
        result["timezone"] = str(exif["OffsetTimeOriginal"])
    elif "OffsetTime" in exif:
        result["timezone"] = str(exif["OffsetTime"])

    return result


# ═══════════════════════════════════════════════
# WHERE — GPS location
# ═══════════════════════════════════════════════

def gps_to_decimal(value, ref) -> float:
    """Convert EXIF GPS format to decimal degrees."""
    try:
        d = float(value[0])
        m = float(value[1])
        s = float(value[2])
    except (TypeError, IndexError):
        return 0.0
    decimal = d + (m / 60.0) + (s / 3600.0)
    if ref in ["S", "W"]:
        decimal = -decimal
    return round(decimal, 6)


def extract_where(exif: dict) -> dict:
    result = {
        "latitude": None,
        "longitude": None,
        "altitude_meters": None,
        "direction_degrees": None,
        "speed_kmh": None,
        "address": None,
    }

    gps = get_gps_dict(exif)
    if not gps:
        return result

    if all(k in gps for k in ["GPSLatitude", "GPSLatitudeRef", "GPSLongitude", "GPSLongitudeRef"]):
        result["latitude"] = gps_to_decimal(gps["GPSLatitude"], gps["GPSLatitudeRef"])
        result["longitude"] = gps_to_decimal(gps["GPSLongitude"], gps["GPSLongitudeRef"])

    if "GPSAltitude" in gps:
        try:
            alt = float(gps["GPSAltitude"])
            ref = gps.get("GPSAltitudeRef", 0)
            if ref == 1:
                alt = -alt
            result["altitude_meters"] = round(alt, 1)
        except (TypeError, ValueError):
            pass

    if "GPSImgDirection" in gps:
        try:
            result["direction_degrees"] = round(float(gps["GPSImgDirection"]), 1)
        except (TypeError, ValueError):
            pass

    if "GPSSpeed" in gps:
        try:
            speed = float(gps["GPSSpeed"])
            ref = gps.get("GPSSpeedRef", "K")
            if ref == "M":
                speed *= 1.60934
            elif ref == "N":
                speed *= 1.852
            result["speed_kmh"] = round(speed, 1)
        except (TypeError, ValueError):
            pass

    if result["latitude"] and result["longitude"]:
        try:
            from geopy.geocoders import Nominatim
            geo = Nominatim(user_agent="smart_album_meta")
            loc = geo.reverse(f"{result['latitude']}, {result['longitude']}", language="en", timeout=5)
            if loc:
                result["address"] = loc.address
        except Exception:
            pass

    return result


# ═══════════════════════════════════════════════
# CAMERA — device and settings
# ═══════════════════════════════════════════════

def extract_camera(exif: dict) -> dict:
    result = {
        "make": None,
        "model": None,
        "lens": None,
        "focal_length_mm": None,
        "aperture": None,
        "shutter_speed": None,
        "iso": None,
        "flash_fired": None,
        "exposure_mode": None,
        "white_balance": None,
        "scene_type": None,
    }

    result["make"] = str(exif.get("Make", "")).strip() or None
    result["model"] = str(exif.get("Model", "")).strip() or None

    if "LensModel" in exif:
        result["lens"] = str(exif["LensModel"]).strip()
    elif "LensMake" in exif:
        result["lens"] = str(exif["LensMake"]).strip()

    if "FocalLength" in exif:
        try:
            result["focal_length_mm"] = round(float(exif["FocalLength"]), 1)
        except (TypeError, ValueError):
            pass

    if "FNumber" in exif:
        try:
            result["aperture"] = f"f/{float(exif['FNumber']):.1f}"
        except (TypeError, ValueError):
            pass

    if "ExposureTime" in exif:
        try:
            exp = float(exif["ExposureTime"])
            if exp < 1:
                result["shutter_speed"] = f"1/{int(1/exp)}s"
            else:
                result["shutter_speed"] = f"{exp:.1f}s"
        except (TypeError, ValueError, ZeroDivisionError):
            pass

    if "ISOSpeedRatings" in exif:
        try:
            iso = exif["ISOSpeedRatings"]
            result["iso"] = int(iso) if not isinstance(iso, tuple) else int(iso[0])
        except (TypeError, ValueError):
            pass

    if "Flash" in exif:
        try:
            flash_val = int(exif["Flash"])
            result["flash_fired"] = bool(flash_val & 1)
        except (TypeError, ValueError):
            pass

    if "ExposureMode" in exif:
        modes = {0: "Auto", 1: "Manual", 2: "Auto bracket"}
        try:
            result["exposure_mode"] = modes.get(int(exif["ExposureMode"]), str(exif["ExposureMode"]))
        except (TypeError, ValueError):
            pass

    if "WhiteBalance" in exif:
        wb = {0: "Auto", 1: "Manual"}
        try:
            result["white_balance"] = wb.get(int(exif["WhiteBalance"]), str(exif["WhiteBalance"]))
        except (TypeError, ValueError):
            pass

    if "SceneCaptureType" in exif:
        scenes = {0: "Standard", 1: "Landscape", 2: "Portrait", 3: "Night"}
        try:
            result["scene_type"] = scenes.get(int(exif["SceneCaptureType"]), str(exif["SceneCaptureType"]))
        except (TypeError, ValueError):
            pass

    return result


# ═══════════════════════════════════════════════
# IMAGE PROPERTIES — dimensions, format, size
# ═══════════════════════════════════════════════

def extract_image_properties(image_path: str, exif: dict) -> dict:
    img = Image.open(image_path)
    stat = os.stat(image_path)
    path = Path(image_path)

    result = {
        "width_px": img.width,
        "height_px": img.height,
        "megapixels": round((img.width * img.height) / 1_000_000, 1),
        "orientation": None,
        "aspect_ratio": None,
        "file_size_mb": round(stat.st_size / (1024 * 1024), 2),
        "file_format": path.suffix.upper().replace(".", ""),
        "color_space": None,
    }

    if img.width > img.height:
        result["orientation"] = "Landscape"
    elif img.height > img.width:
        result["orientation"] = "Portrait"
    else:
        result["orientation"] = "Square"

    from math import gcd
    g = gcd(img.width, img.height)
    w_ratio = img.width // g
    h_ratio = img.height // g
    common = {(4, 3): "4:3", (3, 4): "3:4", (16, 9): "16:9", (9, 16): "9:16",
              (1, 1): "1:1", (3, 2): "3:2", (2, 3): "2:3"}
    result["aspect_ratio"] = common.get((w_ratio, h_ratio), f"{w_ratio}:{h_ratio}")

    ratio = max(img.width, img.height) / min(img.width, img.height)
    if ratio > 2.5:
        result["aspect_ratio"] += " (Panorama)"

    if "ColorSpace" in exif:
        spaces = {1: "sRGB", 65535: "Uncalibrated"}
        try:
            result["color_space"] = spaces.get(int(exif["ColorSpace"]), str(exif["ColorSpace"]))
        except (TypeError, ValueError):
            pass

    return result


# ═══════════════════════════════════════════════
# SOFTWARE — editing and origin detection
# ═══════════════════════════════════════════════

def extract_software(exif: dict, image_path: str) -> dict:
    result = {
        "software": None,
        "is_edited": False,
        "is_screenshot": False,
        "is_downloaded": False,
    }

    if "Software" in exif:
        result["software"] = str(exif["Software"]).strip()
        edit_apps = ["lightroom", "photoshop", "snapseed", "vsco", "afterlight", "gimp", "darktable"]
        if any(app in result["software"].lower() for app in edit_apps):
            result["is_edited"] = True

    img = Image.open(image_path)
    screen_sizes = [
        (1170, 2532), (1179, 2556), (1284, 2778), (1290, 2796),
        (1080, 2400), (1080, 2340), (1440, 3200), (1440, 3088),
        (2360, 1640), (2732, 2048), (2388, 1668),
    ]
    dims = (img.width, img.height)
    dims_flipped = (img.height, img.width)
    if dims in screen_sizes or dims_flipped in screen_sizes:
        if "Model" not in exif and "GPSInfo" not in exif:
            result["is_screenshot"] = True

    if not exif or len(exif) < 3:
        result["is_downloaded"] = True

    return result


# ═══════════════════════════════════════════════
# PERCEPTUAL HASH — for duplicate detection
# ═══════════════════════════════════════════════

def compute_phash(image_path: str) -> str:
    img = Image.open(image_path).convert("L")
    img = img.resize((8, 8), Image.Resampling.LANCZOS)
    pixels = list(img.getdata())
    avg = sum(pixels) / len(pixels)
    bits = "".join("1" if p > avg else "0" for p in pixels)
    return hex(int(bits, 2))[2:].zfill(16)


# ═══════════════════════════════════════════════
# PRINT HELPERS
# ═══════════════════════════════════════════════

def print_section(title: str, data: dict):
    """Print a section with only non-None values."""
    items = {k: v for k, v in data.items() if v is not None}
    if not items:
        print(f"\n  {title}")
        print(f"    No data found")
        return

    print(f"\n  {title}")
    max_key = max(len(k) for k in items)
    for key, value in items.items():
        label = key.replace("_", " ").title()
        val_str = str(value)
        if len(val_str) > 80:
            val_str = val_str[:77] + "..."
        print(f"    {label:<{max_key + 4}} {val_str}")


# ═══════════════════════════════════════════════
# PUBLIC FUNCTIONS
# ═══════════════════════════════════════════════

def extractorPrintAll():
    """Prints ALL metadata for every photo in PHOTOS_FOLDER."""
    folder = Path(PHOTOS_FOLDER)

    if not folder.exists():
        print(f"\nFolder '{PHOTOS_FOLDER}' not found.")
        return

    extensions = {".jpg", ".jpeg", ".png", ".heic", ".tiff", ".webp", ".bmp"}
    photos = [f for f in folder.iterdir() if f.suffix.lower() in extensions]

    if not photos:
        print(f"\nNo photos found in '{PHOTOS_FOLDER}/'")
        return

    print(f"\n{'=' * 60}")
    print(f"  COMPLETE METADATA EXTRACTION")
    print(f"  {len(photos)} photos in '{PHOTOS_FOLDER}/'")
    print(f"{'=' * 60}")

    for photo in sorted(photos):
        print(f"\n{'─' * 60}")
        print(f"  {photo.name}")
        print(f"{'─' * 60}")

        try:
            exif = get_exif(str(photo))
        except Exception:
            print(f"\n  UnidentifiedImageError — skipping this file\n")
            continue

        when = extract_when(exif)
        print_section("WHEN", when)

        where = extract_where(exif)
        print_section("WHERE", where)

        camera = extract_camera(exif)
        print_section("CAMERA", camera)

        props = extract_image_properties(str(photo), exif)
        print_section("IMAGE", props)

        software = extract_software(exif, str(photo))
        print_section("ORIGIN", software)

        phash = compute_phash(str(photo))
        print(f"\n  FINGERPRINT")
        print(f"    Perceptual Hash    {phash}")

        print(f"\n  RAW EXIF")
        print(f"    Total Tags Found   {len(exif)}")
        if exif:
            tag_names = [str(k) for k in sorted(exif.keys()) if isinstance(k, str)]
            shown = tag_names[:10]
            remaining = len(tag_names) - 10
            print(f"    Tags               {', '.join(shown)}", end="")
            if remaining > 0:
                print(f" ... +{remaining} more")
            else:
                print()

    print(f"\n{'=' * 60}")
    print(f"  Done. Processed {len(photos)} photos.")
    print(f"{'=' * 60}\n")


def extractorLocation(images: list) -> list:
    """
    Takes a list of image file paths.
    Returns a list of tuples: (filename, latitude, longitude, altitude, address)
    Skips images that can't be opened or have no GPS data.

    Usage:
        paths = ["photos/beach.jpg", "photos/dinner.jpg"]
        locations = extractorLocation(paths)
        for filename, lat, lon, alt, address in locations:
            print(f"{filename}: {lat}, {lon} — {address}")
    """
    results = []

    for image_path in images:
        filename = Path(image_path).name

        try:
            exif = get_exif(str(image_path))
        except Exception:
            print(f"  UnidentifiedImageError — skipping {filename}")
            continue

        where = extract_where(exif)

        if where["latitude"] is None or where["longitude"] is None:
            continue

        results.append((
            filename,
            where["latitude"],
            where["longitude"],
            where["altitude_meters"],
            where["address"],
        ))

    return results



 
def extractorLocationToJson(images: list, output_path: str = "locations.json"):
    """Save locations as JSON for Flutter to read."""
    locations = extractorLocation(images)
    data = [
        {
            "filename": filename,
            "latitude": lat,
            "longitude": lon,
            "altitude": alt,
            "address": address or "",
        }
        for filename, lat, lon, alt, address in locations
    ]

    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Saved {len(data)} locations to {output_path}")


def extractorPrintLocation(images: list):
    """Prints location data for a list of image paths."""
    locations = extractorLocation(images)

    if not locations:
        print("No GPS data found in any of the images.")
        return

    print(f"\n{'=' * 60}")
    print(f"  LOCATIONS — {len(locations)} photos with GPS")
    print(f"{'=' * 60}")

    for filename, lat, lon, alt, address in locations:
        print(f"\n  {filename}")
        print(f"    Lat/Lon    {lat}, {lon}")
        if alt is not None:
            print(f"    Altitude   {alt}m")
        if address:
            addr = address if len(address) <= 70 else address[:67] + "..."
            print(f"    Address    {addr}")

    print(f"\n{'=' * 60}\n")


def extractorPrintWhen(images: list):
    """Prints date/time data for a list of image paths."""
    print(f"\n{'=' * 60}")
    print(f"  DATES — {len(images)} photos")
    print(f"{'=' * 60}")

    for image_path in images:
        filename = Path(image_path).name

        try:
            exif = get_exif(str(image_path))
        except Exception:
            print(f"\n  {filename}")
            print(f"    UnidentifiedImageError — skipping")
            continue

        when = extract_when(exif)

        print(f"\n  {filename}")
        if when["date_taken"]:
            print(f"    Taken      {when['date_taken']}")
        else:
            print(f"    Taken      No date found")
        if when["timezone"]:
            print(f"    Timezone   {when['timezone']}")

    print(f"\n{'=' * 60}\n")


def extractorPrintCamera(images: list):
    """Prints camera data for a list of image paths."""
    print(f"\n{'=' * 60}")
    print(f"  CAMERAS — {len(images)} photos")
    print(f"{'=' * 60}")

    for image_path in images:
        filename = Path(image_path).name

        try:
            exif = get_exif(str(image_path))
        except Exception:
            print(f"\n  {filename}")
            print(f"    UnidentifiedImageError — skipping")
            continue

        camera = extract_camera(exif)

        print(f"\n  {filename}")
        if camera["model"]:
            print(f"    Camera     {camera['make'] or ''} {camera['model']}".rstrip())
        if camera["lens"]:
            print(f"    Lens       {camera['lens']}")
        if camera["aperture"]:
            print(f"    Settings   {camera['aperture']}, {camera['shutter_speed'] or '?'}, ISO {camera['iso'] or '?'}")
        if not camera["model"] and not camera["lens"]:
            print(f"    No camera data found")

    print(f"\n{'=' * 60}\n")


if __name__ == "__main__":
    extractorPrintAll()
    folder = Path(PHOTOS_FOLDER)
    extensions = {".jpg", ".jpeg", ".png", ".heic", ".tiff", ".webp", ".bmp"}
    photos = [f for f in folder.iterdir() if f.suffix.lower() in extensions]
    extractorLocationToJson(photos)