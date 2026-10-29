#!/usr/bin/env python3
"""PocketBase 0.40.6 authorization integration tests.

Runs a TEMPORARY PocketBase instance on 127.0.0.1 with auto-cleanup.
Does NOT connect to the production database, Docker, or a public hostname.
Usage: python3 test_access_policy.py /path/to/pocketbase ./pb_migrations
"""
import contextlib
import http.client
import json
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def req(base, method, path, payload=None, token=None, raw=None, content_type="application/json"):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = token
    if raw is not None:
        data = raw
        headers["Content-Type"] = content_type
    elif payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    else:
        data = None
    request = urllib.request.Request(
        base + path, data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=4) as response:
            body = response.read()
            return response.status, json.loads(body or b"{}")
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            response = json.loads(body)
        except json.JSONDecodeError:
            response = {"error": "non-JSON API error"}
        return e.code, response


def must_ok(result, action):
    code, data = result
    assert 200 <= code < 300, f"{action}: unexpected HTTP {code}"
    return data


def must_deny(result, action):
    code, data = result
    assert code in {400, 401, 403, 404}, f"{action}: unexpected HTTP {code}"


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: test_access_policy.py PB_EXECUTABLE MIGRATIONS_DIR")
    pb = Path(sys.argv[1]).resolve()
    mig = Path(sys.argv[2]).resolve()
    if not pb.is_file() or not (mig / "1793305000_scc_schema_v1.js").is_file():
        raise SystemExit("Missing PocketBase binary or tested migrations; aborting.")
    with tempfile.TemporaryDirectory(prefix="scc-auth-isolation-") as folder:
        root = Path(folder)
        data_dir = root / "data"
        hooks_dir = root / "hooks"
        hooks_dir.mkdir()
        mig_args = ["--dir", str(data_dir), "--migrationsDir", str(mig),
                    "--hooksDir", str(hooks_dir), "--automigrate=false"]
        subprocess.run([str(pb), "migrate", "up", *mig_args],
                       check=True, capture_output=True, text=True, timeout=25)
        # Independent test-only credentials; not stored or printed.
        email = "test-superuser@example.invalid"
        password = secrets.token_urlsafe(26) + "A8"
        subprocess.run(
            [str(pb), "superuser", "upsert", email, password, *mig_args],
            check=True, capture_output=True, text=True, timeout=15
        )
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        base = f"http://127.0.0.1:{port}"
        proc = subprocess.Popen(
            [str(pb), "serve", "--http", f"127.0.0.1:{port}", *mig_args],
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT
        )
        try:
            for _ in range(45):
                if proc.poll() is not None:
                    raise RuntimeError("PocketBase test service exited")
                try:
                    if req(base, "GET", "/api/health")[0] == 200:
                        break
                except (urllib.error.URLError, ConnectionError, TimeoutError):
                    pass
                time.sleep(0.15)
            else:
                raise RuntimeError("PocketBase test service never became healthy")

            admin_token = must_ok(req(
                base, "POST", "/api/collections/_superusers/auth-with-password",
                {"identity": email, "password": password}
            ), "superuser auth")["token"]

            a_password = secrets.token_urlsafe(25) + "B9"
            b_password = secrets.token_urlsafe(25) + "C8"
            a_email = "owner-a@example.invalid"
            b_email = "owner-b@example.invalid"
            must_deny(req(base, "POST", "/api/collections/users/records", {
                "email": "stranger@example.invalid", "password": a_password,
                "passwordConfirm": a_password
            }), "anonymous signup forbidden")
            def provision(e, p):
                result = must_ok(req(base, "POST", "/api/collections/users/records", {
                    "email": e, "password": p, "passwordConfirm": p, "verified": True
                }, admin_token), "superuser user create")
                token = must_ok(req(
                    base, "POST", "/api/collections/users/auth-with-password",
                    {"identity": e, "password": p}
                ), "user sign in")["token"]
                return result["id"], token

            a_id, a_token = provision(a_email, a_password)
            b_id, b_token = provision(b_email, b_password)
            must_deny(req(base, "POST", "/api/collections/products/records",
                          {"title": "unauthorized", "owner": a_id}),
                      "anonymous product write")
            created = must_ok(req(base, "POST", "/api/collections/products/records", {
                "title": "A private product", "owner": a_id, "price_minor": 12500,
                "currency": "YER", "status": "draft"
            }, a_token), "owner product create")
            record_id = created["id"]
            assert created["owner"] == a_id

            a_list = must_ok(req(
                base, "GET", "/api/collections/products/records", token=a_token
            ), "owner list")
            assert any(x["id"] == record_id for x in a_list["items"])
            b_list = must_ok(req(
                base, "GET", "/api/collections/products/records", token=b_token
            ), "other user's list")
            assert not any(x["id"] == record_id for x in b_list["items"])
            must_deny(req(base, "GET", f"/api/collections/products/records/{record_id}",
                          token=b_token), "other user's read")
            must_deny(req(base, "POST", "/api/collections/products/records",
                          {"title": "spoof", "owner": a_id}, b_token),
                      "other user's create spoof")
            must_deny(req(base, "PATCH", f"/api/collections/products/records/{record_id}",
                          {"title": "hijack"}, b_token), "other user's update")
            must_deny(req(base, "PATCH", f"/api/collections/products/records/{record_id}",
                          {"owner": b_id}, a_token), "owner reassignment")
            must_deny(req(base, "DELETE", f"/api/collections/products/records/{record_id}",
                          token=b_token), "other user's delete")
            updated = must_ok(req(
                base, "PATCH", f"/api/collections/products/records/{record_id}",
                {"title": "Owner updated"}, a_token
            ), "owner update")
            assert updated["title"] == "Owner updated" and updated["owner"] == a_id

            must_deny(req(base, "POST", "/api/collections/user_roles/records",
                          {"user": a_id, "role": "admin"}, a_token),
                      "self role escalation")
            must_deny(req(base, "POST", "/api/collections/subscriptions/records",
                          {"owner": a_id, "plan": "premium"}, a_token),
                      "self premium assignment")
            must_deny(req(base, "POST", "/api/collections/ai_jobs/records",
                          {"owner": a_id, "job_type": "render",
                           "state": "completed"}, a_token),
                      "fake completed AI job")
            must_deny(req(base, "POST", "/api/collections/audit_events/records",
                          {"actor": a_id, "action": "fake"}, a_token),
                      "fake audit write")
            must_deny(req(base, "PATCH", f"/api/collections/users/records/{a_id}",
                          {"verified": True}, a_token), "self verification")
            # Private content records must not be publicly discoverable.
            must_ok(req(base, "POST", "/api/collections/content_items/records", {
                "owner": a_id, "title": "Private draft", "format": "post",
                "body": "only for owner", "status": "draft"
            }, a_token), "owner content create")
            other_content = must_ok(req(
                base, "GET", "/api/collections/content_items/records",
                token=b_token
            ), "content list isolation")
            assert other_content["totalItems"] == 0
            print("PASS: 2 users, registration locked, owner reads/writes, "
                  "cross-user denial, role/subscription/AI/audit restrictions, "
                  "user verification protection, private draft isolation.")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)


if __name__ == "__main__":
    main()
