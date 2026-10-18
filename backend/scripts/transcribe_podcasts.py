#!/usr/bin/env python3
"""Locally transcribe published Podcast episodes and upload timed sentences."""

from __future__ import annotations

import argparse
import os
import tempfile
from pathlib import Path
from typing import Any, Optional

import httpx
from dotenv import load_dotenv

# Hugging Face's Xet transport is unreliable on some networks. Standard HTTP
# supports resume and is sufficient for the small Whisper models used here.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "600")

from faster_whisper import WhisperModel


BACKEND_DIR = Path(__file__).resolve().parents[1]
MODEL_DIR = BACKEND_DIR / ".models"


def chunks(values: list[dict[str, Any]], size: int = 200):
    for index in range(0, len(values), size):
        yield values[index : index + size]


def clean_text(value: str) -> str:
    return " ".join(value.strip().split())


class SupabaseAdmin:
    def __init__(self) -> None:
        load_dotenv(BACKEND_DIR / ".env")
        url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
        key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
        if not url or not key:
            raise RuntimeError("backend/.env is missing Supabase credentials")
        self.client = httpx.Client(
            base_url=url + "/rest/v1",
            timeout=30,
            headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )

    def close(self) -> None:
        self.client.close()

    def episodes(
        self,
        podcast_name: str,
        limit: int,
        force: bool,
        episode_title: Optional[str] = None,
        latest_window: bool = False,
    ) -> list[dict[str, Any]]:
        shows = self.client.get(
            "/podcasts", params={"name": f"eq.{podcast_name}", "select": "id,language", "limit": "1"}
        )
        shows.raise_for_status()
        if not shows.json():
            raise RuntimeError(f"Podcast not found: {podcast_name}")
        params = {
            "podcast_id": f"eq.{shows.json()[0]['id']}",
            "editorial_status": "neq.archived",
            "audio_status": "eq.available",
            "select": "id,title,audio_url,audio_mime_type,transcript_status",
            "order": "publish_date.desc.nullslast",
            "limit": str(limit),
        }
        if not force and not latest_window:
            params["transcript_status"] = "neq.ready"
        if episode_title:
            params["title"] = f"eq.{episode_title}"
        response = self.client.get("/episodes", params=params)
        response.raise_for_status()
        language = shows.json()[0].get("language") or "en"
        episodes = response.json()
        if latest_window and not force:
            episodes = [episode for episode in episodes if episode.get("transcript_status") != "ready"]
        return [{**episode, "language": language} for episode in episodes]

    def set_status(
        self,
        episode_id: str,
        status: str,
        transcript_format: Optional[str] = None,
        duration_seconds: Optional[int] = None,
    ) -> None:
        payload = {"transcript_status": status}
        if transcript_format:
            payload["transcript_format"] = transcript_format
        if duration_seconds is not None:
            payload["duration_seconds"] = duration_seconds
        response = self.client.patch(
            "/episodes",
            params={"id": f"eq.{episode_id}"},
            json=payload,
            headers={"Prefer": "return=minimal"},
        )
        response.raise_for_status()

    def replace_sentences(self, episode_id: str, rows: list[dict[str, Any]]) -> None:
        deletion = self.client.delete(
            "/episode_sentences",
            params={"episode_id": f"eq.{episode_id}"},
            headers={"Prefer": "return=minimal"},
        )
        deletion.raise_for_status()
        for batch in chunks(rows):
            response = self.client.post(
                "/episode_sentences", json=batch, headers={"Prefer": "return=minimal"}
            )
            response.raise_for_status()


def download_audio(url: str, destination: Path) -> None:
    with httpx.stream(
        "GET",
        url,
        follow_redirects=True,
        timeout=httpx.Timeout(30, read=120),
        headers={"User-Agent": "TingHuierTranscriptWorker/1.0"},
    ) as response:
        response.raise_for_status()
        with destination.open("wb") as output:
            for data in response.iter_bytes():
                output.write(data)


