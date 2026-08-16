#!/usr/bin/env python3
"""Build Classic GmbH Quartermaster HelperData.lua from questions or JSON.

No loottracker /api/addon access required.

Usage:
  python scripts/write_helperdata.py --example-json
  python scripts/write_helperdata.py --from-json assignments.json --out HelperData.lua
  python scripts/write_helperdata.py --out "D:\\Games\\...\\ClassicGmbHQuartermaster\\HelperData.lua"
  python scripts/write_helperdata.py
      # interactive prompts, then asks for --out if not given

JSON shape:
  {
    "raid": "aq40",
    "title": "AQ40 Friday",
    "announced": true,
    "groups": [["Irae", "Hardzor", null, null, null]],
    "bench": ["Spareone"],
    "assignments": [
      {"section": "C'Thun", "slot": "MT", "player": "Hardzor", "class": "Warrior", "role": "Tank"}
    ]
  }

Environment:
  WOW_PATH  optional World of Warcraft _classic_era_ folder for default --out
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

EXAMPLE_JSON = {
    "raid": "aq40",
    "title": "AQ40 Friday",
    "announced": True,
    "groups": [
        ["Irae", "Hardzor", "Twyn", "Bexey", "Redmiso"],
        ["Cadaverus", "Baretta", None, None, None],
    ],
    "bench": ["Spareone"],
    "assignments": [
        {
            "section": "C'Thun",
            "slot": "MT",
            "player": "Hardzor",
            "class": "Warrior",
            "role": "Tank",
        },
        {
            "section": "C'Thun",
            "slot": "Heal 1",
            "player": "Twyn",
            "class": "Priest",
            "role": "Healer",
        },
    ],
}

_LUA_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def lua_string(value: Any) -> str:
    out: list[str] = []
    for b in str(value).encode("utf-8"):
        if b == 0x5C:
            out.append("\\\\")
        elif b == 0x22:
            out.append('\\"')
        elif b == 0x0A:
            out.append("\\n")
        elif b == 0x0D:
            out.append("\\r")
        elif b == 0x09:
            out.append("\\t")
        elif 32 <= b <= 126:
            out.append(chr(b))
        elif b < 32:
            continue
        else:
            out.append(f"\\{b:03d}")
    return '"' + "".join(out) + '"'


def _lua_key(key: Any) -> str:
    if isinstance(key, bool):
        return f"[{lua_string(str(key))}]"
    if isinstance(key, int) and not isinstance(key, bool):
        return f"[{key}]"
    s = str(key)
    if _LUA_IDENT.match(s):
        return s
    return f"[{lua_string(s)}]"


def to_lua(value: Any) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            return "0"
        if value.is_integer():
            return str(int(value))
        return repr(value)
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, list):
        if not value:
            return "{}"
        return "{" + ",".join(to_lua(item) for item in value) + "}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        parts = [f"{_lua_key(k)}={to_lua(v)}" for k, v in value.items()]
        return "{" + ",".join(parts) + "}"
    return lua_string(str(value))


def _slugify_id(text: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", str(text or "").strip()).strip("_").lower()
    return s or "slot"


def _seat_from_name(name: Any, *, class_name: str | None = None, role: str | None = None) -> dict[str, Any] | None:
    if name is None:
        return None
    if isinstance(name, dict):
        n = str(name.get("name") or "").strip()
        if not n:
            return None
        out: dict[str, Any] = {"name": n}
        for key in ("class", "class_color", "role"):
            if name.get(key):
                out[key] = name[key]
        return out
    n = str(name).strip()
    if not n or n.lower() in {"null", "nil", "-"}:
        return None
    out = {"name": n}
    if class_name:
        out["class"] = class_name
    if role:
        out["role"] = role
    return out


def build_raid_from_spec(spec: dict[str, Any]) -> dict[str, Any]:
    slug = str(spec.get("raid") or spec.get("raid_slug") or "aq40").strip().lower()
    announced = bool(spec.get("announced", True))
    title = str(spec.get("title") or slug.upper()).strip()

    groups_out: list[list[dict[str, Any] | None]] = []
    for raw_group in spec.get("groups") or []:
        if not isinstance(raw_group, list):
            continue
        seats: list[dict[str, Any] | None] = []
        for i in range(5):
            cell = raw_group[i] if i < len(raw_group) else None
            seats.append(_seat_from_name(cell))
        groups_out.append(seats)
    while len(groups_out) < 8:
        groups_out.append([None, None, None, None, None])
    groups_out = groups_out[:8]

    bench_out: list[dict[str, Any]] = []
    for cell in spec.get("bench") or []:
        seat = _seat_from_name(cell)
        if seat:
            bench_out.append(seat)

    # section_label -> list of slot dicts
    by_section: dict[str, list[dict[str, Any]]] = {}
    assignments_out: list[dict[str, Any]] = []
    for row in spec.get("assignments") or []:
        if not isinstance(row, dict):
            continue
        section = str(row.get("section") or row.get("section_label") or "General").strip()
        slot_label = str(row.get("slot") or row.get("label") or "").strip()
        player = str(row.get("player") or row.get("player_name") or "").strip()
        if not slot_label or not player:
            continue
        class_name = str(row.get("class") or "").strip() or None
        role = str(row.get("role") or "").strip() or None
        slot_id = str(row.get("slot_id") or f"{_slugify_id(section)}_{_slugify_id(slot_label)}")
        assignments_out.append(
            {
                "slot_id": slot_id,
                "label": slot_label,
                "section_label": section,
                "board_label": section,
                "mark": row.get("mark") or None,
                "player_name": player,
                "class": class_name,
                "class_color": row.get("class_color"),
                "role": role,
            }
        )
        by_section.setdefault(section, []).append(
            {
                "id": slot_id,
                "label": slot_label,
                "mark": row.get("mark") or None,
                "player_name": player,
                "class": class_name,
                "class_color": row.get("class_color"),
                "role": role,
            }
        )

    sections_out: list[dict[str, Any]] = []
    for idx, (section_label, slots) in enumerate(by_section.items(), start=1):
        sec_id = _slugify_id(section_label) or f"sec_{idx}"
        sections_out.append(
            {
                "id": sec_id,
                "label": section_label,
                "kind": "boss",
                "boards": [
                    {
                        "id": f"{sec_id}_board",
                        "label": section_label,
                        "slots": slots,
                    }
                ],
            }
        )

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "raid_slug": slug,
        "title": title,
        "event_start_at": spec.get("event_start_at"),
        "version": str(spec.get("version") or 1),
        "updated_at": now,
        "announced": announced,
        "member_locked": not announced,
        "has_sheet": True,
        "bug_trio_last": spec.get("bug_trio_last"),
        "groups": groups_out,
        "bench": bench_out,
        "assignments": assignments_out,
        "sections": sections_out,
    }


def build_helper_payload(spec: dict[str, Any]) -> dict[str, Any]:
    raid = build_raid_from_spec(spec)
    slug = raid["raid_slug"]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    revision = str(spec.get("revision") or uuid.uuid4())
    return {
        "version": 1,
        "revision": revision,
        "syncedAt": now,
        "raidSyncedAt": now,
        "raidRevision": revision,
        "syncSource": "manual",
        "user": spec.get("user") or {},
        "raids": {slug: raid},
        "wishlists": {},
        "wishlistByItem": {},
        "items": {},
    }


def render_helperdata(payload: dict[str, Any]) -> str:
    return (
        "-- Generated by write_helperdata.py. Do not edit by hand.\n"
        f"GmbHLootTrackerHelperData = {to_lua(payload)}\n"
    )


def default_out_path() -> Path | None:
    wow = (os.environ.get("WOW_PATH") or "").strip()
    if not wow:
        candidate = Path(r"D:\Games\World of Warcraft\_classic_era_")
        if candidate.is_dir():
            wow = str(candidate)
    if not wow:
        return None
    return (
        Path(wow).expanduser()
        / "Interface"
        / "AddOns"
        / "ClassicGmbHQuartermaster"
        / "HelperData.lua"
    )


def _ask(prompt: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default is not None else ""
    raw = input(f"{prompt}{suffix}: ").strip()
    if raw == "" and default is not None:
        return default
    return raw


def interactive_spec() -> dict[str, Any]:
    print("Interactive HelperData builder (empty line ends assignment list).\n")
    slug = _ask("Raid slug (aq40/naxx/bwl)", "aq40").lower()
    title = _ask("Title", slug.upper())
    announced_raw = _ask("Announced for members? (y/n)", "y").lower()
    announced = announced_raw in {"y", "yes", "1", "true"}

    groups: list[list[str | None]] = []
    print("\nGroups: enter up to 5 comma-separated names per group.")
    print("Blank group name list skips that group and stops further groups.\n")
    for gi in range(1, 9):
        line = _ask(f"G{gi} names", "")
        if not line:
            break
        parts = [p.strip() for p in line.split(",")]
        seats: list[str | None] = []
        for i in range(5):
            if i < len(parts) and parts[i]:
                seats.append(parts[i])
            else:
                seats.append(None)
        groups.append(seats)

    bench_line = _ask("Bench names (comma-separated, optional)", "")
    bench = [p.strip() for p in bench_line.split(",") if p.strip()] if bench_line else []

    print("\nAssignments: section | slot | player [| class [| role]]")
    print("Example: C'Thun | MT | Hardzor | Warrior | Tank")
    print("Empty line when done.\n")
    assignments: list[dict[str, Any]] = []
    while True:
        line = input("assignment> ").strip()
        if not line:
            break
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3:
            print("  Need at least: section | slot | player")
            continue
        row: dict[str, Any] = {
            "section": parts[0],
            "slot": parts[1],
            "player": parts[2],
        }
        if len(parts) >= 4 and parts[3]:
            row["class"] = parts[3]
        if len(parts) >= 5 and parts[4]:
            row["role"] = parts[4]
        assignments.append(row)

    return {
        "raid": slug,
        "title": title,
        "announced": announced,
        "groups": groups,
        "bench": bench,
        "assignments": assignments,
    }


def load_spec_from_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("JSON root must be an object")
    return data


def count_stats(payload: dict[str, Any]) -> tuple[int, int, int]:
    raids = payload.get("raids") or {}
    seats = 0
    bench_n = 0
    assign_n = 0
    for raid in raids.values():
        if not isinstance(raid, dict):
            continue
        for group in raid.get("groups") or []:
            for seat in group or []:
                if isinstance(seat, dict) and seat.get("name"):
                    seats += 1
        bench_n += len(raid.get("bench") or [])
        assign_n += len(raid.get("assignments") or [])
    return seats, bench_n, assign_n


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Write Classic GmbH Quartermaster HelperData.lua from JSON or questions."
    )
    parser.add_argument(
        "--from-json",
        type=Path,
        help="Read raid/groups/assignments from this JSON file",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="Output HelperData.lua path",
    )
    parser.add_argument(
        "--example-json",
        action="store_true",
        help="Print an example JSON file to stdout and exit",
    )
    args = parser.parse_args(argv)

    if args.example_json:
        print(json.dumps(EXAMPLE_JSON, indent=2))
        return 0

    if args.from_json:
        if not args.from_json.is_file():
            print(f"JSON not found: {args.from_json}", file=sys.stderr)
            return 1
        try:
            spec = load_spec_from_json(args.from_json)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"Failed to read JSON: {exc}", file=sys.stderr)
            return 1
    else:
        try:
            spec = interactive_spec()
        except EOFError:
            print("Aborted.", file=sys.stderr)
            return 1

    out = args.out
    if out is None:
        default = default_out_path()
        default_s = str(default) if default else ""
        try:
            chosen = _ask("Output HelperData.lua path", default_s or "HelperData.lua")
        except EOFError:
            print("Aborted.", file=sys.stderr)
            return 1
        out = Path(chosen)

    payload = build_helper_payload(spec)
    text = render_helperdata(payload)
    out = out.expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8", newline="\n")

    seats, bench_n, assign_n = count_stats(payload)
    print(f"Wrote {out}")
    print(f"  size={out.stat().st_size} bytes")
    print(f"  group_seats={seats} bench={bench_n} assignments={assign_n}")
    print(">>> /reload in WoW so the addon reloads HelperData.lua")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
