#!/usr/bin/env python3
"""Upload generated learning audio to the public Supabase Storage bucket."""

from __future__ import annotations

import argparse
import mimetypes
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Optional
from urllib.parse import quote

import httpx
from dotenv import load_dotenv

from learning_audio_key import storage_key


ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "backend"


def required_env(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value:
        raise RuntimeError(f"missing {name}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="backend/generated/learning-audio")
    parser.add_argument("--bucket", default="learning-audio")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace existing Storage objects. Use only for an intentional audio refresh.",
    )
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--prefix", help="Only upload paths under this prefix, for example words/KaoYan_2")
    parser.add_argument("--only-list", help="Only upload object keys listed in this UTF-8 text file.")
    parser.add_argument(
        "--list-first",
        action="store_true",
        help="List Storage objects first and upload only missing paths.",
    )
    args = parser.parse_args()
    load_dotenv(BACKEND / ".env")
    source = ROOT / args.source
    files = sorted(path for path in source.rglob("*") if path.is_file() and path.suffix.lower() in {".mp3", ".m4a", ".aac"})
    if args.prefix:
        normalized_prefix = args.prefix.strip("/") + "/"
        files = [path for path in files if path.relative_to(source).as_posix().startswith(normalized_prefix)]
    if args.only_list:
        listed = {
            line.strip() for line in (ROOT / args.only_list).read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
        files = [
            path for path in files
            if storage_key(path.relative_to(source).as_posix()) in listed
        ]
    if not files:
        raise RuntimeError(f"no generated audio under {source}")
    base = required_env("SUPABASE_URL").rstrip("/")
    key = required_env("SUPABASE_SERVICE_ROLE_KEY")
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "x-upsert": "true" if args.overwrite else "false",
        "cache-control": "31536000",
    }
    if not args.dry_run:
        bucket_response = None
        for attempt in range(1, 6):
            try:
                bucket_response = httpx.get(f"{base}/storage/v1/bucket/{quote(args.bucket)}", headers=headers, timeout=60)
                break
            except httpx.HTTPError:
                if attempt == 5:
                    raise
                time.sleep(attempt * 3)
        assert bucket_response is not None
        missing_bucket = bucket_response.status_code in {400, 404} and "not found" in bucket_response.text.lower()
        if missing_bucket:
            create_response = httpx.post(
                f"{base}/storage/v1/bucket",
                headers={**headers, "Content-Type": "application/json"},
                json={"id": args.bucket, "name": args.bucket, "public": True, "file_size_limit": 10485760, "allowed_mime_types": ["audio/mpeg", "audio/mp4", "audio/x-m4a"]},
                timeout=30,
            )
            create_response.raise_for_status()
        else:
            bucket_response.raise_for_status()

    if args.list_first and not args.dry_run:
        existing: set[str] = set()
        list_client = httpx.Client(timeout=180)

        def list_prefix(prefix: str) -> None:
            offset = 0
            while True:
                for attempt in range(1, 4):
                    try:
                        response = list_client.post(
                            f"{base}/storage/v1/object/list/{quote(args.bucket)}",
                            headers={**headers, "Content-Type": "application/json"},
                            json={"prefix": prefix, "limit": 100, "offset": offset, "sortBy": {"column": "name", "order": "asc"}},
                        )
                        response.raise_for_status()
                        break
                    except httpx.HTTPError:
                        if attempt == 3:
                            raise
                        time.sleep(attempt * 2)
                entries = response.json()
                for entry in entries:
                    name = entry.get("name")
                    if not name:
                        continue
                    path = f"{prefix}/{name}" if prefix else name
                    if entry.get("id") is None:
                        list_prefix(path)
                    else:
                        existing.add(path)
                print(f"listed prefix={prefix or '/'} offset={offset} objects={len(existing)}", flush=True)
                if len(entries) < 100:
                    break
                offset += len(entries)

        try:
            list_prefix(args.prefix.strip("/") if args.prefix else "")
        finally:
            list_client.close()
        before = len(files)
        files = [
            path for path in files
            if storage_key(path.relative_to(source).as_posix()) not in existing
        ]
        print(f"remote objects={len(existing)} local={before} missing={len(files)}", flush=True)
        if not files:
            return 0

    transfer_client = httpx.Client(
        timeout=httpx.Timeout(60, connect=20),
        limits=httpx.Limits(max_connections=max(4, args.workers), max_keepalive_connections=max(4, args.workers)),
    )

    def upload(path: Path) -> tuple[str, str, Optional[str]]:
        relative = path.relative_to(source).as_posix()
        object_key = storage_key(relative)
        content_type = mimetypes.guess_type(path.name)[0] or "audio/mpeg"
        url = f"{base}/storage/v1/object/{quote(args.bucket)}/{quote(object_key, safe='/')}"
        public_url = f"{base}/storage/v1/object/public/{quote(args.bucket)}/{quote(object_key, safe='/')}"
        last_error = "upload was not attempted"
        try:
            if transfer_client.head(public_url, timeout=20).status_code == 200:
                return object_key, "skipped", None
        except httpx.HTTPError:
            pass
        for attempt in range(1, 4):
            try:
                response = transfer_client.post(url, headers={**headers, "Content-Type": content_type}, content=path.read_bytes())
                if response.is_success:
                    return object_key, "uploaded", None
                response_text = response.text.lower()
                if not args.overwrite and response.status_code in {400, 409} and any(
                    marker in response_text
                    for marker in ("duplicate", "already exists", "resourcealreadyexists")
                ):
                    return object_key, "skipped", None
                last_error = f"{response.status_code} {response.text[:200]}"
            except httpx.HTTPError as error:
                last_error = str(error)
            if attempt < 3:
                time.sleep(attempt)
        return object_key, "failed", last_error

    uploaded = skipped = failed = 0
    if args.dry_run:
        for path in files:
            print(storage_key(path.relative_to(source).as_posix()))
    else:
        try:
            with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
                futures = [executor.submit(upload, path) for path in files]
                for index, future in enumerate(as_completed(futures), 1):
                    relative, status, error = future.result()
                    if status == "uploaded":
                        uploaded += 1
                    elif status == "skipped":
                        skipped += 1
                    if error:
                        failed += 1
                        print(f"fail {relative}: {error}")
                    if index % 100 == 0 or index == len(files):
                        print(
                            f"progress {index}/{len(files)} uploaded={uploaded} "
                            f"skipped={skipped} failed={failed}",
                            flush=True,
                        )
        finally:
            transfer_client.close()
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
