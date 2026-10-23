#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import signal
import sqlite3
import threading
import time
import uuid
import webbrowser
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import httpx

from .operations import Queue, ROOT, PYTHON, KOKORO_PYTHON, audio_row, bounded_int, credentials, environment, local_audio, redact, remote_get
from .store import Store, component, now, write_json

STATIC = Path(__file__).parent / "static"


def password_hash(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 600000).hex()


class Application:
    def __init__(self, state, worker=True):
        self.store = Store(state)
        self.queue = Queue(self.store, start=worker)
        self.sessions = {}
        self.auth_lock = threading.Lock()
        self.failures = []
        self.bootstrap = secrets.token_urlsafe(32)
        self.bootstrap_expires = time.time() + 300
        self.initial_password = None
        path = self.store.state / "credentials.json"
        if not path.exists():
            self.initial_password = secrets.token_urlsafe(18)
            self.set_password(self.initial_password)
        self.auth = json.loads(path.read_text())

    def set_password(self, password):
        if not isinstance(password, str) or not 12 <= len(password) <= 256:
            raise ValueError("密码长度需为 12–256 位")
        salt = secrets.token_hex(16)
        self.auth = {"salt": salt, "hash": password_hash(password, salt)}
        path = self.store.state / "credentials.json"
        write_json(path, self.auth)
        path.chmod(0o600)

    def login(self, password=None, token=None):
        with self.auth_lock:
            self.failures = [t for t in self.failures if t > time.time() - 60]
            if len(self.failures) >= 8:
                raise ValueError("尝试次数过多，请 1 分钟后重试")
            is_token = isinstance(token, str) and bool(self.bootstrap) and time.time() < self.bootstrap_expires and secrets.compare_digest(token, self.bootstrap)
            valid = is_token or (isinstance(password, str) and len(password) <= 256 and hmac.compare_digest(password_hash(password, self.auth["salt"]), self.auth["hash"]))
            if not valid:
                self.failures.append(time.time())
                raise ValueError("密码错误或启动链接已过期，请在启动终端查看密码")
            if is_token:
                self.bootstrap = ""
            session_id = secrets.token_urlsafe(32)
            self.sessions = {key: value for key, value in self.sessions.items() if value["expires"] > time.time()}
            session = {"csrf": secrets.token_urlsafe(32), "expires": time.time() + 12 * 3600}
            self.sessions[session_id] = session
            return session_id, session

    def summary(self):
        jobs = self.store.query("SELECT id,title,kind,status,created,updated,error FROM jobs ORDER BY created DESC LIMIT 8")
        return {
            "books": len(self.store.books()),
            "flags": self.store.query("SELECT count(*) AS n FROM flags WHERE status='open'")[0]["n"],
            "pending": self.store.query("SELECT count(*) AS n FROM jobs WHERE status IN ('queued','running')")[0]["n"],
            "failed": self.store.query("SELECT count(*) AS n FROM jobs WHERE status IN ('failed','interrupted')")[0]["n"],
            "jobs": jobs,
        }

    def list_words(self, query):
        key = query.get("book", "KaoYan_2")
        needle = query.get("q", "").casefold().strip()
        flags = {r["word_id"]: r for r in self.store.query("SELECT * FROM flags WHERE book=? AND kind=?", (key, query.get("kind", "word")))}
        rows = self.store.words(key)
        meta = self.store.book(key)
        if needle:
            rows = [row for row in rows if needle in (str(row["text"]) + " " + str(row.get("meaningZh", row.get("meaning", ""))) + " " + str(row["id"])).casefold()]
        if query.get("flagged") == "1":
            rows = [row for row in rows if flags.get(str(row["id"]), {}).get("status") == "open"]
        total = len(rows)
        offset = bounded_int(query.get("offset", 0), 0, 100000)
        limit = bounded_int(query.get("limit", 60), 1, 200)
        items = []
        for row in rows[offset:offset + limit]:
            item = {**row, "flag": flags.get(str(row["id"]))}
            try:
                item["has_local_audio"] = local_audio(audio_row(self.store, key, row["id"], query.get("kind", "word"), meta=meta, word=row)) is not None
            except ValueError:
                item["has_local_audio"] = False
            items.append(item)
        return {"items": items, "total": total, "offset": offset}

    def create_audio_job(self, data, audit=False):
        book = component(data.get("book", ""))
        ids = data.get("ids")
        if not isinstance(ids, list) or not ids or len(ids) > (1000 if audit else 100):
            raise ValueError("请选择单词；生成每批最多 100 个，检查最多 1000 个")
        if len(set(map(str, ids))) != len(ids):
            raise ValueError("单词列表重复")
        meta = self.store.book(book)
        by_id = {str(w["id"]): w for w in self.store.words(book)}
        if any(str(word_id) not in by_id for word_id in ids):
            raise ValueError("单词不存在")
        rows = [audio_row(self.store, book, str(word_id), data.get("audio_kind", "word"), meta=meta, word=by_id[str(word_id)]) for word_id in ids]
        # Shared meaning audio has one Storage object; do not publish it twice.
        rows = list({r["target_path"]: r for r in rows}.values())
        payload = {"rows": rows}
        if not audit:
            provider = data.get("provider", "kokoro")
            if provider not in ("kokoro", "edge", "gtts"):
                raise ValueError("不支持该语音引擎")
            if provider == "kokoro" and any(r["language"] == "zh-CN" for r in rows):
                raise ValueError("中文释义请选择 Edge 或 gTTS")
            try:
                speed = float(data.get("speed", 0.85))
            except (TypeError, ValueError):
                raise ValueError("语速无效")
            if not 0.6 <= speed <= 1.3:
                raise ValueError("语速必须在 0.6–1.3 之间")
            payload.update(provider=provider, speed=speed)
        action = "检查" if audit else "生成"
        return self.queue.enqueue("audio_audit" if audit else "audio_generate", f"{action} {self.store.book(book)['title']} · {len(rows)} 条音频", payload)

    def get(self, path, query):
        if path == "/api/summary":
            return self.summary()
        if path == "/api/settings":
            env = environment()
            return {"supabase": bool(env.get("SUPABASE_URL") and env.get("SUPABASE_SERVICE_ROLE_KEY")), "ai": bool(env.get("AI_API_KEY") and env.get("AI_MODEL")), "ai_model": env.get("AI_MODEL", "未配置"), "kokoro": KOKORO_PYTHON.exists(), "python": PYTHON.exists(), "state": str(self.store.state), "address": "仅本机 127.0.0.1", "cache": "App 音频缓存约每 1 小时刷新；需联网再次播放。"}
        if path == "/api/books":
            items = self.store.books()
            for row in items:
                row["count"] = len(self.store.words(row["id"]))
                row["draft"] = (self.store.state / "books" / f"{row['id']}.json").exists()
            return {"items": items}
        if path == "/api/words":
            return self.list_words(query)
        if path == "/api/word":
            return self.store.word(query["book"], query["id"])
        if path == "/api/flags":
            items = self.store.query("SELECT * FROM flags ORDER BY updated DESC LIMIT 1000")
            for row in items:
                try:
                    row["text"] = self.store.word(row["book"], row["word_id"])["text"]
                except ValueError:
                    row["text"] = "已移除词条 " + row["word_id"]
            return {"items": items}
        if path == "/api/jobs":
            return {"items": self.store.query("SELECT id,kind,title,status,created,updated,error FROM jobs ORDER BY created DESC LIMIT 200")}
        if path == "/api/job":
            job = self.store.job(query["id"])
            log = self.store.state / "jobs" / job["id"] / "task.log"
            job["log"] = log.read_text(encoding="utf-8", errors="replace")[-40000:] if log.exists() else "等待执行…"
            # Exclude potentially large article/book snapshots from every polling response.
            job["payload"] = {k: v for k, v in job["payload"].items() if k not in ("words", "article")}
            journal = self.store.state / "jobs" / job["id"] / "publication.json"
            job["can_rollback"] = (job["kind"] == "audio_publish" and journal.exists() and any(r["had_previous"] for r in json.loads(journal.read_text()))) or (job["kind"] == "book_publish" and (self.store.state / "jobs" / job["id"] / "catalog-before.json").exists())
            return job
        if path == "/api/sources":
            return {"items": self.store.sources()}
        if path == "/api/source-status":
            source = next((s for s in self.store.sources() if s["key"] == query.get("source")), None)
            if not source:
                raise ValueError("来源不存在")
            base, headers = credentials()
            response = httpx.get(base + "/rest/v1/podcasts", headers=headers, params={"name": "eq." + source["name"], "select": "id,name,rights_status", "limit": "2"}, timeout=30)
            response.raise_for_status()
            if len(response.json()) != 1:
                raise ValueError("请先同步该来源的 RSS 元数据，或检查线上是否存在同名来源")
            return response.json()[0]
        if path == "/api/episodes":
            return self.episodes(query)
        if path == "/api/episode":
            return self.episode(query["id"])
        if path == "/api/articles":
            return {"items": self.store.query("SELECT id,title,updated,result IS NOT NULL AS has_result FROM articles ORDER BY updated DESC")}
        if path == "/api/article":
            rows = self.store.query("SELECT * FROM articles WHERE id=?", (component(query["id"]),))
            if not rows:
                raise ValueError("文章不存在")
            row = rows[0]
            row["result"] = json.loads(row["result"]) if row["result"] else None
            return row
        raise ValueError("接口不存在")

    def episodes(self, query):
        source = next((s for s in self.store.sources() if s["key"] == query.get("source")), None)
        if not source:
            raise ValueError("请选择播客来源")
        base, headers = credentials()
        response = httpx.get(base + "/rest/v1/episodes", headers=headers, params={"select": "id,title,publish_date,duration_seconds,editorial_status,transcript_status,audio_status,validation_status,podcast:podcasts!inner(name)", "podcast.name": "eq." + source["name"], "order": "publish_date.desc.nullslast", "limit": "30"}, timeout=30)
        response.raise_for_status()
        return {"items": response.json()}

    def episode(self, episode_id):
        # Only canonical UUIDs reach database filters.
        episode_id = str(uuid.UUID(episode_id))
        base, headers = credentials()
        result = {}
        with httpx.Client(base_url=base + "/rest/v1", headers=headers, timeout=30) as client:
            for name, endpoint, params in (
                ("episode", "episodes", {"id": "eq." + episode_id, "select": "id,title,editorial_status,validation_error"}),
                ("sentences", "episode_sentences", {"episode_id": "eq." + episode_id, "select": "id,sequence,start_ms,end_ms,english,chinese", "order": "sequence.asc", "limit": "1000"}),
                ("insights", "episode_ai_insights", {"episode_id": "eq." + episode_id, "select": "summary_zh,summary_en,key_points", "limit": "1"}),
            ):
                response = client.get("/" + endpoint, params=params)
                response.raise_for_status()
                result[name] = response.json()
        return result

    @staticmethod
    def confirmed(data):
        if data.get("confirm") is not True:
            raise ValueError("该操作会修改线上数据，请先确认")

    def post(self, path, data):
        if path in ("/api/audio/generate", "/api/audio/audit"):
            return {"job_id": self.create_audio_job(data, path.endswith("audit"))}
        if path == "/api/flags":
            book, word_id, kind = component(data["book"]), str(data["id"]), data.get("kind", "word")
            self.store.word(book, word_id)
            if kind not in ("word", "meaningZh", "meaningEn") or data.get("status", "open") not in ("open", "resolved"):
                raise ValueError("标记类型或状态无效")
            note = str(data.get("note", ""))
            if len(note) > 2000:
                raise ValueError("备注最多 2000 字")
            self.store.execute("INSERT OR REPLACE INTO flags VALUES(?,?,?,?,?,?)", (book, word_id, kind, data.get("status", "open"), note, now()))
            return {"ok": True}
        if path == "/api/books/import-preview":
            words = self.store.validate_words(data.get("words"))
            return {"count": len(words), "sample": words[:5]}
        if path == "/api/books/import":
            key = component(data["id"])
            if any(b["id"] == key for b in self.store.books()):
                raise ValueError("该词书 ID 已存在；请使用新 ID，避免覆盖已有词书")
            count = self.store.save_book(key, data["title"], data["language"], data["words"])
            return {"count": count}
        if path == "/api/word/save":
            key = component(data["book"])
            with self.store.lock:
                meta = self.store.book(key)
                words = self.store.words(key)
                found = False
                for index, row in enumerate(words):
                    if str(row["id"]) == str(data["id"]):
                        if data.get("expected") != row:
                            raise ValueError("词条已被其他页面修改，请刷新后重试")
                        fields = {k: data["changes"][k] for k in ("text", "article", "phonetic", "meaningZh", "meaningEn", "exampleEn", "exampleZh") if k in data["changes"]}
                        words[index] = {**row, **fields}
                        if "meaningZh" in fields:
                            words[index]["meaning"] = fields["meaningZh"]
                        if "exampleEn" in fields:
                            words[index]["example"] = fields["exampleEn"]
                        found = True
                        break
                if not found:
                    raise ValueError("单词不存在")
                self.store.save_book(key, meta["title"], meta["language"], words)
            return {"ok": True}
        if path == "/api/audio/publish":
            self.confirmed(data)
            source = self.store.job(data["job_id"])
            if source["kind"] != "audio_generate" or source["status"] != "succeeded":
                raise ValueError("只能发布已成功生成的音频")
            items = source["result"]["items"]
            indexes = data.get("indexes", list(range(len(items))))
            if not isinstance(indexes, list) or not indexes or any(type(i) is not int or i < 0 or i >= len(items) for i in indexes):
                raise ValueError("发布选择无效")
            indexes = sorted(set(indexes))
            for index in indexes:
                row = items[index]
                if audio_row(self.store, row["book"], row["word_id"], row["kind"])["text"] != row["text"]:
                    raise ValueError("词条已修改，请重新生成")
            return {"job_id": self.queue.enqueue("audio_publish", "发布音频 · " + source["title"], {"source_job": source["id"], "indexes": indexes})}
        if path == "/api/rollback":
            self.confirmed(data)
            source = self.store.job(data["job_id"])
            if source["status"] not in ("succeeded", "failed", "interrupted"):
                raise ValueError("任务执行中不能回滚")
            if source["kind"] == "audio_publish":
                journal = self.store.state / "jobs" / source["id"] / "publication.json"
                if not journal.exists():
                    raise ValueError("没有发布备份")
                rows = [{k: v for k, v in row.items() if k != "had_previous"} for row in json.loads(journal.read_text()) if row["had_previous"]]
                if not rows:
                    raise ValueError("首次发布，没有旧音频可回滚")
                # Store only backed-up rows; partial publication can be rolled back too.
                return {"job_id": self.queue.enqueue("audio_rollback", "回滚 · " + source["title"], {"source_job": source["id"], "rollback_rows": rows})}
            if source["kind"] == "book_publish" and (self.store.state / "jobs" / source["id"] / "catalog-before.json").exists():
                return {"job_id": self.queue.enqueue("book_rollback", "回滚 · " + source["title"], {"source_job": source["id"]})}
            raise ValueError("该任务没有可回滚的发布备份")
        if path == "/api/books/publish":
            self.confirmed(data)
            meta = self.store.book(component(data["book"]))
            language = "en-us" if meta["language"] == "english" else "de-de"
            return {"job_id": self.queue.enqueue("book_publish", "发布词书 · " + meta["title"], {"book": meta["id"], "title": meta["title"], "language": meta["language"], "prefix": f"v2/words/{language}/{meta['id'].lower()}", "words": self.store.words(meta["id"])})}
        if path == "/api/job/retry":
            job = self.store.job(data["id"])
            if job["status"] not in ("failed", "interrupted", "cancelled"):
                raise ValueError("仅可重试失败、中断或已取消的任务")
            if job["kind"] in ("audio_publish", "audio_rollback", "book_publish", "book_rollback", "episode_publish"):
                raise ValueError("线上写入任务请检查当前状态后，从原内容重新发起，避免重复覆盖")
            return {"job_id": self.queue.enqueue(job["kind"], job["title"], job["payload"])}
        if path == "/api/job/cancel":
            with self.store.lock:
                job = self.store.job(data["id"])
                if job["status"] != "queued":
                    raise ValueError("仅可取消排队中的任务；运行中的任务请等待完成")
                self.store.execute("UPDATE jobs SET status='cancelled',updated=? WHERE id=?", (now(), job["id"]))
            return {"ok": True}
        if path == "/api/sources/save":
            source = data.get("source")
            if not isinstance(source, dict):
                raise ValueError("来源格式无效")
            component(source.get("key", ""))
            if source.get("category") not in ("easy", "thinking", "world", "future"):
                raise ValueError("来源分类无效")
            if source.get("language") not in ("en", "de"):
                raise ValueError("语言只支持 en / de")
            url = urlparse(source.get("rss_url", ""))
            if url.scheme not in ("https", "http") or not url.hostname or url.username or url.password:
                raise ValueError("RSS 地址必须是有效的 HTTP(S) 地址，不能包含密码")
            if not isinstance(source.get("name"), str) or not 1 <= len(source["name"].strip()) <= 200:
                raise ValueError("请填写来源名称")
            clean = {key: source.get(key, "") for key in ("key", "name", "rss_url", "category", "language", "level")}
            clean.update(is_active=True)
            with self.store.lock:
                sources = self.store.sources()
                if any(s["key"] == clean["key"] or s["name"] == clean["name"] for s in sources):
                    raise ValueError("来源 ID 或名称已存在")
                write_json(self.store.state / "sources.json", [*sources, clean])
            return {"ok": True}
        if path == "/api/podcast/run":
            action = data.get("action")
            if action not in ("preview", "sync", "probe", "timed", "transcribe", "translate", "ai", "validate"):
                raise ValueError("未知播客操作")
            source = next((s for s in self.store.sources() if s["key"] == data.get("source")), None)
            if not source:
                raise ValueError("来源不存在")
            if action != "preview":
                self.confirmed(data)
            limit = bounded_int(data.get("limit", 1), 1, 20)
            if action in ("ai", "translate") and not (environment().get("AI_API_KEY") and environment().get("AI_MODEL")):
                raise ValueError("尚未配置 AI_API_KEY / AI_MODEL")
            if type(data.get("force", False)) is not bool:
                raise ValueError("覆盖选项无效")
            return {"job_id": self.queue.enqueue("podcast", {"preview": "预览 RSS", "sync": "同步元数据", "probe": "检查音频", "timed": "导入时间轴字幕", "transcribe": "转写", "translate": "逐句翻译", "ai": "AI 总结", "validate": "校验节目"}[action] + " · " + source["name"], {"action": action, "source": source, "limit": limit, "force": data.get("force", False)})}
        if path == "/api/source-rights":
            self.confirmed(data)
            status = data.get("status")
            if status not in ("unknown", "reviewed", "approved", "rejected"):
                raise ValueError("来源状态无效")
            source = self.get("/api/source-status", {"source": data["source"]})
            return {"job_id": self.queue.enqueue("source_rights", "更新来源状态 · " + source["name"], {"source": source, "status": status})}
        if path == "/api/episode/publish":
            self.confirmed(data)
            episode_id = str(uuid.UUID(data["id"]))
            return {"job_id": self.queue.enqueue("episode_publish", "发布单集 · " + episode_id[:8], {"episode_id": episode_id})}
        if path == "/api/articles/save":
            article_id = component(data.get("id") or uuid.uuid4().hex)
            title, text = str(data.get("title", "")).strip(), str(data.get("text", "")).strip()
            if not 1 <= len(title) <= 300 or not 20 <= len(text) <= 60000:
                raise ValueError("请填写标题，正文为 20–60000 字")
            self.store.execute("INSERT INTO articles VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,text=excluded.text,result=CASE WHEN articles.text=excluded.text AND articles.title=excluded.title THEN articles.result ELSE NULL END,updated=excluded.updated", (article_id, title, text, None, now()))
            return {"id": article_id}
        if path == "/api/articles/generate":
            article = self.get("/api/article", {"id": data["id"]})
            article.pop("result", None)
            if not (environment().get("AI_API_KEY") and environment().get("AI_MODEL")):
                raise ValueError("尚未配置 AI_API_KEY / AI_MODEL")
            return {"job_id": self.queue.enqueue("article_ai", "总结文章 · " + article["title"], {"article": article})}
        if path == "/api/articles/result":
            article = self.get("/api/article", {"id": data["id"]})
            if article["result"] != data.get("expected"):
                raise ValueError("总结已更新，请刷新后再编辑")
            result = data.get("result")
            if not isinstance(result, dict) or not all(isinstance(result.get(k), str) and result[k].strip() for k in ("summary_zh", "summary_en")):
                raise ValueError("请填写中英文总结")
            if not isinstance(result.get("key_points"), list) or not all(isinstance(p, str) for p in result["key_points"]):
                raise ValueError("要点必须是文本数组")
            if not isinstance(result.get("difficult_words"), list) or not all(isinstance(w, dict) and all(isinstance(w.get(k), str) for k in ("word", "meaning_zh", "meaning_en")) for w in result["difficult_words"]):
                raise ValueError("词汇必须是含 word、meaning_zh、meaning_en 的对象数组")
            with self.store.lock:
                write_json(self.store.state / "article-history" / article["id"] / f"{time.time_ns()}.json", article)
                self.store.execute("UPDATE articles SET result=?,updated=? WHERE id=?", (json.dumps(result, ensure_ascii=False), now(), article["id"]))
            return {"ok": True}
        raise ValueError("接口不存在")

    def audio(self, query):
        if "job" in query:
            job = self.store.job(query["job"])
            if job["kind"] != "audio_generate" or job["status"] != "succeeded":
                raise ValueError("音频尚未生成完成")
            index = bounded_int(query.get("index", 0), 0, len(job["result"]["items"]) - 1)
            row = job["result"]["items"][index]
            path = self.store.state / "jobs" / job["id"] / "audio" / row["target_path"]
            return path.read_bytes()
        row = audio_row(self.store, query["book"], query["id"], query.get("kind", "word"))
        if query.get("version") == "online":
            content = remote_get(row)
            if content is None:
                raise ValueError("线上未找到该音频")
            return content
        path = local_audio(row)
        if not path:
            raise ValueError("本地没有该音频，可试听线上版本或重新生成")
        return path.read_bytes()


