#!/usr/bin/env python3
"""Clear broken WordPress featured image URLs from posts.json."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POSTS_PATH = ROOT / "src" / "data" / "posts.json"
LEGACY_UPLOAD = re.compile(r"/wp-content/uploads/", re.I)
PLACEHOLDER = re.compile(r"Will-You-Be-My-Best-Man\.png", re.I)


def should_clear(url: str | None) -> bool:
    if not url:
        return False
    return bool(LEGACY_UPLOAD.search(url) or PLACEHOLDER.search(url))


def main() -> None:
    posts = json.loads(POSTS_PATH.read_text(encoding="utf-8"))
    cleared = 0

    for post in posts:
        featured = post.get("featuredImage")
        if not should_clear(featured):
            continue
        post["featuredImage"] = None
        cleared += 1
        print(f"cleared: {post['slug']}")

    POSTS_PATH.write_text(
        json.dumps(posts, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"\nCleared {cleared} broken featured image URLs.")

if __name__ == "__main__":
    main()
