#!/usr/bin/env python3
"""Collect curated Podcast RSS metadata and write it to Supabase.

This collector stores publisher-hosted audio URLs. It does not download audio,
generate transcripts, or publish episodes to the iOS client.
"""

from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Optional, Tuple

import feedparser
import httpx
from dotenv import load_dotenv
import os


BACKEND_DIR = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = BACKEND_DIR / "config" / "rss_sources.json"
ALLOWED_CATEGORIES = {"easy", "thinking", "world", "future"}


def text(value: Any) -> str:
    return str(value or "").strip()


def parse_duration(value: Any) -> Optional[int]:
    raw = text(value)
    if not raw:
        return None
    try:
        if raw.isdigit():
            return int(raw)
        parts = [int(part) for part in raw.split(":")]
        if len(parts) == 2:
            return parts[0] * 60 + parts[1]
        if len(parts) == 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
    except ValueError:
        return None
    return None


def parse_date(entry: Any) -> Optional[str]:
    parsed = entry.get("published_parsed") or entry.get("updated_parsed")
    if not parsed:
        return None
    value = datetime.fromtimestamp(calendar.timegm(parsed), tz=timezone.utc)
    return value.isoformat()


def first_url(items: Iterable[Any]) -> Optional[str]:
    for item in items:
        if isinstance(item, dict):
            candidate = text(item.get("href") or item.get("url"))
        else:
            candidate = text(getattr(item, "href", "") or getattr(item, "url", ""))
        if candidate:
            return candidate
    return None


def episode_audio_url(entry: Any) -> Optional[str]:
    enclosure_url = first_url(entry.get("enclosures", []))
    if enclosure_url:
        return enclosure_url

    for item in entry.get("links", []):
        item_type = text(item.get("type"))
        if item.get("rel") == "enclosure" or item_type.startswith("audio/"):
            candidate = text(item.get("href"))
            if candidate:
                return candidate

    return first_url(entry.get("media_content", []))


def enclosure_metadata(entry: Any) -> tuple[Optional[str], Optional[str], Optional[int]]:
    candidates = list(entry.get("enclosures", [])) + list(entry.get("links", []))
    for item in candidates:
        item_type = text(item.get("type")).lower()
        url = text(item.get("href") or item.get("url"))
        if not url or not (item.get("rel") == "enclosure" or item_type.startswith("audio/")):
            continue
        raw_length = text(item.get("length"))
        return url, item_type or None, int(raw_length) if raw_length.isdigit() else None
    audio = episode_audio_url(entry)
    return audio, None, None


def timed_transcript(entry: Any) -> tuple[Optional[str], Optional[str]]:
    for item in entry.get("links", []):
        url = text(item.get("href") or item.get("url"))
        item_type = text(item.get("type")).lower()
        lower_url = url.lower().split("?", 1)[0]
        if item_type in {"text/vtt", "application/vtt"} or lower_url.endswith(".vtt"):
            return url, "vtt"
        if item_type in {"application/x-subrip", "text/srt"} or lower_url.endswith(".srt"):
            return url, "srt"
    return None, None


def normalized_audio_url(url: str) -> str:
    if url.startswith("http://open.live.bbc.co.uk/"):
        return "https://" + url[len("http://") :]
    return url


def image_url(container: Any) -> Optional[str]:
    itunes = container.get("image") or container.get("itunes_image")
    if isinstance(itunes, dict):
        candidate = text(itunes.get("href") or itunes.get("url"))
        if candidate:
            return candidate
    elif text(itunes):
        return text(itunes)
    return first_url(container.get("media_thumbnail", []))


def stable_guid(entry: Any, audio_url: str) -> str:
    supplied = text(entry.get("id") or entry.get("guid"))
    if supplied:
        return supplied
    basis = audio_url or text(entry.get("link")) or text(entry.get("title"))
    return "generated:" + hashlib.sha256(basis.encode("utf-8")).hexdigest()


