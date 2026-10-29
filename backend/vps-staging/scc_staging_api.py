#!/usr/bin/env python3
"""LOCAL-ONLY, READ-ONLY Smart Content Creator staging API.

NOT PocketBase. No client registration, authentication database, or public API.
"""
import hmac
import json
import os
import secrets
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "smart_content_creator.sqlite3"
TOKEN_PATH = ROOT / "data" / ".local_admin_token"

def get_token():
    os.umask(0o077)
    if not TOKEN_PATH.exists():
        try:
            fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as file:
                file.write(secrets.token_urlsafe(48) + "\n")
        except FileExistsError:
            pass
    if TOKEN_PATH.stat().st_mode & 0o077:
        raise RuntimeError("Token file permissions are too open")
    return TOKEN_PATH.read_text().strip()

class Handler(BaseHTTPRequestHandler):
    server_version = "SCCStaging/0.1"
    sys_version = ""

    def log_message(self, fmt, *args):
        # No URLs/tokens/headers or request bodies in logs.
        pass

    def reply(self, code, payload, extra=None):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        expected = "Bearer " + self.server.local_token
        provided = self.headers.get("Authorization", "")
        return hmac.compare_digest(provided, expected)

    def do_GET(self):
        route = urlsplit(self.path).path
        if route == "/healthz":
            try:
                with sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=1) as con:
                    good = con.execute("PRAGMA quick_check").fetchone()[0] == "ok"
                self.reply(200 if good else 503, {"status": "ok" if good else "unhealthy", "service": "scc-staging"})
            except Exception:
                self.reply(503, {"status": "unhealthy"})
            return
        if not self.authorized():
            self.reply(401, {"error": "unauthorized"}, {"WWW-Authenticate": "Bearer"})
            return
        if route == "/v1/status":
            with sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=1) as con:
                tables = [r[0] for r in con.execute(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
                )]
                empty = {t: con.execute('SELECT COUNT(*) FROM "' + t + '"').fetchone()[0] for t in tables}
            self.reply(200, {"database": "ready", "mode": "readonly", "tables": len(tables), "rows": empty})
        elif route == "/v1/products":
            with sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=1) as con:
                con.row_factory = sqlite3.Row
                rows = [dict(r) for r in con.execute(
                    "SELECT id, title, price_decimal, currency, quantity, status FROM products ORDER BY created_at DESC LIMIT 50"
                )]
            self.reply(200, {"items": rows, "count": len(rows), "readOnly": True})
        else:
            self.reply(404, {"error": "not_found"})

    def do_POST(self):
        self.reply(405, {"error": "writes_disabled"}, {"Allow": "GET"})

    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST

def make_server(port=8789):
    srv = ThreadingHTTPServer(("127.0.0.1", int(port)), Handler)
    srv.local_token = get_token()
    return srv

if __name__ == "__main__":
    print("SCC_STAGING_READ_ONLY_LOOPBACK_ONLY: 127.0.0.1:8789")
    print("No public deployment. Terminate with Ctrl+C.")
    make_server().serve_forever()