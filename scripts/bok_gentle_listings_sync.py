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
  - All property styles (house, apartment/townhouse, land, commercial, …)
    published/updated in the last N days.

Examples:
  python3 scripts/bok_gentle_listings_sync.py --days 30 --delay 4
  python3 scripts/bok_gentle_listings_sync.py --days 7 --delay 4 --max-details 250
  python3 scripts/bok_gentle_listings_sync.py --days 7 --skip-search-crawl

Hourly batches (--max-details N) fetch newest unfinished URLs first; the
progress cache skips completed ones so later runs reach further back until
the window is covered.

Then load into Rails:
  bin/rails bok:import
  bin/rails bok:sync
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
    agent_agency: str = ""
    agent_phone: str = ""
    agent_image: str = ""
    image: str = ""
    images: list[str] = field(default_factory=list)
    date_published: str = ""
    lastmod: str = ""
    property_style: str = ""
    property_type: str = ""
    description: str = ""
    features: list[str] = field(default_factory=list)
    # Scraper "brain" flags — Rails ListingAddressBrain uses these to decide
    # whether an OpenAI/Google enrich pass is needed on import.
    weak_address: bool = False
    weak_reasons: list[str] = field(default_factory=list)
    has_street_signal: bool = False
    scraped_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


MARKETING_RE = re.compile(
    r"\b(?:house|home|homes?|apartment|townhouse|property)?\s*"
    r"(?:for\s+sale|for\s+rent|of\s+sale)|"
    r"\b(?:investment\s+propert|income\s+generating|prime\s+propert|reduced)\b",
    re.I,
)
STREET_RE = re.compile(
    r"\b(?:road|rd\.?|street|st\.?|avenue|ave\.?|drive|dr\.?|lane|ln\.?|"
    r"crescent|close|trace|boulevard|blvd\.?|way|gardens|estate|heights|"
    r"terrace|hill|shores|court|place)\b",
    re.I,
)
PLACEHOLDER_LOC = re.compile(r"^(?:n/?a|na|none|null|unknown|-)?$", re.I)


def assess_address_strength(title: str, location: str, description: str, url: str = "") -> dict:
    """Cheap heuristic used at scrape time to flag weak address documents."""
    title = title or ""
    location = (location or "").strip()
    desc = (description or "")[:1200]
    slug = ""
    m = re.search(r"/property/([^/]+)/?", url or "")
    if m:
        slug = m.group(1).replace("-", " ")

    reasons: list[str] = []
    blob = f"{title}\n{location}\n{slug}\n{desc}"
    has_street = bool(STREET_RE.search(blob))

    if PLACEHOLDER_LOC.match(location):
        reasons.append("missing_location")
    if MARKETING_RE.search(title) and not STREET_RE.search(title):
        reasons.append("marketing_title")
    if location and len(location.split()) >= 4 and not STREET_RE.search(location):
        reasons.append("noisy_location")
    if not has_street:
        reasons.append("no_street_signal")
    # Community-only location with marketing-ish title — still enrichable.
    if location and not STREET_RE.search(location) and MARKETING_RE.search(f"{title} {desc[:200]}"):
        if "marketing_title" not in reasons:
            reasons.append("community_only_marketing")

    return {
        "weak_address": bool(reasons),
        "weak_reasons": reasons,
        "has_street_signal": has_street,
    }


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
                print(f"  GET [{self.request_count}] {err.code} {url}", flush=True)
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


def parse_features(html: str) -> list[str]:
    """Extract amenity labels from BOK's div.column.features / span.feature chips."""
    block = first_match(
        r'<div class="column features[^"]*"[^>]*>(.*?)</div>\s*(?:<div class="clear"|$)',
        html,
        re.I | re.S,
    )
    if not block:
        return []

    features: list[str] = []
    for match in re.finditer(
        r'<span\b[^>]*\bclass="[^"]*\bfeature\b[^"]*"[^>]*>(.*?)</span>',
        block,
        flags=re.I | re.S,
    ):
        label = strip_tags(match.group(1))
        if label and label not in features:
            features.append(label)
    return features


