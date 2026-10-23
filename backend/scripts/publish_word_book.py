#!/usr/bin/env python3
"""Validate and publish one versioned word book to Supabase.

The catalog row remains inactive unless --activate is explicitly provided.
Existing active data is not modified if validation or upload verification fails.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import quote

import httpx
from dotenv import load_dotenv

MAX_BYTES = 25 * 1024 * 1024
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9._-]+$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--book-id", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--language", required=True, choices=("english", "german"))
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--content-version", required=True)
    parser.add_argument("--audio-path-prefix")
    parser.add_argument("--sort-order", type=int, default=0)
    parser.add_argument("--activate", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def validate(args: argparse.Namespace) -> bytes:
    if not SAFE_COMPONENT.fullmatch(args.book_id):
        raise ValueError("book-id 只能包含字母、数字、点、下划线和连字符")
    if not SAFE_COMPONENT.fullmatch(args.content_version):
        raise ValueError("content-version 只能包含字母、数字、点、下划线和连字符")
    if args.audio_path_prefix and (args.audio_path_prefix.startswith("/") or ".." in args.audio_path_prefix):
        raise ValueError("audio-path-prefix 不能以 / 开头或包含 ..")
    raw = args.source.read_bytes()
    if not raw or len(raw) > MAX_BYTES:
        raise ValueError("JSON 必须非空且不超过 25 MB")
    words = json.loads(raw)
    if not isinstance(words, list) or not words or len(words) > 100_000:
        raise ValueError("词书必须是包含 1 到 100000 个单词的 JSON 数组")
    seen: set[str] = set()
    for index, word in enumerate(words):
        if not isinstance(word, dict):
            raise ValueError(f"第 {index + 1} 项不是对象")
        word_id = str(word.get("id", "")).strip()
        text = str(word.get("text", "")).strip()
        if not word_id or not text:
            raise ValueError(f"第 {index + 1} 项缺少非空 id 或 text")
        if word_id in seen:
            raise ValueError(f"存在重复 id: {word_id}")
        seen.add(word_id)
    return raw


def main() -> int:
    args = parse_args()
    try:
        raw = validate(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"validation failed: {error}", file=sys.stderr)
        return 2

    digest = hashlib.sha256(raw).hexdigest()
    object_path = f"books/{args.book_id}/{args.content_version}.json"
    print(f"validated words JSON: {len(raw)} bytes, sha256={digest}")
    print(f"target: word-book-content/{object_path}")
    if args.dry_run:
        return 0

    load_dotenv(Path(__file__).resolve().parents[1] / ".env")
    base_url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    service_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not base_url or not service_key:
        print("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 未配置", file=sys.stderr)
        return 2

    headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}
    encoded_path = "/".join(quote(part, safe="") for part in object_path.split("/"))
    upload_url = f"{base_url}/storage/v1/object/word-book-content/{encoded_path}"
    with httpx.Client(timeout=60) as client:
        response = client.post(
            upload_url,
            headers={**headers, "Content-Type": "application/json", "x-upsert": "true"},
            content=raw,
        )
        response.raise_for_status()
        public_url = f"{base_url}/storage/v1/object/public/word-book-content/{encoded_path}"
        verification = client.get(public_url)
        verification.raise_for_status()
        if hashlib.sha256(verification.content).hexdigest() != digest:
            raise RuntimeError("上传后校验失败，目录未更新")

        if not args.activate:
            print("uploaded and verified; catalog unchanged (rerun with --activate to publish)")
            return 0

        row = {
            "book_id": args.book_id,
            "title": args.title,
            "language": args.language,
            "content_version": args.content_version,
            "data_url": public_url,
            "audio_path_prefix": args.audio_path_prefix,
            "sort_order": args.sort_order,
            "is_active": True,
        }
        catalog = client.post(
            f"{base_url}/rest/v1/word_books?on_conflict=book_id",
            headers={
                **headers,
                "Content-Type": "application/json",
                "Prefer": "resolution=merge-duplicates,return=minimal",
            },
            json=row,
        )
        catalog.raise_for_status()

    print(f"published {args.book_id} {args.content_version}: active")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
