#!/usr/bin/env python3
"""Generate contextual, learner-friendly Chinese podcast subtitles with AI."""
from __future__ import annotations
import argparse, json, os, sys, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any
import httpx
from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parents[1]
PROMPT_VERSION = "podcast-translation-v1-contextual-zh"

def required_env(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value: raise RuntimeError(f"missing {name}")
    return value

def prompt(title: str, language: str, rows: list[dict[str, Any]]) -> str:
    source = "German" if language.lower().startswith("de") else "English"
    data = [{"id": row["id"], "text": row["english"]} for row in rows]
    return f"""You are an expert Chinese editor for {source} learners. Translate every podcast
subtitle into natural, concise Simplified Chinese that is easy to understand. Use surrounding
sentences to resolve pronouns, idioms, jokes, discourse markers, and implied meaning. Preserve tone
and facts. Do not add explanations or information. Never merge, omit, or reorder sentences. Return
exactly one translation for every supplied id. Episode: {title}. Version: {PROMPT_VERSION}.
Input JSON: {json.dumps(data, ensure_ascii=False)}
Return JSON only: {{"translations":[{{"id":"supplied id","chinese":"clear translation"}}]}}"""

def parsed(text: str) -> dict[str, Any]:
    cleaned = text.strip()
    if cleaned.startswith("```"): cleaned = "\n".join(cleaned.splitlines()[1:-1]).strip()
    start, end = cleaned.find("{"), cleaned.rfind("}")
    value = json.loads(cleaned[start:end + 1] if start >= 0 and end > start else cleaned)
    if not isinstance(value, dict): raise RuntimeError("AI response root must be an object")
    return value

def response_text(payload: dict[str, Any]) -> str:
    if isinstance(payload.get("output_text"), str): return payload["output_text"]
    for item in payload.get("output", []):
        for content in item.get("content", []):
            if isinstance(content.get("text"), str): return content["text"]
    raise RuntimeError("AI response contained no output text")

def call_ai(message: str) -> dict[str, Any]:
    provider = (os.getenv("AI_PROVIDER") or "openai").strip().lower()
    base = (os.getenv("AI_BASE_URL") or "https://api.openai.com/v1").rstrip("/")
    headers = {"Authorization": f"Bearer {required_env('AI_API_KEY')}", "Content-Type": "application/json"}
    model, timeout = required_env("AI_MODEL"), float(os.getenv("AI_TIMEOUT_SECONDS") or "180")
    last_error: Exception = RuntimeError("not attempted")
    for attempt in range(1, 4):
        try:
            if provider == "openai":
                result = httpx.post(f"{base}/responses", headers=headers,
                    json={"model": model, "input": message}, timeout=timeout)
                result.raise_for_status(); return parsed(response_text(result.json()))
            if provider == "openai_compatible":
                result = httpx.post(f"{base}/chat/completions", headers=headers, json={"model": model,
                    "messages": [{"role": "user", "content": message}],
                    "response_format": {"type": "json_object"}, "temperature": 0.1}, timeout=timeout)
                result.raise_for_status(); return parsed(result.json()["choices"][0]["message"]["content"])
            raise RuntimeError(f"unsupported AI_PROVIDER: {provider}")
        except (httpx.HTTPError, json.JSONDecodeError, KeyError, RuntimeError) as error:
            last_error = error
            if attempt < 3: time.sleep(attempt * 2)
    raise RuntimeError(f"AI translation failed after 3 attempts: {last_error}")

def validate(
    result: dict[str, Any], rows: list[dict[str, Any]], require_complete: bool = True
) -> dict[str, str]:
    expected = {str(row["id"]) for row in rows}; values: dict[str, str] = {}
    for item in result.get("translations", []):
        key, value = str(item.get("id", "")), str(item.get("chinese", "")).strip()
        if key in expected and value: values[key] = value
    if require_complete and expected - values.keys():
        raise RuntimeError(f"AI omitted {len(expected - values.keys())} translations")
    return values

def translate_complete(title: str, language: str, rows: list[dict[str, Any]]) -> dict[str, str]:
    """Retry only omitted sentence IDs instead of rejecting a whole translated batch."""
    remaining = rows
    values: dict[str, str] = {}
    for _ in range(3):
        partial = validate(call_ai(prompt(title, language, remaining)), remaining, require_complete=False)
        values.update(partial)
        remaining = [row for row in remaining if str(row["id"]) not in values]
        if not remaining:
            return values
    raise RuntimeError(f"AI omitted {len(remaining)} translations after targeted retries")

def main() -> int:
    parser = argparse.ArgumentParser(description="Generate contextual AI Chinese subtitles")
    parser.add_argument("--podcast-name"); parser.add_argument("--limit", type=int, default=1000)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--force", action="store_true", help="Replace existing translations")
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--batch-size", type=int, default=40)
    args = parser.parse_args(); load_dotenv(BACKEND_DIR / ".env")
    rest = required_env("SUPABASE_URL").rstrip("/") + "/rest/v1"
    key = required_env("SUPABASE_SERVICE_ROLE_KEY"); required_env("AI_API_KEY"); required_env("AI_MODEL")
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    with httpx.Client(base_url=rest, headers=headers, timeout=60) as db:
        params = {"transcript_status": "eq.ready", "select": "id,title,podcast_id,podcast:podcasts(language)",
                  "order": "publish_date.desc.nullslast", "limit": str(min(max(args.limit, 1), 5000)),
                  "offset": str(max(args.offset, 0))}
        if args.podcast_name:
            show = db.get("/podcasts", params={"name": f"eq.{args.podcast_name}", "select": "id", "limit": "1"}); show.raise_for_status()
            if not show.json(): raise RuntimeError(f"Podcast not found: {args.podcast_name}")
            params["podcast_id"] = f"eq.{show.json()[0]['id']}"
        episodes = db.get("/episodes", params=params); episodes.raise_for_status(); episodes = episodes.json()
        updated = failed = 0
        for number, episode in enumerate(episodes, 1):
            sentence_params = {"episode_id": f"eq.{episode['id']}", "select": "id,english,chinese,sequence",
                               "order": "sequence.asc", "limit": "10000"}
            if not args.force: sentence_params["chinese"] = "is.null"
            response = db.get("/episode_sentences", params=sentence_params); response.raise_for_status(); rows = response.json()
            if not rows: print(f"[{number}/{len(episodes)}] Up to date: {episode['title']}", flush=True); continue
            try:
                language = (episode.get("podcast") or {}).get("language") or "en"
                batch_size = max(5, min(args.batch_size, 40))
                batches = [rows[start:start + batch_size] for start in range(0, len(rows), batch_size)]
                completed: list[dict[str, str]] = []
                with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 10))) as pool:
                    futures = {
                        pool.submit(translate_complete, episode["title"], language, batch): batch
                        for batch in batches
                    }
                    for future in as_completed(futures):
                        completed.append(future.result())
                for translations in completed:
                    for sentence_id, chinese in translations.items():
                        db.patch("/episode_sentences", params={"id": f"eq.{sentence_id}"}, json={"chinese": chinese}).raise_for_status(); updated += 1
                print(f"[{number}/{len(episodes)}] AI translated: {episode['title']} ({len(rows)})", flush=True)
            except Exception as error:
                failed += 1; print(f"[{number}/{len(episodes)}] FAILED: {episode['title']}: {error}", file=sys.stderr, flush=True)
        print(f"AI Chinese sentences updated: {updated}; failed episodes: {failed}", flush=True)
        return 1 if failed else 0

if __name__ == "__main__": raise SystemExit(main())
