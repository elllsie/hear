#!/usr/bin/env python3
"""Generate consistent word-audio replacements from an audit manifest."""

from __future__ import annotations

import argparse
import asyncio
import html
import json
import os
import re
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Optional

import httpx
from dotenv import load_dotenv


ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "backend"
DEFAULT_VOICES = {
    "de-DE": "de-DE-KatjaNeural",
    "en-US": "en-US-JennyNeural",
    "zh-CN": "zh-CN-XiaoxiaoNeural",
}
EDGE_VOICES = {
    "de-DE": "de-DE-KatjaNeural",
    "en-US": "en-US-AriaNeural",
    "zh-CN": "zh-CN-XiaoxiaoNeural",
}
GTTS_LANGUAGES = {
    "de-DE": ("de", "de"),
    "en-US": ("en", "com"),
    "zh-CN": ("zh-CN", "com"),
}


def safe_name(text: str) -> str:
    value = unicodedata.normalize("NFC", text.strip().lower())
    value = re.sub(r"[^\wäöüß-]", "_", value, flags=re.UNICODE)
    return re.sub(r"_+", "_", value).strip("_") or "word"


def word_rows_from_book(book: str) -> list[dict[str, str]]:
    data_path = ROOT / "听会儿" / "data" / f"{book}.json"
    data = json.loads(data_path.read_text(encoding="utf-8"))
    language = "en-US" if book == "KaoYan_2" else "de-DE"
    subdirectory = Path("words") / ("KaoYan_2" if book == "KaoYan_2" else "")
    return [
        {
            "book": book,
            "word_id": str(row.get("id", "")),
            "word": str(row.get("text", "")).strip(),
            "kind": "word",
            "language": language,
            "text": str(row.get("text", "")).strip(),
            "target_path": (subdirectory / f"{safe_name(str(row.get('text', '')))}.mp3").as_posix(),
        }
        for row in data
        if str(row.get("text", "")).strip()
    ]


def required_env(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value:
        raise RuntimeError(f"missing {name}")
    return value


def synthesize_azure(text: str, language: str, output: Path) -> None:
    region = required_env("AZURE_SPEECH_REGION")
    key = required_env("AZURE_SPEECH_KEY")
    voice = os.getenv(f"AZURE_SPEECH_VOICE_{language.replace('-', '_')}") or DEFAULT_VOICES[language]
    ssml = (
        f'<speak version="1.0" xml:lang="{language}">'
        f'<voice name="{voice}">{html.escape(text)}</voice></speak>'
    )
    response = httpx.post(
        f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1",
        headers={
            "Ocp-Apim-Subscription-Key": key,
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
            "User-Agent": "TingHuiErAudioPipeline",
        },
        content=ssml.encode("utf-8"),
        timeout=60,
    )
    response.raise_for_status()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(response.content)


def synthesize_gtts(text: str, language: str, output: Path, tld_override: Optional[str] = None) -> None:
    # Import lazily so Azure remains usable when gTTS is not installed.
    from gtts import gTTS

    lang, default_tld = GTTS_LANGUAGES[language]
    tld = tld_override or default_tld
    output.parent.mkdir(parents=True, exist_ok=True)
    gTTS(text=text, lang=lang, tld=tld, slow=False).save(str(output))


def synthesize_edge(text: str, language: str, output: Path, voice_override: Optional[str] = None) -> None:
    import edge_tts

    output.parent.mkdir(parents=True, exist_ok=True)
    voice = voice_override or EDGE_VOICES[language]
    asyncio.run(edge_tts.Communicate(text=text, voice=voice).save(str(output)))


def synthesize(
    text: str,
    language: str,
    output: Path,
    provider: str,
    retries: int,
    gtts_tld: Optional[str] = None,
    edge_voice: Optional[str] = None,
) -> None:
    for attempt in range(1, retries + 1):
        try:
            if provider == "gtts":
                synthesize_gtts(text, language, output, tld_override=gtts_tld)
            elif provider == "edge":
                synthesize_edge(text, language, output, voice_override=edge_voice)
            else:
                synthesize_azure(text, language, output)
            return
        except Exception:
            output.unlink(missing_ok=True)
            if attempt == retries:
                raise
            time.sleep(min(2 ** attempt, 10))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default="backend/reports/audio/system_tts_fallbacks.json")
    parser.add_argument(
        "--word-book",
        help="Generate every word from a bundled book instead of reading the missing-audio manifest.",
    )
    parser.add_argument("--word-prefix", help="Only generate words beginning with this text (case-insensitive).")
    parser.add_argument("--output-dir", default="backend/generated/learning-audio")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--provider", choices=("gtts", "edge", "azure"), default="gtts")
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--gtts-tld", help="Google TTS domain, for example com, co.uk, com.au, or ca.")
    parser.add_argument("--edge-voice", help="Override the default Microsoft Edge TTS voice.")
    parser.add_argument(
        "--delay",
        type=float,
        default=0.2,
        help="Seconds between successful requests; useful for avoiding rate limits.",
    )
    args = parser.parse_args()
    load_dotenv(BACKEND / ".env")
    rows = (
        word_rows_from_book(args.word_book)
        if args.word_book
        else json.loads((ROOT / args.manifest).read_text(encoding="utf-8"))
    )
    if args.word_prefix:
        prefix = args.word_prefix.casefold()
        rows = [row for row in rows if str(row["word"]).casefold().startswith(prefix)]
    if args.limit is not None:
        rows = rows[:max(0, args.limit)]
    output_root = ROOT / args.output_dir
    completed = skipped = failed = 0

    def generate(row: dict[str, object]) -> tuple[str, Optional[str]]:
        output = output_root / str(row["target_path"])
        if output.is_file() and output.stat().st_size > 0 and not args.overwrite:
            return "skipped", None
        try:
            synthesize(
                str(row["text"]),
                str(row["language"]),
                output,
                provider=args.provider,
                retries=max(1, args.retries),
                gtts_tld=args.gtts_tld,
                edge_voice=args.edge_voice,
            )
            if not output.is_file() or output.stat().st_size == 0:
                output.unlink(missing_ok=True)
                raise RuntimeError("speech service returned no audio data")
            if args.delay > 0:
                time.sleep(args.delay)
            return "completed", None
        except Exception as error:
            return "failed", f"fail {row['word']} {row['kind']}: {error}"

    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        futures = [executor.submit(generate, row) for row in rows]
        for index, future in enumerate(as_completed(futures), 1):
            status, error = future.result()
            if status == "completed":
                completed += 1
            elif status == "skipped":
                skipped += 1
            else:
                failed += 1
            if error:
                print(error, flush=True)
            if index % 50 == 0 or index == len(rows):
                print(
                    f"progress {index}/{len(rows)} completed={completed} "
                    f"skipped={skipped} failed={failed}",
                    flush=True,
                )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
