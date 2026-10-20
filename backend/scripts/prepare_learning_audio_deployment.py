#!/usr/bin/env python3
"""Create a lower-bitrate deployment copy while preserving v2 object keys."""

from __future__ import annotations

import argparse
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--language", choices=("de-DE", "en-US"), required=True)
    parser.add_argument("--source", default="backend/generated/learning-audio")
    parser.add_argument("--output", default="backend/generated/learning-audio-deploy")
    parser.add_argument("--bitrate", type=int, default=32)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    source_root = ROOT / args.source
    output_root = ROOT / args.output
    language_root = source_root / "v2" / "words" / args.language
    files = sorted(language_root.rglob("*.mp3"))
    if not files:
        raise RuntimeError(f"no MP3 files under {language_root}")

    def convert(source: Path) -> tuple[str, str]:
        target = output_root / source.relative_to(source_root)
        if target.is_file() and target.stat().st_size >= 512 and not args.overwrite:
            return "skipped", str(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        staged = target.with_suffix(".mp3.tmp")
        try:
            subprocess.run(
                ["lame", "--silent", "-b", str(args.bitrate), str(source), str(staged)],
                check=True,
            )
            if not staged.is_file() or staged.stat().st_size < 512:
                raise RuntimeError("invalid encoded file")
            staged.replace(target)
            return "completed", str(target)
        finally:
            staged.unlink(missing_ok=True)

    completed = skipped = failed = 0
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        futures = [executor.submit(convert, path) for path in files]
        for index, future in enumerate(as_completed(futures), 1):
            try:
                status, _ = future.result()
                if status == "completed":
                    completed += 1
                else:
                    skipped += 1
            except Exception as error:
                failed += 1
                print(f"failed: {error}", flush=True)
            if index % 250 == 0 or index == len(files):
                print(
                    f"progress {index}/{len(files)} completed={completed} "
                    f"skipped={skipped} failed={failed}",
                    flush=True,
                )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
