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


def normalize_prefix(prefix: str) -> str:
    return prefix.strip().strip("/")


def normalize_upload_id(raw: str) -> str:
    value = raw.strip().strip("/")
    if not value:
        raise SystemExit("Upload ID is empty.")
    if "/" in value:
        parts = [part for part in value.split("/") if part]
        if len(parts) >= 2 and parts[0] == "uploads-staging":
            return parts[1]
        return parts[-1]
    return value


def staging_object_key(prefix: str, upload_id: str, *parts: str) -> str:
    segments = [normalize_prefix(prefix), normalize_upload_id(upload_id), *parts]
    return "/".join(segment.strip("/") for segment in segments if segment.strip("/"))


def resolve_meta_key(s3, bucket: str, prefix: str, upload_id: str) -> str:
    import botocore

    normalized_id = normalize_upload_id(upload_id)
    normalized_prefix = normalize_prefix(prefix)
    permission_errors: list[str] = []
    candidates = [
        staging_object_key(prefix, upload_id, "meta.json"),
        f"{normalized_prefix}/{normalized_id}/meta.json",
        f"{normalized_prefix}//{normalized_id}/meta.json",
    ]
    seen = set()
    for meta_key in candidates:
        if meta_key in seen:
            continue
        seen.add(meta_key)
        try:
            s3.head_object(Bucket=bucket, Key=meta_key)
            return meta_key
        except botocore.exceptions.ClientError as error:
            code = error.response.get("Error", {}).get("Code")
            if code in {"403", "AccessDenied"}:
                permission_errors.append(meta_key)
                continue
            if code not in {"404", "NoSuchKey", "NotFound"}:
                raise

    response = s3.list_objects_v2(
        Bucket=bucket,
        Prefix=f"{normalized_prefix}/",
        Delimiter="/",
    )
    for common_prefix in response.get("CommonPrefixes", []):
        folder = common_prefix.get("Prefix", "")
        folder_id = folder.rstrip("/").split("/")[-1]
        if folder_id != normalized_id:
            continue
        meta_key = f"{folder}meta.json"
        try:
            s3.head_object(Bucket=bucket, Key=meta_key)
            return meta_key
        except botocore.exceptions.ClientError as error:
            code = error.response.get("Error", {}).get("Code")
            if code in {"403", "AccessDenied"}:
                permission_errors.append(meta_key)
                continue
            if code not in {"404", "NoSuchKey", "NotFound"}:
                raise

    search_prefixes = []
    for candidate in [normalized_prefix, "uploads-staging", "upload-staging"]:
        if candidate and candidate not in search_prefixes:
            search_prefixes.append(candidate)

    for search_prefix in search_prefixes:
        scan_prefix = f"{search_prefix}/"
        paginator = s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=bucket, Prefix=scan_prefix):
            for item in page.get("Contents", []):
                key = item.get("Key", "")
                if not key.endswith("/meta.json"):
                    continue
                if f"/{normalized_id}/" not in key and not key.endswith(f"/{normalized_id}/meta.json"):
                    continue
                try:
                    s3.head_object(Bucket=bucket, Key=key)
                    return key
                except botocore.exceptions.ClientError as error:
                    code = error.response.get("Error", {}).get("Code")
                    if code in {"403", "AccessDenied"}:
                        permission_errors.append(key)
                        continue
                    if code not in {"404", "NoSuchKey", "NotFound"}:
                        raise

    listing_prefix = staging_object_key(prefix, upload_id)
    response = s3.list_objects_v2(Bucket=bucket, Prefix=f"{listing_prefix}/", MaxKeys=5)
    found_keys = [item["Key"] for item in response.get("Contents", []) if item.get("Key")]

    folder_response = s3.list_objects_v2(
        Bucket=bucket,
        Prefix=f"{normalized_prefix}/",
        Delimiter="/",
    )
    visible_folders = [
        entry.get("Prefix", "").rstrip("/").split("/")[-1]
        for entry in folder_response.get("CommonPrefixes", [])
        if entry.get("Prefix")
    ]

    hint = ""
    if found_keys:
        hint = f" Found objects under s3://{bucket}/{listing_prefix}/: {', '.join(found_keys[:5])}."
    else:
        hint = f" No objects found under s3://{bucket}/{listing_prefix}/."
    if visible_folders:
        hint += f" Visible folders under {normalized_prefix}/: {', '.join(visible_folders[:10])}."
    else:
        hint += f" No folders visible under s3://{bucket}/{normalized_prefix}/."

    if permission_errors:
        raise SystemExit(
            "Cannot read upload bundle from S3 (AccessDenied). "
            f"Bucket {bucket}, tried keys including {permission_errors[0]}. "
            "Use AWS credentials for the same account as the upload API, or rerun Bootstrap AWS."
        )

    raise SystemExit(
        "Upload bundle not found in S3. "
        f"Tried keys: {', '.join(seen)} in bucket {bucket}.{hint} "
        "Verify the upload ID from S3 and that UPLOAD_S3_BUCKET / UPLOAD_S3_PREFIX match the upload API."
    )


def log_aws_identity(s3) -> None:
    import boto3

    sts = boto3.client("sts", region_name=s3.meta.region_name)
    identity = sts.get_caller_identity()
    print(
        f"AWS identity: account={identity.get('Account')} arn={identity.get('Arn')}",
        file=sys.stderr,
    )


def download_staging_from_s3(upload_id: str, bucket: str, prefix: str) -> tuple[Path, dict]:
    import boto3

    region = __import__("os").environ.get("AWS_REGION", "us-east-1")
    normalized_id = normalize_upload_id(upload_id)
    normalized_prefix = normalize_prefix(prefix)
    s3 = boto3.client("s3", region_name=region)
    staging_path = STAGING_DIR / normalized_id
    photos_path = staging_path / "photos"
    photos_path.mkdir(parents=True, exist_ok=True)

    log_aws_identity(s3)
    print(
        f"Downloading upload bundle from s3://{bucket}/{normalized_prefix}/{normalized_id}/ "
        f"(region={region})",
        file=sys.stderr,
    )

    meta_key = resolve_meta_key(s3, bucket, normalized_prefix, normalized_id)
    meta_obj = s3.get_object(Bucket=bucket, Key=meta_key)
    meta = json.loads(meta_obj["Body"].read().decode("utf-8"))

    effective_bucket = meta.get("storageBucket", bucket)
    for index, key in enumerate(meta.get("photoKeys", []), start=1):
        obj = s3.get_object(Bucket=effective_bucket, Key=key)
        suffix = Path(key).suffix or ".jpg"
        target = photos_path / f"{index:03d}{suffix}"
        target.write_bytes(obj["Body"].read())

    return staging_path, meta


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: process-upload.py <upload-id>")

    upload_id = sys.argv[1]
    bucket = __import__("os").environ.get("UPLOAD_S3_BUCKET", "web-mervin-cz-com")
    prefix = __import__("os").environ.get("UPLOAD_S3_PREFIX", "uploads-staging")

    staging_path, meta = download_staging_from_s3(upload_id, bucket, prefix)
    result = process_upload(staging_path, meta)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
