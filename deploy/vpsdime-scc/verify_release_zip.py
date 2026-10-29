#!/usr/bin/env python3
"""Offline official-release artifact verifier / extractor.

Usage: python3 verify_release_zip.py pocketbase_*.zip <trusted-sha256>
No network access is performed. SHA256 must be independently verified.
Refuses to replace an existing PocketBase executable.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import zipfile

def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: verify_release_zip.py pocketbase.zip TRUSTED_SHA256")
    path = Path(sys.argv[1]).resolve()
    expected = sys.argv[2].strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise SystemExit("Trusted SHA256 must be exactly 64 hex digits")
    if not path.is_file():
        raise SystemExit("The specified official archive is not present")
    target = Path(__file__).resolve().parent / "pocketbase"
    if target.exists():
        raise SystemExit("Refusing to overwrite an existing PocketBase binary")

    digest = hashlib.sha256()
    with path.open("rb") as src:
        for block in iter(lambda: src.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise SystemExit("Archive SHA256 mismatch: no binary extracted")

    with zipfile.ZipFile(path, "r") as archive:
        matches = [item for item in archive.infolist()
                   if item.filename == "pocketbase" and not item.is_dir()]
        if len(matches) != 1:
            raise SystemExit("Expected precisely one pocketbase binary in archive")
        item = matches[0]
        if not 1000000 <= item.file_size <= 300000000:
            raise SystemExit("Executable size outside expected bounds")
        fd, temp = tempfile.mkstemp(prefix=".pb-verified-", dir=str(target.parent))
        try:
            with os.fdopen(fd, "wb") as dest, archive.open(item) as payload:
                shutil.copyfileobj(payload, dest, length=1024*1024)
                dest.flush()
                os.fsync(dest.fileno())
            with open(temp, "rb") as stream:
                hdr = stream.read(20)
            if hdr[:4] != b"\x7fELF" or hdr[18:20] != b"\x3e\x00":
                raise SystemExit("Official asset must contain an x86_64 ELF binary")
            os.chmod(temp, 0o555)
            os.replace(temp, target)
            print("Verified official archive checksum; linux/amd64 binary extracted.")
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

if __name__ == "__main__":
    main()