def parse_gallery_images(html: str) -> list[str]:
    """Full-size photo URLs from the listing gallery (`div.thumbs` → figure > a[href])."""
    start = re.search(r'<div class="thumbs"[^>]*>', html, flags=re.I)
    if not start:
        return []
    chunk = html[start.end() : start.end() + 120_000]
    end = re.search(
        r'</div>\s*(?:</div>\s*)?(?:<div class="|</div>\s*</div>\s*</div>)',
        chunk,
        flags=re.I,
    )
    block = chunk[: end.start()] if end else chunk

    images: list[str] = []
    for href in re.findall(
        r"<a\s+href=['\"](https?://[^'\"]+\.(?:jpe?g|png|webp)[^'\"]*)['\"]",
        block,
        flags=re.I,
    ):
        url = unescape(href.strip())
        if re.search(r"-320x320\.(?:jpe?g|png|webp)$", url, flags=re.I):
            continue
        if url not in images:
            images.append(url)
    return images


def is_placeholder_image(url: str) -> bool:
    u = url.lower()
    return any(
        token in u
        for token in (
            "/themes/",
            "share.jpg",
            "default.jpg",
            "default-halfpage-hero",
            "bok-icon.png",
            "logo.png",
        )
    )


def has_usable_images(listing: Listing) -> bool:
    """True when gallery/hero has at least one non-placeholder photo URL."""
    if any(url and not is_placeholder_image(url) for url in listing.images):
        return True
    return bool(listing.image) and not is_placeholder_image(listing.image)


def parse_og_image(html: str) -> str:
    """Best Open Graph image that isn't a site/theme placeholder."""
    for match in re.finditer(
        r'<meta[^>]+property=["\']og:image["\'][^>]*>',
        html,
        flags=re.I,
    ):
        tag = match.group(0)
        content = re.search(r'content=["\']([^"\']+)["\']', tag, flags=re.I)
        if not content:
            continue
        url = unescape(content.group(1).strip())
        if url and not is_placeholder_image(url):
            return url
    return ""


def first_match(pattern: str, text: str, flags: int = re.I) -> str:
    m = re.search(pattern, text, flags)
    return m.group(1).strip() if m else ""


def parse_agent_block(html: str) -> tuple[str, str, str, str]:
    """Pull listing agent name, agency, phone, and photo from #agent-data."""
    block = first_match(
        r'<div[^>]*\bid=["\']agent-data["\'][^>]*>(.*?)</div>\s*<div\b',
        html,
        re.I | re.S,
    )
    if not block:
        block = first_match(
            r'<div[^>]*\bid=["\']agent-data["\'][^>]*>(.*?)</div>',
            html,
            re.I | re.S,
        )
    scope = block or html

    photo = first_match(
        r'<a[^>]*class=["\'][^"\']*profile-pic[^"\']*["\'][^>]*>\s*<img[^>]+src=["\']([^"\']+)',
        scope,
        re.I | re.S,
    )
    if not photo:
        photo = first_match(
            r'<div[^>]*\bid=["\']agent-data["\'][^>]*>.*?src=["\']([^"\']+)["\']',
            html,
            re.I | re.S,
        )

    # Name is often wrapped in an author <a>; strip_tags handles that.
    name_html = first_match(
        r"Meet the Agent:</h5>\s*<h3[^>]*>(.*?)</h3>",
        scope,
        re.I | re.S,
    )
    if not name_html:
        name_html = first_match(
            r"Meet the Agent:</h5>\s*<h3[^>]*>\s*([^<]+)",
            html,
            re.I | re.S,
        )
    name = strip_tags(name_html)

    agency = strip_tags(
        first_match(r"Agency:\s*(?:<a\b[^>]*>)?([^<\n]+)", scope, re.I)
    )
    phone = strip_tags(
        first_match(r"Phone:\s*(?:<a\b[^>]*>)?([^<\n]+)", scope, re.I)
    )
    if not phone:
        tel = first_match(r'href=["\']tel:([^"\']+)', scope, re.I)
        if tel:
            digits = re.sub(r"\D", "", tel)
            phone = f"({digits[-10:-7]}) {digits[-7:-4]}-{digits[-4:]}" if len(digits) >= 10 else tel

    return name, agency, phone, photo


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


