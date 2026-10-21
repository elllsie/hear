#!/usr/bin/env python3
"""Verify every local learning audio object is readable from Supabase Storage."""

from __future__ import annotations

import argparse
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import quote

import httpx
from dotenv import load_dotenv

from learning_audio_key import storage_key


ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="听会儿/Audio.bundle")
    parser.add_argument("--bucket", default="learning-audio")
    parser.add_argument("--workers", type=int, default=16)
    parser.add_argument("--prefix")
    parser.add_argument("--only-list", help="Only verify object keys listed in this UTF-8 text file.")
    parser.add_argument("--manifest", help="Only verify target_path values from a JSON manifest.")
    parser.add_argument(
        "--compare-content",
        action="store_true",
        help="GET each object with a cache-busting query and compare its bytes with the local file.",
    )
    parser.add_argument("--missing-output", default="backend/reports/audio/supabase_missing.txt")
    args = parser.parse_args()
    load_dotenv(ROOT / "backend" / ".env")
    source = ROOT / args.source
    if args.only_list:
        only_list = ROOT / args.only_list
        paths = [line.strip() for line in only_list.read_text(encoding="utf-8").splitlines() if line.strip()]
    elif args.manifest:
        manifest_rows = json.loads((ROOT / args.manifest).read_text(encoding="utf-8"))
        paths = [str(row["target_path"]).strip() for row in manifest_rows if str(row.get("target_path", "")).strip()]
    else:
        paths = [path.relative_to(source).as_posix() for path in source.rglob("*") if path.is_file() and path.suffix.lower() in {".mp3", ".m4a", ".aac"}]
    if args.prefix:
        prefix = args.prefix.strip("/") + "/"
        paths = [path for path in paths if path.startswith(prefix)]
    local_paths_by_key: dict[str, str] = {}
    if args.compare_content:
        # `--only-list` is documented as accepting Storage object keys. Chinese
        # filenames are converted to ASCII-only keys before upload, so an
        # object key such as `meanings/zh/04242931.mp3` is not itself a local
        # filename. Build the reverse lookup once so a mismatch report can be
        # passed straight back into this command for a strict byte comparison.
        local_paths_by_key = {
            storage_key(path.relative_to(source).as_posix()): path.relative_to(source).as_posix()
            for path in source.rglob("*")
            if path.is_file() and path.suffix.lower() in {".mp3", ".m4a", ".aac"}
        }
    base = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    if not base:
        raise RuntimeError("missing SUPABASE_URL")
    client = httpx.Client(
        timeout=httpx.Timeout(30, connect=15),
        limits=httpx.Limits(max_connections=max(4, args.workers), max_keepalive_connections=max(4, args.workers)),
    )

    def exists(path: str) -> tuple[str, bool]:
        object_key = storage_key(path)
        url = f"{base}/storage/v1/object/public/{quote(args.bucket)}/{quote(object_key, safe='/')}"
        if args.compare_content:
            url = f"{url}?audioVersion={time.time_ns()}"
        for attempt in range(1, 4):
            try:
                response = client.get(url) if args.compare_content else client.head(url)
                found = response.status_code == 200
                if found and args.compare_content:
                    local_path = source / local_paths_by_key.get(object_key, path)
                    found = local_path.is_file() and response.content == local_path.read_bytes()
                return object_key, found
            except httpx.HTTPError:
                if attempt < 3:
                    time.sleep(attempt)
        return object_key, False

    missing: list[str] = []
    try:
        with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
            futures = [executor.submit(exists, path) for path in paths]
            for index, future in enumerate(as_completed(futures), 1):
                path, found = future.result()
                if not found:
                    missing.append(path)
                if index % 500 == 0 or index == len(paths):
                    print(f"progress {index}/{len(paths)} missing={len(missing)}", flush=True)
    finally:
        client.close()
    output = ROOT / args.missing_output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(sorted(missing)) + ("\n" if missing else ""), encoding="utf-8")
    print(f"verified={len(paths) - len(missing)} missing={len(missing)}")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
