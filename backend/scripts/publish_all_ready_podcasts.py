#!/usr/bin/env python3
"""Publish every selected Podcast episode that has passed all content gates."""

from __future__ import annotations

import argparse
import os
from collections import Counter
from pathlib import Path

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]


def chunks(values: list[str], size: int = 100) -> list[list[str]]:
    return [values[index:index + size] for index in range(0, len(values), size)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true", help="Apply publication changes; default is read-only.")
    args = parser.parse_args()

    load_dotenv(BACKEND_DIR / ".env")
    project_url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not project_url or not key:
        raise RuntimeError("backend/.env is missing Supabase credentials")

    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }
    with httpx.Client(base_url=project_url + "/rest/v1", headers=headers, timeout=60) as client:
        response = client.get(
            "/episodes",
            params={
                "audio_status": "eq.available",
                "transcript_status": "eq.ready",
                "validation_status": "eq.passed",
                "editorial_status": "eq.selected",
                "select": "id,title,podcast_id,podcast:podcasts(id,name,language)",
                "order": "publish_date.desc.nullslast,id.desc",
                "limit": "10000",
            },
        )
        response.raise_for_status()
        episodes = response.json()
        counts = Counter((row.get("podcast") or {}).get("name", "Unknown") for row in episodes)
        print(f"eligible={len(episodes)} podcasts={len(counts)} mode={'execute' if args.execute else 'dry-run'}")
        for name, count in sorted(counts.items()):
            print(f"  {name}: {count}")
        if not args.execute or not episodes:
            return 0

        podcast_ids = sorted({row["podcast_id"] for row in episodes})
        for batch in chunks(podcast_ids):
            identifier_filter = "in.(" + ",".join(batch) + ")"
            approved = client.patch(
                "/podcasts",
                params={"id": identifier_filter},
                json={"rights_status": "approved", "is_active": True},
                headers={"Prefer": "return=minimal"},
            )
            approved.raise_for_status()

        episode_ids = [row["id"] for row in episodes]
        for batch in chunks(episode_ids):
            identifier_filter = "in.(" + ",".join(batch) + ")"
            published = client.patch(
                "/episodes",
                params={"id": identifier_filter},
                json={"editorial_status": "published"},
                headers={"Prefer": "return=minimal"},
            )
            published.raise_for_status()

        verify = client.get(
            "/episodes",
            params={
                "id": "in.(" + ",".join(episode_ids) + ")",
                "editorial_status": "eq.published",
                "select": "id",
                "limit": "10000",
            },
        )
        verify.raise_for_status()
        verified = len(verify.json())
        print(f"published={verified}/{len(episode_ids)}")
        return 0 if verified == len(episode_ids) else 1


if __name__ == "__main__":
    raise SystemExit(main())
