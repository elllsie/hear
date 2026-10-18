#!/usr/bin/env python3
"""Apply generic publication quality gates to normalized Podcast episodes."""

from __future__ import annotations

import argparse
import os
import time
from pathlib import Path

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]


def validate(episode: dict, rows: list[dict], require_chinese: bool) -> list[str]:
    errors = []
    if episode.get("audio_status") != "available":
        errors.append("audio is not available")
    if episode.get("transcript_status") != "ready":
        errors.append("transcript is not ready")
    if len(rows) < 2:
        errors.append("too few transcript sentences")
        return errors
    previous_end = 0
    for index, row in enumerate(rows):
        if row["start_ms"] < previous_end - 2_000:
            errors.append(f"non-monotonic timeline at sequence {index}")
            break
        if row["end_ms"] <= row["start_ms"]:
            errors.append(f"invalid interval at sequence {index}")
            break
        previous_end = row["end_ms"]
    duration_ms = (episode.get("duration_seconds") or 0) * 1000
    if duration_ms and abs(rows[-1]["end_ms"] - duration_ms) > max(30_000, duration_ms * 0.05):
        errors.append("transcript end differs from audio duration by more than 5%/30s")
    if require_chinese and any(not (row.get("chinese") or "").strip() for row in rows):
        errors.append("Chinese translation is incomplete")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--podcast-name")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--require-chinese", action="store_true")
    args = parser.parse_args()
    load_dotenv(BACKEND_DIR / ".env")
    url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not url or not key:
        raise RuntimeError("Missing Supabase credentials")
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    failed = 0
    with httpx.Client(base_url=url + "/rest/v1", headers=headers, timeout=60) as client:
        def request(method: str, path: str, **kwargs) -> httpx.Response:
            for attempt in range(1, 4):
                try:
                    response = client.request(method, path, **kwargs)
                    response.raise_for_status()
                    return response
                except httpx.HTTPError:
                    if attempt == 3:
                        raise
                    time.sleep(attempt * 2)
            raise RuntimeError("unreachable")

        params = {
            "editorial_status": "neq.archived",
            "select": "id,title,duration_seconds,audio_status,transcript_status,editorial_status,podcast_id",
            "order": "publish_date.desc.nullslast",
            "limit": str(min(max(args.limit, 1), 200)),
        }
        if args.podcast_name:
            show = client.get("/podcasts", params={"name": f"eq.{args.podcast_name}", "select": "id", "limit": "1"})
            show.raise_for_status()
            if not show.json():
                raise RuntimeError(f"Podcast not found: {args.podcast_name}")
            params["podcast_id"] = f"eq.{show.json()[0]['id']}"
        episodes = request("GET", "/episodes", params=params)
        for episode in episodes.json():
            sentences = request(
                "GET",
                "/episode_sentences",
                params={"episode_id": f"eq.{episode['id']}", "select": "sequence,start_ms,end_ms,chinese", "order": "sequence.asc", "limit": "10000"},
            )
            errors = validate(episode, sentences.json(), args.require_chinese)
            payload = {
                "validation_status": "failed" if errors else "passed",
                "validation_error": "; ".join(errors) or None,
            }
            if not errors and episode.get("editorial_status") == "imported":
                payload["editorial_status"] = "selected"
            request("PATCH", "/episodes", params={"id": f"eq.{episode['id']}"}, json=payload)
            print(f"{'FAILED' if errors else 'PASSED'}: {episode['title']}" + (f" — {payload['validation_error']}" if errors else ""))
            failed += bool(errors)
    if failed:
        print(f"Validation rejected {failed} episode(s); other episodes remain eligible.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
