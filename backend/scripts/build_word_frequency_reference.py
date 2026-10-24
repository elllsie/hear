#!/usr/bin/env python3
"""Bundle wordfreq's English frequency reference for offline word-book selection.

Requires wordfreq==3.1.1. Frequencies are a difficulty proxy, not AI assessments.
wordfreq data is CC BY-SA 4.0; see bundled attribution.
"""
import json
from pathlib import Path
from wordfreq import zipf_frequency

ROOT = Path(__file__).resolve().parents[2]
words = set()
for name in ("KaoYan_2", "IELTS_9400"):
    words.update(row["text"].strip().lower() for row in json.loads(
        (ROOT / f"听会儿/data/{name}.json").read_text()))
scores = {word: round((8 - zipf_frequency(word, "en")) * 1000) for word in sorted(words)}
target = ROOT / "听会儿/data/EnglishWordFrequency.json"
target.write_text(json.dumps({"source": "wordfreq 3.1.1; English Zipf frequency",
    "license": "CC BY-SA 4.0", "scores": scores}, ensure_ascii=False, indent=2) + "\n")
print(f"Bundled frequency reference for {len(scores)} words")
