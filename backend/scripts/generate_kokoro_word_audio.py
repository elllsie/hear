#!/usr/bin/env python3
"""Generate versioned vocabulary MP3 files with local Kokoro models."""

from __future__ import annotations

import argparse
import gc
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import soundfile as sf
import torch

ROOT = Path(__file__).resolve().parents[2]
KOKOROTTS_RUNTIME = ROOT / "backend" / ".local" / "kokorotts-runtime"
if KOKOROTTS_RUNTIME.is_dir():
    sys.path.insert(0, str(KOKOROTTS_RUNTIME))
    from kokorotts.model import KModel
    from kokorotts.pipeline import KPipeline
else:
    from kokoro import KModel, KPipeline

from learning_audio_catalog import BOOK_LANGUAGES, word_rows_from_book


DEFAULT_MODEL_ROOT = ROOT / "backend" / ".local" / "kokoro-models"
DEFAULT_OUTPUT_ROOT = ROOT / "backend" / "generated" / "learning-audio"
DEFAULT_FAILURE_REPORT = ROOT / "backend" / "reports" / "audio" / "kokoro_failures.json"

MODEL_SETTINGS = {
    "en-US": {
        "language": "a",
        "model": "english/kokoro-v1_0.pth",
        "voice": "english/voices/af_heart.pt",
        "voice_name": "Kokoro American English / af_heart",
    },
    "de-DE": {
        "language": "de",
        "model": "german/kikiri_german_victoria_ep10.pth",
        "voice": "german/voices/victoria.pt",
        "voice_name": "Kokoro German / Victoria",
    },
}


class KokoroSynthesizer:
    def __init__(self, language: str, model_root: Path) -> None:
        settings = MODEL_SETTINGS[language]
        config_path = model_root / "config.json"
        model_path = model_root / settings["model"]
        voice_path = model_root / settings["voice"]
        for path in (config_path, model_path, voice_path):
            if not path.is_file():
                raise FileNotFoundError(f"missing Kokoro file: {path}")

        self.language = language
        self.voice_name = settings["voice_name"]
        self.model = KModel(config=config_path, model=model_path).to("cpu").eval()
        self.voice = torch.load(voice_path, map_location="cpu", weights_only=True)
        self.pipeline = KPipeline(
            lang_code=settings["language"],
            repo_id="local",
            model=self.model,
            device="cpu",
        )

    def render_mp3(self, text: str, output: Path, bitrate: int, speed: float = 1.0) -> None:
        chunks = [
            result.audio.detach().cpu()
            for result in self.pipeline(text, voice=self.voice, speed=speed)
            if result.audio is not None and result.audio.numel() > 0
        ]
        if not chunks:
            raise RuntimeError("Kokoro returned no audio")
        audio = torch.cat(chunks).numpy()
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="kokoro-word-") as temp_dir:
            wav_path = Path(temp_dir) / "speech.wav"
            mp3_path = Path(temp_dir) / "speech.mp3"
            sf.write(wav_path, audio, 24_000, subtype="PCM_16")
            subprocess.run(
                ["lame", "--silent", "-b", str(bitrate), str(wav_path), str(mp3_path)],
                check=True,
            )
            if not mp3_path.is_file() or mp3_path.stat().st_size < 512:
                raise RuntimeError("LAME returned an invalid MP3")
            staged = output.with_suffix(output.suffix + ".tmp")
            shutil.copyfile(mp3_path, staged)
            os.replace(staged, output)


def selected_rows(books: list[str], offset: int, limit: int | None) -> list[dict[str, str]]:
    rows = [row for book in books for row in word_rows_from_book(book)]
    rows = rows[max(0, offset):]
    if limit is not None:
        rows = rows[:max(0, limit)]
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--book", choices=tuple(BOOK_LANGUAGES))
    selection.add_argument("--all-word-books", action="store_true")
    selection.add_argument("--manifest", help="Generate only rows from a JSON manifest/report.")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_ROOT.relative_to(ROOT)))
    parser.add_argument("--model-dir", default=str(DEFAULT_MODEL_ROOT.relative_to(ROOT)))
    parser.add_argument("--failure-report", default=str(DEFAULT_FAILURE_REPORT.relative_to(ROOT)))
    parser.add_argument("--bitrate", type=int, default=48, choices=(32, 40, 48, 56, 64, 80, 96))
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument(
        "--append-period",
        action="store_true",
        help="Add sentence-final punctuation to isolated words for a complete release and tail.",
    )
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--progress-every", type=int, default=25)
    args = parser.parse_args()

    if args.manifest:
        manifest = json.loads((ROOT / args.manifest).read_text(encoding="utf-8"))
        rows = manifest.get("items") if isinstance(manifest, dict) else manifest
        if not isinstance(rows, list):
            raise RuntimeError("manifest must be a JSON array or an object containing an items array")
        rows = rows[max(0, args.offset):]
        if args.limit is not None:
            rows = rows[:max(0, args.limit)]
    else:
        books = list(BOOK_LANGUAGES) if args.all_word_books else [args.book]
        rows = selected_rows(books, args.offset, args.limit)
    output_root = ROOT / args.output_dir
    model_root = ROOT / args.model_dir
    report_path = ROOT / args.failure_report
    completed = skipped = 0
    failures: list[dict[str, str]] = []
    started = time.monotonic()

    for language in dict.fromkeys(str(row["language"]) for row in rows):
        language_rows = [row for row in rows if row["language"] == language]
        engine = KokoroSynthesizer(language, model_root)
        print(
            f"loaded {engine.voice_name}; language={language}; rows={len(language_rows)}",
            flush=True,
        )
        for row in language_rows:
            output = output_root / row["target_path"]
            if output.is_file() and output.stat().st_size >= 512 and not args.overwrite:
                skipped += 1
            else:
                error: Exception | None = None
                for attempt in range(1, max(1, args.retries) + 1):
                    try:
                        speech_text = str(row["text"])
                        if args.append_period and speech_text and speech_text[-1] not in ".!?":
                            speech_text += "."
                        engine.render_mp3(speech_text, output, args.bitrate, speed=args.speed)
                        completed += 1
                        error = None
                        break
                    except Exception as caught:
                        error = caught
                        output.unlink(missing_ok=True)
                        if attempt < max(1, args.retries):
                            time.sleep(0.25)
                if error is not None:
                    failure = {
                        "book": row["book"],
                        "word_id": row["word_id"],
                        "word": row["word"],
                        "language": language,
                        "target_path": row["target_path"],
                        "error": str(error),
                    }
                    failures.append(failure)
                    print(f"failed {row['book']} {row['word']}: {error}", flush=True)

            processed = completed + skipped + len(failures)
            if processed % max(1, args.progress_every) == 0 or processed == len(rows):
                elapsed = time.monotonic() - started
                rate = processed / elapsed if elapsed else 0.0
                print(
                    f"progress {processed}/{len(rows)} completed={completed} "
                    f"skipped={skipped} failed={len(failures)} rate={rate:.2f}/s",
                    flush=True,
                )
        del engine
        gc.collect()

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(
            {
                "selected": len(rows),
                "completed": completed,
                "skipped": skipped,
                "failed": len(failures),
                "items": failures,
            },
            ensure_ascii=False,
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
