#!/usr/bin/env python3
import argparse
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional


PROJECT_URL = "https://frljmdtogeyajpbwjavv.supabase.co"
BUCKET = "audio"
PROJECT_DIR = Path(__file__).resolve().parent
DEFAULT_AUDIO_UPLOAD_DIR = PROJECT_DIR / "audio_upload"
DEFAULT_FAILED_LIST = PROJECT_DIR / "supabase_upload_failed.txt"


def iter_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*") if path.is_file() and not path.name.startswith("."))


def load_file_list(path: Path, root: Path) -> list[Path]:
    files: list[Path] = []
    with path.open("r", encoding="utf-8") as file:
        for line in file:
            raw = line.strip()
            if not raw or raw.startswith("#"):
                continue
            candidate = Path(raw)
            if not candidate.is_absolute():
                candidate = root / raw
            if candidate.is_file():
                files.append(candidate)
            else:
                print(f"warn   : missing listed file {raw}")
    return sorted(dict.fromkeys(files))


def content_type(path: Path) -> str:
    guessed, _ = mimetypes.guess_type(path.name)
    return guessed or "application/octet-stream"


def upload_file(path: Path, root: Path, bucket: str, key: str, overwrite: bool, retries: int) -> None:
    object_path = path.relative_to(root).as_posix()
    encoded_object_path = urllib.parse.quote(object_path, safe="/")
    url = f"{PROJECT_URL}/storage/v1/object/{bucket}/{encoded_object_path}"
    data = path.read_bytes()
    headers = {
        "Authorization": f"Bearer {key}",
        "apikey": key,
        "Content-Type": content_type(path),
        "x-upsert": "true" if overwrite else "false",
    }
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")

    last_error: Optional[Exception] = None
    for attempt in range(1, retries + 2):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                if 200 <= response.status < 300:
                    return
                raise RuntimeError(f"HTTP {response.status}")
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, RuntimeError) as error:
            last_error = error
            if attempt <= retries:
                time.sleep(min(2 ** attempt, 10))
                continue
            raise RuntimeError(f"{object_path}: {last_error}") from last_error


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload audio_upload files to Supabase Storage.")
    parser.add_argument("--root", default=str(DEFAULT_AUDIO_UPLOAD_DIR), help="Local upload root")
    parser.add_argument("--bucket", default=BUCKET, help=argparse.SUPPRESS)
    parser.add_argument("--execute", action="store_true", help="Actually upload files. Default is dry-run.")
    parser.add_argument("--no-overwrite", action="store_true", help="Do not upsert existing objects")
    parser.add_argument("--limit", type=int, help="Upload at most N files")
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--failed-list", default=str(DEFAULT_FAILED_LIST), help="Where to write failed relative paths")
    parser.add_argument("--only-list", help="Only upload relative paths listed in this file")
    args = parser.parse_args()

    root = Path(args.root).expanduser()
    if not root.is_absolute():
        root = PROJECT_DIR / root
    if not root.exists():
        print(f"missing upload root: {root}", file=sys.stderr)
        return 1

    if args.only_list:
        only_list_path = Path(args.only_list).expanduser()
        if not only_list_path.is_absolute():
            only_list_path = PROJECT_DIR / only_list_path
        if not only_list_path.exists():
            print(f"missing only-list file: {only_list_path}", file=sys.stderr)
            return 1
        files = load_file_list(only_list_path, root)
    else:
        files = iter_files(root)

    if args.limit is not None:
        files = files[: args.limit]

    total_size = sum(path.stat().st_size for path in files)
    print(f"root   : {root}")
    print(f"bucket : {args.bucket}")
    print(f"files  : {len(files)}")
    print(f"size   : {total_size / 1024 / 1024:.1f} MB")
    if args.only_list:
        print(f"list   : {args.only_list}")

    if not args.execute:
        print("mode   : dry-run")
        for path in files[:10]:
            print(f"sample : {path.relative_to(root).as_posix()}")
        if len(files) > 10:
            print(f"... {len(files) - 10} more")
        return 0

    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or os.environ.get("SUPABASE_ACCESS_TOKEN")
    if not key:
        print("missing SUPABASE_SERVICE_ROLE_KEY environment variable", file=sys.stderr)
        return 1

    print("mode   : upload")
    uploaded = 0
    failed = 0
    failed_paths: list[str] = []
    overwrite = not args.no_overwrite
    failed_list_path = Path(args.failed_list).expanduser()
    if not failed_list_path.is_absolute():
        failed_list_path = PROJECT_DIR / failed_list_path

    for index, path in enumerate(files, start=1):
        object_path = path.relative_to(root).as_posix()
        try:
            upload_file(path, root, args.bucket, key, overwrite, args.retries)
            uploaded += 1
        except Exception as error:
            failed += 1
            failed_paths.append(object_path)
            print(f"fail   : {error}")

        if index % 50 == 0 or index == len(files):
            print(f"progress: {index}/{len(files)} uploaded={uploaded} failed={failed}")

    failed_list_path.write_text("\n".join(failed_paths) + ("\n" if failed_paths else ""), encoding="utf-8")
    print(f"failed-list: {failed_list_path}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
