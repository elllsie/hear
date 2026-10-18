#!/usr/bin/env python3
"""Import BBC official transcript PDFs with an approximate learning timeline.

BBC labels these documents as not word-for-word transcripts and provides no
timestamps. This script preserves that distinction: it creates a proportional
timeline for immediate learning use, which can later be replaced by Whisper.
"""

from __future__ import annotations

import html
import io
import os
import re
from pathlib import Path
from typing import Any

import feedparser
import httpx
from dotenv import load_dotenv
from pypdf import PdfReader


BACKEND_DIR = Path(__file__).resolve().parents[1]
BBC_FEED = "https://podcasts.files.bbci.co.uk/p02pc9tn.rss"


def official_page_by_title() -> dict[str, str]:
    response = httpx.get(
        BBC_FEED,
        follow_redirects=True,
        timeout=60,
        headers={"User-Agent": "TingHuierTranscriptWorker/1.0"},
    )
    response.raise_for_status()
    feed = feedparser.parse(response.content)
    result: dict[str, str] = {}
    for entry in feed.entries:
        summary = html.unescape(str(entry.get("summary") or ""))
        matches = re.findall(r'https://www\.bbc\.co\.uk/learningenglish/[^"<\s]+', summary)
        if matches:
            result[str(entry.get("title") or "").strip()] = matches[0]
    return result


def transcript_pdf_url(page_url: str) -> str:
    response = httpx.get(page_url, follow_redirects=True, timeout=30, headers={"User-Agent": "Mozilla/5.0"})
    response.raise_for_status()
    match = re.search(
        r'href="([^"]+_transcript\.pdf)(?:%20|\s)*"',
        response.text,
        flags=re.IGNORECASE,
    )
    if not match:
        raise RuntimeError("official transcript PDF link not found")
    return html.unescape(match.group(1))


def transcript_paragraphs(pdf_url: str, episode_title: str) -> list[str]:
    response = httpx.get(pdf_url, timeout=60)
    response.raise_for_status()
    document = PdfReader(io.BytesIO(response.content))
    raw = "\n".join(page.extract_text() or "" for page in document.pages)
    raw = raw.split("\nVOCABULARY", 1)[0]

    ignored_patterns = [
        r"^BBC LEARNING ENGLISH$",
        r"^6 Minute English$",
        r"^6 Minute English ©.*$",
        r"^bbclearningenglish\.com Page \d+ of \d+$",
        r"^This is not a word-for-word transcript\.$",
        re.escape(episode_title),
    ]
    kept: list[str] = []
    for line in raw.splitlines():
        value = " ".join(line.split())
        if not value:
            kept.append("")
            continue
        if any(re.match(pattern, value, flags=re.IGNORECASE) for pattern in ignored_patterns):
            continue
        kept.append(value)

    blocks = [" ".join(block.split()) for block in re.split(r"\n\s*\n", "\n".join(kept))]
    blocks = [block for block in blocks if block]
    utterances: list[str] = []
    current_speaker = ""
    speaker_pattern = re.compile(r"^(?:Dr |Professor )?[A-Z][A-Za-z'-]+(?: [A-Z][A-Za-z'-]+){0,3}$")
    for block in blocks:
        if len(block) <= 45 and speaker_pattern.fullmatch(block):
            current_speaker = block
            continue
        sentences = re.split(r"(?<=[.!?])\s+(?=[A-Z])", block)
        for index, sentence in enumerate(sentences):
            sentence = sentence.strip()
            if len(sentence) < 2:
                continue
            prefix = f"{current_speaker}: " if index == 0 and current_speaker else ""
            utterances.append(prefix + sentence)
    return utterances


def timed_rows(episode: dict[str, Any], utterances: list[str]) -> list[dict[str, Any]]:
    total_ms = int((episode.get("duration_seconds") or 360) * 1_000)
    weights = [max(1, len(re.findall(r"[A-Za-z']+", text))) for text in utterances]
    total_weight = sum(weights)
    cursor = 0
    rows: list[dict[str, Any]] = []
    for sequence, (english, weight) in enumerate(zip(utterances, weights)):
        end = total_ms if sequence == len(utterances) - 1 else cursor + round(total_ms * weight / total_weight)
        rows.append(
            {
                "episode_id": episode["id"],
                "sequence": sequence,
                "start_ms": cursor,
                "end_ms": max(cursor + 1, end),
                "english": english,
                "chinese": None,
                "speaker": None,
                "source": "official_pdf",
                "timing_quality": "approximate",
                "alignment_confidence": None,
            }
        )
        cursor = end
    return rows


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
        response = client.get(
            "/episodes",
            params={
                "podcast_id": f"eq.{podcast_id}",
                "editorial_status": "eq.published",
                "select": "id,title,duration_seconds",
                "order": "publish_date.desc",
                "limit": "5",
            },
        )
        response.raise_for_status()
        episodes = response.json()

        failures = 0
        for episode in episodes:
            try:
                page_url = pages.get(episode["title"])
                if not page_url:
                    raise RuntimeError("official learning page not found in RSS")
                pdf_url = transcript_pdf_url(page_url)
                utterances = transcript_paragraphs(pdf_url, episode["title"])
                if len(utterances) < 10:
                    raise RuntimeError("too few transcript sentences extracted")
                rows = timed_rows(episode, utterances)
                deletion = client.delete(
                    "/episode_sentences",
                    params={"episode_id": f"eq.{episode['id']}"},
                    headers={"Prefer": "return=minimal"},
                )
                deletion.raise_for_status()
                for index in range(0, len(rows), 200):
                    insertion = client.post(
                        "/episode_sentences", json=rows[index : index + 200], headers={"Prefer": "return=minimal"}
                    )
                    insertion.raise_for_status()
                status = client.patch(
                    "/episodes",
                    params={"id": f"eq.{episode['id']}"},
                    json={"transcript_status": "ready"},
                    headers={"Prefer": "return=minimal"},
                )
                status.raise_for_status()
                print(f"Imported: {episode['title']} ({len(rows)} sentences)")
            except Exception as error:
                failures += 1
                print(f"FAILED: {episode['title']}: {error}")
    return 2 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
