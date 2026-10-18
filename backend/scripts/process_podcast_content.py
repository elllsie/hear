#!/usr/bin/env python3
"""One command entry point for reusable Podcast metadata/transcript processing."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


BACKEND_DIR = Path(__file__).resolve().parents[1]
CONFIG = BACKEND_DIR / "config" / "rss_sources.json"
SCRIPTS = BACKEND_DIR / "scripts"


def run(arguments: list[str]) -> None:
    print("+", " ".join(arguments), flush=True)
    subprocess.run(arguments, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync RSS and process transcripts using source adapters")
    parser.add_argument("--source", help="Process one source key; default is all configured sources")
    parser.add_argument("--skip-rss", action="store_true")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--skip-ai", action="store_true")
    args = parser.parse_args()

    sources: list[dict[str, Any]] = json.loads(CONFIG.read_text(encoding="utf-8"))
    if args.source:
        sources = [source for source in sources if source["key"] == args.source]
        if not sources:
            print(f"ERROR: unknown source {args.source}", file=sys.stderr)
            return 1

    python = sys.executable
    if not args.skip_rss:
        for source in sources:
            run([python, str(SCRIPTS / "sync_podcasts.py"), "--source", source["key"], "--limit", str(args.limit)])

    for source in sources:
        common = ["--podcast-name", source["name"], "--limit", str(args.limit)]
        run([python, str(SCRIPTS / "probe_podcast_capabilities.py"), *common])
        mirror = source.get("audio_mirror") or {}
        if mirror.get("enabled"):
            mirror_command = [
                python,
                str(SCRIPTS / "mirror_podcast_audio.py"),
                *common,
                "--bucket",
                mirror.get("bucket", "podcast-audio"),
            ]
            if mirror.get("download_strategy") == "single":
                mirror_command.append("--single-stream")
            run(mirror_command)
        run([python, str(SCRIPTS / "import_timed_transcripts.py"), *common])
        transcription = source.get("transcript") or {}
        transcription_command = [python, str(SCRIPTS / "transcribe_podcasts.py"), *common]
        if transcription.get("model"):
            transcription_command.extend(["--model", transcription["model"]])
        if transcription.get("language"):
            transcription_command.extend(["--language", transcription["language"]])
        run(transcription_command)
        run([python, str(SCRIPTS / "translate_podcast_sentences.py"), *common])
        if not args.skip_ai and (source.get("ai") or {}).get("enabled", True):
            run([python, str(SCRIPTS / "generate_podcast_ai_insights.py"), *common])
        run([python, str(SCRIPTS / "validate_podcast_episodes.py"), *common])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