def parse_feed(
    source: dict[str, Any], timeout: float
) -> Tuple[dict[str, Any], list[dict[str, Any]]]:
    headers = {"User-Agent": "TingHuierPodcastCollector/1.0 (+RSS metadata only)"}
    with httpx.Client(follow_redirects=True, timeout=timeout, headers=headers) as client:
        response = client.get(source["rss_url"])
        response.raise_for_status()

    feed = feedparser.parse(response.content)
    if feed.bozo and not feed.entries:
        raise ValueError(f"RSS parse failed: {feed.bozo_exception}")

    channel = feed.feed
    podcast = {
        "name": text(source.get("name") or channel.get("title")),
        "description": text(channel.get("subtitle") or channel.get("description") or channel.get("summary")),
        "rss_url": source["rss_url"],
        "website_url": source.get("website_url") or text(channel.get("link")) or None,
        "cover_url": image_url(channel),
        "language": "en",
        "category": source["category"],
        "host": source.get("host"),
        "region": source.get("region"),
        "level": source.get("level"),
        "is_active": bool(source.get("is_active", True)),
    }

    episodes: list[dict[str, Any]] = []
    for entry in feed.entries:
        audio, audio_mime_type, audio_content_length = enclosure_metadata(entry)
        transcript_url, transcript_format = timed_transcript(entry)
        title = text(entry.get("title"))
        if not audio or not title:
            continue
        episodes.append(
            {
                "guid": stable_guid(entry, audio),
                "title": title,
                "description": text(entry.get("summary") or entry.get("description")),
                "audio_url": normalized_audio_url(audio),
                "audio_mime_type": audio_mime_type,
                "audio_content_length": audio_content_length,
                "audio_status": "unchecked",
                "transcript_url": transcript_url,
                "transcript_format": transcript_format,
                "source_url": text(entry.get("link")) or None,
                "cover_url": image_url(entry) or podcast["cover_url"],
                "duration_seconds": parse_duration(entry.get("itunes_duration")),
                "publish_date": parse_date(entry),
                "transcript_status": "none",
                "editorial_status": "imported",
            }
        )
    return podcast, episodes


class SupabaseWriter:
    def __init__(self, url: str, service_key: str, timeout: float) -> None:
        self.client = httpx.Client(
            base_url=url.rstrip("/") + "/rest/v1",
            follow_redirects=True,
            timeout=timeout,
            headers={
                "apikey": service_key,
                "Authorization": f"Bearer {service_key}",
                "Content-Type": "application/json",
            },
        )

    def close(self) -> None:
        self.client.close()

    def save_podcast(self, podcast: dict[str, Any]) -> str:
        result = self.client.get(
            "/podcasts",
            params={"rss_url": f"eq.{podcast['rss_url']}", "select": "id", "limit": "1"},
        )
        result.raise_for_status()
        rows = result.json()
        now = datetime.now(timezone.utc).isoformat()

        if rows:
            podcast_id = rows[0]["id"]
            patch = dict(podcast)
            patch["last_synced_at"] = now
            response = self.client.patch(
                "/podcasts",
                params={"id": f"eq.{podcast_id}"},
                json=patch,
                headers={"Prefer": "return=minimal"},
            )
            response.raise_for_status()
            return podcast_id

        payload = dict(podcast)
        payload.update({"rights_status": "unknown", "last_synced_at": now})
        response = self.client.post(
            "/podcasts", json=payload, headers={"Prefer": "return=representation"}
        )
        response.raise_for_status()
        return response.json()[0]["id"]

    def existing_episodes(self, podcast_id: str) -> dict[str, dict[str, Any]]:
        response = self.client.get(
            "/episodes",
            params={
                "podcast_id": f"eq.{podcast_id}",
                "select": "id,guid,audio_url",
                "limit": "10000",
            },
        )
        response.raise_for_status()
        return {row["guid"]: row for row in response.json()}

    def update_episode_metadata(
        self, existing: dict[str, Any], episode: dict[str, Any]
    ) -> None:
        mutable_fields = {
            "title",
            "description",
            "audio_url",
            "audio_mime_type",
            "audio_content_length",
            "source_url",
            "cover_url",
            "duration_seconds",
            "publish_date",
        }
        payload = {key: episode[key] for key in mutable_fields}
        # An RSS feed without Podcasting 2.0 transcript metadata must not erase
        # a transcript URL previously imported by another pipeline stage.
        if episode.get("transcript_url"):
            payload["transcript_url"] = episode["transcript_url"]
            payload["transcript_format"] = episode["transcript_format"]
        if existing.get("audio_url") != episode["audio_url"]:
            payload.update(
                {
                    "audio_status": "unchecked",
                    "resolved_audio_url": None,
                    "audio_checked_at": None,
                    "audio_error": None,
                    "audio_fingerprint": None,
                }
            )
        response = self.client.patch(
            "/episodes",
            params={"id": f"eq.{existing['id']}"},
            json=payload,
            headers={"Prefer": "return=minimal"},
        )
        response.raise_for_status()

    def insert_episodes(self, podcast_id: str, episodes: list[dict[str, Any]]) -> None:
        if not episodes:
            return
        payload = [{**episode, "podcast_id": podcast_id} for episode in episodes]
        response = self.client.post(
            "/episodes", json=payload, headers={"Prefer": "return=minimal"}
        )
        response.raise_for_status()


