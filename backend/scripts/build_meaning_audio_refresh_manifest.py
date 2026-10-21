#!/usr/bin/env python3
"""Build an in-place refresh manifest for Chinese meanings with stale POS labels."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from audit_word_audio import meaning_filename, spoken_meaning


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "听会儿" / "data"
OLD_LABEL_PATTERN = re.compile(
    r"(?i)(^|[；;\uff0c,、\s])\s*"
    r"(n|v|vt|vi|adj|adv|prep|pron|conj|num|art|aux|abbr|int|pl|sing|interj|det|modal)"
    r"\.?\s+"
)


def legacy_spoken_meaning(text: str) -> str:
    text = OLD_LABEL_PATTERN.sub(r"\1", text)
    text = re.sub(r"\s+", " ", text)
    return re.sub(r"([；;，,、])\s+", r"\1", text).strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--books", nargs="+", default=["KaoYan_2", "IELTS_9400"])
    parser.add_argument(
        "--all",
        action="store_true",
        help="Refresh every selected meaning, not only meanings changed by cleanup.",
    )
    parser.add_argument(
        "--reuse-identical-from",
        help="Skip targets already used by this reference book, for example IELTS_9400.",
    )
    parser.add_argument(
        "--output",
        default="backend/reports/audio/chinese-meaning-refresh/refresh_manifest.json",
    )
    args = parser.parse_args()

    reusable_targets: set[str] = set()
    if args.reuse_identical_from:
        reference_words = json.loads(
            (DATA_DIR / f"{args.reuse_identical_from}.json").read_text(encoding="utf-8")
        )
        for word in reference_words:
            raw = str(word.get("meaningZh") or word.get("meaning") or "").strip()
            lookup_text = legacy_spoken_meaning(raw)
            if lookup_text:
                reusable_targets.add(f"meanings/zh/{meaning_filename(lookup_text)}")

    rows: list[dict[str, str]] = []
    seen_targets: set[str] = set()
    for book in args.books:
        words = json.loads((DATA_DIR / f"{book}.json").read_text(encoding="utf-8"))
        for word in words:
            raw = str(word.get("meaningZh") or word.get("meaning") or "").strip()
            old_text = legacy_spoken_meaning(raw)
            new_text = spoken_meaning(raw)
            if not new_text or (not args.all and new_text == old_text):
                continue
            target = f"meanings/zh/{meaning_filename(old_text)}"
            if target in reusable_targets:
                continue
            if target in seen_targets:
                continue
            seen_targets.add(target)
            rows.append(
                {
                    "book": book,
                    "word_id": str(word.get("id", "")),
                    "word": str(word.get("text", "")),
                    "kind": "meaningZh",
                    "language": "zh-CN",
                    "text": new_text,
                    "target_path": target,
                }
            )

    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"refresh={len(rows)} output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
