#!/usr/bin/env python3
"""Isolated localhost-only authentication and per-user products proof of concept.

IMPORTANT: NOT PocketBase. NOT a production identity provider or public API.
Uses Python stdlib and new throwaway SQLite DB. Does not touch Firebase or WAHA.
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
from decimal import Decimal, InvalidOperation
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from uuid import uuid4

SESSION_TTL = 12 * 60 * 60
EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,190}$")
ALLOWED_CURRENCIES = {"YER", "USD", "SAR"}
MIGRATION = """
CREATE TABLE IF NOT EXISTS auth_passwords (
 user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 salt BLOB NOT NULL,
 verifier BLOB NOT NULL,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS auth_sessions (
 token_sha256 TEXT PRIMARY KEY,
 user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 expires_unix INTEGER NOT NULL,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_expiry ON auth_sessions(expires_unix);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_user ON auth_sessions(user_id);
"""

def _email(value):
    if not isinstance(value, str):
        raise ValueError("invalid_email")
    email = value.strip().lower()
    if len(email) > 254 or not EMAIL_RE.fullmatch(email):
        raise ValueError("invalid_email")
    return email

def _password(value):
    if not isinstance(value, str) or not 12 <= len(value) <= 128:
        raise ValueError("invalid_password")
    if len(value.encode("utf-8")) > 256:
        raise ValueError("invalid_password")
    return value

def _price(value):
    if not isinstance(value, str) or not re.fullmatch(r"(0|[1-9]\d{0,9})(?:\.\d{1,2})?", value):
        raise ValueError("invalid_price")
    try:
        amount = Decimal(value)
    except InvalidOperation as exc:
        raise ValueError("invalid_price") from exc
    if amount > Decimal("9999999999.99"):
        raise ValueError("invalid_price")
    return format(amount, "f")

class PreviewStore:
    def __init__(self, path):
        self.path = Path(path)

    def _db(self):
        con = sqlite3.connect(str(self.path), timeout=5)
        con.execute("PRAGMA foreign_keys=ON")
        con.row_factory = sqlite3.Row
        return con

    def migrate(self):
        # Caller must initialize the existing, EMPTY schema before running this.
        with self._db() as db:
            required = db.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='users'"
            ).fetchone()
            if not required:
                raise RuntimeError("Base empty SCC schema is required")
            db.executescript(MIGRATION)

    def register(self, email, password, display_name):
        email = _email(email)
        password = _password(password)
        if not isinstance(display_name, str) or len(display_name.strip()) > 100:
            raise ValueError("invalid_display_name")
        uid = uuid4().hex
        salt = secrets.token_bytes(16)
        verifier = hashlib.scrypt(
            password.encode("utf-8"), salt=salt, n=2**14, r=8, p=1, dklen=32
        )
        try:
            with self._db() as db:
                db.execute(
                    "INSERT INTO users (id, email_normalized, display_name) VALUES (?,?,?)",
                    (uid, email, display_name.strip()),
                )
                db.execute(
                    "INSERT INTO user_roles (user_id, role) VALUES (?, 'member')",
                    (uid,),
                )
                db.execute(
                    "INSERT INTO auth_passwords (user_id, salt, verifier) VALUES (?,?,?)",
                    (uid, salt, verifier),
                )
        except sqlite3.IntegrityError as exc:
            raise ValueError("email_unavailable") from exc
        return {"id": uid, "email": email, "role": "member"}

    def login(self, email, password):
        # The API deliberately returns the same error for unknown users or bad passwords.
        email = _email(email)
        password = _password(password)
        with self._db() as db:
            row = db.execute(
                "SELECT u.id, p.salt, p.verifier FROM users u "
                "JOIN auth_passwords p ON p.user_id=u.id "
                "WHERE u.email_normalized=? AND u.is_active=1",
                (email,),
            ).fetchone()
            salt = row["salt"] if row else bytes(16)
            expected = row["verifier"] if row else bytes(32)
            actual = hashlib.scrypt(
                password.encode("utf-8"), salt=salt, n=2**14, r=8, p=1, dklen=32
            )
            if not hmac.compare_digest(actual, expected) or row is None:
                raise ValueError("invalid_credentials")
            token = secrets.token_urlsafe(32)
            digest = hashlib.sha256(token.encode("ascii")).hexdigest()
            db.execute(
                "INSERT INTO auth_sessions (token_sha256, user_id, expires_unix) VALUES (?,?,?)",
                (digest, row["id"], int(time.time()) + SESSION_TTL),
            )
        return token

    def identify(self, token):
        if not isinstance(token, str) or not 20 <= len(token) <= 100:
            return None
        digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
        with self._db() as db:
            row = db.execute(
                "SELECT u.id, u.email_normalized, r.role FROM auth_sessions s "
                "JOIN users u ON u.id=s.user_id "
                "JOIN user_roles r ON r.user_id=u.id "
                "WHERE s.token_sha256=? AND s.expires_unix>? AND u.is_active=1",
                (digest, int(time.time())),
            ).fetchone()
        if row is None:
            return None
        return {"id":row["id"], "email":row["email_normalized"], "role":row["role"]}

    def logout(self, token):
        digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
        with self._db() as db:
            db.execute("DELETE FROM auth_sessions WHERE token_sha256=?", (digest,))

    def products(self, actor):
        with self._db() as db:
            return [dict(row) for row in db.execute(
                "SELECT id, title, price_decimal, currency, quantity, status "
                "FROM products WHERE owner_id=? ORDER BY created_at DESC LIMIT 50",
                (actor["id"],),
            )]

    def create_product(self, actor, payload):
        if not isinstance(payload, dict) or not set(payload).issubset(
            {"title", "price_decimal", "currency", "quantity"}
        ):
            raise ValueError("invalid_fields")
        title = payload.get("title")
        currency = payload.get("currency", "YER")
        qty = payload.get("quantity", 0)
        if not isinstance(title, str) or not 1 <= len(title.strip()) <= 200:
            raise ValueError("invalid_title")
        if currency not in ALLOWED_CURRENCIES:
            raise ValueError("invalid_currency")
        if type(qty) is not int or not 0 <= qty <= 1000000:
            raise ValueError("invalid_quantity")
        price = _price(payload.get("price_decimal"))
        pid = uuid4().hex
        with self._db() as db:
            db.execute(
                "INSERT INTO products "
                "(id, owner_id, title, price_decimal, currency, quantity, status) "
                "VALUES (?,?,?,?,?,?,'draft')",
                (pid, actor["id"], title.strip(), price, currency, qty),
            )
        return {"id":pid, "title":title.strip(), "price_decimal":price,
                "currency":currency, "quantity":qty, "status":"draft"}

class PreviewHandler(BaseHTTPRequestHandler):
    server_version = "SCCAuthPreview/0.1"
    sys_version = ""

    def log_message(self, fmt, *args):
        # Avoid tokens, account names, URLs and raw input in logs.
        pass

    def _send(self, status, data):
        raw = json.dumps(data, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        self.wfile.write(raw)

    def _json(self):
        size = self.headers.get("Content-Length", "")
        if not size.isdecimal() or not 0 < int(size) <= 16384:
            raise ValueError("invalid_content_length")
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            raise ValueError("expected_json")
        body = self.rfile.read(int(size))
        try:
            data = json.loads(body)
        except (ValueError, UnicodeDecodeError) as exc:
            raise ValueError("invalid_json") from exc
        if not isinstance(data, dict):
            raise ValueError("invalid_json")
        return data

    def _token(self):
        header = self.headers.get("Authorization", "")
        return header[7:] if header.startswith("Bearer ") else ""

    def _actor(self):
        return self.server.store.identify(self._token())

    def do_GET(self):
        route = urlsplit(self.path).path
        if route == "/healthz":
            self._send(200, {"status":"ok","service":"scc-auth-preview"})
            return
        actor = self._actor()
        if actor is None:
            self._send(401, {"error":"unauthorized"})
        elif route == "/v1/auth/me":
            self._send(200, {"user":actor})
        elif route == "/v1/products":
            self._send(200, {"items":self.server.store.products(actor)})
        else:
            self._send(404, {"error":"not_found"})

    def do_POST(self):
        route = urlsplit(self.path).path
        try:
            if route == "/v1/auth/register":
                if not self.server.registration_enabled:
                    self._send(403, {"error":"registration_disabled"})
                    return
                data = self._json()
                user = self.server.store.register(
                    data.get("email"), data.get("password"), data.get("display_name", "")
                )
                self._send(201, {"user":user})
            elif route == "/v1/auth/login":
                data = self._json()
                token = self.server.store.login(data.get("email"), data.get("password"))
                self._send(200, {"access_token":token, "expires_in":SESSION_TTL})
            elif route == "/v1/auth/logout":
                actor = self._actor()
                if actor is None:
                    self._send(401, {"error":"unauthorized"})
                    return
                self.server.store.logout(self._token())
                self._send(200, {"status":"ok"})
            elif route == "/v1/products":
                actor = self._actor()
                if actor is None:
                    self._send(401, {"error":"unauthorized"})
                    return
                product = self.server.store.create_product(actor, self._json())
                self._send(201, {"product":product})
            else:
                self._send(404, {"error":"not_found"})
        except ValueError as error:
            self._send(400, {"error":str(error)})
        except sqlite3.Error:
            self._send(503, {"error":"database_unavailable"})

    def do_PUT(self):
        self._send(405, {"error":"method_not_allowed"})

    do_PATCH = do_PUT
    do_DELETE = do_PUT

def make_preview_server(store, port=0, registration_enabled=False):
    server = ThreadingHTTPServer(("127.0.0.1", port), PreviewHandler)
    server.store = store
    server.registration_enabled = bool(registration_enabled)
    return server