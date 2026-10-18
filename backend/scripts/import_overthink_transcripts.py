#!/usr/bin/env python3
"""Import exact timestamped transcripts published on overthinkpodcast.com."""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path
from typing import Any

import httpx
from bs4 import BeautifulSoup
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]
SITE = "https://overthinkpodcast.com"
TIMESTAMP = re.compile(r"\[(\d{2}):(\d{2}):(\d{2})\]")
MAX_TIMELINE_DRIFT_SECONDS = 15


def seconds(hours: str, minutes: str, value: str) -> int:
    return int(hours) * 3600 + int(minutes) * 60 + int(value)


def episode_numbers() -> dict[str, int]:
    response = httpx.get(SITE + "/episodes", timeout=30, headers={"User-Agent": "Mozilla/5.0"})
    response.raise_for_status()
    soup = BeautifulSoup(response.text, "html.parser")
    result: dict[str, int] = {}
    for anchor in soup.find_all("a", href=True):
        label = " ".join(anchor.get_text(" ", strip=True).split())
        match = re.fullmatch(r"Episode\s+(\d+):\s*(.+)", label, flags=re.IGNORECASE)
        if match:
            result[match.group(2).strip().casefold()] = int(match.group(1))
    return result


def transcript_rows(episode: dict[str, Any], number: int) -> list[dict[str, Any]]:
    url = f"{SITE}/episode-{number:03d}-transcript"
    response = httpx.get(url, follow_redirects=True, timeout=30, headers={"User-Agent": "Mozilla/5.0"})
    response.raise_for_status()
    text = BeautifulSoup(response.text, "html.parser").get_text("\n", strip=True)
    matches = list(TIMESTAMP.finditer(text))
    if len(matches) < 10:
        raise RuntimeError(f"too few timestamps found at {url}")

    duration_ms = int((episode.get("duration_seconds") or 0) * 1_000)
    transcript_end_ms = seconds(*matches[-1].groups()) * 1_000
    allowed_drift_ms = max(MAX_TIMELINE_DRIFT_SECONDS * 1_000, round(duration_ms * 0.02))
    if duration_ms <= 0:
        raise RuntimeError("episode duration is missing; cannot validate transcript timeline")
    if abs(transcript_end_ms - duration_ms) > allowed_drift_ms:
        raise RuntimeError(
            "official transcript does not match the RSS audio edit: "
            f"last timestamp={transcript_end_ms / 1000:.0f}s, "
            f"audio={duration_ms / 1000:.0f}s"
        )
    rows: list[dict[str, Any]] = []
    for index, match in enumerate(matches):
        start_ms = seconds(*match.groups()) * 1_000
        next_start_ms = (
            seconds(*matches[index + 1].groups()) * 1_000
            if index + 1 < len(matches)
            else max(duration_ms, start_ms + 1_000)
        )
        body_end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        body = " ".join(text[match.end() : body_end].split())
        if index == len(matches) - 1:
            body = re.split(r"\s+Episodes\s+Contact\s*$", body)[0].strip()
        if not body:
            continue
        speaker = None
        speaker_match = re.match(r"^([^:]{1,50}):\s*(.+)$", body)
        if speaker_match:
            speaker = speaker_match.group(1).strip()
            body = speaker_match.group(2).strip()
        rows.append(
            {
                "episode_id": episode["id"],
                "sequence": len(rows),
                "start_ms": start_ms,
                "end_ms": max(start_ms + 1, next_start_ms),
                "english": body,
                "chinese": None,
                "speaker": speaker,
                "source": "official_timestamped",
                "timing_quality": "exact",
                "alignment_confidence": 1.0,
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--podcast-name", default="Overthink")
    args = parser.parse_args()
    load_dotenv(BACKEND_DIR / ".env")
    project_url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not project_url or not key:
        raise RuntimeError("Missing Supabase credentials")
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    numbers = episode_numbers()

    with httpx.Client(base_url=project_url + "/rest/v1", headers=headers, timeout=30) as client:
        shows = client.get("/podcasts", params={"name": f"eq.{args.podcast_name}", "select": "id", "limit": "1"})
        shows.raise_for_status()
        podcast_id = shows.json()[0]["id"]
        response = client.get(
            "/episodes",
            params={
                "podcast_id": f"eq.{podcast_id}",
                "editorial_status": "neq.archived",
                "select": "id,title,duration_seconds",
                "order": "publish_date.desc",
                "limit": str(min(max(args.limit, 1), 200)),
            },
        )
        response.raise_for_status()
        episodes = response.json()

        failures = 0
        for episode in episodes:
            try:
                number = numbers.get(episode["title"].casefold())
                if number is None:
                    raise RuntimeError("episode number not found on official Episodes page")
                rows = transcript_rows(episode, number)
                deletion = client.delete(
                    "/episode_sentences",
                    params={"episode_id": f"eq.{episode['id']}"},
                    headers={"Prefer": "return=minimal"},
                )
                deletion.raise_for_status()
                for offset in range(0, len(rows), 200):
                    insertion = client.post(
                        "/episode_sentences", json=rows[offset : offset + 200], headers={"Prefer": "return=minimal"}
                    )
                    insertion.raise_for_status()
                status = client.patch(
                    "/episodes",
                    params={"id": f"eq.{episode['id']}"},
                    json={"transcript_status": "ready"},
                    headers={"Prefer": "return=minimal"},
                )
                status.raise_for_status()
                print(f"Imported: Episode {number} · {episode['title']} ({len(rows)} timed segments)")
            except Exception as error:
                failures += 1
                print(f"FAILED: {episode['title']}: {error}")
    return 2 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
