#!/usr/bin/env python3
"""Create and verify an empty isolated SQLite prototype; never connect to WAHA or Firebase."""
from pathlib import Path
import os, sqlite3

root = Path(__file__).resolve().parent
data = root / "data"
dbfile = data / "smart_content_creator.sqlite3"
schema = root / "schema.sql"
os.umask(0o077)
root.chmod(0o700)
data.mkdir(mode=0o700, exist_ok=True)
if dbfile.exists():
    print("DATABASE_ALREADY_EXISTS: refusing to overwrite", dbfile)
    raise SystemExit(2)
try:
    conn = sqlite3.connect(str(dbfile))
    try:
        conn.execute("PRAGMA foreign_keys=ON")
        conn.executescript(schema.read_text(encoding="utf-8"))
        bad = conn.execute("PRAGMA integrity_check").fetchone()[0]
        tables = [row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )]
        counts = {name:conn.execute('SELECT COUNT(*) FROM "' + name + '"').fetchone()[0] for name in tables}
        assert bad == "ok" and len(tables) == 8 and all(n == 0 for n in counts.values())
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        conn.commit()
        print("SQLITE_CREATED:", dbfile)
        print("INTEGRITY:", bad)
        print("TABLES:", ", ".join(tables))
        print("ROW_COUNTS:", counts)
    finally:
        conn.close()
    dbfile.chmod(0o600)
except Exception:
    if dbfile.exists():
        dbfile.unlink()
    raise