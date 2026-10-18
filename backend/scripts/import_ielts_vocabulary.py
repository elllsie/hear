#!/usr/bin/env python3
"""Import the IELTS XLS word list and enrich missing phonetics/examples with AI."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import httpx
import xlrd
from dotenv import load_dotenv


ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "backend"
DEFAULT_XLS = ROOT / "docs" / "雅思词汇9400词EXCEL版-顺序版.xls"
DEFAULT_OUTPUT = ROOT / "听会儿" / "data" / "IELTS_9400.json"
KAOYAN_PATH = ROOT / "听会儿" / "data" / "KaoYan_2.json"


def required_env(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value:
        raise RuntimeError(f"missing {name}")
    return value


def parsed(text: str) -> dict[str, Any]:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = "\n".join(cleaned.splitlines()[1:-1]).strip()
    start, end = cleaned.find("{"), cleaned.rfind("}")
    return json.loads(cleaned[start:end + 1] if start >= 0 and end > start else cleaned)


def response_text(payload: dict[str, Any]) -> str:
    if isinstance(payload.get("output_text"), str):
        return payload["output_text"]
    for item in payload.get("output", []):
        for content in item.get("content", []):
            if isinstance(content.get("text"), str):
                return content["text"]
    raise RuntimeError("AI response contained no output text")


def call_ai(message: str) -> dict[str, Any]:
    provider = (os.getenv("AI_PROVIDER") or "openai").strip().lower()
    base = (os.getenv("AI_BASE_URL") or "https://api.openai.com/v1").rstrip("/")
    headers = {"Authorization": f"Bearer {required_env('AI_API_KEY')}", "Content-Type": "application/json"}
    model = required_env("AI_MODEL")
    timeout = float(os.getenv("AI_TIMEOUT_SECONDS") or "180")
    last_error: Exception = RuntimeError("not attempted")
    for attempt in range(1, 5):
        try:
            if provider == "openai":
                response = httpx.post(
                    f"{base}/responses", headers=headers,
                    json={"model": model, "input": message}, timeout=timeout,
                )
                response.raise_for_status()
                return parsed(response_text(response.json()))
            if provider == "openai_compatible":
                response = httpx.post(
                    f"{base}/chat/completions", headers=headers,
                    json={
                        "model": model,
                        "messages": [{"role": "user", "content": message}],
                        "response_format": {"type": "json_object"},
                        "temperature": 0.1,
                    }, timeout=timeout,
                )
                response.raise_for_status()
                return parsed(response.json()["choices"][0]["message"]["content"])
            raise RuntimeError(f"unsupported AI_PROVIDER: {provider}")
        except (httpx.HTTPError, json.JSONDecodeError, KeyError, RuntimeError) as error:
            last_error = error
            if attempt < 4:
                time.sleep(attempt * 2)
    raise RuntimeError(f"AI enrichment failed: {last_error}")


def prompt(rows: list[dict[str, Any]]) -> str:
    source = [{"id": row["id"], "word": row["text"], "meaningZh": row["meaningZh"]} for row in rows]
    return f"""You are editing a high-quality IELTS vocabulary book for Chinese learners.
