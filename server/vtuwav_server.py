"""VTuWAV personal-use video job server.

Requires: pip install -U yt-dlp ; ffmpeg installed on PATH.
Only process videos you own or are authorized to save. No DRM decryption.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
import uuid
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from yt_dlp import YoutubeDL

HOST = os.getenv("VTUWAV_HOST", "127.0.0.1")
PORT = int(os.getenv("VTUWAV_PORT", "8787"))
KEY = os.environ.get("VTUWAV_API_KEY", "")
BASE = Path(os.getenv("VTUWAV_WORK_DIR", "./vtuwav_jobs")).resolve()
BASE.mkdir(parents=True, exist_ok=True)
JOBS: dict[str, dict] = {}
LOCK = threading.RLock()
MAX_ACTIVE = 1
TTL_SECONDS = 60 * 60
MAX_BODY = 8192
ALLOWED_DOMAINS = (
    "youtube.com", "youtu.be", "youtube-nocookie.com",
    "vimeo.com", "nicovideo.jp", "nico.ms",
)


def allowed_url(raw: str) -> bool:
    try:
        u = urlsplit(raw)
        host = (u.hostname or "").lower().rstrip(".")
        return u.scheme in ("https", "http") and any(
            host == domain or host.endswith("." + domain)
            for domain in ALLOWED_DOMAINS
        )
    except ValueError:
        return False


def json_copy(job: dict) -> dict:
    return {k: v for k, v in job.items() if k in ("id", "state", "progress", "title", "error")}


def cleanup() -> None:
    with LOCK:
        expired = [job_id for job_id, job in JOBS.items()
                   if job["state"] != "processing" and time.time() - job["created"] > TTL_SECONDS]
        for job_id in expired:
            JOBS.pop(job_id, None)
            shutil.rmtree(BASE / job_id, ignore_errors=True)


def job_worker(job_id: str, url: str) -> None:
    folder = BASE / job_id
    folder.mkdir(parents=True, exist_ok=True)

    def hook(info: dict) -> None:
        with LOCK:
            job = JOBS.get(job_id)
            if job is None:
                return
            total = info.get("total_bytes") or info.get("total_bytes_estimate")
            done = info.get("downloaded_bytes") or 0
            if total:
                job["progress"] = min(95, max(job["progress"], int(done / total * 95)))

    try:
        options = {
            "format": "bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4]",
            "merge_output_format": "mp4",
            "outtmpl": str(folder / "video.%(ext)s"),
            "noplaylist": True,
            "quiet": True,
            "no_warnings": True,
            "progress_hooks": [hook],
            "retries": 3,
            "fragment_retries": 3,
            "socket_timeout": 30,
            "max_filesize": 1024 * 1024 * 1024,
            "cachedir": False,
        }
        with YoutubeDL(options) as ydl:
            details = ydl.extract_info(url, download=True)
            if not details:
                raise RuntimeError("動画情報を取得できませんでした")
        result = folder / "video.mp4"
        if not result.is_file() or result.stat().st_size == 0:
            raise RuntimeError("MP4を作成できませんでした（サイトや形式が非対応の可能性）")
        with LOCK:
            job = JOBS[job_id]
            job["state"] = "ready"
            job["progress"] = 100
            job["title"] = (details.get("title") or "video")[:120]
    except Exception as exc:
        with LOCK:
            job = JOBS.get(job_id)
            if job:
                job["state"] = "failed"
                job["error"] = str(exc)[:500]
        shutil.rmtree(folder, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status: int, data: dict) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authorized(self) -> bool:
        if self.headers.get("X-VTuWAV-Key", "") != KEY:
            self.send_json(401, {"error": "アクセスキーが違います"})
            return False
        return True

    def do_POST(self) -> None:
        if not self.authorized():
            return
        if self.path != "/jobs":
            self.send_json(404, {"error": "URLが見つかりません"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY:
                raise ValueError("リクエストのサイズが不正です")
            request = json.loads(self.rfile.read(length))
            url = request.get("url", "")
            if not isinstance(url, str) or not allowed_url(url):
                self.send_json(400, {"error": "このサイトのURLには現在対応していません"})
                return
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            self.send_json(400, {"error": str(exc)})
            return
        cleanup()
        with LOCK:
            if sum(j["state"] == "processing" for j in JOBS.values()) >= MAX_ACTIVE:
                self.send_json(429, {"error": "他の動画を処理中です。完了後に再度お試しください"})
                return
            job_id = uuid.uuid4().hex
            JOBS[job_id] = {"id": job_id, "state": "processing", "progress": 0,
                            "title": "", "error": "", "created": time.time()}
        threading.Thread(target=job_worker, args=(job_id, url), daemon=True).start()
        self.send_json(202, json_copy(JOBS[job_id]))

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"ok": True})
            return
        if not self.authorized():
            return
        cleanup()
        match = re.fullmatch(r"/jobs/([0-9a-f]{32})(/file)?", self.path)
        if not match:
            self.send_json(404, {"error": "URLが見つかりません"})
            return
        job_id, file_requested = match.groups()
        with LOCK:
            job = JOBS.get(job_id)
            snapshot = json_copy(job) if job else None
        if snapshot is None:
            self.send_json(404, {"error": "処理結果が見つかりません（保存期限切れの可能性）"})
            return
        if not file_requested:
            self.send_json(200, snapshot)
            return
        if snapshot["state"] != "ready":
            self.send_json(409, {"error": "動画の準備がまだ完了していません"})
            return
        filename = BASE / job_id / "video.mp4"
        if not filename.is_file():
            self.send_json(404, {"error": "動画ファイルが見つかりません"})
            return
        try:
            size = filename.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", 'attachment; filename="video.mp4"')
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            with filename.open("rb") as stream:
                shutil.copyfileobj(stream, self.wfile, length=256 * 1024)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    if not KEY:
        raise SystemExit("VTUWAV_API_KEY を設定してください（任意の長い文字列）")
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg がありません。OSにインストールしてください")
    if not shutil.which("deno"):
        print("警告: Denoが見つかりません。2026年のYouTube解析は失敗する場合があります。", flush=True)
    print(f"VTuWAV server: {HOST}:{PORT} /health", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
