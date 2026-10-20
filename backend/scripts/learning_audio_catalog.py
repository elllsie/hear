#!/usr/bin/env python3
"""Canonical language and storage layout for bundled vocabulary books."""

from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
AUDIO_VERSION = "v2"

BOOK_LANGUAGES = {
    "12yue": "de-DE",
    "A1": "de-DE",
    "A2": "de-DE",
    "B1": "de-DE",
    "KaoYan_2": "en-US",
    "IELTS_9400": "en-US",
}


def language_for_book(book: str) -> str:
    try:
        return BOOK_LANGUAGES[book]
    except KeyError as error:
        raise ValueError(f"unsupported vocabulary book: {book}") from error


def word_audio_path(book: str, filename: str) -> Path:
    language = language_for_book(book)
    return Path(AUDIO_VERSION) / "words" / language / book / filename


def safe_name(text: str) -> str:
    value = unicodedata.normalize("NFC", text.strip().lower())
    value = re.sub(r"[^\wäöüß-]", "_", value, flags=re.UNICODE)
    return re.sub(r"_+", "_", value).strip("_") or "word"


def word_rows_from_book(book: str) -> list[dict[str, str]]:
    data_path = ROOT / "听会儿" / "data" / f"{book}.json"
    data = json.loads(data_path.read_text(encoding="utf-8"))
    language = language_for_book(book)
    rows: list[dict[str, str]] = []
    for row in data:
        text = str(row.get("text", "")).strip()
        if not text:
            continue
        word_id = str(row.get("id", "")).strip()
        filename = f"{safe_name(text)}_{safe_name(word_id)}.mp3"
        rows.append({
            "book": book,
            "word_id": word_id,
            "word": text,
            "kind": "word",
            "language": language,
            "text": text,
            "target_path": word_audio_path(book, filename).as_posix(),
        })
    return rows
