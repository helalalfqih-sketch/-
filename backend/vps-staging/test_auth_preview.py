#!/usr/bin/env python3
"""No production writes. Create temporary databases and listen on loopback only."""
import hashlib
import json
import sqlite3
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from auth_preview import PreviewStore, make_preview_server

SCHEMA = Path(__file__).resolve().parent / "schema.sql"

class AuthPreviewTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(prefix="scc-auth-unit-")
        self.addCleanup(self.dir.cleanup)
        self.dbpath = Path(self.dir.name) / "testing.sqlite3"
        with sqlite3.connect(self.dbpath) as db:
            db.executescript(SCHEMA.read_text(encoding="utf-8"))
        self.store = PreviewStore(self.dbpath)
        self.store.migrate()
        self.server = make_preview_server(self.store, registration_enabled=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = "http://127.0.0.1:" + str(self.server.server_address[1])

    def call(self, method, path, obj=None, token=None):
        headers = {"Accept":"application/json"}
        body = None
        if obj is not None:
            body = json.dumps(obj).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = "Bearer " + token
        req = Request(self.base + path, data=body, method=method, headers=headers)
        try:
            with urlopen(req, timeout=8) as res:
                return res.status, json.loads(res.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())

    def register_and_login(self, email):
        s, data = self.call("POST","/v1/auth/register", {
            "email":email, "password":"LongExamplePassphrase#2026", "display_name":"Test Person"
        })
        self.assertEqual(s, 201, data)
        self.assertEqual(data["user"]["role"], "member")
        s, data = self.call("POST","/v1/auth/login", {
            "email":email, "password":"LongExamplePassphrase#2026"
        })
        self.assertEqual(s, 200, data)
        return data["access_token"]

    def test_loopback_only_and_no_anonymous_access(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        self.assertEqual(self.call("GET","/healthz")[0], 200)
        self.assertEqual(self.call("GET","/v1/auth/me")[0], 401)
        self.assertEqual(self.call("GET","/v1/products")[0], 401)
        self.assertEqual(self.call("POST","/v1/products",{"title":"bad"})[0], 401)
        self.assertEqual(self.call("DELETE","/v1/products/anything")[0], 405)
        self.assertEqual(self.call("GET","/notfound")[0], 401)

    def test_registration_default_is_disabled(self):
        other = make_preview_server(self.store)
        try:
            self.assertFalse(other.registration_enabled)
        finally:
            other.server_close()

    def test_account_roles_and_isolation(self):
        a = self.register_and_login("Alice@Example.org")
        b = self.register_and_login("bob@example.org")
        s, info = self.call("GET","/v1/auth/me",token=a)
        self.assertEqual(s, 200)
        self.assertEqual(info["user"]["email"],"alice@example.org")
        self.assertEqual(info["user"]["role"],"member")
        s, response = self.call("POST","/v1/products",{
            "title":"Test Camera","price_decimal":"1234.00","currency":"YER","quantity":3
        },token=a)
        self.assertEqual(s,201,response)
        self.assertEqual(response["product"]["status"],"draft")
        self.assertEqual(self.call("GET","/v1/products",token=b),(200,{"items":[]}))
        s, owned = self.call("GET","/v1/products",token=a)
        self.assertEqual(s,200)
        self.assertEqual(len(owned["items"]),1)
        self.assertEqual(owned["items"][0]["price_decimal"],"1234.00")
        s, response = self.call("POST","/v1/products",{
            "title":"Not Allowed","price_decimal":"0","owner_id":info["user"]["id"]
        },token=b)
        self.assertEqual(s,400,response)
        s, response = self.call("POST","/v1/products",{
            "title":"Not Allowed","price_decimal":"0","role":"admin"
        },token=b)
        self.assertEqual(s,400,response)
        with sqlite3.connect(self.dbpath) as db:
            users = db.execute("SELECT count(*) FROM users").fetchone()[0]
            roles = db.execute("SELECT role FROM user_roles").fetchall()
            count = db.execute("SELECT count(*) FROM products").fetchone()[0]
        self.assertEqual(users,2)
        self.assertEqual({r[0] for r in roles},{"member"})
        self.assertEqual(count,1)

    def test_validation_and_password_not_stored_in_plaintext(self):
        self.register_and_login("case@example.org")
        self.assertEqual(self.call("POST","/v1/auth/register",{
            "email":"CASE@example.org", "password":"LongExamplePassphrase#2026"
        })[0],400)
        self.assertEqual(self.call("POST","/v1/auth/login",{
            "email":"case@example.org", "password":"WrongExamplePassphrase2026"
        })[0],400)
        with sqlite3.connect(self.dbpath) as db:
            salt, verifier = db.execute(
                "SELECT salt, verifier FROM auth_passwords"
            ).fetchone()
        self.assertEqual(len(salt),16)
        self.assertEqual(len(verifier),32)
        self.assertNotEqual(verifier,b"LongExamplePassphrase#2026")

    def test_logout_and_expired_sessions(self):
        token = self.register_and_login("tokens@example.org")
        self.assertEqual(self.call("GET","/v1/auth/me",token=token)[0],200)
        self.assertEqual(self.call("POST","/v1/auth/logout",token=token)[0],200)
        self.assertEqual(self.call("GET","/v1/auth/me",token=token)[0],401)
        new_token = self.store.login("tokens@example.org","LongExamplePassphrase#2026")
        digest = hashlib.sha256(new_token.encode("ascii")).hexdigest()
        with sqlite3.connect(self.dbpath) as db:
            db.execute("UPDATE auth_sessions SET expires_unix=1 WHERE token_sha256=?",(digest,))
        self.assertEqual(self.call("GET","/v1/auth/me",token=new_token)[0],401)

    def test_product_validation_rejects_bad_prices(self):
        token = self.register_and_login("validation@example.org")
        for bad in ["-1","1e5","0.00001","NaN","1,000",0,None]:
            with self.subTest(bad=bad):
                code,_ = self.call("POST","/v1/products",{
                    "title":"Bad price","price_decimal":bad
                },token=token)
                self.assertEqual(code,400)

if __name__ == "__main__":
    unittest.main(verbosity=2)