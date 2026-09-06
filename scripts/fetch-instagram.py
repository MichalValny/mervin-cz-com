#!/usr/bin/env python3
"""Fetch latest Instagram posts for the static site build."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "src" / "data" / "instagram.json"
LIMIT = 8
WP_ACCOUNT_ID = "28316371414628054"
DEFAULT_USERNAME = "mervinczcom"
DEFAULT_PROFILE_URL = "https://www.instagram.com/mervinczcom/"


def fetch_json(url: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "mervin-cz-com/2.0 (+https://www.mervin-cz.com)"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def normalize_post(post_id: str, permalink: str, image_url: str, media_type: str) -> dict:
    return {
        "id": post_id,
        "permalink": permalink,
        "imageUrl": image_url,
        "mediaType": media_type,
    }


def fetch_from_graph_api() -> dict | None:
    token = os.environ.get("INSTAGRAM_ACCESS_TOKEN")
    if not token:
        return None

    user_id = os.environ.get("INSTAGRAM_USER_ID", "me")
    params = urllib.parse.urlencode(
        {
            "fields": "id,caption,media_type,media_url,permalink,thumbnail_url",
            "limit": str(LIMIT),
            "access_token": token,
        }
    )
    url = f"https://graph.instagram.com/{user_id}/media?{params}"
    payload = fetch_json(url)
    posts = []

    for item in payload.get("data", []):
        image_url = item.get("media_url") or item.get("thumbnail_url") or ""
        permalink = item.get("permalink") or ""
        if not image_url or not permalink:
            continue
        posts.append(
            normalize_post(
                str(item.get("id", "")),
                permalink,
                image_url,
                item.get("media_type", "IMAGE"),
            )
        )

    if not posts:
        return None

    username = os.environ.get("INSTAGRAM_USERNAME", DEFAULT_USERNAME)
    return {
        "username": username,
        "profileUrl": f"https://www.instagram.com/{username}/",
        "updatedAt": datetime.now(UTC).isoformat(),
        "source": "graph-api",
        "posts": posts[:LIMIT],
    }


def fetch_from_wordpress_api() -> dict:
    media_url = (
        "https://www.mervin-cz.com/wp-json/quadlayers/instagram/frontend/user-media"
        f"?account_id={WP_ACCOUNT_ID}&limit={LIMIT}"
    )
    profile_url = (
        "https://www.mervin-cz.com/wp-json/quadlayers/instagram/frontend/user-profile"
        f"?account_id={WP_ACCOUNT_ID}"
    )

    media_payload = fetch_json(media_url)
    profile_payload = fetch_json(profile_url)
    posts = []

    for item in media_payload.get("data", []):
        media = item.get("media") or {}
        image_url = media.get("url") or media.get("thumbnail") or ""
        permalink = item.get("share_url") or ""
        if not image_url or not permalink:
            continue
        posts.append(
            normalize_post(
                str(item.get("id", "")),
                permalink,
                image_url,
                item.get("media_type", media.get("type", "IMAGE")),
            )
        )

    username = profile_payload.get("username") or DEFAULT_USERNAME
    profile_link = profile_payload.get("link") or DEFAULT_PROFILE_URL

    return {
        "username": username,
        "profileUrl": profile_link,
        "updatedAt": datetime.now(UTC).isoformat(),
        "source": "wordpress-api",
        "posts": posts[:LIMIT],
    }


def load_existing() -> dict:
    if OUTPUT.exists():
        return json.loads(OUTPUT.read_text(encoding="utf-8"))
    return {
        "username": DEFAULT_USERNAME,
        "profileUrl": DEFAULT_PROFILE_URL,
        "updatedAt": None,
        "source": "empty",
        "posts": [],
    }


def main() -> int:
    try:
        data = fetch_from_graph_api() or fetch_from_wordpress_api()
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        print(f"Warning: Instagram fetch failed: {error}", file=sys.stderr)
        existing = load_existing()
        if existing.get("posts"):
            print(f"Keeping existing Instagram cache ({len(existing['posts'])} posts).")
            return 0
        print("No Instagram cache available.", file=sys.stderr)
        return 1

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Saved {len(data['posts'])} Instagram posts to {OUTPUT} ({data['source']}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
