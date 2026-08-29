#!/usr/bin/env python3
"""Compile the 18+ blocklist source into the native asset.

  tool/web_blocker/blocked_websites.json  ->  android/app/src/main/assets/adult_domains.txt.gz

Run via `bash tool/dev.sh adultlist`. The native WebBlockEngine reads only the
.gz (one entry per line, `#` comments allowed) and matches a browser host as a
suffix set: the host itself, any parent label, or the bare TLD. The Dart test
test/adult_blocklist_test.dart fails whenever source and asset drift.
"""
import gzip
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tool/web_blocker/blocked_websites.json"
OUT = ROOT / "android/app/src/main/assets/adult_domains.txt.gz"
# A lowercase registrable host (labels + a 2-24 letter TLD) or a bare TLD.
HOST = re.compile(r"^(?:[a-z0-9-]+\.)*[a-z]{2,24}$")
HEADER = (
    "# Detoxo adult-domains blocklist - GENERATED from tool/web_blocker/blocked_websites.json\n"
    "# by `bash tool/dev.sh adultlist`; do not edit by hand. Matched natively as a suffix set:\n"
    "# the host, any parent label, or the bare TLD (WebBlockEngine.matchHost).\n"
)


def main() -> int:
    src = json.loads(SRC.read_text())
    allow = set(src.get("allow", []))
    entries = sorted(set(src["domains"]) | set(src["tlds"]))
    bad = [e for e in entries if not HOST.match(e) or e.startswith("www.") or e in allow]
    if bad:
        print(f"refusing invalid entries: {bad}", file=sys.stderr)
        return 1
    body = (HEADER + "\n".join(entries) + "\n").encode()
    # mtime=0 + no filename: byte-stable output, so re-running never dirties git.
    with OUT.open("wb") as f, gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0) as gz:
        gz.write(body)
    print(f"{len(entries)} entries -> {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
