#!/usr/bin/env python3
"""
Archive exact place polygons for Trinidad & Tobago from OpenStreetMap
via Nominatim (public API). Store GeoJSON under data/geo/boundaries/.

Usage:
  python3 scripts/archive_tt_geo_boundaries.py
"""

from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parents[1] / "data" / "geo" / "boundaries"
USER_AGENT = "EstateRealty/1.0 (TT boundary archive; +https://mybunchofkeys.com)"
SLEEP = 1.1  # Nominatim usage policy: max 1 req/sec

# Curated settlement / admin names (not street addresses).
PLACES = [
    "Port of Spain",
    "San Fernando",
    "Chaguanas",
    "Arima",
    "Point Fortin",
    "Couva",
    "Tunapuna",
    "Diego Martin",
    "Maraval",
    "Westmoorings",
    "Cascade",
    "St. Ann's",
    "Belmont",
    "Woodbrook",
    "St. James",
    "Maracas",
    "Santa Cruz",
    "San Juan",
    "Barataria",
    "Champs Fleurs",
    "Curepe",
    "St. Augustine",
    "St. Joseph",
    "Arouca",
    "Trincity",
    "Valsayn",
    "Cunupia",
    "Freeport",
    "Carapichaima",
    "Princes Town",
    "Sangre Grande",
    "Rio Claro",
    "Mayaro",
    "Siparia",
    "Fyzabad",
    "Debe",
    "Penal",
    "Gasparillo",
    "La Romain",
    "Palmiste",
    "Gulf View",
    "Petit Valley",
    "Diamond Vale",
    "Carenage",
    "Chaguaramas",
    "Glencoe",
    "Goodwood Park",
    "Moka",
    "Paramin",
    "Blanchisseuse",
    "Tobago",
    "Scarborough",
    "Bacolet",
    "El Dorado",
    "Endeavour",
    "Charlieville",
    "Longdenville",
    "Tacarigua",
    "Piarco",
    "Brazil",
    "Cumuto",
    "Gran Couva",
    "Preysal",
    "Point Lisas",
    "Claxton Bay",
    "San Raphael",
    "D'Abadie",
    "Santa Rosa",
]


def slugify(name: str) -> str:
    s = name.lower().strip()
    s = s.replace("'", "").replace(".", "")
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")


def nominatim_search(name: str) -> dict | None:
    params = urllib.parse.urlencode(
        {
            "q": f"{name}, Trinidad and Tobago",
            "format": "jsonv2",
            "polygon_geojson": 1,
            "limit": 5,
            "addressdetails": 1,
            "countrycodes": "tt",
        }
    )
    req = urllib.request.Request(
        f"https://nominatim.openstreetmap.org/search?{params}",
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        rows = json.loads(resp.read().decode("utf-8"))

    for row in rows:
        geo = row.get("geojson")
        if not geo or geo.get("type") not in {"Polygon", "MultiPolygon"}:
            continue
        # Prefer administrative / place polygons over incidental features
        if row.get("category") in {"boundary", "place", "administrative"} or row.get("type") in {
            "administrative",
            "city",
            "town",
            "suburb",
            "village",
            "hamlet",
            "neighbourhood",
            "borough",
        }:
            return row
    # Fall back to first polygonal result
    for row in rows:
        geo = row.get("geojson")
        if geo and geo.get("type") in {"Polygon", "MultiPolygon"}:
            return row
    return None


def feature_from_nominatim(name: str, row: dict) -> dict:
    return {
        "type": "Feature",
        "properties": {
            "name": name,
            "display_name": row.get("display_name"),
            "osm_type": row.get("osm_type"),
            "osm_id": row.get("osm_id"),
            "category": row.get("category"),
            "type": row.get("type"),
            "source": "OpenStreetMap / Nominatim",
            "license": "ODbL",
        },
        "geometry": row["geojson"],
        "bbox": [
            float(row["boundingbox"][2]),  # west
            float(row["boundingbox"][0]),  # south
            float(row["boundingbox"][3]),  # east
            float(row["boundingbox"][1]),  # north
        ]
        if row.get("boundingbox")
        else None,
    }


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    index: dict[str, dict] = {}
    ok = 0
    miss = 0

    for i, name in enumerate(PLACES):
        slug = slugify(name)
        print(f"[{i+1}/{len(PLACES)}] {name}…", flush=True)
        try:
            row = nominatim_search(name)
        except Exception as exc:
            print(f"  error: {exc}", flush=True)
            miss += 1
            time.sleep(SLEEP)
            continue

        if not row:
            print("  no polygon", flush=True)
            miss += 1
            time.sleep(SLEEP)
            continue

        feature = feature_from_nominatim(name, row)
        path = OUT_DIR / f"{slug}.geojson"
        path.write_text(json.dumps(feature, ensure_ascii=False), encoding="utf-8")
        keys = {name.lower(), slug.replace("-", " ")}
        for key in keys:
            index[key] = {
                "file": path.name,
                "name": name,
                "osm_id": feature["properties"]["osm_id"],
                "bbox": feature.get("bbox"),
            }
        print(f"  saved {path.name} ({feature['geometry']['type']})", flush=True)
        ok += 1
        time.sleep(SLEEP)

    (OUT_DIR / "index.json").write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Done. archived={ok} missed={miss} → {OUT_DIR}", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
