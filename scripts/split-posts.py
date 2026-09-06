#!/usr/bin/env python3
"""Split post body HTML from posts.json into individual files."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POSTS_JSON = ROOT / "src" / "data" / "posts.json"
CONTENT_DIR = ROOT / "src" / "content" / "posts"


def main() -> None:
    posts = json.loads(POSTS_JSON.read_text(encoding="utf-8"))
    CONTENT_DIR.mkdir(parents=True, exist_ok=True)

    for post in posts:
        slug = post["slug"]
        content = post.pop("content", "")
        html_path = CONTENT_DIR / f"{slug}.html"
        html_path.write_text(content or "", encoding="utf-8")

    POSTS_JSON.write_text(
        json.dumps(posts, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Wrote {len(posts)} HTML files to {CONTENT_DIR}")
    print(f"Updated metadata in {POSTS_JSON}")


if __name__ == "__main__":
    main()
