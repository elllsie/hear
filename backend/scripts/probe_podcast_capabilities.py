#!/usr/bin/env python3
"""Detect audio and timed-transcript capabilities without source-specific code."""

from __future__ import annotations

import argparse
import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]
SUPPORTED_AUDIO = {"audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/ogg"}


def classify(status: int, content_type: str) -> str:
    if status in {401, 403}:
        return "requires_auth"
    if not 200 <= status < 400:
        return "unavailable"
    mime = content_type.split(";", 1)[0].strip().lower()
    return "available" if mime in SUPPORTED_AUDIO or mime.startswith("audio/") else "unsupported"


def probe(url: str, timeout: float) -> dict[str, Any]:
    headers = {
        "User-Agent": "TingHuierCapabilityProbe/1.0",
        "Accept": "audio/*,*/*;q=0.1",
        "Range": "bytes=0-262143",
    }
    with httpx.stream("GET", url, headers=headers, follow_redirects=True, timeout=timeout) as response:
        sample = bytearray()
        for chunk in response.iter_bytes():
            sample.extend(chunk[: max(0, 262_144 - len(sample))])
            if len(sample) >= 262_144:
                break
        body = bytes(sample)
        content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
        content_length = response.headers.get("content-length")
        content_range = response.headers.get("content-range", "")
        if "/" in content_range and content_range.rsplit("/", 1)[1].isdigit():
            content_length = content_range.rsplit("/", 1)[1]
        status = classify(response.status_code, content_type)
        return {
            "audio_status": status,
            "audio_mime_type": content_type or None,
            "audio_content_length": int(content_length) if content_length and content_length.isdigit() else None,
            "resolved_audio_url": str(response.url),
            "audio_fingerprint": hashlib.sha256(body).hexdigest() if body else None,
            "audio_checked_at": datetime.now(timezone.utc).isoformat(),
            "audio_error": None if status == "available" else f"HTTP {response.status_code}; MIME {content_type or 'unknown'}",
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--podcast-name")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=45)
    args = parser.parse_args()

    load_dotenv(BACKEND_DIR / ".env")
    url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not url or not key:
        raise RuntimeError("Missing Supabase credentials")
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    failures = 0
    with httpx.Client(base_url=url + "/rest/v1", headers=headers, timeout=30) as database:
        params: dict[str, str] = {
            "select": "id,title,audio_url,transcript_url,transcript_format,cover_url,podcast:podcasts(name)",
            "order": "publish_date.desc.nullslast",
            "limit": str(min(max(args.limit, 1), 200)),
            "offset": str(max(args.offset, 0)),
        }
        if args.podcast_name:
            show = database.get("/podcasts", params={"name": f"eq.{args.podcast_name}", "select": "id", "limit": "1"})
            show.raise_for_status()
            if not show.json():
                raise RuntimeError(f"Podcast not found: {args.podcast_name}")
            params["podcast_id"] = f"eq.{show.json()[0]['id']}"
        episodes = database.get("/episodes", params=params)
        episodes.raise_for_status()
        for episode in episodes.json():
            try:
                result = probe(episode["audio_url"], args.timeout)
            except Exception as error:
                failures += 1
                result = {
                    "audio_status": "unavailable",
                    "audio_checked_at": datetime.now(timezone.utc).isoformat(),
                    "audio_error": repr(error)[:500],
                }
            snapshot = {
                "rss": True,
                "audio": result["audio_status"],
                "timed_transcript": bool(episode.get("transcript_url") and episode.get("transcript_format")),
                "cover": bool(episode.get("cover_url")),
            }
            result["capability_snapshot"] = snapshot
            update = database.patch(
                "/episodes", params={"id": f"eq.{episode['id']}"}, json=result,
                headers={"Prefer": "return=minimal"},
            )
            update.raise_for_status()
            print(f"{result['audio_status']}: {episode['title']}")
    if failures:
        print(f"Capability probe completed with {failures} unavailable episode(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
