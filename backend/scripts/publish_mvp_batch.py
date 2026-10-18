#!/usr/bin/env python3
"""Publish an explicitly reviewed MVP Podcast batch through Supabase REST."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]
BBC_NAME = "BBC 6 Minute English"
EPISODE_IDS = [
    "60524ef6-ac57-4338-b2d3-0a83db8e722a",  # Why does heartbreak hurt so much?
    "fff7032e-2ad7-46aa-86ae-4ab7c33796ad",  # Why do we itch?
    "878853db-391e-4e3e-9e05-e28249ba5bce",  # Is rejection good for us?
    "be6e8d0d-f719-4cbc-bc20-8a69d3e891c7",  # Can apps teach you a language?
    "f95e093a-68fc-490d-be01-cd840e93ecfb",  # Climate change and extreme weather
]


def fail(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def main() -> int:
    load_dotenv(BACKEND_DIR / ".env")
    base_url = (os.getenv("SUPABASE_URL") or "").rstrip("/") + "/rest/v1"
    service_key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not service_key or base_url == "/rest/v1":
        return fail("backend/.env is missing Supabase credentials")

    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }
    id_filter = "in.(" + ",".join(EPISODE_IDS) + ")"

    with httpx.Client(base_url=base_url, headers=headers, timeout=20) as client:
        response = client.get(
            "/episodes",
            params={
                "id": id_filter,
                "select": "id,title,duration_seconds,podcast_id,podcast:podcasts(id,name)",
            },
        )
        response.raise_for_status()
        rows: list[dict[str, Any]] = response.json()
        if len(rows) != len(EPISODE_IDS):
            return fail(f"expected {len(EPISODE_IDS)} episodes, found {len(rows)}")

        podcast_ids = {row["podcast_id"] for row in rows}
        podcast_names = {(row.get("podcast") or {}).get("name") for row in rows}
        if len(podcast_ids) != 1 or podcast_names != {BBC_NAME}:
            return fail("selected episodes do not all belong to BBC 6 Minute English")
        if any(not 300 <= (row.get("duration_seconds") or 0) <= 1800 for row in rows):
            return fail("one or more selected episodes are outside the 5-30 minute MVP range")

        podcast_id = next(iter(podcast_ids))
        approve = client.patch(
            "/podcasts",
            params={"id": f"eq.{podcast_id}"},
            json={"rights_status": "approved"},
            headers={"Prefer": "return=minimal"},
        )
        approve.raise_for_status()

        publish = client.patch(
            "/episodes",
            params={"id": id_filter},
            json={"editorial_status": "published"},
            headers={"Prefer": "return=representation"},
        )
        publish.raise_for_status()
        published = publish.json()
        if len(published) != len(EPISODE_IDS):
            return fail(f"publication count mismatch: {len(published)}")

        verify = client.get(
            "/episodes",
            params={
                "id": id_filter,
                "editorial_status": "eq.published",
                "select": "id,title,duration_seconds",
                "order": "publish_date.desc",
            },
        )
        verify.raise_for_status()
        verified = verify.json()

    print(f"Published {len(verified)} episodes from {BBC_NAME}:")
    for row in verified:
        print(f"  - {row['title']} ({round(row['duration_seconds'] / 60, 1)} min)")
    return 0 if len(verified) == len(EPISODE_IDS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
