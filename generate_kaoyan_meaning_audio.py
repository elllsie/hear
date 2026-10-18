#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import tempfile
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Optional


PROJECT_DIR = Path(__file__).resolve().parent
DATA_PATH = PROJECT_DIR / "听会儿" / "data" / "KaoYan_2.json"
AUDIO_ROOT = PROJECT_DIR / "听会儿" / "Audio.bundle" / "meanings"

FIELDS = {
    "zh": ("meaningZh", "Tingting"),
    "en": ("meaningEn", "Samantha"),
}


def safe_filename(text: str) -> str:
    name = unicodedata.normalize("NFC", text.strip().lower())
    name = re.sub(r"[^\wäöüß-]", "_", name, flags=re.UNICODE)
    name = re.sub(r"_+", "_", name).strip("_")
    return name or "word"


def filename_hash(text: str) -> str:
    value = 2166136261
    key = unicodedata.normalize("NFC", text.strip().lower()).encode("utf-8")
    for byte in key:
        value ^= byte
        value = (value * 16777619) & 0xFFFFFFFF
    return f"{value:08x}"


def safe_meaning_filename(text: str) -> str:
    base = safe_filename(text)[:160]
    return f"{base}_{filename_hash(text)}.mp3"


def spoken_meaning(text: str) -> str:
    cleaned = re.sub(
        r"(?i)(^|[；;，,、\s])\s*(n|v|vt|vi|adj|adv|prep|pron|conj|num|art|aux|abbr|int|pl|sing|interj|det|modal)\.?\s+",
        r"\1",
        text,
    )
    cleaned = re.sub(r"\s+", " ", cleaned)
    cleaned = re.sub(r"([；;，,、])\s+", r"\1", cleaned)
    return cleaned.strip()


def collect_texts(field_name: str) -> dict[str, str]:
    items = json.loads(DATA_PATH.read_text(encoding="utf-8"))
    texts: dict[str, str] = {}
    for item in items:
        text = spoken_meaning(str(item.get(field_name, "")).strip())
        if not text:
            continue
        filename = safe_meaning_filename(text)
        texts.setdefault(filename, text)
    return texts


def run(command: list[str]) -> None:
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def generate_one(text: str, voice: str, audio_path: Path, overwrite: bool) -> str:
    if audio_path.exists() and not overwrite:
        return "skip"

    audio_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp_dir:
        aiff_path = Path(tmp_dir) / "speech.aiff"
        run(["say", "-v", voice, "-o", str(aiff_path), text])
        run([
            "ffmpeg",
            "-y",
            "-i",
            str(aiff_path),
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "48k",
            "-ac",
            "1",
            str(audio_path),
        ])

    return "ok"


def generate_field(language: str, overwrite: bool, limit: Optional[int], workers: int) -> tuple[int, int, int]:
    field_name, voice = FIELDS[language]
    audio_dir = AUDIO_ROOT / language
    texts = collect_texts(field_name)
    total = len(texts) if limit is None else min(limit, len(texts))
    ok = 0
    skipped = 0
    failed = 0

    print(f"\n=== KaoYan_2 {field_name} -> {audio_dir} ===")
    print(f"voice : {voice}")
    print(f"total : {total}")

    selected = list(sorted(texts.items()))
    if limit is not None:
        selected = selected[:limit]

    with ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
        futures = {
            executor.submit(generate_one, text, voice, audio_dir / filename, overwrite): filename
            for filename, text in selected
        }
        for index, future in enumerate(as_completed(futures), start=1):
            filename = futures[future]
            try:
                result = future.result()
                if result == "skip":
                    skipped += 1
                else:
                    ok += 1
            except Exception as error:
                failed += 1
                print(f"fail  {filename}: {error}")

            if index % 50 == 0 or index == total:
                print(f"progress {language}: {index}/{total} ok={ok} skipped={skipped} failed={failed}")

    return ok, skipped, failed


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate cleaned KaoYan meaning audio with macOS say.")
    parser.add_argument("--language", choices=["zh", "en", "all"], default="all")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()

    languages = ["zh", "en"] if args.language == "all" else [args.language]
    failed = 0
    for language in languages:
        _, _, field_failed = generate_field(language, args.overwrite, args.limit, args.workers)
        failed += field_failed

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