def parse_description(html: str) -> str:
    """Full listing copy from #description, plus optional About the Region."""
    parts: list[str] = []

    desc = first_match(r'<div id=["\']description["\']>(.*?)</div>', html, re.I | re.S)
    if desc:
        text = strip_tags(desc)
        if text:
            parts.append(text)

    region = first_match(r'<div class=["\']region-desc["\']>(.*?)</div>', html, re.I | re.S)
    if region:
        region_text = strip_tags(region)
        region_text = re.sub(r"View More\s+.+\s+Listings\s*$", "", region_text, flags=re.I).strip()
        if region_text:
            heading = first_match(r'<h3 class=["\']region-title["\']>(.*?)</h3>', html, re.I | re.S)
            heading = strip_tags(heading) if heading else "About the Region"
            parts.append(f"{heading}\n{region_text}")

    if parts:
        return "\n\n".join(parts)

    # Legacy fallback when #description is missing
    about = first_match(
        r"About this Property(.*?)(?:Property\s*<span class=\"bunches\">Location|Mortgages Powered)",
        html,
        re.I | re.S,
    )
    return strip_tags(about) if about else ""


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
    hint = f"{find_more_text} {title} {url}".lower()

    style = ""
    if (
        re.search(r"\bhouse\b", find_more_text)
        and "townhouse" not in find_more_text
        and "apartment" not in find_more_text
    ):
        style = "House"
    elif "apartment" in find_more_text or "townhouse" in find_more_text:
        style = "Apartment/Townhouse"
    elif re.search(r"\bland\b", find_more_text) or "acreage" in find_more_text:
        style = "Land"
    elif any(
        token in find_more_text
        for token in ("commercial", "office", "warehouse", "retail", "industrial", "storage")
    ):
        style = "Commercial"

    if not style:
        if "townhouse" in hint or "apartment" in hint:
            style = "Apartment/Townhouse"
        elif re.search(r"\bland\b|\bacre", hint):
            style = "Land"
        elif any(
            token in hint
            for token in ("commercial", "office", "warehouse", "retail", "gym-space", "storage")
        ):
            style = "Commercial"
        elif re.search(r"\bhouse\b|\bhome\b|\bvilla\b|\bpenthouse\b", hint):
            style = "House"

    # Taxonomy markup fallbacks
    if not style and re.search(r'property_style[^>]*>\s*House\s*<', html, re.I):
        style = "House"
    if not style and re.search(r'property_style[^>]*>\s*Apartment', html, re.I):
        style = "Apartment/Townhouse"
    if not style and re.search(r'property_style[^>]*>\s*Land\s*<', html, re.I):
        style = "Land"
    if not style and re.search(r'property_style[^>]*>\s*Commercial', html, re.I):
        style = "Commercial"

    price_block = first_match(r'<div class="column-half price">(.*?)</div>\s*<div', html, re.I | re.S)
    price = ""
    if price_block:
        # Prefer largest/most complete price-looking text
        candidates = re.findall(r"\$[\d,]+(?:\s*/\s*Mth)?(?:\s*\(USD\))?", strip_tags(price_block))
        price = candidates[0] if candidates else ""
    if not price:
        price = first_match(r'<h4[^>]*>\s*(\$[^<]+)\s*</h4>', html)

    ptype = ""
    if "for sale" in find_more_text or "buy" in find_more_text:
        ptype = "For Sale"
    elif "for rent" in find_more_text or re.search(r"\brent\b", find_more_text):
        ptype = "For Rent"
    elif "/ mth" in price.lower() or "/mth" in price.lower() or "for-rent" in hint or "for rent" in hint:
        ptype = "For Rent"
    elif "for-sale" in hint or "for sale" in hint:
        ptype = "For Sale"

    location = first_match(r"<strong>Location:</strong>\s*<br\s*/?>\s*([^<\n]+)", html)
    if not location:
        location = first_match(r"Location:\s*([^<\n]+)", html)

    bedrooms = first_match(r"Bedrooms:\s*([0-9.]+)", html)
    bathrooms = first_match(r"Bathrooms:\s*([0-9.]+)", html)
    sqft = first_match(r"Sq\.\s*Footage:\s*([^<\n]+)", html)
    parking = first_match(r"Parking:\s*([0-9.]+)", html)
    bok_id = first_match(r"(BOK-\s*[0-9]+)", html)
    bok_id = re.sub(r"\s+", "", bok_id)
    agent, agent_agency, agent_phone, agent_image = parse_agent_block(html)

    description = parse_description(html)
    features = parse_features(html)
    images = parse_gallery_images(html)
    if image and is_placeholder_image(image):
        image = ""
    if image and image not in images:
        images = [image] + images
    elif not image and images:
        image = images[0]
    if not images:
        og = parse_og_image(html)
        if og:
            images = [og]
            image = og

    if not title:
        title = unescape(first_match(r"<h1[^>]*>(.*?)</h1>", html, re.I | re.S))
        title = strip_tags(title)

    location_clean = strip_tags(location)
    strength = assess_address_strength(title, location_clean, description, url)

    return Listing(
        url=url,
        title=title,
        price=price,
        bok_id=bok_id,
        location=location_clean,
        bedrooms=bedrooms,
        bathrooms=bathrooms,
        sqft=strip_tags(sqft),
        parking=parking,
        agent=agent,
        agent_agency=agent_agency,
        agent_phone=agent_phone,
        agent_image=agent_image,
        image=image,
        images=images,
        date_published=date_published,
        lastmod=lastmod,
        property_style=style,
        property_type=ptype,
        description=description,
        features=features,
        weak_address=strength["weak_address"],
        weak_reasons=strength["weak_reasons"],
        has_street_signal=strength["has_street_signal"],
    )


