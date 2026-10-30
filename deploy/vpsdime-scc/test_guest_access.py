"""Real PocketBase integration tests in a disposable local database; no production calls."""
import concurrent.futures
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def main():
    binary = str(Path(sys.argv[1]).resolve())
    source = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="scc-guest-test-") as folder:
        root = Path(folder)
        shutil.copytree(source / "pb_hooks", root / "hooks")
        shutil.copytree(source / "pb_migrations", root / "migrations")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        url = f"http://127.0.0.1:{port}"
        options = [f"--dir={root / 'data'}", f"--migrationsDir={root / 'migrations'}", f"--hooksDir={root / 'hooks'}"]
        subprocess.run([binary, "migrate", "up", *options], check=True, stdout=subprocess.DEVNULL)
        password = secrets.token_urlsafe(32)
        subprocess.run([binary, "superuser", "upsert", "test@example.invalid", password, *options], check=True, stdout=subprocess.DEVNULL)
        env = dict(os.environ, SCC_GUEST_ENABLED="1", SCC_AI_API_KEY="local-test-not-a-provider-key", SCC_AI_MODEL="test", SCC_AI_API_URL="https://127.0.0.1:1")
        log = open(root / "server.log", "w+")
        process = subprocess.Popen([binary, "serve", f"--http=127.0.0.1:{port}", *options], env=env, stdout=log, stderr=log)
        def call(path, body=None, token=None, method=None):
            headers = {"Content-Type": "application/json"}
            if token:
                headers["Authorization"] = token
            req = urllib.request.Request(url + path, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=15) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)
        try:
            for _ in range(80):
                try:
                    if call("/api/health")[0] == 200:
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise AssertionError("PocketBase did not start")
            code, auth = call("/api/collections/_superusers/auth-with-password", {"identity": "test@example.invalid", "password": password})
            assert code == 200
            admin = auth["token"]
            route = "/api/scc/guest/session"
            assert call(route, {})[0] == 400
            assert call(route, {"deviceSecret": "short"})[0] == 400
            secret = secrets.token_urlsafe(32)
            code, a = call(route, {"deviceSecret": secret, "owner": "attacker", "verified": True})
            assert code == 200, a
            code, repeat = call(route, {"deviceSecret": secret})
            assert code == 200 and repeat["record"]["id"] == a["record"]["id"]
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(lambda _: call(route, {"deviceSecret": secret}), range(4)))
            assert all(status == 200 and result["record"]["id"] == a["record"]["id"] for status, result in results)
            code, b = call(route, {"deviceSecret": secrets.token_urlsafe(32)})
            assert code == 200 and b["record"]["id"] != a["record"]["id"]
            assert call("/api/collections/users/records", {"email": "intruder@example.invalid", "password": password, "passwordConfirm": password})[0] in (400, 403)
            assert call("/api/collections/scc_guest_devices/records", token=a["token"])[0] == 403
            assert call("/api/scc/ai/text", {"prompt": "test"})[0] == 401
            for collection, fields in [("products", {"title": "Private product", "price_minor": 100, "currency": "YER", "status": "draft"}), ("content_items", {"title": "Private draft", "body": "private", "format": "post", "status": "draft"})]:
                path = f"/api/collections/{collection}/records"
                code, record = call(path, dict(fields, owner=a["record"]["id"]), a["token"])
                assert code == 200, record
                assert call(path + "/" + record["id"], token=b["token"])[0] == 404
                assert call(path + "/" + record["id"], {"title": "attack"}, b["token"], "PATCH")[0] == 404
                assert call(path, dict(fields, owner=a["record"]["id"]), b["token"])[0] == 400
                assert call(path, token=b["token"])[1]["items"] == []
                assert call(path + "/" + record["id"], {"title": "Saved change"}, a["token"], "PATCH")[0] == 200
            # Provider connection fails deliberately: do not invent a successful generation.
            assert call("/api/scc/ai/text", {"prompt": "test"}, a["token"])[0] == 502
            for _ in range(7):
                assert call("/api/collections/ai_jobs/records", {"owner": a["record"]["id"], "job_type": "chat", "state": "failed"}, admin)[0] == 200
            assert call("/api/scc/ai/text", {"prompt": "test"}, a["token"])[0] == 429
            for _ in range(42):
                assert call("/api/collections/ai_jobs/records", {"owner": a["record"]["id"], "job_type": "chat", "state": "failed"}, admin)[0] == 200
            assert call("/api/scc/ai/text", {"prompt": "test"}, b["token"])[0] == 429
            for _ in range(8):
                assert call(route, {"deviceSecret": secrets.token_urlsafe(32)})[0] == 200
            assert call(route, {"deviceSecret": secrets.token_urlsafe(32)})[0] == 429
            assert call(route, {"deviceSecret": secret})[0] == 200
            process.terminate()
            process.wait(timeout=10)
            process = subprocess.Popen([binary, "serve", f"--http=127.0.0.1:{port}", *options], env=env, stdout=log, stderr=log)
            for _ in range(80):
                try:
                    code, resumed = call(route, {"deviceSecret": secret})
                    if code == 200:
                        break
                except OSError:
                    time.sleep(.1)
            assert resumed["record"]["id"] == a["record"]["id"]
            assert call("/api/collections/products/records", token=resumed["token"])[1]["items"][0]["title"] == "Saved change"
            print("PASS: real PocketBase guest bootstrap/retry/concurrency/restart, owner isolation, locked signup, provider failure, user/global quotas, device cap")
        except Exception:
            log.flush()
            # Server log is retained only in this disposable directory; never print bearer data.
            raise
        finally:
            process.terminate()
            process.wait(timeout=10)
            log.close()


if __name__ == "__main__":
    main()
