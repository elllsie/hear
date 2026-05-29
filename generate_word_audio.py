#!/usr/bin/env python3
"""
Generate German word pronunciation MP3 files with gTTS.

Examples:
  python3 generate_word_audio.py A1
  python3 generate_word_audio.py A2 B1
  python3 generate_word_audio.py '听会儿/data/*.json'

Output:
  听会儿/audio/words/<safe-word-name>.mp3
  听会儿/audio/meanings/zh/<safe-meaning-name>.mp3
  听会儿/audio/meanings/en/<safe-meaning-name>.mp3
"""

import argparse
import glob
import json
import re
import shutil
import sys
import unicodedata
from pathlib import Path
from typing import Optional

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
DEFAULT_SHARED_AUDIO_DIR = DEFAULT_AUDIO_DIR / "words"
DEFAULT_MEANING_AUDIO_DIRS = {
    "meaningZh": DEFAULT_AUDIO_DIR / "meanings" / "zh",
    "meaningEn": DEFAULT_AUDIO_DIR / "meanings" / "en",
}
DEFAULT_MEANING_LANGS = {
    "meaningZh": "zh-CN",
    "meaningEn": "en",
}


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


def load_words(json_path: Path) -> list[dict]:
    with json_path.open("r", encoding="utf-8") as file:
        data = json.load(file)

    if not isinstance(data, list):
        raise ValueError(f"{json_path} must contain a JSON array")

    return data


def word_key(text: str) -> str:
    return unicodedata.normalize("NFC", text.strip().lower())


def collect_unique_words(json_paths: list[Path]) -> tuple[dict[str, str], int, int]:
    words_by_filename: dict[str, str] = {}
    seen_words: set[str] = set()
    duplicate_count = 0
    collision_count = 0

    for json_path in json_paths:
        for item in load_words(json_path):
            text = str(item.get("text", "")).strip()
            if not text:
                continue

            key = word_key(text)
            if key in seen_words:
                duplicate_count += 1
                continue
            seen_words.add(key)

            filename = f"{safe_filename(text)}.mp3"
            existing = words_by_filename.get(filename)
            if existing is not None and word_key(existing) != key:
                collision_count += 1
                print(f"warn  filename collision: {existing!r} and {text!r} -> {filename}")
                continue

            words_by_filename[filename] = text

    return words_by_filename, duplicate_count, collision_count


def collect_unique_field_texts(json_paths: list[Path], field_name: str) -> tuple[dict[str, str], int, int]:
    texts_by_filename: dict[str, str] = {}
    seen_texts: set[str] = set()
    duplicate_count = 0
    collision_count = 0

    for json_path in json_paths:
        for item in load_words(json_path):
            text = str(item.get(field_name, "")).strip()
            if not text:
                continue

            key = word_key(text)
            if key in seen_texts:
                duplicate_count += 1
                continue
            seen_texts.add(key)

            filename = safe_meaning_filename(text)
            existing = texts_by_filename.get(filename)
            if existing is not None and word_key(existing) != key:
                collision_count += 1
                print(f"warn  filename collision: {existing!r} and {text!r} -> {filename}")
                continue

            texts_by_filename[filename] = text

    return texts_by_filename, duplicate_count, collision_count


def find_existing_audio(filename: str, output_dir: Path, legacy_audio_root: Optional[Path]) -> Optional[Path]:
    if legacy_audio_root is None or not legacy_audio_root.exists():
        return None

    for path in sorted(legacy_audio_root.rglob(filename)):
        if path.is_file() and output_dir not in path.parents:
            return path

    return None


def generate_shared_audio(
    json_paths: list[Path],
    output_dir: Path,
    legacy_audio_root: Optional[Path],
    lang: str,
    slow: bool,
    overwrite: bool,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    words_by_filename, duplicate_count, collision_count = collect_unique_words(json_paths)
    success = 0
    reused = 0
    skipped = 0
    failed = 0

    print(f"\n=== shared word audio -> {output_dir} ===")
    print("books : " + ", ".join(path.stem for path in json_paths))
    print(f"unique: {len(words_by_filename)}")
    print(f"dupes : {duplicate_count}")
    if collision_count:
        print(f"name collisions skipped: {collision_count}")

    for filename, text in sorted(words_by_filename.items()):
        audio_path = output_dir / filename

        if audio_path.exists() and not overwrite:
            print(f"skip  {filename}")
            skipped += 1
            continue

        existing_audio = find_existing_audio(filename, output_dir, legacy_audio_root)
        if existing_audio is not None and not overwrite:
            try:
                shutil.copy2(existing_audio, audio_path)
                print(f"reuse {filename} <- {existing_audio.relative_to(PROJECT_DIR)}")
                reused += 1
                continue
            except Exception as error:
                print(f"warn  could not reuse {filename}: {error}")

        try:
            gTTS(text=text, lang=lang, slow=slow).save(str(audio_path))
            print(f"ok    {filename}")
            success += 1
        except Exception as error:
            print(f"fail  {filename}: {error}")
            failed += 1

    print("-" * 40)
    print(f"success: {success}")
    print(f"reused : {reused}")
    print(f"skipped: {skipped}")
    print(f"failed : {failed}")
    print(f"output : {output_dir}")


def generate_field_audio(
    json_paths: list[Path],
    field_name: str,
    output_dir: Path,
    lang: str,
    slow: bool,
    overwrite: bool,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    texts_by_filename, duplicate_count, collision_count = collect_unique_field_texts(json_paths, field_name)
    success = 0
    skipped = 0
    failed = 0

    print(f"\n=== {field_name} audio -> {output_dir} ===")
    print("books : " + ", ".join(path.stem for path in json_paths))
    print(f"unique: {len(texts_by_filename)}")
    print(f"dupes : {duplicate_count}")
    if collision_count:
        print(f"name collisions skipped: {collision_count}")

    for filename, text in sorted(texts_by_filename.items()):
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
    parser.add_argument("--audio-dir", default=str(DEFAULT_SHARED_AUDIO_DIR), help="Shared output directory")
    parser.add_argument("--audio-root", help=argparse.SUPPRESS)
    parser.add_argument("--lang", default="de", help="gTTS language code")
    parser.add_argument("--slow", action="store_true", help="Generate slower pronunciation")
    parser.add_argument("--overwrite", action="store_true", help="Regenerate existing MP3 files")
    parser.add_argument("--no-reuse-existing", action="store_true", help="Do not copy matching MP3 files from old audio folders")
    parser.add_argument("--include-meanings", action="store_true", help="Also generate meaningZh and meaningEn MP3 files")
    parser.add_argument("--only-meanings", action="store_true", help="Generate only meaningZh and meaningEn MP3 files")
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

    if not args.only_meanings:
        audio_dir_arg = args.audio_root or args.audio_dir
        audio_dir = Path(audio_dir_arg).expanduser()
        if not audio_dir.is_absolute():
            audio_dir = PROJECT_DIR / audio_dir

        legacy_audio_root = None if args.no_reuse_existing else DEFAULT_AUDIO_DIR
        generate_shared_audio(json_files, audio_dir, legacy_audio_root, args.lang, args.slow, args.overwrite)

    if args.include_meanings or args.only_meanings:
        for field_name, output_dir in DEFAULT_MEANING_AUDIO_DIRS.items():
            generate_field_audio(
                json_files,
                field_name,
                output_dir,
                DEFAULT_MEANING_LANGS[field_name],
                args.slow,
                args.overwrite,
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