For every supplied English headword, provide:
1. phonetic: one standard IPA pronunciation wrapped in forward slashes; prefer mainstream British pronunciation.
2. exampleEn: one natural, concise English sentence that clearly demonstrates the supplied Chinese meaning.
3. exampleZh: an accurate, natural Simplified Chinese translation of exampleEn.
Do not change, omit, or reorder ids. Do not invent a different word. Avoid names, politics, unsafe content,
and overly complex sentences. Return JSON only.
Input: {json.dumps(source, ensure_ascii=False)}
Schema: {{"items":[{{"id":"supplied id","phonetic":"/IPA/","exampleEn":"...","exampleZh":"..."}}]}}"""


def import_xls(path: Path, kaoyan: list[dict[str, Any]]) -> list[dict[str, Any]]:
    known = {str(row.get("text", "")).strip().casefold(): row for row in kaoyan}
    sheet = xlrd.open_workbook(str(path)).sheet_by_index(0)
    rows: list[dict[str, Any]] = []
    for index in range(sheet.nrows):
        word = str(sheet.cell_value(index, 1)).strip()
        meaning = str(sheet.cell_value(index, 2)).strip()
        if not word:
            continue
        reused = known.get(word.casefold(), {})
        example_en = str(reused.get("exampleEn") or reused.get("example") or "").strip()
        example_zh = str(reused.get("exampleZh") or "").strip()
        rows.append({
            "id": str(index + 1),
            "text": word,
            "article": "",
            "phonetic": str(reused.get("phonetic") or "").strip(),
            "meaning": meaning,
            "meaningZh": meaning,
            "meaningEn": "",
            "example": example_en,
            "exampleZh": example_zh,
            "exampleEn": example_en,
            "source": "IELTS_9400",
        })
    return rows


def complete(row: dict[str, Any]) -> bool:
    return all(str(row.get(key) or "").strip() for key in ("phonetic", "exampleEn", "exampleZh"))


def write_json(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def validate_result(result: dict[str, Any], rows: list[dict[str, Any]]) -> dict[str, dict[str, str]]:
    expected = {str(row["id"]) for row in rows}
    values: dict[str, dict[str, str]] = {}
    for item in result.get("items", []):
        key = str(item.get("id", ""))
        fields = {name: str(item.get(name, "")).strip() for name in ("phonetic", "exampleEn", "exampleZh")}
        if key in expected and all(fields.values()):
            if not fields["phonetic"].startswith("/"):
                fields["phonetic"] = f"/{fields['phonetic'].strip('/')}/"
            values[key] = fields
    missing = expected - values.keys()
    if missing:
        raise RuntimeError(f"AI omitted or returned invalid data for {len(missing)} words")
    return values


def enrich(rows: list[dict[str, Any]], output: Path, workers: int, batch_size: int) -> int:
    pending = [row for row in rows if not complete(row)]
    if not pending:
        print("All IELTS entries already enriched")
        return 0
    batches = [pending[start:start + batch_size] for start in range(0, len(pending), batch_size)]
    by_id = {str(row["id"]): row for row in rows}
    failed: list[list[dict[str, Any]]] = []
    completed = 0
    with ThreadPoolExecutor(max_workers=max(1, min(workers, 10))) as pool:
        futures = {pool.submit(call_ai, prompt(batch)): batch for batch in batches}
        for number, future in enumerate(as_completed(futures), 1):
            batch = futures[future]
            try:
                values = validate_result(future.result(), batch)
                for row_id, fields in values.items():
                    row = by_id[row_id]
                    row.update(fields)
                    row["example"] = fields["exampleEn"]
                completed += len(values)
                write_json(output, rows)
            except Exception as error:
                failed.append(batch)
                print(f"batch failed ({len(batch)} words): {error}", file=sys.stderr, flush=True)
            if number % 10 == 0 or number == len(batches):
                print(f"progress batches={number}/{len(batches)} enriched={completed} failed_batches={len(failed)}", flush=True)
    if failed:
        retry_rows = [row for batch in failed for row in batch if not complete(row)]
        print(f"retrying {len(retry_rows)} words with smaller batches", flush=True)
        return enrich(rows, output, workers=max(1, workers // 2), batch_size=max(5, batch_size // 2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xls", default=str(DEFAULT_XLS))
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=25)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    load_dotenv(BACKEND / ".env")
    output = Path(args.output)
    kaoyan = json.loads(KAOYAN_PATH.read_text(encoding="utf-8"))
    if output.is_file():
        rows = json.loads(output.read_text(encoding="utf-8"))
    else:
        rows = import_xls(Path(args.xls), kaoyan)
        write_json(output, rows)
    print(f"IELTS rows={len(rows)} complete={sum(complete(row) for row in rows)} pending={sum(not complete(row) for row in rows)}")
    if args.prepare_only:
        return 0
    required_env("AI_API_KEY")
    required_env("AI_MODEL")
    return enrich(rows, output, workers=args.workers, batch_size=max(5, min(args.batch_size, 30)))


if __name__ == "__main__":
    raise SystemExit(main())
