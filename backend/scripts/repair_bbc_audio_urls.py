#!/usr/bin/env python3
"""Change imported BBC media-selector entry URLs from HTTP to HTTPS."""

import os
from pathlib import Path

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]


def main() -> int:
    load_dotenv(BACKEND_DIR / ".env")
    url = (os.getenv("SUPABASE_URL") or "").rstrip("/")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or ""
    if not url or not key:
        raise RuntimeError("Missing Supabase credentials")
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    with httpx.Client(base_url=url + "/rest/v1", headers=headers, timeout=20) as client:
        response = client.get(
            "/episodes",
            params={
                "audio_url": "like.http://open.live.bbc.co.uk/*",
                "select": "id,title,audio_url",
                "limit": "1000",
            },
        )
        response.raise_for_status()
        rows = response.json()
        for row in rows:
            secure_url = "https://" + row["audio_url"][len("http://") :]
            update = client.patch(
                "/episodes",
                params={"id": f"eq.{row['id']}"},
                json={"audio_url": secure_url},
                headers={"Prefer": "return=minimal"},
            )
            update.raise_for_status()
            print(f"Updated: {row['title']}")
    print(f"BBC audio URLs repaired: {len(rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
