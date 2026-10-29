#!/usr/bin/env python3
"""Initialize a SEPARATE empty auth-preview database. Never touch the main staging DB."""
import os
import sqlite3
from pathlib import Path
from auth_preview import PreviewStore

ROOT=Path(__file__).resolve().parent
DB=ROOT/"data"/"auth_preview.sqlite3"
os.umask(0o077)
if DB.exists():
    print("REFUSING_TO_OVERWRITE_EXISTING_DATABASE")
    raise SystemExit(2)
with sqlite3.connect(DB) as c:
    c.execute("PRAGMA foreign_keys=ON")
    c.executescript((ROOT/"schema.sql").read_text(encoding="utf-8"))
store=PreviewStore(DB)
store.migrate()
with sqlite3.connect(DB) as c:
    names=[r[0] for r in c.execute(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    assert len(names)==10, names
    for name in names:
        assert c.execute('SELECT count(*) FROM "'+name+'"').fetchone()[0]==0, name
    assert c.execute("PRAGMA integrity_check").fetchone()[0]=="ok"
DB.chmod(0o600)
print("AUTH_PREVIEW_CREATED_EMPTY")
print("TABLE_COUNT",len(names))
print("DB_MODE",oct(DB.stat().st_mode & 0o777))