#!/usr/bin/env python3
"""Start the isolated LOCAL-ONLY, registration-disabled auth preview."""
import os
from pathlib import Path
from auth_preview import PreviewStore, make_preview_server

ROOT=Path(__file__).resolve().parent
DB=ROOT/"data"/"auth_preview.sqlite3"
if not DB.is_file() or DB.stat().st_mode & 0o077:
    raise RuntimeError("auth preview DB missing or permissions too open")
store=PreviewStore(DB)
server=make_preview_server(store, port=8790, registration_enabled=False)
print("SCC_AUTH_PREVIEW_LOOPBACK_ONLY 127.0.0.1:8790",flush=True)
print("REGISTRATION=DISABLED; NO_PUBLIC_ENDPOINT; NOT_POCKETBASE",flush=True)
server.serve_forever()