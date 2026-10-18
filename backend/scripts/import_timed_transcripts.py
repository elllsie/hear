#!/usr/bin/env python3
"""Import generic WebVTT/SRT transcripts into normalized episode sentences."""

from __future__ import annotations

import argparse
import html
import os
import re
from pathlib import Path

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]
TIMING = re.compile(
    r"(?P<start>\d{1,2}:\d{2}(?::\d{2})?[,.]\d{3})\s*-->\s*"
    r"(?P<end>\d{1,2}:\d{2}(?::\d{2})?[,.]\d{3})[^\n]*\n(?P<body>.*?)(?=\n\s*\n|\Z)",
    re.DOTALL,
)


def milliseconds(value: str) -> int:
    parts = value.replace(",", ".").split(":")
    seconds = float(parts[-1])
    minutes = int(parts[-2])
    hours = int(parts[-3]) if len(parts) == 3 else 0
    return round((hours * 3600 + minutes * 60 + seconds) * 1000)


def parse_timed_text(text: str, episode_id: str, source: str) -> list[dict]:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    rows = []
    for match in TIMING.finditer(text):
        body = re.sub(r"<[^>]+>", "", match.group("body"))
        body = html.unescape(" ".join(body.split()))
        body = re.sub(r"^\d+\s+", "", body).strip()
        if not body:
            continue
        start_ms, end_ms = milliseconds(match.group("start")), milliseconds(match.group("end"))
        if end_ms <= start_ms:
            continue
        rows.append({
            "episode_id": episode_id,
            "sequence": len(rows),
            "start_ms": start_ms,
            "end_ms": end_ms,
            "english": body,
            "chinese": None,
            "speaker": None,
            "source": source,
            "timing_quality": "exact",
            "alignment_confidence": 1.0,
        })
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--podcast-name")
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()
    load_dotenv(BACKEND_DIR / ".env")
    url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not url or not key:
        raise RuntimeError("Missing Supabase credentials")
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    failures = 0
    with httpx.Client(base_url=url + "/rest/v1", headers=headers, timeout=30) as database:
        params = {
            "transcript_url": "not.is.null",
            "transcript_format": "in.(vtt,srt)",
            "audio_status": "eq.available",
            "select": "id,title,transcript_url,transcript_format,podcast_id",
            "order": "publish_date.desc.nullslast",
            "limit": str(min(max(args.limit, 1), 200)),
        }
        if args.podcast_name:
            show = database.get("/podcasts", params={"name": f"eq.{args.podcast_name}", "select": "id", "limit": "1"})
            show.raise_for_status()
            if not show.json():
                raise RuntimeError(f"Podcast not found: {args.podcast_name}")
            params["podcast_id"] = f"eq.{show.json()[0]['id']}"
        response = database.get("/episodes", params=params)
        response.raise_for_status()
        for episode in response.json():
            try:
                transcript = httpx.get(
                    episode["transcript_url"], follow_redirects=True, timeout=45,
                    headers={"User-Agent": "TingHuierTranscriptWorker/1.0"},
                )
                transcript.raise_for_status()
                rows = parse_timed_text(
                    transcript.text, episode["id"], f"official_{episode['transcript_format']}"
                )
                if len(rows) < 2:
                    raise RuntimeError("too few timed transcript cues")
                database.delete("/episode_sentences", params={"episode_id": f"eq.{episode['id']}"}).raise_for_status()
                for offset in range(0, len(rows), 200):
                    database.post("/episode_sentences", json=rows[offset:offset + 200]).raise_for_status()
                database.patch(
                    "/episodes", params={"id": f"eq.{episode['id']}"},
                    json={"transcript_status": "ready"},
                ).raise_for_status()
                print(f"Imported {episode['transcript_format']}: {episode['title']} ({len(rows)})")
            except Exception as error:
                failures += 1
                database.patch(
                    "/episodes", params={"id": f"eq.{episode['id']}"},
                    json={"transcript_status": "failed"},
                ).raise_for_status()
                print(f"FAILED: {episode['title']}: {error}")
    if failures:
        print(f"Timed transcript import completed with {failures} fallback candidate(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
