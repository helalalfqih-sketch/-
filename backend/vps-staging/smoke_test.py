#!/usr/bin/env python3
"""Smoke test staging API on random loopback port; server stops on completion."""
import json
from threading import Thread
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from scc_staging_api import make_server

srv = make_server(0)
t = Thread(target=srv.serve_forever, daemon=True)
t.start()
host = "http://127.0.0.1:" + str(srv.server_address[1])

def request(path, token=None, method="GET"):
    headers = {"Authorization": "Bearer " + token} if token else {}
    req = Request(host + path, headers=headers, method=method)
    try:
        with urlopen(req, timeout=4) as r:
            return r.status, json.load(r)
    except HTTPError as ex:
        return ex.code, json.load(ex)

try:
    status, health = request("/healthz")
    assert status == 200 and health["status"] == "ok"
    status, body = request("/v1/status")
    assert status == 401
    status, body = request("/v1/status", srv.local_token)
    assert status == 200 and body["tables"] == 8
    assert all(number == 0 for number in body["rows"].values())
    status, body = request("/v1/products", srv.local_token)
    assert status == 200 and body["items"] == []
    status, body = request("/v1/products", srv.local_token, method="POST")
    assert status == 405
    assert srv.server_address[0] == "127.0.0.1"
    print("PASS health=200, unauthorized=401, status=200, products=empty, writes=405, loopback_only=True")
finally:
    srv.shutdown()
    srv.server_close()