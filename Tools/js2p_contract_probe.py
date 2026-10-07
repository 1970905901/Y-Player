#!/usr/bin/env python3
"""js2p 宿主契约回归（任意平台可跑）。

与 `Tools/analyze_js2p.py`（静态分析）互补：本脚本**实跑** bundle 并断言契约。
M16P2 的手动实测已证明该路径可行，这里把它变成可重复的作业。

断言分级（重要）：
- **硬断言**（失败即退出码 1）：就绪行可解析出端口、`GET /health` 返回 `ok:true`。
  这两项只依赖 bundle 自身，完全确定。
- **软断言**（只报告，不影响退出码）：站点数、`/spider/<key>/init` 探活。
  它们依赖 bundle 启动时拉取的**远端配置**（`RemoteWexConfig`），远端抖动
  不应该把正常的 PR / 定时任务判成「契约破坏」，因此只记录证据。

用法：
    python Tools/js2p_contract_probe.py [bundle-url]
环境变量：
    JS2P_NODE        node 可执行文件路径（默认 `node`，本地可用便携版）
    JS2P_BUNDLE_URL  覆盖 bundle 地址
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

DEFAULT_URL = "https://9280.kstore.vip/ceshi/index.js"
READY = re.compile(r"CatVodSpiderios listening on http://127\.0\.0\.1:(\d+)")
LOADED_KEYS = re.compile(r"site config loaded, keys=([\w,]+)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(ROOT, "Tools", ".cache")
OUT_DIR = os.path.join(ROOT, "Tools", "out")

lines: list[str] = []
hard_failures: list[str] = []


def log(text: str) -> None:
    lines.append(str(text))
    print(text)


def write_report() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "js2p-contract.txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def fetch(url: str, timeout: int = 180) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "YPlayer-contract/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        return response.read()


def ensure_bundle(url: str) -> str:
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, "index.js")
    if not os.path.exists(path) or os.path.getsize(path) < 1_000_000:
        log(f"downloading bundle: {url}")
        with open(path, "wb") as handle:
            handle.write(fetch(url))

    digest = hashlib.md5()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    log(f"bundleBytes={os.path.getsize(path)} md5={digest.hexdigest()}")

    # 同目录发布的 .md5 是「官方当前版本」的指纹：不一致说明上游换了 bundle（软信号）。
    try:
        published = fetch(url + ".md5", timeout=60).decode("utf-8", "replace").strip().split()[0]
        if published.lower() == digest.hexdigest():
            log(f"publishedMd5=match ({published})")
        else:
            log(f"publishedMd5=MISMATCH published={published} local={digest.hexdigest()} (仅提示)")
    except Exception as error:  # noqa: BLE001
        log(f"publishedMd5=unavailable ({type(error).__name__}: {error})")
    return path


def main() -> int:
    url = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("JS2P_BUNDLE_URL", DEFAULT_URL)
    node = os.environ.get("JS2P_NODE", "node")

    bundle = ensure_bundle(url)
    stdout_lines: list[str] = []

    try:
        proc = subprocess.Popen(  # noqa: S603
            [node, os.path.basename(bundle)],
            cwd=os.path.dirname(bundle),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
    except FileNotFoundError:
        log(f"node 不可用：{node}（CI 请用 actions/setup-node，或设 JS2P_NODE）")
        write_report()
        return 1

    def pump(stream, tag: str) -> None:
        for raw in stream:
            line = raw.rstrip("\r\n")
            stdout_lines.append(line)
            if "incoming request" not in line and '"msg":"request completed"' not in line:
                log(f"[{tag}] {line[:220]}")

    threading.Thread(target=pump, args=(proc.stdout, "stdout"), daemon=True).start()
    threading.Thread(target=pump, args=(proc.stderr, "stderr"), daemon=True).start()

    port = None
    keys: list[str] = []
    deadline = time.time() + 90
    while time.time() < deadline:
        for line in list(stdout_lines):
            match = READY.search(line)
            if match:
                port = int(match.group(1))
            found = LOADED_KEYS.search(line)
            if found:
                keys = found.group(1).split(",")
        if port:
            break
        time.sleep(0.3)

    if port is None:
        hard_failures.append("就绪行未出现（90s 内没有解析到端口）")
        log("HARD FAIL: ready line missing")
        proc.kill()
        write_report()
        return 1

    log(f"HARD OK: ready port={port}")
    base = f"http://127.0.0.1:{port}"

    def get(path: str, timeout: int = 20, limit: int = 4000) -> tuple[int, str]:
        try:
            with urllib.request.urlopen(base + path, timeout=timeout) as response:  # noqa: S310
                return response.status, response.read(limit).decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            return error.code, error.read(400).decode("utf-8", "replace")
        except Exception as error:  # noqa: BLE001
            return 0, f"{type(error).__name__}: {error}"

    status, body = get("/health")
    if status == 200 and '"ok":true' in body:
        log(f"HARD OK: GET /health -> {status} {body[:120]}")
    else:
        hard_failures.append(f"GET /health 异常：status={status} body={body[:120]}")
        log(f"HARD FAIL: GET /health -> {status} {body[:120]}")

    # ---- 软断言（只报告） ----
    # `/full-config` 实测 19 KB 左右：必须读全量，否则 JSON 被截断会误判成解析失败。
    status, body = get("/full-config", timeout=30, limit=4_000_000)
    site_count = 0
    if status == 200:
        try:
            payload = json.loads(body)
            sites = (payload.get("video") or {}).get("sites") or []
            site_count = len(sites)
        except ValueError:
            site_count = -1
    log(f"SOFT: GET /full-config -> {status} sites={site_count}")

    if keys:
        key = keys[0]
        request = urllib.request.Request(  # noqa: S310
            f"{base}/spider/{key}/init",
            data=b"{}",
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=25) as response:  # noqa: S310
                text = response.read(300).decode("utf-8", "replace")
                log(f"SOFT: POST /spider/{key}/init -> {response.status} {text[:160]}")
        except Exception as error:  # noqa: BLE001
            log(f"SOFT: POST /spider/{key}/init -> {type(error).__name__}: {error}")
    else:
        log("SOFT: 启动日志里没有 site config keys（远端配置未加载）")

    proc.kill()
    log(f"--- result: hardFailures={len(hard_failures)} ---")
    write_report()
    for failure in hard_failures:
        print(f"FAILED: {failure}")
    return 1 if hard_failures else 0


if __name__ == "__main__":
    sys.exit(main())

