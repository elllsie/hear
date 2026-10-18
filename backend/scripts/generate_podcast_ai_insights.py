#!/usr/bin/env python3
"""Generate reusable episode summaries and difficult-word candidates."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import httpx
from dotenv import load_dotenv


BACKEND_DIR = Path(__file__).resolve().parents[1]
PROMPT_VERSION = "podcast-insights-v2-bilingual-meanings"

OUTPUT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "summary_zh": {"type": "string"},
        "summary_en": {"type": "string"},
        "key_points": {"type": "array", "items": {"type": "string"}},
        "difficult_words": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "word": {"type": "string"},
                    "lemma": {"type": "string"},
                    "meaning_zh": {"type": "string"},
                    "meaning_en": {"type": "string"},
                    "level": {"type": "string"},
                    "sentence_id": {"type": "string"},
                    "reason": {"type": "string"},
                },
                "required": ["word", "lemma", "meaning_zh", "meaning_en", "level", "sentence_id", "reason"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["summary_zh", "summary_en", "key_points", "difficult_words"],
    "additionalProperties": False,
}


def required_env(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value:
        raise RuntimeError(f"missing {name}")
    return value


def prompt(title: str, level: str, source_language: str, transcript: list[dict[str, Any]]) -> str:
    rows = [
        {"sentence_id": row["id"], "start_ms": row["start_ms"], "text": row["english"]}
        for row in transcript
    ]
    normalized_language = source_language.lower()
    language_name = "German" if normalized_language.startswith("de") or "german" in normalized_language else "English"
    return f"""You are a {language_name}-learning editor. Analyze this {language_name} podcast transcript.
Episode: {title}
Source language: {language_name}
Learner level: {level or 'B1-C1'}

Return concise Chinese and English summaries, 3-6 Chinese key points, and 10-25 useful difficult
words or phrases appropriate for the learner level. Exclude names, places, numbers, URLs, basic
words, and transcription errors. Preserve useful multi-word phrases. The selected word must occur
verbatim in its referenced sentence. Use the supplied sentence_id exactly; never invent one.
Provide a concise Chinese definition in meaning_zh and a clear learner-friendly English definition
in meaning_en. Reasons must be concise Chinese. Deduplicate by lowercase lemma and rank by learning
value. You must return every required field in the following JSON Schema, with non-empty summaries,
3-6 key points, and 10-25 difficult words. Return JSON only.

Required JSON Schema:
{json.dumps(OUTPUT_SCHEMA, ensure_ascii=False)}

