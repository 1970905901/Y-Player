#!/usr/bin/env python3
"""js2p bundle static analysis (M1.5 step 1).

Downloads the bundle, verifies its MD5 against the sibling .md5 file, then extracts
the host contract we must implement (catServerFactory / /msg / messageToDart) and the
Node built-in modules it actually depends on. Output: Tools/out/js2p-report.txt.

Usage:
    python Tools/analyze_js2p.py [url]
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
import urllib.request
from collections import Counter

DEFAULT_URL = "https://9280.kstore.vip/ceshi/index.js"

TOKENS = [
    "catServerFactory", "catDartServerPort", "messageToDart", "js2p", "_WEB_",
    "/msg", "/spider", "/config", "createServer", ".listen(", ".address(",
    "process.env", "NODE_ENV", "Buffer", "AbortController", "TextDecoder", "TextEncoder",
    "WebSocket", "node-fetch", "pako", "inflate", "deflate", "zlib",
    "child_process", "worker_threads", "require('fs')", 'require("fs")',
    '"sites"', '"parses"', '"lives"', '"wallpaper"', '"spider"', '"key"', '"api"',
    "__jsEvalReturn", "homeContent", "playerContent",
]

CONTEXTS = [
    ("catServerFactory", r"catServerFactory", 420),
    ("/msg", r'"/msg"', 420),
    ("catDartServerPort", r"catDartServerPort", 420),
    ("listen(", r"\.listen\(", 300),
    ("/spider", r'"/spider', 240),
    ("/config", r'"/config', 240),
]


def fetch(url: str, timeout: int = 180) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "YPlayer-analyzer/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def main() -> int:
    url = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cache_dir = os.path.join(root, "Tools", ".cache")
    out_dir = os.path.join(root, "Tools", "out")
    os.makedirs(cache_dir, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)

    print(f"downloading {url}")
    data = fetch(url)
    with open(os.path.join(cache_dir, "index.js"), "wb") as handle:
        handle.write(data)

    remote = fetch(url + ".md5").decode("utf-8", "replace").strip()
    local = hashlib.md5(data).hexdigest()
    text = data.decode("utf-8", "replace")

    lines: list[str] = [
        "# js2p bundle static analysis",
        f"url = {url}",
        f"bytes = {len(data)}",
        f"remote_md5 = {remote}",
        f"local_md5 = {local}",
        f"md5_match = {remote.lower() == local}",
        "",
        "== require() modules (top 80) ==",
    ]

    requires = re.findall(r"""require\(\s*["']([^"']{1,80})["']\s*\)""", text)
    for name, count in Counter(requires).most_common(80):
        lines.append(f"{name:<36}{count}")
    lines.append(f"total_require_sites = {text.count('require(')}")
    lines.append("")

    lines.append("== token counts ==")
    for token in TOKENS:
        count = text.count(token)
        if count:
            lines.append(f"{token:<26}{count}")
    lines.append("")

    for title, pattern, radius in CONTEXTS:
        lines.append(f"== context: {title} ==")
        matches = list(re.finditer(pattern, text))[:3]
        for index, match in enumerate(matches, start=1):
            start = max(0, match.start() - radius)
            end = min(len(text), match.end() + radius)
            lines.append(f"--- match {index} ---")
            lines.append(text[start:end])
        lines.append("")

    # code region right before the esbuild legal-comment block (contains the entry logic)
    marker = text.find("Copyright(c) 2014 Jonathan Ong")
    if marker > 0:
        lines.append("== tail before legal comments ==")
        lines.append(text[max(0, marker - 1800):marker])
        lines.append("")

    report_path = os.path.join(out_dir, "js2p-report.txt")
    with open(report_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    print(f"report written: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
