#!/usr/bin/env python3
"""Provision a normal PocketBase app user over a private Docker bridge.

Run interactively as root on the authorized VPS. The script never connects to
public creator-api, never prints credentials and never creates a superuser.
No default credentials are embedded or written to disk.
"""
from __future__ import annotations

import getpass
import ipaddress
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request


CONTAINER = "scc-production-pocketbase-1"
NETWORK = "indexes-waha_default"
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$")


def api_request(base: str, path: str, payload: dict,
                token: str | None = None) -> dict:
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = token
    request = urllib.request.Request(
        base + path,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            if not 200 <= response.status < 300:
                raise RuntimeError("PocketBase declined a request")
            value = json.load(response)
            if not isinstance(value, dict):
                raise RuntimeError("Unexpected PocketBase response")
            return value
    except urllib.error.HTTPError as err:
        raise RuntimeError(
            f"PocketBase refused the operation (HTTP {err.code}); "
            "review private logs, not passwords."
        ) from None


def private_backend_url() -> str:
    details = subprocess.check_output(
        ["docker", "inspect", "--format",
         "{{json .NetworkSettings.Networks}}", CONTAINER],
        text=True,
        timeout=8,
    )
    networks = json.loads(details)
    if NETWORK not in networks:
        raise RuntimeError("The PocketBase container is not on the expected Docker network")
    ip = ipaddress.ip_address(networks[NETWORK]["IPAddress"])
    if not ip.is_private or ip.version != 4:
        raise RuntimeError("Refusing a nonprivate or unsupported Docker address")
    return f"http://{ip}:8090"


def main() -> None:
    if os.geteuid() != 0:
        raise SystemExit("Run from an authorized VPS root console, not Desktop Commander")
    base = private_backend_url()
    # Never print the private Docker address, admin token, or credentials.
    probe = urllib.request.Request(base + "/api/health", method="GET")
    with urllib.request.urlopen(probe, timeout=8) as response:
        health = json.load(response)
    if health.get("code") != 200:
        raise SystemExit("PocketBase health check did not pass")

    admin_email = input("PocketBase superuser email: ").strip()
    if not EMAIL_RE.fullmatch(admin_email):
        raise SystemExit("Invalid superuser email")

    admin_pass = getpass.getpass("Superuser password (hidden): ")
    if not admin_pass:
        raise SystemExit("Administrator password must not be empty")

    user_email = input("New NORMAL app user email: ").strip()
    if not EMAIL_RE.fullmatch(user_email):
        raise SystemExit("Invalid normal user email")

    user_pass = getpass.getpass("New app user password (hidden, 14+ chars): ")
    user_confirm = getpass.getpass("Confirm app user password: ")
    if len(user_pass) < 14 or user_pass != user_confirm:
        raise SystemExit("User password was too short or did not match")
    if user_email == admin_email and user_pass == admin_pass:
        raise SystemExit("Use a separate password for normal and superuser accounts")

    auth = api_request(base, "/api/collections/_superusers/auth-with-password", {
        "identity": admin_email,
        "password": admin_pass,
    })
    token = auth.get("token")
    if not isinstance(token, str) or not token:
        raise RuntimeError("Superuser authentication failed")

    created = api_request(base, "/api/collections/users/records", {
        "email": user_email,
        "password": user_pass,
        "passwordConfirm": user_confirm,
        "verified": False,
        "emailVisibility": False,
    }, token)
    if not isinstance(created.get("id"), str):
        raise RuntimeError("PocketBase did not confirm user record creation")

    print("SUCCESS: normal app user created in the existing PocketBase users collection.")
    print("The account is NOT a superuser. Public sign-up remains disabled.")
    print("Keep the password private. Email verification/reset requires configured mail delivery.")


if __name__ == "__main__":
    try:
        main()
    except (subprocess.SubprocessError, KeyError, OSError, ValueError,
            urllib.error.URLError, RuntimeError) as exc:
        # Do not leak sensitive response bodies into logs.
        print(f"ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
