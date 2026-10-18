#!/usr/bin/env python3
"""Mirror approved Podcast audio into Supabase Storage and publish its stable URL."""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]
DEFAULT_BUCKET = "podcast-audio"
MAX_BYTES = 250 * 1024 * 1024
MIN_BYTES = 32_000
TUS_CHUNK_SIZE = 6 * 1024 * 1024
TRANSCODE_THRESHOLD = 45 * 1024 * 1024
DOWNLOAD_CHUNK_SIZE = 4 * 1024 * 1024


def extension(url: str, content_type: str) -> str:
    by_type = {
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/aac": "aac",
        "audio/ogg": "ogg",
    }
    if content_type in by_type:
        return by_type[content_type]
    suffix = Path(urlparse(url).path).suffix.lower().lstrip(".")
    return suffix if suffix in {"mp3", "m4a", "aac", "ogg"} else "mp3"


def download_range(url: str, start: int, end: int, destination: Path) -> str:
    headers = {
        "User-Agent": "TingHuierAudioMirror/1.0",
        "Accept": "audio/mpeg,audio/*;q=0.9,*/*;q=0.1",
        "Range": f"bytes={start}-{end}",
    }
    last_error: Exception | None = None
    for _ in range(3):
        try:
            response = httpx.get(
                url,
                headers=headers,
                follow_redirects=True,
                timeout=httpx.Timeout(30, read=60, write=60, pool=30),
            )
            response.raise_for_status()
            if response.status_code != 206:
                raise ValueError(f"publisher ignored byte range: HTTP {response.status_code}")
            expected = end - start + 1
            if len(response.content) != expected:
                raise ValueError(f"range length mismatch: expected {expected}, got {len(response.content)}")
            destination.write_bytes(response.content)
            return response.headers.get("content-type", "").split(";", 1)[0].lower()
        except (httpx.HTTPError, OSError, ValueError) as error:
            last_error = error
    raise RuntimeError(f"range {start}-{end} failed after 3 attempts: {last_error}")


def resolve_download_url(url: str) -> tuple[str, int, str]:
    response = httpx.get(
        url,
        headers={"Range": "bytes=0-4095", "User-Agent": "TingHuierAudioMirror/1.0"},
        follow_redirects=True,
        timeout=httpx.Timeout(30, read=60),
    )
    response.raise_for_status()
    content_range = response.headers.get("content-range", "")
    total = int(content_range.rsplit("/", 1)[1]) if "/" in content_range and content_range.rsplit("/", 1)[1].isdigit() else 0
    content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
    return str(response.url), total, content_type


def download(client: httpx.Client, url: str, destination: Path, expected_size: int = 0) -> tuple[str, int]:
    if expected_size > 0:
        resolved_url, resolved_size, resolved_type = resolve_download_url(url)
        if resolved_size:
            expected_size = resolved_size
        if expected_size > MAX_BYTES:
            raise ValueError(f"audio exceeds {MAX_BYTES} bytes")
        parts = []
        for index, start in enumerate(range(0, expected_size, DOWNLOAD_CHUNK_SIZE)):
            parts.append((start, min(expected_size - 1, start + DOWNLOAD_CHUNK_SIZE - 1), destination.parent / f"part-{index:04d}"))
        with ThreadPoolExecutor(max_workers=4) as executor:
            content_types = list(executor.map(lambda part: download_range(resolved_url, *part), parts))
        with destination.open("wb") as output:
            for _, _, part_path in parts:
                with part_path.open("rb") as part:
                    while chunk := part.read(1024 * 1024):
                        output.write(chunk)
                part_path.unlink()
        content_type = resolved_type or next((value for value in content_types if value), "application/octet-stream")
        return content_type, destination.stat().st_size

    headers = {"User-Agent": "TingHuierAudioMirror/1.0", "Accept": "audio/mpeg,audio/*;q=0.9,*/*;q=0.1"}
    size = 0
    with client.stream("GET", url, headers=headers, timeout=httpx.Timeout(30, read=60)) as response:
        response.raise_for_status()
        content_type = response.headers.get("content-type", "").split(";", 1)[0].lower()
        with destination.open("wb") as output:
            for chunk in response.iter_bytes():
                size += len(chunk)
                output.write(chunk)
    if size < MIN_BYTES:
        raise ValueError(f"audio is unexpectedly small: {size} bytes")
    return content_type or "application/octet-stream", size