Transcript JSON:
{json.dumps(rows, ensure_ascii=False)}"""


def extract_response_text(payload: dict[str, Any]) -> str:
    if isinstance(payload.get("output_text"), str):
        return payload["output_text"]
    for item in payload.get("output", []):
        for content in item.get("content", []):
            if isinstance(content.get("text"), str):
                return content["text"]
    raise RuntimeError("AI response contained no output text")


def parse_ai_json(text: str) -> dict[str, Any]:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        lines = cleaned.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        cleaned = "\n".join(lines).strip()
    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start >= 0 and end > start:
        cleaned = cleaned[start:end + 1]
    result = json.loads(cleaned)
    if not isinstance(result, dict):
        raise RuntimeError("AI response root must be a JSON object")
    return result


def call_ai(message: str) -> tuple[dict[str, Any], str]:
    provider = (os.getenv("AI_PROVIDER") or "openai").strip().lower()
    api_key = required_env("AI_API_KEY")
    model = required_env("AI_MODEL")
    timeout = float(os.getenv("AI_TIMEOUT_SECONDS") or "120")
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}

    last_error: Exception = RuntimeError("AI request was not attempted")
    for attempt in range(1, 4):
        try:
            if provider == "openai":
                base_url = (os.getenv("AI_BASE_URL") or "https://api.openai.com/v1").rstrip("/")
                response = httpx.post(
                    f"{base_url}/responses",
                    headers=headers,
                    json={
                        "model": model,
                        "input": message,
                        "text": {"format": {"type": "json_schema", "name": "podcast_insights", "strict": True, "schema": OUTPUT_SCHEMA}},
                    },
                    timeout=timeout,
                )
                response.raise_for_status()
                text = extract_response_text(response.json())
            elif provider == "openai_compatible":
                base_url = required_env("AI_BASE_URL").rstrip("/")
                response = httpx.post(
                    f"{base_url}/chat/completions",
                    headers=headers,
                    json={
                        "model": model,
                        "messages": [{"role": "user", "content": message}],
                        "response_format": {"type": "json_object"},
                        "temperature": 0.1,
                    },
                    timeout=timeout,
                )
                response.raise_for_status()
                text = response.json()["choices"][0]["message"]["content"]
            else:
                raise RuntimeError(f"unsupported AI_PROVIDER: {provider}")
            return parse_ai_json(text), model
        except (json.JSONDecodeError, KeyError, RuntimeError, httpx.HTTPError) as error:
            last_error = error
            if attempt < 3:
                print(f"AI response attempt {attempt} failed ({error}); retrying...", file=sys.stderr)
                time.sleep(attempt)
    raise RuntimeError(f"AI response failed after 3 attempts: {last_error}")


def validate_result(result: dict[str, Any], sentences: list[dict[str, Any]]) -> dict[str, Any]:
    if not str(result.get("summary_zh", "")).strip() or not str(result.get("summary_en", "")).strip():
        raise RuntimeError("AI returned an empty summary")
    if not isinstance(result.get("key_points"), list) or not result["key_points"]:
        raise RuntimeError("AI returned no key points")
    by_id = {row["id"]: row for row in sentences}
    seen: set[str] = set()
    valid_words: list[dict[str, Any]] = []
    for candidate in result.get("difficult_words", []):
        sentence = by_id.get(str(candidate.get("sentence_id", "")))
        lemma = str(candidate.get("lemma", "")).strip().lower()
        word = str(candidate.get("word", "")).strip()
        meaning_zh = str(candidate.get("meaning_zh", "")).strip()
        meaning_en = str(candidate.get("meaning_en", "")).strip()
        if not sentence or not lemma or lemma in seen or not meaning_zh or not meaning_en:
            continue
        if word.lower() not in sentence["english"].lower():
            continue
        seen.add(lemma)
        valid_words.append({
            **candidate,
            "word": word,
            "lemma": lemma,
            "sentence": sentence["english"],
            "start_ms": sentence["start_ms"],
        })
    result["difficult_words"] = valid_words[:25]
    if not result["difficult_words"]:
        raise RuntimeError("AI difficult words did not match any supplied transcript sentence")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate AI summaries and difficult words")
    parser.add_argument("--podcast-name")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--include-unpublished",
        action="store_true",
        help="Also process imported/selected episodes that are not visible in the app",
    )
    args = parser.parse_args()

    load_dotenv(BACKEND_DIR / ".env")
    if not (os.getenv("AI_API_KEY") or "").strip():
        print("AI insights skipped: AI_API_KEY is not configured")
        return 0

    rest_url = required_env("SUPABASE_URL").rstrip("/") + "/rest/v1"
    service_key = required_env("SUPABASE_SERVICE_ROLE_KEY")
    headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}
    schema_probe = httpx.get(
        f"{rest_url}/episode_difficult_words",
        headers=headers,
        params={"select": "meaning_zh,meaning_en", "limit": "1"},
        timeout=30,
    )
    if not schema_probe.is_success:
        raise RuntimeError(
            "podcast bilingual columns are unavailable; run "
            "supabase/sql/podcast_bilingual_word_meanings.sql first"
        )
    params: dict[str, str] = {
        "transcript_status": "eq.ready",
        "select": "id,title,podcast:podcasts(name,level,language)",
        "order": "publish_date.desc.nullslast",
        "limit": str(max(1, args.limit)),
    }
    if not args.include_unpublished:
        params["editorial_status"] = "eq.published"
    if args.podcast_name:
        params["select"] = "id,title,podcast:podcasts!inner(name,level,language)"
        params["podcast.name"] = f"eq.{args.podcast_name}"

    episodes_response = httpx.get(f"{rest_url}/episodes", headers=headers, params=params, timeout=30)
    episodes_response.raise_for_status()
    episodes = episodes_response.json()

    for episode in episodes:
        episode_id = episode["id"]
        if not args.force:
            existing = httpx.get(
                f"{rest_url}/episode_ai_insights",
                headers=headers,
                params={"episode_id": f"eq.{episode_id}", "select": "episode_id,prompt_version", "limit": "1"},
                timeout=30,
            )
            existing.raise_for_status()
            existing_rows = existing.json()
            if existing_rows and existing_rows[0].get("prompt_version") == PROMPT_VERSION:
                continue

        sentence_response = httpx.get(
            f"{rest_url}/episode_sentences",
            headers=headers,
            params={
                "episode_id": f"eq.{episode_id}",
                "select": "id,start_ms,english",
                "order": "sequence.asc",
            },
            timeout=30,
        )
        sentence_response.raise_for_status()
        sentences = sentence_response.json()
        if not sentences:
            continue

        podcast = episode.get("podcast") or {}
        result, model = call_ai(prompt(
            episode["title"],
            podcast.get("level") or "",
            podcast.get("language") or "en",
            sentences,
        ))
        result = validate_result(result, sentences)
        insight_row = {
            "episode_id": episode_id,
            "summary_zh": result.get("summary_zh", ""),
            "summary_en": result.get("summary_en", ""),
            "key_points": result.get("key_points", []),
            "model": model,
            "prompt_version": PROMPT_VERSION,
        }
        upsert = httpx.post(
            f"{rest_url}/episode_ai_insights",
            headers={**headers, "Prefer": "resolution=merge-duplicates"},
            params={"on_conflict": "episode_id"},
            json=insight_row,
            timeout=30,
        )
        upsert.raise_for_status()

        delete = httpx.delete(
            f"{rest_url}/episode_difficult_words",
            headers=headers,
            params={"episode_id": f"eq.{episode_id}"},
            timeout=30,
        )
        delete.raise_for_status()
        word_rows = [{
            "episode_id": episode_id,
            "sentence_id": word["sentence_id"],
            "word": word["word"],
            "lemma": word["lemma"],
            # Keep the legacy field populated for older app versions.
            "meaning": word["meaning_zh"],
            "meaning_zh": word["meaning_zh"],
            "meaning_en": word["meaning_en"],
            "cefr_level": word["level"],
            "sentence": word["sentence"],
            "start_ms": word["start_ms"],
            "reason": word["reason"],
            "sequence": index,
        } for index, word in enumerate(result["difficult_words"])]
        if word_rows:
            insert = httpx.post(
                f"{rest_url}/episode_difficult_words", headers=headers, json=word_rows, timeout=30
            )
            insert.raise_for_status()
        print(f"Generated AI insights: {episode['title']} ({len(word_rows)} words)")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, httpx.HTTPError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
