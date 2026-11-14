#!/usr/bin/env python3
"""Fetch and verify the official SQLite amalgamation for Android native builds."""

from __future__ import annotations

import hashlib
import io
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

VERSION = "3530400"  # SQLite 3.53.4
EXPECTED_SHA3_256 = "628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e"
ARCHIVE_NAME = f"sqlite-amalgamation-{VERSION}.zip"
URLS = (
    f"https://www.sqlite.org/2026/{ARCHIVE_NAME}",
    f"https://www2.sqlite.org/2026/{ARCHIVE_NAME}",
    f"https://www3.sqlite.org/2026/{ARCHIVE_NAME}",
)
OUTPUT_DIR = Path(".ci/sqlite3")


def download_verified() -> bytes:
    errors: list[str] = []
    for url in URLS:
        for attempt in range(1, 4):
            try:
                request = urllib.request.Request(
                    url,
                    headers={"User-Agent": "Water-provision-Android-build/1.0"},
                )
                with urllib.request.urlopen(request, timeout=120) as response:
                    payload = response.read()
                actual = hashlib.sha3_256(payload).hexdigest()
                if actual != EXPECTED_SHA3_256:
                    raise ValueError(
                        f"SHA3-256 mismatch for {url}: {actual}"
                    )
                return payload
            except (OSError, urllib.error.URLError, ValueError) as error:
                errors.append(f"{url} (attempt {attempt}): {error}")
                if attempt < 3:
                    time.sleep(attempt * 3)
    raise RuntimeError(
        "Unable to fetch a verified SQLite amalgamation.\n" + "\n".join(errors)
    )


def main() -> None:
    payload = download_verified()
    member_prefix = f"sqlite-amalgamation-{VERSION}/"
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for filename in ("sqlite3.c", "sqlite3.h"):
            member = member_prefix + filename
            try:
                content = archive.read(member)
            except KeyError as error:
                raise RuntimeError(f"Official SQLite archive is missing {member}") from error
            (OUTPUT_DIR / filename).write_bytes(content)

    source = OUTPUT_DIR / "sqlite3.c"
    header = OUTPUT_DIR / "sqlite3.h"
    if not source.is_file() or not header.is_file():
        raise RuntimeError("SQLite source/header were not extracted")
    print(
        f"Verified SQLite 3.53.4 amalgamation (SHA3-256 {EXPECTED_SHA3_256}); "
        f"prepared {source} and {header}."
    )


if __name__ == "__main__":
    main()
