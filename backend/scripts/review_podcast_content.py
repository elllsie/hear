#!/usr/bin/env python3
"""Read-only report for reviewing imported Podcast content."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Any

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description="List imported Podcast episodes for editorial review")
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--min-minutes", type=int, default=5)
    parser.add_argument("--max-minutes", type=int, default=30)
    args = parser.parse_args()

    load_dotenv(BACKEND_DIR / ".env")
    url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not url or not key:
        print("ERROR: backend/.env is missing Supabase credentials", file=sys.stderr)
        return 1

    selection = (
        "id,title,duration_seconds,publish_date,editorial_status,"
        "podcast:podcasts(name,level,rights_status)"
    )
    params = {
        "select": selection,
        "duration_seconds": f"gte.{args.min_minutes * 60}",
        "and": f"(duration_seconds.lte.{args.max_minutes * 60})",
        "order": "publish_date.desc.nullslast",
        "limit": str(min(max(args.limit, 1), 200)),
    }
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    response = httpx.get(
        url + "/rest/v1/episodes", params=params, headers=headers, timeout=20, follow_redirects=True
    )
    response.raise_for_status()
    rows: list[dict[str, Any]] = response.json()

    if not rows:
        print("No episodes matched the requested duration range.")
        return 0

    for row in rows:
        podcast = row.get("podcast") or {}
        minutes = round((row.get("duration_seconds") or 0) / 60, 1)
        print(
            f"{row['id']} | {minutes:>4} min | {podcast.get('level') or '-':<5} | "
            f"{podcast.get('name') or '-'} | {row['title']}"
        )
    print(f"Candidates: {len(rows)} (read-only; nothing was published)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
