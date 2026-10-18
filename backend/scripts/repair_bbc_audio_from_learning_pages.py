#!/usr/bin/env python3
"""Replace BBC media-selector URLs with stable official Learning English MP3s."""

from __future__ import annotations

import html
import os
import re
from pathlib import Path

import httpx
from dotenv import load_dotenv

from import_bbc_official_transcripts import official_page_by_title


BACKEND_DIR = Path(__file__).resolve().parents[1]


def official_mp3(page_url: str) -> str:
    response = httpx.get(page_url, timeout=30, headers={"User-Agent": "Mozilla/5.0"})
    response.raise_for_status()
    links = re.findall(r'href="([^"]+_download\.mp3)(?:%20|\s)*"', response.text, flags=re.IGNORECASE)
    if not links:
        raise RuntimeError("official MP3 link not found")
    return html.unescape(links[0]).strip()


def main() -> int:
    load_dotenv(BACKEND_DIR / ".env")
    project_url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not project_url or not key:
        raise RuntimeError("Missing Supabase credentials")
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    pages = official_page_by_title()

    with httpx.Client(base_url=project_url + "/rest/v1", headers=headers, timeout=30) as client:
        shows = client.get("/podcasts", params={"name": "eq.BBC 6 Minute English", "select": "id", "limit": "1"})
        shows.raise_for_status()
        podcast_id = shows.json()[0]["id"]
        episodes = client.get(
            "/episodes",
            params={"podcast_id": f"eq.{podcast_id}", "select": "id,title,audio_url", "limit": "1000"},
        )
        episodes.raise_for_status()

        updated = 0
        skipped = 0
        failed = 0
        for episode in episodes.json():
            try:
                page_url = pages.get(episode["title"])
                if not page_url:
                    skipped += 1
                    continue
                mp3_url = official_mp3(page_url)
                if episode["audio_url"] == mp3_url:
                    skipped += 1
                    continue
                response = client.patch(
                    "/episodes",
                    params={"id": f"eq.{episode['id']}"},
                    json={"audio_url": mp3_url},
                    headers={"Prefer": "return=minimal"},
                )
                response.raise_for_status()
                updated += 1
                print(f"Updated: {episode['title']}")
            except Exception as error:
                failed += 1
                print(f"FAILED: {episode['title']}: {error}")
    print(f"BBC direct audio: updated={updated} skipped={skipped} failed={failed}")
    return 2 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
