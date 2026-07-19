#!/usr/bin/env python3
"""Deterministic local origin for the cache integration test.

Serves a fixed content blob under several path aliases so each test scenario
(miss/hit, nocache bypass, range, redirect, concurrency) can assert against an
independent per-path hit counter without interfering with one another. Must
handle requests concurrently (ThreadingHTTPServer) so the concurrency-dedup
test can tell nginx's proxy_cache_lock behavior apart from origin-side
serialization.
"""
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIXTURE_PATH = os.environ.get("FIXTURE_PATH", "/fixtures/fixture.bin")
with open(FIXTURE_PATH, "rb") as f:
    CONTENT = f.read()

CONTENT_PATHS = {"/fixture.bin", "/nocache.bin", "/range.bin", "/slow.bin"}
SLOW_DELAY_SECONDS = float(os.environ.get("SLOW_DELAY_SECONDS", "1.5"))

RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")

_lock = threading.Lock()
_hits: dict[str, int] = {}


def _record_hit(path):
    with _lock:
        _hits[path] = _hits.get(path, 0) + 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass  # keep container logs quiet; /stats is the source of truth

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/healthz":
            self._respond(200, b"ok", content_type="text/plain")
            return

        if path == "/stats":
            with _lock:
                body = json.dumps({"hits": dict(_hits)}).encode()
            self._respond(200, body, content_type="application/json")
            return

        if path == "/redirect":
            _record_hit("/redirect")
            self.send_response(302)
            self.send_header("Location", "/fixture.bin")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path in CONTENT_PATHS:
            _record_hit(path)
            if path == "/slow.bin":
                time.sleep(SLOW_DELAY_SECONDS)
            self._serve_content()
            return

        self._respond(404, b"not found", content_type="text/plain")

    def _serve_content(self):
        total = len(CONTENT)
        range_header = self.headers.get("Range")
        if range_header:
            m = RANGE_RE.match(range_header.strip())
            if m:
                start_s, end_s = m.groups()
                start = int(start_s) if start_s else 0
                end = int(end_s) if end_s else total - 1
                end = min(end, total - 1)
                if start <= end < total:
                    chunk = CONTENT[start : end + 1]
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
                    self.send_header("Content-Length", str(len(chunk)))
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Accept-Ranges", "bytes")
                    self.end_headers()
                    self.wfile.write(chunk)
                    return
            self._respond(416, b"invalid range", content_type="text/plain")
            return

        self.send_response(200)
        self.send_header("Content-Length", str(total))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self.wfile.write(CONTENT)

    def _respond(self, code, body, content_type="text/plain"):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()
