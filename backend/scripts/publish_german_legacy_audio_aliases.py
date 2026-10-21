#!/usr/bin/env python3
"""Publish German v2 audio under the case-sensitive paths used by released apps."""

from __future__ import annotations

import argparse
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import quote

import httpx
from dotenv import load_dotenv

from learning_audio_key import safe_component


ROOT = Path(__file__).resolve().parents[2]
BOOKS = ("12yue", "A1", "A2", "B1")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        default="backend/generated/learning-audio-deploy/v2/words/de-DE",
    )
    parser.add_argument("--bucket", default="learning-audio")
    parser.add_argument("--workers", type=int, default=16)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    load_dotenv(ROOT / "backend" / ".env")
    base = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = (os.getenv("SUPABASE_SERVICE_ROLE_KEY") or "").strip()
    if not base or not key:
        raise RuntimeError("missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY")

    source = ROOT / args.source
    entries: list[tuple[Path, str]] = []
    for book in BOOKS:
        for path in sorted((source / book).glob("*.mp3")):
            # Released builds used these exact case-sensitive folder names,
            # while filenames were normalized to lowercase ASCII.
            object_key = f"v2/words/de-DE/{book}/{safe_component(path.name)}"
            entries.append((path, object_key))

    if not entries:
        raise RuntimeError(f"no German audio found under {source}")
    if args.dry_run:
        for _, object_key in entries:
            print(object_key)
        print(f"aliases={len(entries)}")
        return 0

    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "cache-control": "31536000",
        "x-upsert": "false",
    }
    client = httpx.Client(
        timeout=httpx.Timeout(60, connect=20),
        limits=httpx.Limits(
            max_connections=max(4, args.workers),
            max_keepalive_connections=max(4, args.workers),
        ),
    )

    def publish(entry: tuple[Path, str]) -> tuple[str, str]:
        path, object_key = entry
        encoded_key = quote(object_key, safe="/")
        public_url = f"{base}/storage/v1/object/public/{quote(args.bucket)}/{encoded_key}"
        for attempt in range(1, 4):
            try:
                if client.head(public_url).status_code == 200:
                    return object_key, "present"
                response = client.post(
                    f"{base}/storage/v1/object/{quote(args.bucket)}/{encoded_key}",
                    headers={**headers, "Content-Type": "audio/mpeg"},
                    content=path.read_bytes(),
                )
                if response.is_success:
                    return object_key, "uploaded"
                if response.status_code in {400, 409} and "exist" in response.text.lower():
                    return object_key, "present"
                error = f"HTTP {response.status_code}: {response.text[:160]}"
            except httpx.HTTPError as exc:
                error = str(exc)
            if attempt < 3:
                time.sleep(attempt)
        return object_key, f"failed: {error}"

    uploaded = present = failed = 0
    try:
        with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
            futures = [executor.submit(publish, entry) for entry in entries]
            for index, future in enumerate(as_completed(futures), 1):
                object_key, result = future.result()
                if result == "uploaded":
                    uploaded += 1
                elif result == "present":
                    present += 1
                else:
                    failed += 1
                    print(f"{object_key}: {result}", flush=True)
                if index % 500 == 0 or index == len(entries):
                    print(
                        f"progress {index}/{len(entries)} uploaded={uploaded} "
                        f"present={present} failed={failed}",
                        flush=True,
                    )
    finally:
        client.close()
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
