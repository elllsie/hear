#!/usr/bin/env python3
"""Publish the latest reviewed episodes for one imported Podcast."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--podcast-name", required=True)
    parser.add_argument("--latest", type=int, default=2)
    parser.add_argument("--confirm-reviewed", action="store_true")
    args = parser.parse_args()
    if not args.confirm_reviewed:
        print("ERROR: pass --confirm-reviewed after content/rights review", file=sys.stderr)
        return 1

    load_dotenv(BACKEND_DIR / ".env")
    project_url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not project_url or not key:
        print("ERROR: missing Supabase credentials", file=sys.stderr)
        return 1

    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    with httpx.Client(base_url=project_url + "/rest/v1", headers=headers, timeout=20) as client:
        shows = client.get(
            "/podcasts", params={"name": f"eq.{args.podcast_name}", "select": "id,name", "limit": "1"}
        )
        shows.raise_for_status()
        if not shows.json():
            print(f"ERROR: podcast not found: {args.podcast_name}", file=sys.stderr)
            return 1
        podcast_id = shows.json()[0]["id"]

        episodes = client.get(
            "/episodes",
            params={
                "podcast_id": f"eq.{podcast_id}",
                "editorial_status": "eq.selected",
                "audio_status": "eq.available",
                "transcript_status": "eq.ready",
                "validation_status": "eq.passed",
                "select": "id,title,duration_seconds,audio_url,audio_status,transcript_status,validation_status",
                "order": "publish_date.desc.nullslast",
                "limit": str(min(max(args.latest, 1), 10)),
            },
        )
        episodes.raise_for_status()
        rows = episodes.json()
        if not rows:
            print("ERROR: podcast has no validated episodes ready to publish", file=sys.stderr)
            return 1

        approve = client.patch(
            "/podcasts",
            params={"id": f"eq.{podcast_id}"},
            json={"rights_status": "approved"},
            headers={"Prefer": "return=minimal"},
        )
        approve.raise_for_status()

        episode_ids = "in.(" + ",".join(row["id"] for row in rows) + ")"
        publish = client.patch(
            "/episodes",
            params={"id": episode_ids},
            json={"editorial_status": "published"},
            headers={"Prefer": "return=minimal"},
        )
        publish.raise_for_status()

    print(f"Published {len(rows)} latest episodes from {args.podcast_name}:")
    for row in rows:
        minutes = round((row.get("duration_seconds") or 0) / 60, 1)
        scheme = row["audio_url"].split(":", 1)[0]
        print(f"  - {row['title']} ({minutes} min, {scheme})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
