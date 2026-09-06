#!/usr/bin/env python3
"""Migrate all Google Photos widget galleries to self-hosted local galleries."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from download_gallery import download_file, download_gallery, extract_image_urls, make_thumb

ROOT = Path(__file__).resolve().parent.parent
POSTS_PATH = ROOT / "src" / "data" / "posts.json"
PUBLIC_DIR = ROOT / "public" / "galleries"
PROGRESS_PATH = ROOT / "scripts" / ".migrate-progress.json"


def load_posts() -> list[dict]:
    return json.loads(POSTS_PATH.read_text(encoding="utf-8"))


def save_posts(posts: list[dict]) -> None:
    POSTS_PATH.write_text(
        json.dumps(posts, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def gallery_title(widget_html: str) -> str | None:
    match = re.search(r'data-title="([^"]+)"', widget_html)
    if not match:
        return None
    return match.group(1).replace(" 📸", "").strip()


def gallery_slug(post_slug: str, index: int) -> str:
    return post_slug if index == 0 else f"{post_slug}-{index + 1}"


def gallery_complete(slug: str, expected_count: int) -> bool:
    manifest_path = PUBLIC_DIR / slug / "manifest.json"
    if not manifest_path.exists():
        return False
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return False
    if manifest.get("count") != expected_count:
        return False
    gallery_dir = PUBLIC_DIR / slug
    for i in range(1, expected_count + 1):
        if not (gallery_dir / f"{i:03d}.jpg").exists():
            return False
        if not (gallery_dir / "thumbs" / f"{i:03d}.webp").exists():
            return False
    return True


def download_featured(slug: str, url: str) -> str | None:
    if not url or url.startswith("/"):
        return url or None

    dest = PUBLIC_DIR / slug / "featured.jpg"
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        return f"/galleries/{slug}/featured.jpg"

    try:
        download_file(url, dest)
        make_thumb(dest, PUBLIC_DIR / slug / "featured-thumb.webp", size=640)
        return f"/galleries/{slug}/featured.jpg"
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print(f"  ! featured image failed: {exc}", file=sys.stderr)
        return None


def compact_local_gallery(post: dict) -> None:
    """Replace inline image lists with slug references when manifest exists."""
    local = post.get("localGalleries")
    if not local:
        return

    compact: list[dict] = []
    changed = False
    for index, gallery in enumerate(local):
        if gallery.get("slug") and not gallery.get("images"):
            compact.append(gallery)
            continue

        slug = gallery.get("slug") or gallery_slug(post["slug"], index)
        manifest_path = PUBLIC_DIR / slug / "manifest.json"
        if manifest_path.exists() and gallery.get("images"):
            compact.append({"slug": slug, "title": gallery.get("title")})
            changed = True
        else:
            compact.append(gallery)

    if changed:
        post["localGalleries"] = compact


def migrate_post(post: dict, *, dry_run: bool = False) -> dict:
    widgets = [g for g in post.get("galleries", []) if g]
    if not widgets and post.get("localGalleries"):
        compact_local_gallery(post)
        return {"slug": post["slug"], "galleries": 0, "images": 0, "skipped": "already-local"}

    if not widgets:
        return {"slug": post["slug"], "galleries": 0, "images": 0, "skipped": "no-gallery"}

    post_slug = post["slug"]
    local_refs: list[dict] = []
    total_images = 0

    print(f"\n=== {post_slug} ({len(widgets)} gallery/widgets) ===", flush=True)

    try:
        for index, widget in enumerate(widgets):
            slug = gallery_slug(post_slug, index)
            title = gallery_title(widget)
            urls = extract_image_urls(widget)
            count = len(urls)

            if count == 0:
                print(f"  [{slug}] no images found, skipping", flush=True)
                continue

            if gallery_complete(slug, count):
                print(f"  [{slug}] already complete ({count} images)", flush=True)
            elif dry_run:
                print(f"  [{slug}] would download {count} images", flush=True)
            else:
                print(f"  [{slug}] downloading {count} images...", flush=True)
                download_gallery(slug, widget, title)

            local_refs.append({"slug": slug, "title": title})
            total_images += count

        featured = post.get("featuredImage")
        if featured and not featured.startswith("/") and local_refs and not dry_run:
            featured_local = download_featured(post_slug, featured)
            if featured_local:
                post["featuredImage"] = featured_local
            elif local_refs:
                first_slug = local_refs[0]["slug"]
                post["featuredImage"] = f"/galleries/{first_slug}/001.jpg"

        if not dry_run and local_refs:
            post["localGalleries"] = local_refs
            post["galleries"] = []
    except Exception as exc:
        return {
            "slug": post_slug,
            "galleries": len(local_refs),
            "images": total_images,
            "error": str(exc),
        }

    return {
        "slug": post_slug,
        "galleries": len(local_refs),
        "images": total_images,
    }


def load_progress() -> set[str]:
    if not PROGRESS_PATH.exists():
        return set()
    data = json.loads(PROGRESS_PATH.read_text(encoding="utf-8"))
    return set(data.get("completed", []))


def save_progress(completed: set[str]) -> None:
    PROGRESS_PATH.write_text(
        json.dumps({"completed": sorted(completed)}, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slug", help="Migrate a single post slug")
    parser.add_argument("--dry-run", action="store_true", help="Only report work, do not download")
    parser.add_argument("--limit", type=int, help="Process at most N posts")
    parser.add_argument("--save-every", type=int, default=1, help="Write posts.json every N posts")
    args = parser.parse_args()

    posts = load_posts()
    completed = load_progress()

    candidates = []
    for post in posts:
        widgets = [g for g in post.get("galleries", []) if g]
        has_inline_local = any(g.get("images") for g in post.get("localGalleries", []))
        if widgets or has_inline_local:
            candidates.append(post)

    if args.slug:
        candidates = [p for p in candidates if p["slug"] == args.slug]
        if not candidates:
            raise SystemExit(f"No migratable post found for slug: {args.slug}")

    if args.limit:
        candidates = candidates[: args.limit]

    print(f"Migrating {len(candidates)} posts...")
    started = time.time()
    summary_images = 0

    for index, post in enumerate(candidates, start=1):
        if post["slug"] in completed and not args.slug:
            print(f"[{index}/{len(candidates)}] skip completed: {post['slug']}")
            continue

        result = migrate_post(post, dry_run=args.dry_run)
        summary_images += result.get("images", 0)

        if not args.dry_run and result.get("skipped") != "no-gallery":
            if result.get("error"):
                print(f"  ! failed: {result['error']}", file=sys.stderr)
            else:
                completed.add(post["slug"])
                if index % args.save_every == 0 or index == len(candidates):
                    save_posts(posts)
                    save_progress(completed)
                    print(f"  saved progress ({len(completed)} completed, {index}/{len(candidates)})", flush=True)

    elapsed = time.time() - started
    print(f"\nDone in {elapsed:.0f}s, ~{summary_images} images processed")


if __name__ == "__main__":
    main()
