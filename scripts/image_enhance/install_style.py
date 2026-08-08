#!/usr/bin/env python3
"""Install scripts/image_enhance/styles/tt_realty_listing.dtstyle into darktable's data.db.

darktable-cli --style looks up styles by name in ~/.config/darktable/data.db.
Copying the .dtstyle file alone is not enough.
"""
from __future__ import annotations

import argparse
import base64
import re
import sqlite3
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_STYLE = ROOT / "scripts/image_enhance/styles/tt_realty_listing.dtstyle"
DEFAULT_DB = Path.home() / ".config/darktable/data.db"


def dt_decode(payload: str) -> bytes:
    if not payload:
        return b""
    if payload.startswith("gz"):
        return zlib.decompress(base64.b64decode(payload[4:]))
    return base64.b64decode(payload)


def parse_style(path: Path) -> tuple[str, str, list[dict]]:
    text = path.read_text()
    name = re.search(r"<name>(.*?)</name>", text, re.S).group(1).strip()
    desc_m = re.search(r"<description>(.*?)</description>", text, re.S)
    desc = desc_m.group(1).strip() if desc_m else ""
    plugins = []
    for block in re.findall(r"<plugin>(.*?)</plugin>", text, re.S):

        def g(tag: str, b: str = block) -> str:
            m = re.search(fr"<{tag}>(.*?)</{tag}>", b, re.S)
            return m.group(1) if m else ""

        plugins.append(
            {
                "num": int(g("num")),
                "module": int(g("module")),
                "operation": g("operation"),
                "op_params": dt_decode(g("op_params")),
                "enabled": int(g("enabled") or "1"),
                "blendop_params": dt_decode(g("blendop_params")),
                "blendop_version": int(g("blendop_version") or "13"),
                "multi_priority": int(g("multi_priority") or "0"),
                "multi_name": g("multi_name"),
                "multi_name_hand_edited": int(g("multi_name_hand_edited") or "0"),
            }
        )
    if not name or not plugins:
        raise SystemExit(f"invalid style file (need name + plugins): {path}")
    return name, desc, plugins


def install(style_path: Path, db_path: Path) -> int:
    name, desc, plugins = parse_style(style_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    # Mirror file where the dry script also copies it.
    mirror = db_path.parent / "styles" / f"{name}.dtstyle"
    mirror.parent.mkdir(parents=True, exist_ok=True)
    mirror.write_text(style_path.read_text())

    con = sqlite3.connect(db_path)
    cur = con.cursor()
    for (sid,) in list(cur.execute("SELECT id FROM styles WHERE name=?", (name,))):
        cur.execute("DELETE FROM style_items WHERE styleid=?", (sid,))
        cur.execute("DELETE FROM styles WHERE id=?", (sid,))

    iop_list = ",".join(p["operation"] for p in sorted(plugins, key=lambda x: -x["num"]))
    cur.execute(
        "INSERT INTO styles(name, description, iop_list) VALUES (?,?,?)",
        (name, desc, iop_list),
    )
    sid = cur.lastrowid
    for p in plugins:
        cur.execute(
            """
            INSERT INTO style_items(
              styleid, num, module, operation, op_params, enabled,
              blendop_params, blendop_version, multi_priority, multi_name,
              multi_name_hand_edited
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                sid,
                p["num"],
                p["module"],
                p["operation"],
                sqlite3.Binary(p["op_params"]),
                p["enabled"],
                sqlite3.Binary(p["blendop_params"]),
                p["blendop_version"],
                p["multi_priority"],
                p["multi_name"],
                p["multi_name_hand_edited"],
            ),
        )
    con.commit()
    con.close()
    return sid


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--style", type=Path, default=DEFAULT_STYLE)
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    args = ap.parse_args()
    if not args.style.is_file():
        raise SystemExit(f"style not found: {args.style}")
    sid = install(args.style, args.db)
    name, _, plugins = parse_style(args.style)
    print(f"installed {name} id={sid} plugins={len(plugins)} db={args.db}")


if __name__ == "__main__":
    main()
