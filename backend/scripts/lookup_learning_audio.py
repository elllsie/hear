#!/usr/bin/env python3
"""Print local and Supabase audio paths for one vocabulary entry."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from audit_word_audio import meaning_filename, spoken_meaning
from build_meaning_audio_refresh_manifest import legacy_spoken_meaning
from learning_audio_key import safe_component, storage_key


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "听会儿" / "data"
LOCAL_AUDIO_ROOT = ROOT / "backend" / "generated" / "learning-audio"
PUBLIC_BASE = (
    "https://frljmdtogeyajpbwjavv.supabase.co/"
    "storage/v1/object/public/learning-audio"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--book", required=True, help="For example KaoYan_2 or IELTS_9400")
    parser.add_argument("--word", required=True)
    args = parser.parse_args()

    rows = json.loads((DATA_DIR / f"{args.book}.json").read_text(encoding="utf-8"))
    matches = [row for row in rows if str(row.get("text", "")).casefold() == args.word.casefold()]
    if not matches:
        raise SystemExit(f"word not found: {args.word} in {args.book}")

    for row in matches:
        word = str(row["text"])
        word_id = str(row["id"])
        raw_meaning = str(row.get("meaningZh") or row.get("meaning") or "").strip()
        lookup_meaning = legacy_spoken_meaning(raw_meaning)
        spoken = spoken_meaning(raw_meaning)
        word_relative = f"v2/words/en-US/{args.book}/{safe_component(word)}_{safe_component(word_id)}.mp3"
        meaning_relative = f"meanings/zh/{meaning_filename(lookup_meaning)}"

        print(f"word: {word}")
        print(f"id: {word_id}")
        print(f"raw meaning: {raw_meaning}")
        print(f"spoken meaning: {spoken}")
        print(f"word local: {LOCAL_AUDIO_ROOT / word_relative}")
        print(f"word storage: {storage_key(word_relative)}")
        print(f"word URL: {PUBLIC_BASE}/{storage_key(word_relative)}")
        print(f"meaning local: {LOCAL_AUDIO_ROOT / meaning_relative}")
        print(f"meaning storage: {storage_key(meaning_relative)}")
        print(f"meaning URL: {PUBLIC_BASE}/{storage_key(meaning_relative)}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