def load_sources(path: Path, selected: Optional[str]) -> list[dict[str, Any]]:
    sources = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(sources, list) or not sources:
        raise ValueError("Config must be a non-empty JSON array")
    required = {"key", "name", "rss_url", "category"}
    for source in sources:
        missing = required - source.keys()
        if missing:
            raise ValueError(f"Source is missing fields {sorted(missing)}: {source}")
        if source["category"] not in ALLOWED_CATEGORIES:
            raise ValueError(f"Unsupported category: {source['category']}")
    if selected:
        sources = [item for item in sources if item["key"] == selected]
        if not sources:
            raise ValueError(f"Unknown source key: {selected}")
    return sources


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sync curated Podcast RSS metadata to Supabase")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--source", help="Sync only one source key")
    parser.add_argument("--limit", type=int, default=20, help="Newest entries per source (default: 20)")
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--dry-run", action="store_true", help="Fetch and parse RSS without writing")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.limit < 1:
        print("ERROR: --limit must be at least 1", file=sys.stderr)
        return 1

    load_dotenv(BACKEND_DIR / ".env")
    try:
        sources = load_sources(args.config, args.source)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: invalid config: {error}", file=sys.stderr)
        return 1

    writer: Optional[SupabaseWriter] = None
    if not args.dry_run:
        supabase_url = text(os.getenv("SUPABASE_URL"))
        service_key = text(os.getenv("SUPABASE_SERVICE_ROLE_KEY"))
        if not supabase_url or not service_key:
            print("ERROR: set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in backend/.env", file=sys.stderr)
            return 1
        writer = SupabaseWriter(supabase_url, service_key, args.timeout)

    failures = 0
    total_added = 0
    try:
        for source in sources:
            try:
                podcast, episodes = parse_feed(source, args.timeout)
                episodes = episodes[: args.limit]
                if args.dry_run:
                    print(f"[DRY RUN] {podcast['name']}: parsed={len(episodes)}")
                    for episode in episodes[:3]:
                        print(f"  - {episode['title']} ({episode['duration_seconds'] or '?'}s)")
                    continue

                assert writer is not None
                podcast_id = writer.save_podcast(podcast)
                existing = writer.existing_episodes(podcast_id)
                new_episodes = [item for item in episodes if item["guid"] not in existing]
                existing_episodes = [item for item in episodes if item["guid"] in existing]
                for episode in existing_episodes:
                    writer.update_episode_metadata(existing[episode["guid"]], episode)
                writer.insert_episodes(podcast_id, new_episodes)
                total_added += len(new_episodes)
                print(
                    f"[OK] {podcast['name']}: parsed={len(episodes)} "
                    f"added={len(new_episodes)} updated={len(existing_episodes)}"
                )
            except (httpx.HTTPError, ValueError, KeyError) as error:
                failures += 1
                print(f"[FAILED] {source.get('name', source.get('key'))}: {error}", file=sys.stderr)
    finally:
        if writer:
            writer.close()

    print(f"Done: sources={len(sources)} added={total_added} failures={failures}")
    return 2 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
