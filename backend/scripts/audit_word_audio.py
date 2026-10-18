#!/usr/bin/env python3
"""Find word/meaning audio that falls back to AVSpeechSynthesizer."""

from __future__ import annotations

import argparse
import csv
import json
import re
import unicodedata
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "听会儿" / "data"
AUDIO_ROOT = ROOT / "听会儿" / "Audio.bundle"
DEFAULT_BOOKS = ("A1", "A2", "B1", "KaoYan_2")


def safe_name(text: str) -> str:
    value = unicodedata.normalize("NFC", text.strip().lower())
    value = re.sub(r"[^\wäöüß-]", "_", value, flags=re.UNICODE)
    return re.sub(r"_+", "_", value).strip("_") or "word"


def hash_suffix(text: str) -> str:
    value = 2166136261
    normalized = unicodedata.normalize("NFC", text.strip().lower()).encode("utf-8")
    for byte in normalized:
        value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
    return f"{value:08x}"


def spoken_meaning(text: str) -> str:
    text = re.sub(
        r"(?i)(^|[；;\uff0c,、\s])\s*(n|v|vt|vi|adj|adv|prep|pron|conj|num|art|aux|abbr|int|pl|sing|interj|det|modal)\.?\s+",
        r"\1",
        text,
    )
    text = re.sub(r"\s+", " ", text)
    return re.sub(r"([；;，,、])\s+", r"\1", text).strip()


def meaning_filename(text: str) -> str:
    return f"{safe_name(text)[:160]}_{hash_suffix(text)}.mp3"


def audit(books: list[str]) -> list[dict[str, object]]:
    missing: list[dict[str, object]] = []
    for book in books:
        rows = json.loads((DATA_DIR / f"{book}.json").read_text(encoding="utf-8"))
        for row in rows:
            word = str(row.get("text", "")).strip()
            word_path = Path("words") / ("KaoYan_2" if book == "KaoYan_2" else "") / f"{safe_name(word)}.mp3"
            if not (AUDIO_ROOT / word_path).is_file():
                missing.append({
                    "book": book, "word_id": str(row.get("id", "")), "word": word,
                    "kind": "word", "language": "en-US" if book == "KaoYan_2" else "de-DE",
                    "text": word, "target_path": word_path.as_posix(),
                })
            for field, language, folder in (("meaningZh", "zh-CN", "zh"), ("meaningEn", "en-US", "en")):
                text = spoken_meaning(str(row.get(field, "")).strip())
                if not text:
                    continue
                target_path = Path("meanings") / folder / meaning_filename(text)
                if not (AUDIO_ROOT / target_path).is_file():
                    missing.append({
                        "book": book, "word_id": str(row.get("id", "")), "word": word,
                        "kind": field, "language": language, "text": text,
                        "target_path": target_path.as_posix(),
                    })
    return missing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--books", nargs="+", default=list(DEFAULT_BOOKS))
    parser.add_argument("--output-dir", default="backend/reports/audio")
    args = parser.parse_args()
    output = ROOT / args.output_dir
    output.mkdir(parents=True, exist_ok=True)
    rows = audit(args.books)
    (output / "system_tts_fallbacks.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    with (output / "system_tts_fallbacks.csv").open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=["book", "word_id", "word", "kind", "language", "text", "target_path"])
        writer.writeheader()
        writer.writerows(rows)
    counts: dict[str, int] = {}
    for row in rows:
        key = f"{row['book']}:{row['kind']}"
        counts[key] = counts.get(key, 0) + 1
    print(json.dumps({"total": len(rows), "counts": counts}, ensure_ascii=False, indent=2))
    print(output / "system_tts_fallbacks.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