def timed_rows(segments: Any, episode_id: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for segment in segments:
        if isinstance(segment, dict):
            text = segment.get("text", "")
            start = segment.get("start", 0)
            end = segment.get("end", start)
        else:
            text = segment.text
            start = segment.start
            end = segment.end
        english = clean_text(text)
        start_ms = max(0, round(start * 1_000))
        end_ms = max(start_ms + 1, round(end * 1_000))
        if not english:
            continue
        rows.append(
            {
                "episode_id": episode_id,
                "sequence": len(rows),
                "start_ms": start_ms,
                "end_ms": end_ms,
                "english": english,
                "chinese": None,
                "speaker": None,
                "source": "whisper_generated",
                "timing_quality": "exact",
                "alignment_confidence": None,
            }
        )
    return rows


def decode_audio(audio_path: Path):
    import av
    import numpy as np

    chunks = []
    with av.open(str(audio_path)) as container:
        resampler = av.AudioResampler(format="fltp", layout="mono", rate=16_000)
        for frame in container.decode(audio=0):
            converted = resampler.resample(frame)
            for output in converted if isinstance(converted, list) else [converted]:
                if output is not None:
                    chunks.append(output.to_ndarray().reshape(-1))
    if not chunks:
        raise RuntimeError("audio decoder returned no samples")
    return np.concatenate(chunks).astype(np.float32, copy=False)


def load_transcriber(model_name: str):
    try:
        model = WhisperModel(model_name, device="cpu", compute_type="int8", download_root=str(MODEL_DIR))
        return "faster-whisper", model
    except Exception as error:
        print(f"  faster-whisper unavailable ({error!r}); falling back to OpenAI Whisper CPU", flush=True)
        import whisper

        model = whisper.load_model(model_name, device="cpu", download_root=str(MODEL_DIR))
        return "openai-whisper", model


def audio_duration_seconds(audio_path: Path) -> float:
    import av

    with av.open(str(audio_path)) as container:
        stream = container.streams.audio[0]
        if stream.duration is not None and stream.time_base is not None:
            return float(stream.duration * stream.time_base)
        if container.duration is not None:
            return float(container.duration / av.time_base)
    raise RuntimeError("audio duration is unavailable")


def transcribe(
    backend: str,
    model: Any,
    audio_path: Path,
    episode_id: str,
    language: Optional[str],
) -> tuple[list[dict[str, Any]], float]:
    if backend == "faster-whisper":
        segments, info = model.transcribe(
            str(audio_path),
            language=language,
            beam_size=5,
            vad_filter=True,
            condition_on_previous_text=True,
        )
        rows = timed_rows(segments, episode_id)
        print(f"  language={info.language} probability={info.language_probability:.3f}")
        return rows, audio_duration_seconds(audio_path)

    audio = decode_audio(audio_path)
    result = model.transcribe(
        audio,
        language=language,
        beam_size=5,
        condition_on_previous_text=True,
        fp16=False,
        verbose=False,
    )
    return timed_rows(result["segments"], episode_id), len(audio) / 16_000


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--podcast-name", default="BBC 6 Minute English")
    parser.add_argument("--limit", type=int, default=1)
    parser.add_argument("--model", help="Whisper model override; defaults to tiny.en for English and tiny for German")
    parser.add_argument(
        "--language",
        help="Whisper language override; use 'auto' for multilingual/code-switching audio",
    )
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--latest-window",
        action="store_true",
        help="Inspect exactly the latest --limit episodes, then transcribe only those not ready",
    )
    parser.add_argument("--episode-title")
    args = parser.parse_args()

    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    admin = SupabaseAdmin()
    failures = 0
    try:
        episodes = admin.episodes(
            args.podcast_name,
            min(max(args.limit, 1), 20),
            args.force,
            args.episode_title,
            args.latest_window,
        )
        if not episodes:
            print("No episodes need transcription.")
            return 0
        requested_language = None if args.language == "auto" else args.language
        needs_multilingual = args.language == "auto" or any(item.get("language") == "de" for item in episodes)
        model_name = args.model or ("tiny" if needs_multilingual else "tiny.en")
        print(f"Loading local model {model_name}…", flush=True)
        try:
            backend, model = load_transcriber(model_name)
        except Exception as error:
            print(f"ERROR: unable to initialize Whisper model: {error!r}", flush=True)
            return 2

        for episode in episodes:
            episode_id = episode["id"]
            print(f"Transcribing: {episode['title']}")
            admin.set_status(episode_id, "processing")
            try:
                with tempfile.TemporaryDirectory(prefix="tinghuier-transcript-") as directory:
                    audio_path = Path(directory) / "episode.audio"
                    download_audio(episode["audio_url"], audio_path)
                    print(f"  downloaded={audio_path.stat().st_size / 1_048_576:.1f} MB")
                    language = requested_language if args.language else episode.get("language", "en")
                    rows, duration_seconds = transcribe(backend, model, audio_path, episode_id, language)
                if not rows:
                    raise RuntimeError("Whisper returned no transcript segments")
                admin.replace_sentences(episode_id, rows)
                admin.set_status(episode_id, "ready", "stt", round(duration_seconds))
                print(f"  uploaded={len(rows)} timed sentences; audio_duration={duration_seconds:.2f}s")
            except Exception as error:
                failures += 1
                admin.set_status(episode_id, "failed")
                print(f"  FAILED: {error}")
    finally:
        admin.close()
    if failures:
        print(f"Transcription completed with {failures} failed episode(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
