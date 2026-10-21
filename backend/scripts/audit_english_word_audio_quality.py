#!/usr/bin/env python3
"""Find English word MP3s with unusually compressed or cut speech."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import numpy as np
import soundfile as sf

from learning_audio_catalog import word_rows_from_book


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / "backend" / "generated" / "learning-audio"
DEFAULT_REPORT = ROOT / "backend" / "reports" / "audio" / "english-word-quality-audit.json"
ENGLISH_BOOKS = ("KaoYan_2", "IELTS_9400")


def analyze(path: Path) -> dict[str, float | str] | None:
    try:
        audio, sample_rate = sf.read(path)
    except Exception as error:
        return {"problem": "decode_error", "error": str(error)}
    if audio.ndim > 1:
        audio = np.mean(audio, axis=1)
    amplitude = np.abs(audio)
    if not len(amplitude) or float(np.max(amplitude)) == 0:
        return {"problem": "silent"}
    threshold = max(0.003, float(np.max(amplitude)) * 0.03)
    active = np.flatnonzero(amplitude > threshold)
    if not len(active):
        return {"problem": "silent"}
    active_seconds = float((active[-1] - active[0] + 1) / sample_rate)
    trailing_seconds = float((len(amplitude) - 1 - active[-1]) / sample_rate)
    return {
        "active_seconds": round(active_seconds, 4),
        "trailing_seconds": round(trailing_seconds, 4),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default=str(DEFAULT_SOURCE.relative_to(ROOT)))
    parser.add_argument("--report", default=str(DEFAULT_REPORT.relative_to(ROOT)))
    parser.add_argument("--minimum-trailing-seconds", type=float, default=0.08)
    parser.add_argument("--minimum-seconds-per-letter", type=float, default=0.05)
    parser.add_argument(
        "--include-word",
        action="append",
        default=[],
        help="Include a user-reported word even when waveform thresholds pass.",
    )
    args = parser.parse_args()

    source = ROOT / args.source
    forced_words = {word.strip().casefold() for word in args.include_word if word.strip()}
    candidates: list[dict[str, object]] = []
    checked = 0

    for book in ENGLISH_BOOKS:
        for row in word_rows_from_book(book):
            path = source / row["target_path"]
            checked += 1
            result = analyze(path) if path.is_file() else {"problem": "missing"}
            reasons: list[str] = []
            if result is None:
                continue
            if "problem" in result:
                reasons.append(str(result["problem"]))
            else:
                letters = max(1, len(re.sub(r"[^a-z]", "", row["word"].casefold())))
                seconds_per_letter = float(result["active_seconds"]) / letters
                result["seconds_per_letter"] = round(seconds_per_letter, 4)
                if float(result["trailing_seconds"]) < args.minimum_trailing_seconds:
                    reasons.append("possible_cut_tail")
                if letters >= 5 and seconds_per_letter < args.minimum_seconds_per_letter:
                    reasons.append("compressed_speech")
            if row["word"].casefold() in forced_words:
                reasons.append("user_reported")
            if reasons:
                candidates.append({**row, **result, "reasons": sorted(set(reasons))})

    report = {
        "checked": checked,
        "candidates": len(candidates),
        "thresholds": {
            "minimum_trailing_seconds": args.minimum_trailing_seconds,
            "minimum_seconds_per_letter": args.minimum_seconds_per_letter,
        },
        "items": candidates,
    }
    output = ROOT / args.report
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "items"}, ensure_ascii=False))
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