def load_cache(path: Path) -> dict:
    if not path.exists():
        return {"completed": {}, "listings": []}
    return json.loads(path.read_text())


def save_cache(path: Path, cache: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cache, indent=2, ensure_ascii=False))


def sort_candidates_newest_first(urls: Iterable[str], lastmod_by_url: dict[str, str]) -> list[str]:
    """Prefer sitemap lastmod (newest first); undated URLs sort last, then by URL."""

    def sort_key(url: str) -> tuple:
        dt = parse_dt(lastmod_by_url.get(url))
        # Invert timestamp so newer sorts first; missing dates go last.
        stamp = -(dt.timestamp()) if dt else float("inf")
        return (stamp, url)

    return sorted(urls, key=sort_key)


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
        for row in rows:
            csv_row = dict(row)
            for key in ("features", "images"):
                val = csv_row.get(key)
                if isinstance(val, list):
                    csv_row[key] = "; ".join(val)
            writer.writerow(csv_row)

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
        help="Only use sitemap candidates (all styles); still parse type on detail pages",
    )
    parser.add_argument(
        "--refetch",
        action="store_true",
        help="Re-fetch detail pages even when already marked completed in the progress cache",
    )
    parser.add_argument(
        "--from-cache",
        action="store_true",
        help="Skip discovery; re-fetch detail pages for URLs already in progress_cache listings",
    )
    parser.add_argument(
        "--urls-file",
        type=Path,
        default=None,
        help="Optional text file of listing URLs (one per line) to fetch as candidates",
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

    if args.urls_file:
        file_urls = [
            line.strip()
            for line in args.urls_file.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        recent = {url: "" for url in file_urls}
        candidates = sort_candidates_newest_first(dict.fromkeys(file_urls), recent)
        print(f"From urls-file: {len(candidates)} listing URLs", flush=True)
    elif args.from_cache:
        cached_rows = cache.get("listings", [])
        recent = {
            row["url"]: row.get("lastmod") or row.get("date_published") or ""
            for row in cached_rows
            if row.get("url")
        }
        candidates = sort_candidates_newest_first(recent.keys(), recent)
        print(f"From cache: {len(candidates)} listing URLs (newest first)", flush=True)
    else:
        recent = discover_recent_urls(client, cutoff)

        if args.skip_search_crawl:
            candidates = sort_candidates_newest_first(recent.keys(), recent)
            print(f"Candidates from sitemap only: {len(candidates)} (newest first)", flush=True)
        else:
            house_urls = crawl_house_search(client, max_pages=args.max_search_pages)
            intersection = set(recent) & house_urls
            candidates = sort_candidates_newest_first(intersection, recent)
            print(
                f"Intersection (recent ∩ house search): {len(candidates)} "
                f"(recent={len(recent)}, house_search={len(house_urls)}; newest first)",
                flush=True,
            )

    listings: list[Listing] = []
    listing_fields = asdict(Listing(url="")).keys()

    def listing_from_row(row: dict) -> Listing:
        list_fields = {"features", "images"}
        data = {k: row.get(k, [] if k in list_fields else "") for k in listing_fields}
        for key in list_fields:
            if not isinstance(data.get(key), list):
                raw = data.get(key) or []
                if isinstance(raw, str) and raw.strip():
                    data[key] = [part.strip() for part in raw.split(";") if part.strip()]
                else:
                    data[key] = []
        data["url"] = row.get("url") or data.get("url") or ""
        return Listing(**data)

    # Keep previously completed listings still in window (skip on full refetch)
    if not args.refetch:
        candidate_set = set(candidates)
        for row in cache.get("listings", []):
            dt = parse_dt(row.get("date_published") or row.get("lastmod"))
            if dt and dt >= cutoff:
                # urls-file / from-cache resumes should retain prior enriched rows
                if (
                    args.urls_file
                    or args.from_cache
                    or args.skip_search_crawl
                    or row.get("url") in candidate_set
                ):
                    cached = listing_from_row(row)
                    if has_usable_images(cached):
                        listings.append(cached)

    completed: dict = {} if args.refetch else cache.get("completed", {})
    if args.refetch:
        print("Refetch mode: re-downloading every candidate detail page.", flush=True)
    fetched = 0

    try:
        for url in candidates:
            if url in completed and completed[url].get("ok") and not args.refetch:
                continue
            if args.max_details and fetched >= args.max_details:
                print(f"Reached --max-details={args.max_details}; stopping detail phase.", flush=True)
                break

            try:
                html = client.get(url).decode("utf-8", errors="replace")
            except urllib.error.HTTPError as err:
                completed[url] = {"ok": False, "reason": f"http_{err.code}"}
                print(f"  skip: HTTP {err.code} {url}", flush=True)
                continue
            listing = parse_listing(url, html, lastmod=recent.get(url, ""))
            fetched += 1

            if not listing:
                completed[url] = {"ok": False, "reason": "parse_failed"}
                continue

            published = parse_dt(listing.date_published) or parse_dt(listing.lastmod)
            if published and published < cutoff:
                completed[url] = {"ok": True, "kept": False, "reason": "too_old"}
                continue

            if not has_usable_images(listing):
                completed[url] = {"ok": True, "kept": False, "reason": "no_images"}
                print(f"  skip: no usable images {url}", flush=True)
                continue

            listings.append(listing)
            style_label = listing.property_style or "Unknown"
            completed[url] = {"ok": True, "kept": True, "style": style_label}
            print(
                f"  kept: {listing.bok_id or listing.title[:60]} | {style_label} | "
                f"{listing.price} | {listing.location}"
                + (f" | weak={','.join(listing.weak_reasons)}" if listing.weak_address else ""),
                flush=True,
            )

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
