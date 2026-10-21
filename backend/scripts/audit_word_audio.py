#!/usr/bin/env python3
"""Find word/meaning audio that falls back to AVSpeechSynthesizer."""

from __future__ import annotations

import argparse
import csv
import json
import re
import unicodedata
from pathlib import Path
from typing import Optional


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
    pattern = re.compile(
        r"(?i)(^|[^A-Za-z])\s*(interj|modal|prep|pron|conj|abbr|sing|vbl|adj|adv|num|art|aux|det|prep|vt|vi|pl|int|ad|n|v|a)(?:\.\s*|\s+|(?=[\u3400-\u9fff]))"
    )
    while True:
        cleaned = pattern.sub(r"\1；", text)
        if cleaned == text:
            break
        text = cleaned
    text = re.sub(r"\s*/\s*", "；", text)
    text = re.sub(r"[；;]+", "；", text).strip("；; ")
    text = re.sub(r"\s+", " ", text)
    return re.sub(r"([；;，,、])\s+", r"\1", text).strip()


def meaning_filename(text: str) -> str:
    return f"{safe_name(text)[:160]}_{hash_suffix(text)}.mp3"


def audit(
    books: list[str],
    audio_root: Path = AUDIO_ROOT,
    kinds: Optional[set[str]] = None,
    deduplicate: bool = False,
) -> list[dict[str, object]]:
    missing: list[dict[str, object]] = []
    selected_kinds = kinds or {"word", "meaningZh", "meaningEn"}
    seen_targets: set[str] = set()
    for book in books:
        rows = json.loads((DATA_DIR / f"{book}.json").read_text(encoding="utf-8"))
        for row in rows:
            word = str(row.get("text", "")).strip()
            word_path = Path("words") / ("KaoYan_2" if book == "KaoYan_2" else "") / f"{safe_name(word)}.mp3"
            if "word" in selected_kinds and not (audio_root / word_path).is_file():
                missing.append({
                    "book": book, "word_id": str(row.get("id", "")), "word": word,
                    "kind": "word", "language": "en-US" if book == "KaoYan_2" else "de-DE",
                    "text": word, "target_path": word_path.as_posix(),
                })
            for field, language, folder in (("meaningZh", "zh-CN", "zh"), ("meaningEn", "en-US", "en")):
                if field not in selected_kinds:
                    continue
                raw_text = row.get(field)
                if field == "meaningZh" and not str(raw_text or "").strip():
                    raw_text = row.get("meaning", "")
                text = spoken_meaning(str(raw_text or "").strip())
                if not text:
                    continue
                target_path = Path("meanings") / folder / meaning_filename(text)
                target_key = target_path.as_posix()
                if not (audio_root / target_path).is_file() and (not deduplicate or target_key not in seen_targets):
                    missing.append({
                        "book": book, "word_id": str(row.get("id", "")), "word": word,
                        "kind": field, "language": language, "text": text,
                        "target_path": target_key,
                    })
                    seen_targets.add(target_key)
    return missing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--books", nargs="+", default=list(DEFAULT_BOOKS))
    parser.add_argument("--output-dir", default="backend/reports/audio")
    parser.add_argument("--audio-root", default="听会儿/Audio.bundle")
    parser.add_argument(
        "--kinds",
        nargs="+",
        choices=("word", "meaningZh", "meaningEn"),
        default=["word", "meaningZh", "meaningEn"],
    )
    parser.add_argument("--deduplicate", action="store_true")
    args = parser.parse_args()
    output = ROOT / args.output_dir
    output.mkdir(parents=True, exist_ok=True)
    rows = audit(
        args.books,
        audio_root=ROOT / args.audio_root,
        kinds=set(args.kinds),
        deduplicate=args.deduplicate,
    )
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