def metadata_value(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def transcode_spoken_audio(source: Path, destination: Path) -> int:
    """Create a compact mono MP3 without changing the audio timeline."""
    import av

    with av.open(str(source)) as input_container, av.open(str(destination), mode="w") as output_container:
        output_stream = output_container.add_stream("libmp3lame", rate=44_100)
        output_stream.bit_rate = 64_000
        output_stream.layout = "mono"
        resampler = av.AudioResampler(format="s16p", layout="mono", rate=44_100)
        for frame in input_container.decode(audio=0):
            for converted in resampler.resample(frame):
                for packet in output_stream.encode(converted):
                    output_container.mux(packet)
        for converted in resampler.resample(None):
            for packet in output_stream.encode(converted):
                output_container.mux(packet)
        for packet in output_stream.encode(None):
            output_container.mux(packet)
    return destination.stat().st_size


def tus_upload(
    client: httpx.Client,
    endpoint: str,
    key: str,
    bucket: str,
    object_path: str,
    content_type: str,
    source: Path,
) -> None:
    size = source.stat().st_size
    creation = client.post(
        endpoint,
        headers={
            "Authorization": f"Bearer {key}",
            "apikey": key,
            "Tus-Resumable": "1.0.0",
            "Upload-Length": str(size),
            "Upload-Metadata": ",".join(
                [
                    f"bucketName {metadata_value(bucket)}",
                    f"objectName {metadata_value(object_path)}",
                    f"contentType {metadata_value(content_type)}",
                    f"cacheControl {metadata_value('3600')}",
                ]
            ),
            "x-upsert": "true",
        },
        timeout=60,
    )
    if creation.status_code not in {201, 204}:
        raise RuntimeError(f"TUS create failed ({creation.status_code}): {creation.text[:500]}")
    upload_url = creation.headers.get("location")
    if not upload_url:
        raise RuntimeError("TUS create response omitted Location")
    upload_url = str(httpx.URL(endpoint).join(upload_url))

    offset = 0
    with source.open("rb") as audio_file:
        while offset < size:
            audio_file.seek(offset)
            chunk = audio_file.read(TUS_CHUNK_SIZE)
            response = client.patch(
                upload_url,
                content=chunk,
                headers={
                    "Authorization": f"Bearer {key}",
                    "apikey": key,
                    "Tus-Resumable": "1.0.0",
                    "Upload-Offset": str(offset),
                    "Content-Type": "application/offset+octet-stream",
                    "x-upsert": "true",
                },
                timeout=60,
            )
            if response.status_code != 204:
                raise RuntimeError(f"TUS chunk failed ({response.status_code}): {response.text[:500]}")
            next_offset = response.headers.get("upload-offset")
            offset = int(next_offset) if next_offset and next_offset.isdigit() else offset + len(chunk)


def main() -> int:
    parser = argparse.ArgumentParser(description="Mirror Podcast audio to Supabase Storage")
    parser.add_argument("--podcast-name", required=True)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--bucket", default=DEFAULT_BUCKET)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--single-stream",
        action="store_true",
        help="Download in one request so dynamically assembled audio cannot change between byte ranges",
    )
    args = parser.parse_args()

    load_dotenv(BACKEND_DIR / ".env")
    project_url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not project_url or not key:
        raise RuntimeError("Missing Supabase credentials")

    auth = {"apikey": key, "Authorization": f"Bearer {key}"}
    # New sb_secret service keys are authenticated by the project API gateway;
    # direct *.storage.supabase.co expects a compact JWT access token.
    tus_endpoint = f"{project_url}/storage/v1/upload/resumable"
    with httpx.Client(follow_redirects=True, timeout=args.timeout) as network, httpx.Client(
        base_url=project_url, headers=auth, timeout=args.timeout
    ) as supabase, httpx.Client(follow_redirects=True, timeout=args.timeout) as tus:
        podcasts = supabase.get(
            "/rest/v1/podcasts",
            params={"name": f"eq.{args.podcast_name}", "select": "id,rights_status", "limit": "1"},
        )
        podcasts.raise_for_status()
        if not podcasts.json():
            raise RuntimeError(f"Podcast not found: {args.podcast_name}")
        podcast = podcasts.json()[0]
        if podcast["rights_status"] != "approved":
            raise RuntimeError("Audio mirroring requires podcasts.rights_status=approved")

        response = supabase.get(
            "/rest/v1/episodes",
            params={
                "podcast_id": f"eq.{podcast['id']}",
                "select": "id,guid,title,audio_url,original_audio_url,audio_storage_path,audio_content_length",
                "order": "publish_date.desc.nullslast",
                "limit": str(min(max(args.limit, 1), 200)),
            },
        )
        response.raise_for_status()

        mirrored = skipped = failed = 0
        for episode in response.json():
            if episode.get("audio_storage_path") and not args.force:
                skipped += 1
                continue
            source_url = episode.get("original_audio_url") or episode["audio_url"]
            digest = hashlib.sha256(episode["guid"].encode("utf-8")).hexdigest()[:24]
            try:
                with tempfile.TemporaryDirectory(prefix="tinghuier-audio-") as temporary:
                    temporary_path = Path(temporary) / "audio"
                    content_type, size = download(
                        network,
                        source_url,
                        temporary_path,
                        0 if args.single_stream else int(episode.get("audio_content_length") or 0),
                    )
                    upload_path = temporary_path
                    if size > TRANSCODE_THRESHOLD:
                        upload_path = Path(temporary) / "audio-64k.mp3"
                        original_size = size
                        size = transcode_spoken_audio(temporary_path, upload_path)
                        content_type = "audio/mpeg"
                        print(
                            f"  compressed: {episode['title']} "
                            f"({original_size} -> {size} bytes)",
                            flush=True,
                        )
                    object_path = f"{podcast['id']}/{digest}.{extension(source_url, content_type)}"
                    tus_upload(
                        tus,
                        tus_endpoint,
                        key,
                        args.bucket,
                        object_path,
                        content_type,
                        upload_path,
                    )

                public_url = (
                    f"{project_url}/storage/v1/object/public/{quote(args.bucket)}/"
                    f"{quote(object_path, safe='/')}"
                )
                update = supabase.patch(
                    "/rest/v1/episodes",
                    params={"id": f"eq.{episode['id']}"},
                    json={
                        "original_audio_url": source_url,
                        "audio_url": public_url,
                        "audio_storage_path": object_path,
                        "audio_mirrored_at": datetime.now(timezone.utc).isoformat(),
                        "audio_status": "available",
                        "audio_mime_type": content_type,
                        "audio_content_length": size,
                        "resolved_audio_url": public_url,
                        "audio_error": None,
                    },
                    headers={"Prefer": "return=minimal"},
                )
                update.raise_for_status()
                mirrored += 1
                print(f"mirrored: {episode['title']} ({size} bytes)")
            except (httpx.HTTPError, OSError, ValueError) as error:
                failed += 1
                print(f"failed: {episode['title']}: {error}")

    print(f"Mirror complete: mirrored={mirrored} skipped={skipped} failed={failed}")
    return 2 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
