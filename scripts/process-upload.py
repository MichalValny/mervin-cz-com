#!/usr/bin/env python3
"""Build post + gallery files from a staged S3 upload bundle."""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
except ImportError:
    pass

ROOT = Path(__file__).resolve().parent.parent
POSTS_PATH = ROOT / "src" / "data" / "posts.json"
CATEGORIES_PATH = ROOT / "src" / "data" / "categories.json"
CONTENT_DIR = ROOT / "src" / "content" / "posts"
PUBLIC_GALLERIES = ROOT / "public" / "galleries"
STAGING_DIR = ROOT / ".upload-staging"


def slugify(text: str) -> str:
    normalized = unicodedata.normalize("NFKD", text)
    ascii_text = normalized.encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", ascii_text.lower()).strip("-")
    return slug or "clanek"


def unique_slug(base: str, posts: list[dict]) -> str:
    existing = {post["slug"] for post in posts}
    if base not in existing:
        return base
    index = 2
    while f"{base}-{index}" in existing:
        index += 1
    return f"{base}-{index}"


def paragraphs_to_html(text: str) -> str:
    blocks = [block.strip() for block in re.split(r"\n\s*\n", text) if block.strip()]
    if not blocks:
        blocks = [text.strip()] if text.strip() else []
    return "\n\n".join(f"<p>{block.replace(chr(10), '<br>')}</p>" for block in blocks)


def make_excerpt(text: str, max_len: int = 160) -> str:
    plain = re.sub(r"\s+", " ", text).strip()
    if len(plain) <= max_len:
        return plain
    return f"{plain[:max_len].rstrip()}…"


def make_thumb(src: Path, dest: Path, size: int = 320) -> None:
    with Image.open(src) as img:
        img = img.convert("RGB")
        img.thumbnail((size, size), Image.Resampling.LANCZOS)
        dest.parent.mkdir(parents=True, exist_ok=True)
        img.save(dest, "WEBP", quality=82, method=6)


def load_category(category_slug: str) -> dict:
    categories = json.loads(CATEGORIES_PATH.read_text(encoding="utf-8"))
    for category in categories:
        if category["slug"] == category_slug:
            return {
                "id": category["id"],
                "name": category["name"],
                "slug": category["slug"],
            }
    raise SystemExit(f"Unknown category slug: {category_slug}")


def next_post_id(posts: list[dict]) -> int:
    return max((post["id"] for post in posts), default=5000) + 1


def process_upload(staging_path: Path, meta: dict) -> dict:
    posts = json.loads(POSTS_PATH.read_text(encoding="utf-8"))
    category = load_category(meta["categorySlug"])
    date_parts = meta["date"].split("-")
    year, month, day = int(date_parts[0]), int(date_parts[1]), int(date_parts[2])
    base_slug = slugify(meta["title"])
    slug = unique_slug(base_slug, posts)
    post_id = next_post_id(posts)

    photo_dir = staging_path / "photos"
    photo_files = sorted(photo_dir.glob("*"))
    if not photo_files:
        raise SystemExit("No photos found in staging bundle.")

    gallery_dir = PUBLIC_GALLERIES / slug
    thumbs_dir = gallery_dir / "thumbs"
    gallery_dir.mkdir(parents=True, exist_ok=True)
    thumbs_dir.mkdir(parents=True, exist_ok=True)

    images = []
    for index, src in enumerate(photo_files, start=1):
        ext = src.suffix.lower().lstrip(".") or "jpg"
        if ext in {"heic", "heif"}:
            ext = "jpg"
        dest_name = f"{index:03d}.{ext if ext in {'jpg', 'jpeg', 'png', 'webp'} else 'jpg'}"
        dest = gallery_dir / dest_name
        thumb_dest = thumbs_dir / f"{index:03d}.webp"

        with Image.open(src) as img:
            rgb = img.convert("RGB")
            if dest.suffix.lower() in {".jpg", ".jpeg"}:
                rgb.save(dest, "JPEG", quality=90, optimize=True)
            elif dest.suffix.lower() == ".png":
                rgb.save(dest, "PNG", optimize=True)
            else:
                rgb.save(dest.with_suffix(".jpg"), "JPEG", quality=90, optimize=True)
                dest = dest.with_suffix(".jpg")

        make_thumb(dest, thumb_dest)
        alt = f"{meta['galleryTitle']} – fotografie {index}"
        images.append({
            "src": f"/galleries/{slug}/{dest.name}",
            "thumb": f"/galleries/{slug}/thumbs/{thumb_dest.name}",
            "alt": alt,
        })

    featured = gallery_dir / "featured.jpg"
    if not featured.exists():
        first = gallery_dir / Path(images[0]["src"]).name
        with Image.open(first) as img:
            img.convert("RGB").save(featured, "JPEG", quality=90, optimize=True)

    manifest = {
        "slug": slug,
        "title": meta["galleryTitle"],
        "count": len(images),
        "images": images,
    }
    (gallery_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    html = paragraphs_to_html(meta["text"])
    CONTENT_DIR.mkdir(parents=True, exist_ok=True)
    (CONTENT_DIR / f"{slug}.html").write_text(html + "\n", encoding="utf-8")

    post = {
        "id": post_id,
        "title": meta["title"],
        "slug": slug,
        "path": f"/{year}/{month:02d}/{day:02d}/{slug}/",
        "date": meta["date"],
        "year": year,
        "month": month,
        "day": day,
        "link": f"https://www.mervin-cz.com/{year}/{month:02d}/{day:02d}/{slug}/",
        "excerpt": make_excerpt(meta["text"]),
        "galleries": [],
        "featuredImage": f"/galleries/{slug}/featured.jpg",
        "categories": [category],
        "categoryIds": [category["id"]],
        "localGalleries": [
            {
                "slug": slug,
                "title": meta["galleryTitle"],
            }
        ],
    }

    posts.insert(0, post)
    POSTS_PATH.write_text(json.dumps(posts, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    return {
        "slug": slug,
        "path": post["path"],
        "title": post["title"],
        "photoCount": len(images),
    }


def download_staging_from_s3(upload_id: str, bucket: str, prefix: str) -> tuple[Path, dict]:
    import boto3

    s3 = boto3.client("s3")
    staging_path = STAGING_DIR / upload_id
    photos_path = staging_path / "photos"
    photos_path.mkdir(parents=True, exist_ok=True)

    meta_key = f"{prefix}/{upload_id}/meta.json"
    meta_obj = s3.get_object(Bucket=bucket, Key=meta_key)
    meta = json.loads(meta_obj["Body"].read().decode("utf-8"))

    for index, key in enumerate(meta.get("photoKeys", []), start=1):
        obj = s3.get_object(Bucket=bucket, Key=key)
        suffix = Path(key).suffix or ".jpg"
        target = photos_path / f"{index:03d}{suffix}"
        target.write_bytes(obj["Body"].read())

    return staging_path, meta


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: process-upload.py <upload-id>")

    upload_id = sys.argv[1]
    bucket = __import__("os").environ.get("UPLOAD_S3_BUCKET", "mervin-cz-com")
    prefix = __import__("os").environ.get("UPLOAD_S3_PREFIX", "uploads-staging")

    staging_path, meta = download_staging_from_s3(upload_id, bucket, prefix)
    result = process_upload(staging_path, meta)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
