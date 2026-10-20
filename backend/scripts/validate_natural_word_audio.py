#!/usr/bin/env python3
"""Validate v2 natural word audio coverage and basic MP3 integrity."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from learning_audio_catalog import BOOK_LANGUAGES, word_rows_from_book


ROOT = Path(__file__).resolve().parents[2]


def looks_like_mp3(path: Path) -> bool:
    if path.stat().st_size < 512:
        return False
    header = path.read_bytes()[:3]
    return header == b"ID3" or (len(header) >= 2 and header[0] == 0xFF and header[1] & 0xE0 == 0xE0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="backend/generated/learning-audio")
    parser.add_argument("--report", default="backend/reports/audio/v2_validation.json")
    args = parser.parse_args()

    source = ROOT / args.source
    expected = [row for book in BOOK_LANGUAGES for row in word_rows_from_book(book)]
    problems: list[dict[str, str]] = []
    valid = 0
    for row in expected:
        path = source / row["target_path"]
        if not path.is_file():
            problems.append({**row, "problem": "missing"})
        elif not looks_like_mp3(path):
            problems.append({**row, "problem": "invalid_mp3"})
        else:
            valid += 1

    report = {
        "expected": len(expected),
        "valid": valid,
        "problems": len(problems),
        "problem_counts": dict(Counter(row["problem"] for row in problems)),
        "items": problems,
    }
    output = ROOT / args.report
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "items"}, ensure_ascii=False))
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
