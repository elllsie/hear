#!/usr/bin/env python3
"""
Generate German word pronunciation MP3 files with gTTS.

Examples:
  python3 generate_word_audio.py A1
  python3 generate_word_audio.py A2 B1
  python3 generate_word_audio.py '听会儿/data/*.json'

Output:
  听会儿/audio/<json-name>/<safe-word-name>.mp3
"""

import argparse
import glob
import json
import re
import sys
import unicodedata
from pathlib import Path

try:
    from gtts import gTTS
except ImportError:
    print("Missing dependency: gTTS")
    print("Install it with: python3 -m pip install gTTS")
    sys.exit(1)


PROJECT_DIR = Path(__file__).resolve().parent
APP_DIR = PROJECT_DIR / "听会儿"
DATA_DIR = APP_DIR / "data"
DEFAULT_AUDIO_DIR = APP_DIR / "audio"


def find_json_files(pattern: str) -> list[Path]:
    candidates: list[str] = []
    raw_path = Path(pattern)

    candidates.append(pattern)
    if raw_path.suffix != ".json":
        candidates.append(f"{pattern}.json")
    candidates.append(str(DATA_DIR / pattern))
    if raw_path.suffix != ".json":
        candidates.append(str(DATA_DIR / f"{pattern}.json"))

    matches: list[Path] = []
    for candidate in candidates:
        for match in glob.glob(candidate):
            path = Path(match)
            if path.is_file() and path.suffix == ".json" and path not in matches:
                matches.append(path)

    return matches


def safe_filename(text: str) -> str:
    name = unicodedata.normalize("NFC", text.strip().lower())
    name = re.sub(r"[^\wäöüß-]", "_", name, flags=re.UNICODE)
    name = re.sub(r"_+", "_", name).strip("_")
    return name or "word"


def load_words(json_path: Path) -> list[dict]:
    with json_path.open("r", encoding="utf-8") as file:
        data = json.load(file)

    if not isinstance(data, list):
        raise ValueError(f"{json_path} must contain a JSON array")

    return data


def generate_for_file(json_path: Path, audio_root: Path, lang: str, slow: bool, overwrite: bool) -> None:
    book_name = json_path.stem
    output_dir = audio_root / book_name
    output_dir.mkdir(parents=True, exist_ok=True)

    words = load_words(json_path)
    success = 0
    skipped = 0
    failed = 0

    print(f"\n=== {json_path} -> {output_dir} ===")

    for item in words:
        text = str(item.get("text", "")).strip()
        if not text:
            continue

        filename = f"{safe_filename(text)}.mp3"
        audio_path = output_dir / filename

        if audio_path.exists() and not overwrite:
            print(f"skip  {filename}")
            skipped += 1
            continue

        try:
            gTTS(text=text, lang=lang, slow=slow).save(str(audio_path))
            print(f"ok    {filename}")
            success += 1
        except Exception as error:
            print(f"fail  {filename}: {error}")
            failed += 1

    print("-" * 40)
    print(f"success: {success}")
    print(f"skipped: {skipped}")
    print(f"failed : {failed}")
    print(f"output : {output_dir}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate word pronunciation MP3 files for the app.")
    parser.add_argument("json", nargs="+", help="JSON file, book name, or glob pattern")
    parser.add_argument("--audio-root", default=str(DEFAULT_AUDIO_DIR), help="Output audio root directory")
    parser.add_argument("--lang", default="de", help="gTTS language code")
    parser.add_argument("--slow", action="store_true", help="Generate slower pronunciation")
    parser.add_argument("--overwrite", action="store_true", help="Regenerate existing MP3 files")
    args = parser.parse_args()

    json_files: list[Path] = []
    for pattern in args.json:
        matches = find_json_files(pattern)
        if not matches:
            print(f"not found: {pattern}")
        json_files.extend(path for path in matches if path not in json_files)

    if not json_files:
        print("No JSON files found.")
        return 1

    audio_root = Path(args.audio_root).expanduser()
    if not audio_root.is_absolute():
        audio_root = PROJECT_DIR / audio_root

    for json_path in json_files:
        generate_for_file(json_path, audio_root, args.lang, args.slow, args.overwrite)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
