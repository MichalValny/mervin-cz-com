#!/usr/bin/env python3
"""Scrape all posts and categories from mervin-cz.com WordPress REST API."""

import json
import re
import urllib.request
from pathlib import Path

BASE = "https://www.mervin-cz.com"
OUTPUT = Path(__file__).resolve().parent.parent / "src" / "data"


def fetch_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "mervin-cz-scraper/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode()), resp.headers


def fetch_all_posts():
    posts = []
    page = 1
    while True:
        url = f"{BASE}/wp-json/wp/v2/posts?per_page=100&page={page}&_embed=1"
        print(f"Fetching posts page {page}...")
        data, headers = fetch_json(url)
        if not data:
            break
        posts.extend(data)
        total_pages = int(headers.get("X-WP-TotalPages", 1))
        if page >= total_pages:
            break
        page += 1
    return posts


def fetch_categories():
    cats = []
    page = 1
    while True:
        url = f"{BASE}/wp-json/wp/v2/categories?per_page=100&page={page}"
        data, headers = fetch_json(url)
        if not data:
            break
        cats.extend(data)
        total_pages = int(headers.get("X-WP-TotalPages", 1))
        if page >= total_pages:
            break
        page += 1
    return cats


def fetch_page(slug: str):
    url = f"{BASE}/wp-json/wp/v2/pages?slug={slug}&_embed=1"
    data, _ = fetch_json(url)
    return data[0] if data else None


def extract_gallery_widgets(html: str):
    """Extract pa-gallery-player-widget div blocks from HTML."""
    pattern = r'(<div class="pa-gallery-player-widget"[^>]*>.*?</div>)'
    return re.findall(pattern, html, re.DOTALL)


def strip_gallery_widgets(html: str):
    """Remove gallery widgets and publicalbum comments from content."""
    html = re.sub(r'<!-- publicalbum\.org -->', '', html)
    html = re.sub(
        r'<div class="pa-gallery-player-widget"[^>]*>.*?</div>',
        '',
        html,
        flags=re.DOTALL,
    )
    return html.strip()


def get_featured_image(post):
    embedded = post.get("_embedded", {})
    media = embedded.get("wp:featuredmedia", [])
    if media:
        src = media[0].get("source_url")
        if src:
            return src
        sizes = media[0].get("media_details", {}).get("sizes", {})
        for key in ("medium_large", "large", "medium", "full"):
            if key in sizes:
                return sizes[key]["source_url"]
    return None


def get_category_names(post, cat_map):
    embedded = post.get("_embedded", {})
    terms = embedded.get("wp:term", [[]])
    names = []
    for term_group in terms:
        for term in term_group:
            if term.get("taxonomy") == "category":
                names.append({"id": term["id"], "name": term["name"], "slug": term["slug"]})
    if not names:
        for cid in post.get("categories", []):
            if cid in cat_map:
                c = cat_map[cid]
                names.append({"id": c["id"], "name": c["name"], "slug": c["slug"]})
    return names


def process_post(post, cat_map):
    content_html = post["content"]["rendered"]
    galleries = extract_gallery_widgets(content_html)
    text_content = strip_gallery_widgets(content_html)

    date = post["date"][:10]
    parts = date.split("-")
    slug = post["slug"]
    path = f"/{parts[0]}/{parts[1]}/{parts[2]}/{slug}/"

    return {
        "id": post["id"],
        "title": post["title"]["rendered"],
        "slug": slug,
        "path": path,
        "date": date,
        "year": int(parts[0]),
        "month": int(parts[1]),
        "day": int(parts[2]),
        "link": post["link"],
        "excerpt": post.get("excerpt", {}).get("rendered", "").strip(),
        "content": text_content,
        "galleries": galleries,
        "featuredImage": get_featured_image(post),
        "categories": get_category_names(post, cat_map),
        "categoryIds": post.get("categories", []),
    }


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)

    print("Fetching categories...")
    categories_raw = fetch_categories()
    cat_map = {c["id"]: c for c in categories_raw}
    categories = [
        {
            "id": c["id"],
            "name": c["name"],
            "slug": c["slug"],
            "parent": c["parent"],
            "count": c["count"],
            "link": c["link"],
        }
        for c in categories_raw
        if c["count"] > 0
    ]
    categories.sort(key=lambda x: (-x["count"], x["name"]))

    print("Fetching posts...")
    posts_raw = fetch_all_posts()
    print(f"Found {len(posts_raw)} posts")

    posts = [process_post(p, cat_map) for p in posts_raw]
    posts.sort(key=lambda x: x["date"], reverse=True)

    print("Fetching contribute page...")
    contribute = fetch_page("jak-prispivat")

    site_data = {
        "siteName": "mervin-cz",
        "siteUrl": BASE,
        "logo": f"{BASE}/wp-content/uploads/2020/09/title2-1.png",
        "favicon": f"{BASE}/wp-content/uploads/2020/09/leaf-flag-of-canada-png-4-150x150.png",
        "instagram": False,
    }

    with open(OUTPUT / "site.json", "w", encoding="utf-8") as f:
        json.dump(site_data, f, ensure_ascii=False, indent=2)

    with open(OUTPUT / "categories.json", "w", encoding="utf-8") as f:
        json.dump(categories, f, ensure_ascii=False, indent=2)

    with open(OUTPUT / "posts.json", "w", encoding="utf-8") as f:
        json.dump(posts, f, ensure_ascii=False, indent=2)

    if contribute:
        contribute_data = {
            "title": contribute["title"]["rendered"],
            "content": contribute["content"]["rendered"],
            "slug": contribute["slug"],
        }
        with open(OUTPUT / "contribute.json", "w", encoding="utf-8") as f:
            json.dump(contribute_data, f, ensure_ascii=False, indent=2)

    print(f"Saved to {OUTPUT}")
    print(f"  posts: {len(posts)}")
    print(f"  categories: {len(categories)}")
    print(f"  posts with galleries: {sum(1 for p in posts if p['galleries'])}")


if __name__ == "__main__":
    main()
