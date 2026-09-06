#!/usr/bin/env python3
"""Download gallery images from Google Photos widget HTML and generate local gallery manifest."""

import json
import re
import sys
import urllib.request
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
POSTS_PATH = ROOT / "src" / "data" / "posts.json"
PUBLIC_DIR = ROOT / "public" / "galleries"


def extract_image_urls(widget_html: str) -> list[str]:
    urls = re.findall(r'<object data="([^"]+)"', widget_html)
    seen: set[str] = set()
    unique: list[str] = []
    for url in urls:
        base = re.sub(r'=w\d+-h\d+$', '', url)
        if base not in seen:
            seen.add(base)
            unique.append(url if '=w' in url else f"{url}=w1920-h1080")
    return unique


def download_file(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "mervin-cz-gallery/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        dest.write_bytes(resp.read())


def make_thumb(src: Path, dest: Path, size: int = 320) -> None:
    with Image.open(src) as img:
        img = img.convert("RGB")
        img.thumbnail((size, size), Image.Resampling.LANCZOS)
        dest.parent.mkdir(parents=True, exist_ok=True)
        img.save(dest, "WEBP", quality=82, method=6)


def download_gallery(slug: str, widget_html: str, title: str | None = None) -> dict:
    urls = extract_image_urls(widget_html)
    gallery_dir = PUBLIC_DIR / slug
    thumbs_dir = gallery_dir / "thumbs"
    gallery_dir.mkdir(parents=True, exist_ok=True)
    thumbs_dir.mkdir(parents=True, exist_ok=True)

    images = []
    for i, url in enumerate(urls, start=1):
        name = f"{i:03d}.jpg"
        thumb_name = f"{i:03d}.webp"
        dest = gallery_dir / name
        thumb_dest = thumbs_dir / thumb_name

        print(f"  [{i}/{len(urls)}] {name}")
        if not dest.exists():
            download_file(url, dest)
        if not thumb_dest.exists():
            make_thumb(dest, thumb_dest)

        images.append({
            "src": f"/galleries/{slug}/{name}",
            "thumb": f"/galleries/{slug}/thumbs/{thumb_name}",
            "alt": f"{title or slug} – fotografie {i}",
        })

    manifest = {"slug": slug, "title": title, "count": len(images), "images": images}
    (gallery_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return manifest


def main() -> None:
    slug = sys.argv[1] if len(sys.argv) > 1 else "zabijacka-mervin-2025"
    posts = json.loads(POSTS_PATH.read_text(encoding="utf-8"))
    post = next((p for p in posts if p["slug"] == slug), None)
    if not post:
        raise SystemExit(f"Post not found: {slug}")

    widget = post["galleries"][0] if post.get("galleries") else None
    if not widget:
        raise SystemExit(f"No gallery widget for: {slug}")

    title_match = re.search(r'data-title="([^"]+)"', widget)
    title = title_match.group(1).replace(" 📸", "") if title_match else None

    print(f"Downloading gallery for {slug} ({title})...")
    manifest = download_gallery(slug, widget, title)
    print(f"Done: {manifest['count']} images → public/galleries/{slug}/")


if __name__ == "__main__":
    main()
