from __future__ import annotations

import json
import re
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$")


def now():
    return datetime.now(timezone.utc).isoformat()


def component(value):
    value = str(value)
    if not SAFE.fullmatch(value):
        raise ValueError("标识只能包含字母、数字、下划线和连字符，最多 80 位")
    return value


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


class Store:
    def __init__(self, state):
        self.state = Path(state)
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.state.chmod(0o700)
        self.lock = threading.RLock()
        with self.connect() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS jobs (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL,
              payload TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
              created TEXT NOT NULL, updated TEXT NOT NULL, result TEXT, error TEXT);
            CREATE TABLE IF NOT EXISTS flags (
              book TEXT NOT NULL, word_id TEXT NOT NULL, kind TEXT NOT NULL,
              status TEXT NOT NULL, note TEXT NOT NULL, updated TEXT NOT NULL,
              PRIMARY KEY(book,word_id,kind));
            CREATE TABLE IF NOT EXISTS books (
              id TEXT PRIMARY KEY, title TEXT NOT NULL, language TEXT NOT NULL,
              updated TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS articles (
              id TEXT PRIMARY KEY, title TEXT NOT NULL, text TEXT NOT NULL,
              result TEXT, updated TEXT NOT NULL);
            ''')
            db.execute("UPDATE jobs SET status='interrupted',error='后台已重启，请检查结果后重试',updated=? WHERE status='running'", (now(),))

    def connect(self):
        db = sqlite3.connect(self.state / "admin.sqlite3", timeout=30)
        db.row_factory = sqlite3.Row
        return db

    def query(self, sql, args=()):
        with self.connect() as db:
            return [dict(r) for r in db.execute(sql, args)]

    def execute(self, sql, args=()):
        with self.connect() as db:
            db.execute(sql, args)

    def job(self, job_id):
        rows = self.query("SELECT * FROM jobs WHERE id=?", (component(job_id),))
        if not rows:
            raise ValueError("任务不存在")
        row = rows[0]
        row["payload"] = json.loads(row["payload"])
        row["result"] = json.loads(row["result"]) if row["result"] else None
        return row

    def books(self):
        titles = {"A1": "德语 A1", "A2": "德语 A2", "B1": "德语 B1", "12yue": "德语 · 12月", "KaoYan_2": "考研英语", "IELTS_9400": "雅思英语"}
        result = {}
        for key, title in titles.items():
            if (ROOT / "听会儿" / "data" / f"{key}.json").exists():
                result[key] = {"id": key, "title": title, "language": "english" if key in ("KaoYan_2", "IELTS_9400") else "german", "bundled": True}
        for row in self.query("SELECT * FROM books ORDER BY updated DESC"):
            result[row["id"]] = {**row, "bundled": row["id"] in result}
        return list(result.values())

    def book(self, key):
        component(key)
        for row in self.books():
            if row["id"] == key:
                return row
        raise ValueError("词书不存在")

    def book_path(self, key):
        self.book(key)
        draft = self.state / "books" / f"{key}.json"
        return draft if draft.exists() else ROOT / "听会儿" / "data" / f"{key}.json"

    def words(self, key):
        return json.loads(self.book_path(key).read_text(encoding="utf-8"))

    def word(self, key, word_id):
        for row in self.words(key):
            if str(row["id"]) == str(word_id):
                return row
        raise ValueError("单词不存在")

    @staticmethod
    def validate_words(rows):
        if not isinstance(rows, list) or not 1 <= len(rows) <= 100000:
            raise ValueError("词书必须是 1–100000 条记录的 JSON 数组")
        seen = set()
        cleaned = []
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                raise ValueError(f"第 {index + 1} 行不是对象")
            item = dict(row)
            for key in ("id", "text"):
                if not isinstance(item.get(key), (str, int)) or not str(item[key]).strip():
                    raise ValueError(f"第 {index + 1} 行缺少 {key}")
                item[key] = str(item[key]).strip()
            if item["id"] in seen:
                raise ValueError(f"重复的单词 ID：{item['id']}")
            if len(item["id"]) > 100 or len(item["text"]) > 300:
                raise ValueError("单词 ID 或文本过长")
            for key in ("meaning", "meaningZh", "meaningEn", "phonetic", "article", "example", "exampleZh", "exampleEn", "source"):
                if key in item and (not isinstance(item[key], str) or len(item[key]) > 10000):
                    raise ValueError(f"{key} 必须是长度不超过 10000 的文本")
            seen.add(item["id"])
            cleaned.append(item)
        return cleaned

    def save_book(self, key, title, language, rows):
        component(key)
        if language not in ("english", "german"):
            raise ValueError("只支持英语和德语词书")
        if not title.strip() or len(title) > 200:
            raise ValueError("请填写词书名称（最多 200 字）")
        rows = self.validate_words(rows)
        with self.lock:
            destination = self.state / "books" / f"{key}.json"
            if destination.exists():
                write_json(self.state / "book-history" / key / f"{now().replace(':', '-')}.json", self.words(key))
            write_json(destination, rows)
            self.execute("INSERT INTO books VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,language=excluded.language,updated=excluded.updated", (key, title.strip(), language, now()))
        return len(rows)

    def sources(self):
        path = self.state / "sources.json"
        if not path.exists():
            default = ROOT / "backend" / "config" / "rss_sources.json"
            write_json(path, json.loads(default.read_text()) if default.exists() else [])
        return json.loads(path.read_text())