class Handler(BaseHTTPRequestHandler):
    server_version = "TingHuierLocal/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    @property
    def app(self):
        return self.server.app

    def respond(self, status, content, content_type="application/json; charset=utf-8", headers=None):
        if not isinstance(content, bytes):
            content = json.dumps(content, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(content)

    def valid_host(self):
        return self.headers.get("Host") == f"127.0.0.1:{self.server.server_port}"

    def session(self):
        try:
            cookie = SimpleCookie(self.headers.get("Cookie", ""))
            session_id = cookie["tinghuier_admin"].value if "tinghuier_admin" in cookie else ""
        except Exception:
            return None
        session = self.app.sessions.get(session_id)
        return session if session and session["expires"] > time.time() else None

    def do_GET(self):
        if not self.valid_host():
            return self.respond(403, {"error": "只允许通过 127.0.0.1 访问"})
        parsed = urlparse(self.path)
        path = parsed.path
        query = {k: v[-1] for k, v in parse_qs(parsed.query).items()}
        if path in ("/", "/app.js", "/style.css"):
            asset = STATIC / ({"/": "index.html"}.get(path, path[1:]))
            return self.respond(200, asset.read_bytes(), mimetypes.guess_type(str(asset))[0] or "text/plain")
        session = self.session()
        if not session:
            return self.respond(401, {"error": "请先登录"})
        try:
            if path == "/api/session":
                return self.respond(200, {"csrf": session["csrf"]})
            if path == "/api/audio":
                content = self.app.audio(query)
                # Support browser audio seeking for short word/meaning MP3s.
                range_value = self.headers.get("Range", "")
                if range_value:
                    match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_value)
                    if not match or not any(match.groups()):
                        return self.respond(416, b"", headers={"Content-Range": f"bytes */{len(content)}"})
                    left, right = match.groups()
                    start = int(left) if left else max(0, len(content) - int(right))
                    end = min(len(content) - 1, int(right)) if right and left else len(content) - 1
                    if start > end or start >= len(content):
                        return self.respond(416, b"", headers={"Content-Range": f"bytes */{len(content)}"})
                    return self.respond(206, content[start:end + 1], "audio/mpeg", {"Content-Range": f"bytes {start}-{end}/{len(content)}", "Accept-Ranges": "bytes"})
                return self.respond(200, content, "audio/mpeg", {"Accept-Ranges": "bytes"})
            if path == "/api/books/export":
                key = component(query["book"])
                content = json.dumps(self.app.store.words(key), ensure_ascii=False, indent=2).encode()
                return self.respond(200, content, "application/json; charset=utf-8", {"Content-Disposition": f'attachment; filename="{key}.json"'})
            return self.respond(200, self.app.get(path, query))
        except (ValueError, KeyError, FileNotFoundError) as error:
            self.respond(400, {"error": redact(str(error))})
        except Exception as error:
            self.respond(500, {"error": redact(str(error))})

    def do_POST(self):
        self.close_connection = True
        origin = f"http://127.0.0.1:{self.server.server_port}"
        if not self.valid_host() or self.headers.get("Origin") != origin:
            return self.respond(403, {"error": "请求来源无效"})
        if self.headers.get_content_type() != "application/json":
            return self.respond(415, {"error": "需要 JSON 请求"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 25 * 1024 * 1024:
                return self.respond(413, {"error": "请求大小需在 1 字节到 25 MB 之间"})
            self.connection.settimeout(30)
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError("请求必须是对象")
            path = urlparse(self.path).path
            if path == "/api/login":
                session_id, session = self.app.login(data.get("password"), data.get("token"))
                return self.respond(200, {"csrf": session["csrf"]}, headers={"Set-Cookie": f"tinghuier_admin={session_id}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200"})
            session = self.session()
            if not session:
                return self.respond(401, {"error": "登录已过期，请重新登录"})
            if not secrets.compare_digest(self.headers.get("X-CSRF-Token", ""), session["csrf"]):
                return self.respond(403, {"error": "请求校验失败，请刷新页面"})
            if path == "/api/logout":
                with self.app.auth_lock:
                    self.app.sessions = {key: value for key, value in self.app.sessions.items() if value is not session}
                return self.respond(200, {"ok": True}, headers={"Set-Cookie": "tinghuier_admin=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"})
            if path == "/api/password":
                old = data.get("current", "")
                if not isinstance(old, str) or len(old) > 256 or not hmac.compare_digest(password_hash(old, self.app.auth["salt"]), self.app.auth["hash"]):
                    raise ValueError("当前密码错误")
                with self.app.auth_lock:
                    self.app.set_password(data.get("password"))
                    self.app.sessions.clear()
                return self.respond(200, {"ok": True}, headers={"Set-Cookie": "tinghuier_admin=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"})
            return self.respond(200, self.app.post(path, data))
        except (ValueError, KeyError, TypeError, FileNotFoundError) as error:
            self.respond(400, {"error": redact(str(error))})
        except Exception as error:
            self.respond(500, {"error": redact(str(error))})


def main():
    parser = argparse.ArgumentParser(description="听会儿本地内容管理台")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--open", action="store_true")
    parser.add_argument("--reset-password", action="store_true")
    args = parser.parse_args()
    state = ROOT / "backend" / ".admin"
    # Lock before Store initialization so a second process cannot mark active jobs interrupted.
    import fcntl
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = (state / "server.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"管理后台已启动。打开 http://127.0.0.1:{args.port} 即可。")
        if args.open:
            webbrowser.open(f"http://127.0.0.1:{args.port}")
        return
    app = Application(state, worker=False)
    if args.reset_password:
        app.initial_password = secrets.token_urlsafe(18)
        app.set_password(app.initial_password)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.app = app
    app.queue = Queue(app.store)
    address = f"http://127.0.0.1:{args.port}"
    print(f"\n听会儿管理台：{address}", flush=True)
    if app.initial_password:
        print(f"首次登录密码（请保存）：{app.initial_password}", flush=True)
    print("仅本机可访问。关闭网页不会停止任务；关闭此终端会停止后台。\n", flush=True)
    if args.open:
        webbrowser.open(address + "/#login=" + app.bootstrap)
    try:
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n后台已停止。未完成任务会在下次启动时标记为中断。")
    finally:
        app.queue.shutdown()
        server.server_close()
        lock.close()


if __name__ == "__main__":
    main()
