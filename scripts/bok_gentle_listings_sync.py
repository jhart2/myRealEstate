#!/usr/bin/env python3
"""
Gentle listing sync for mybunchofkeys.com (your own site).

Design goals:
  - Minimize load: prefer Yoast property sitemaps to skip old URLs before
    fetching HTML detail pages.
  - One request at a time (no concurrency).
  - Configurable delay + jitter between requests.
  - Clear identifying User-Agent (not disguised).
  - Resume-friendly JSON progress cache.
  - Houses for sale published/updated in the last N days.

Examples:
  python3 scripts/bok_gentle_listings_sync.py --days 30 --delay 4
  python3 scripts/bok_gentle_listings_sync.py --days 30 --delay 5 --max-details 25
  python3 scripts/bok_gentle_listings_sync.py --days 7 --skip-search-crawl

Then load into Rails:
  bin/rails bok:import
  bin/rails "bok:import[scripts/bok_sync_data/houses_last_month_….json]"
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from html import unescape
from pathlib import Path
from typing import Iterable
from xml.etree import ElementTree as ET

BASE = "https://mybunchofkeys.com"
SITEMAP_INDEX = f"{BASE}/sitemap_index.xml"
HOUSE_SEARCH = (
    f"{BASE}/?_sft_property_style=house&_sft_property_type=buy&sfid=219"
)
USER_AGENT = (
    "BOKGentleSync/1.0 (+https://mybunchofkeys.com; "
    "owner/internal house listing sync; sequential; polite delay; "
    "contact: admin@mybunchofkeys.com)"
)
SM_NS = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}


@dataclass
class Listing:
    url: str
    title: str = ""
    price: str = ""
    bok_id: str = ""
    location: str = ""
    bedrooms: str = ""
    bathrooms: str = ""
    sqft: str = ""
    parking: str = ""
    agent: str = ""
    image: str = ""
    date_published: str = ""
    lastmod: str = ""
    property_style: str = ""
    property_type: str = ""
    description: str = ""
    scraped_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


class GentleClient:
    def __init__(self, delay: float, jitter: float, timeout: float = 60.0):
        self.delay = delay
        self.jitter = jitter
        self.timeout = timeout
        self._last_request_at = 0.0
        self.request_count = 0

    def _wait(self) -> None:
        if self._last_request_at <= 0:
            return
        elapsed = time.monotonic() - self._last_request_at
        target = self.delay + random.uniform(0, max(self.jitter, 0))
        remaining = target - elapsed
        if remaining > 0:
            time.sleep(remaining)

    def get(self, url: str, retries: int = 5) -> bytes:
        last_err: Exception | None = None
        for attempt in range(retries):
            self._wait()
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": USER_AGENT,
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    "Accept-Language": "en-US,en;q=0.8",
                },
                method="GET",
            )
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    body = resp.read()
                    self._last_request_at = time.monotonic()
                    self.request_count += 1
                    print(f"  GET [{self.request_count}] {resp.status} {url}", flush=True)
                    return body
            except urllib.error.HTTPError as err:
                self._last_request_at = time.monotonic()
                self.request_count += 1
                last_err = err
                if err.code in {429, 500, 502, 503, 504}:
                    backoff = min(120.0, (2 ** attempt) * self.delay + random.uniform(0, 2))
                    print(f"  backoff {backoff:.1f}s after HTTP {err.code} for {url}", flush=True)
                    time.sleep(backoff)
                    continue
                raise
            except urllib.error.URLError as err:
                self._last_request_at = time.monotonic()
                last_err = err
                backoff = min(60.0, (2 ** attempt) * self.delay)
                print(f"  backoff {backoff:.1f}s after network error: {err}", flush=True)
                time.sleep(backoff)
        raise RuntimeError(f"failed after retries: {url}") from last_err


def parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    value = value.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(value)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def strip_tags(html: str) -> str:
    text = re.sub(r"<[^>]+>", " ", html)
    text = unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def first_match(pattern: str, text: str, flags: int = re.I) -> str:
    m = re.search(pattern, text, flags)
    return m.group(1).strip() if m else ""


def discover_recent_urls(client: GentleClient, cutoff: datetime) -> dict[str, str]:
    """
    Return {url: lastmod} for property URLs with sitemap lastmod >= cutoff.
    Only downloads property sitemaps that can still contain recent URLs
    (walking newest → oldest, stopping early).
    """
    print("Loading sitemap index…", flush=True)
    index_xml = client.get(SITEMAP_INDEX)
    root = ET.fromstring(index_xml)
    property_maps: list[tuple[str, datetime | None]] = []
    for node in root.findall("sm:sitemap", SM_NS):
        loc = node.findtext("sm:loc", default="", namespaces=SM_NS)
        if "property-sitemap" not in loc:
            continue
        lastmod = parse_dt(node.findtext("sm:lastmod", default="", namespaces=SM_NS))
        property_maps.append((loc, lastmod))

    # Newest Yoast shards tend to be highest-numbered; sort descending by name.
    def map_key(item: tuple[str, datetime | None]) -> tuple[int, str]:
        loc = item[0]
        m = re.search(r"property-sitemap(\d*)\.xml", loc)
        num = int(m.group(1) or "1") if m else 0
        return (num, loc)

    property_maps.sort(key=map_key, reverse=True)

    recent: dict[str, str] = {}
    for loc, index_lastmod in property_maps:
        # Skip shards whose index stamp is older than cutoff when present.
        if index_lastmod and index_lastmod < cutoff - timedelta(days=2):
            print(f"  skip old shard {loc.split('/')[-1]} (index lastmod {index_lastmod.date()})", flush=True)
            continue

        print(f"Loading {loc.split('/')[-1]}…", flush=True)
        xml = client.get(loc)
        shard = ET.fromstring(xml)
        shard_recent = 0
        newest: datetime | None = None
        oldest: datetime | None = None
        for url in shard.findall("sm:url", SM_NS):
            page = url.findtext("sm:loc", default="", namespaces=SM_NS)
            lastmod_raw = url.findtext("sm:lastmod", default="", namespaces=SM_NS)
            lastmod = parse_dt(lastmod_raw)
            if not page or not lastmod:
                continue
            newest = max(newest, lastmod) if newest else lastmod
            oldest = min(oldest, lastmod) if oldest else lastmod
            if lastmod >= cutoff:
                recent[page.split("?")[0].rstrip("/") + "/"] = lastmod_raw
                shard_recent += 1

        print(
            f"  dates {oldest.date() if oldest else '-'} → {newest.date() if newest else '-'}; "
            f"kept {shard_recent}",
            flush=True,
        )
        # Once a whole shard is older than the window, older shards will be older too.
        if newest and newest < cutoff:
            print("  reached older-than-window shard; stopping sitemap walk.", flush=True)
            break

    print(f"Recent sitemap URLs: {len(recent)}", flush=True)
    return recent


def extract_listing_links(html: str) -> list[str]:
    links = re.findall(r'href="(https://mybunchofkeys\.com/property/[^"#?]+)"', html)
    cleaned: list[str] = []
    seen: set[str] = set()
    for link in links:
        norm = urllib.parse.unquote(link).split("?")[0].rstrip("/") + "/"
        if norm not in seen:
            seen.add(norm)
            cleaned.append(norm)
    return cleaned


def crawl_house_search(client: GentleClient, max_pages: int) -> set[str]:
    """Collect house-for-sale listing URLs from filtered search pages."""
    print("Crawling house + buy search pages…", flush=True)
    urls: set[str] = set()
    empty_streak = 0
    for page in range(1, max_pages + 1):
        page_url = HOUSE_SEARCH if page == 1 else f"{HOUSE_SEARCH}&sf_paged={page}"
        html = client.get(page_url).decode("utf-8", errors="replace")
        found = extract_listing_links(html)
        new = [u for u in found if u not in urls]
        for u in new:
            urls.add(u)
        print(f"  search page {page}: {len(found)} links, {len(new)} new (total {len(urls)})", flush=True)
        if not new:
            empty_streak += 1
        else:
            empty_streak = 0
        if empty_streak >= 2:
            print("  no new links on consecutive pages; stopping search crawl.", flush=True)
            break
    return urls


def parse_listing(url: str, html: str, lastmod: str = "") -> Listing | None:
    # JSON-LD date + image
    date_published = ""
    image = ""
    title = ""
    for blob in re.findall(
        r'<script type="application/ld\+json"[^>]*>(.*?)</script>',
        html,
        flags=re.I | re.S,
    ):
        if "datePublished" not in blob and "WebPage" not in blob:
            continue
        try:
            data = json.loads(blob)
        except json.JSONDecodeError:
            continue
        graph = data.get("@graph", [data]) if isinstance(data, dict) else []
        for node in graph:
            if not isinstance(node, dict):
                continue
            if node.get("@type") == "WebPage":
                date_published = node.get("datePublished") or date_published
                title = unescape(node.get("name") or title)
                thumb = node.get("thumbnailUrl") or ""
                if thumb:
                    image = thumb
            if node.get("@type") == "ImageObject" and not image:
                image = node.get("contentUrl") or node.get("url") or image

    # Style / type chips (“Find More In”)
    find_more = first_match(r"Find More In:(.*?)</div>", html, re.I | re.S)
    find_more_text = strip_tags(find_more).lower() if find_more else ""

    style = ""
    if re.search(r"\bhouse\b", find_more_text):
        style = "House"
    elif "apartment" in find_more_text or "townhouse" in find_more_text:
        style = "Apartment/Townhouse"
    elif re.search(r"\bland\b", find_more_text):
        style = "Land"

    ptype = ""
    if "for sale" in find_more_text or "buy" in find_more_text:
        ptype = "For Sale"
    elif "for rent" in find_more_text or "rent" in find_more_text:
        ptype = "For Rent"

    # Fallback style detection
    if not style and re.search(r'property_style[^>]*>\s*House\s*<', html, re.I):
        style = "House"

    price_block = first_match(r'<div class="column-half price">(.*?)</div>\s*<div', html, re.I | re.S)
    price = ""
    if price_block:
        # Prefer largest/most complete price-looking text
        candidates = re.findall(r"\$[\d,]+(?:\s*/\s*Mth)?(?:\s*\(USD\))?", strip_tags(price_block))
        price = candidates[0] if candidates else ""
    if not price:
        price = first_match(r'<h4[^>]*>\s*(\$[^<]+)\s*</h4>', html)

    location = first_match(r"<strong>Location:</strong>\s*<br\s*/?>\s*([^<\n]+)", html)
    if not location:
        location = first_match(r"Location:\s*([^<\n]+)", html)

    bedrooms = first_match(r"Bedrooms:\s*([0-9.]+)", html)
    bathrooms = first_match(r"Bathrooms:\s*([0-9.]+)", html)
    sqft = first_match(r"Sq\.\s*Footage:\s*([^<\n]+)", html)
    parking = first_match(r"Parking:\s*([0-9.]+)", html)
    bok_id = first_match(r"(BOK-\s*[0-9]+)", html)
    bok_id = re.sub(r"\s+", "", bok_id)
    agent = first_match(r"Meet the Agent:</h5>\s*<h3[^>]*>\s*([^<]+)", html)

    about = first_match(r"About this Property(.*?)(?:Property\s*<span class=\"bunches\">Location|Mortgages Powered)", html, re.I | re.S)
    description = strip_tags(about)[:1200] if about else ""

    if not title:
        title = unescape(first_match(r"<h1[^>]*>(.*?)</h1>", html, re.I | re.S))
        title = strip_tags(title)

    return Listing(
        url=url,
        title=title,
        price=price,
        bok_id=bok_id,
        location=strip_tags(location),
        bedrooms=bedrooms,
        bathrooms=bathrooms,
        sqft=strip_tags(sqft),
        parking=parking,
        agent=strip_tags(agent),
        image=image,
        date_published=date_published,
        lastmod=lastmod,
        property_style=style,
        property_type=ptype,
        description=description,
    )


def load_cache(path: Path) -> dict:
    if not path.exists():
        return {"completed": {}, "listings": []}
    return json.loads(path.read_text())


def save_cache(path: Path, cache: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cache, indent=2, ensure_ascii=False))


def write_outputs(listings: Iterable[Listing], out_dir: Path, stamp: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = [asdict(item) for item in listings]
    json_path = out_dir / f"houses_last_month_{stamp}.json"
    csv_path = out_dir / f"houses_last_month_{stamp}.csv"
    json_path.write_text(json.dumps(rows, indent=2, ensure_ascii=False))

    fieldnames = list(asdict(Listing(url="")).keys())
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} listings →\n  {json_path}\n  {csv_path}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Gentle house listing sync for mybunchofkeys.com")
    parser.add_argument("--days", type=int, default=30, help="Lookback window in days (default: 30)")
    parser.add_argument("--delay", type=float, default=4.0, help="Base seconds between requests (default: 4)")
    parser.add_argument("--jitter", type=float, default=1.5, help="Extra random delay 0..jitter seconds")
    parser.add_argument("--max-search-pages", type=int, default=250, help="Max house search pages to crawl")
    parser.add_argument("--max-details", type=int, default=0, help="Optional cap on detail fetches (0 = no cap)")
    parser.add_argument(
        "--skip-search-crawl",
        action="store_true",
        help="Only use sitemap candidates; still verify House on detail pages",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "bok_sync_data",
        help="Output / cache directory",
    )
    args = parser.parse_args()

    if args.delay < 2.0:
        print("Refusing delay < 2s — keep this gentle on production traffic.", file=sys.stderr)
        return 2

    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)
    client = GentleClient(delay=args.delay, jitter=args.jitter)
    cache_path = args.out_dir / "progress_cache.json"
    cache = load_cache(cache_path)

    print(f"Window: since {cutoff.isoformat()} UTC", flush=True)
    print(f"Delay: {args.delay}s + up to {args.jitter}s jitter (sequential)", flush=True)

    recent = discover_recent_urls(client, cutoff)

    if args.skip_search_crawl:
        candidates = sorted(recent.keys())
        print(f"Candidates from sitemap only: {len(candidates)}", flush=True)
    else:
        house_urls = crawl_house_search(client, max_pages=args.max_search_pages)
        candidates = sorted(set(recent) & house_urls)
        print(
            f"Intersection (recent ∩ house search): {len(candidates)} "
            f"(recent={len(recent)}, house_search={len(house_urls)})",
            flush=True,
        )
        # Also include recent URLs not yet seen in search crawl if search was capped early
        # No — stick to intersection for “houses” accuracy.

    listings: list[Listing] = []
    # Keep previously completed listings still in window
    for row in cache.get("listings", []):
        dt = parse_dt(row.get("date_published") or row.get("lastmod"))
        if dt and dt >= cutoff and (row.get("property_style") == "House" or not row.get("property_style")):
            if row.get("url") in candidates or args.skip_search_crawl:
                listings.append(Listing(**{k: row.get(k, "") for k in asdict(Listing(url="")).keys()}))

    completed: dict = cache.get("completed", {})
    fetched = 0

    try:
        for url in candidates:
            if url in completed and completed[url].get("ok"):
                continue
            if args.max_details and fetched >= args.max_details:
                print(f"Reached --max-details={args.max_details}; stopping detail phase.", flush=True)
                break

            html = client.get(url).decode("utf-8", errors="replace")
            listing = parse_listing(url, html, lastmod=recent.get(url, ""))
            fetched += 1

            if not listing:
                completed[url] = {"ok": False, "reason": "parse_failed"}
                continue

            published = parse_dt(listing.date_published) or parse_dt(listing.lastmod)
            is_house = listing.property_style == "House" or (
                args.skip_search_crawl
                and re.search(r"\bhouse\b", (listing.title + " " + listing.description).lower())
                and listing.property_style != "Apartment/Townhouse"
                and listing.property_style != "Land"
            )

            # Prefer explicit House chip when present
            if listing.property_style and listing.property_style != "House":
                completed[url] = {"ok": True, "kept": False, "reason": f"style={listing.property_style}"}
                continue

            if published and published < cutoff:
                completed[url] = {"ok": True, "kept": False, "reason": "too_old"}
                continue

            if not is_house and listing.property_style != "House":
                # Intersection path should usually already be houses; keep if chip missing but from house search
                if args.skip_search_crawl:
                    completed[url] = {"ok": True, "kept": False, "reason": "not_house"}
                    continue

            listings.append(listing)
            completed[url] = {"ok": True, "kept": True}
            print(f"  kept: {listing.bok_id or listing.title[:60]} | {listing.price} | {listing.location}", flush=True)

            cache = {
                "completed": completed,
                "listings": [asdict(x) for x in listings],
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }
            save_cache(cache_path, cache)

    except KeyboardInterrupt:
        print("\nInterrupted — saving progress.", flush=True)
        save_cache(
            cache_path,
            {
                "completed": completed,
                "listings": [asdict(x) for x in listings],
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
        )
        return 130

    # De-dupe by URL
    by_url = {item.url: item for item in listings}
    final_rows = sorted(by_url.values(), key=lambda x: x.date_published or x.lastmod, reverse=True)

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    write_outputs(final_rows, args.out_dir, stamp)
    save_cache(
        cache_path,
        {
            "completed": completed,
            "listings": [asdict(x) for x in final_rows],
            "updated_at": datetime.now(timezone.utc).isoformat(),
        },
    )
    print(f"Done. Requests made: {client.request_count}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
