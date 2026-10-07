#!/usr/bin/env python3
"""取 nodejs-mobile 的 NodeMobile.xcframework（iOS 内嵌 Node 运行时）。

为什么用脚本而不是把二进制入库：解压后 device 54.9 MB + simulator fat 115.4 MB，
放进 git 会让仓库臃肿；版本与校验值登记在 `ThirdParty/node-mobile.lock.json`，
谁都能用一条命令拿到**同一个**产物并校验。

用法：
    python Scripts/fetch_nodejs_mobile.py          # 下载（若需要）+ 校验 + 解压
    python Scripts/fetch_nodejs_mobile.py --check  # 只校验已解压的产物
环境变量：
    NODEJS_MOBILE_ZIP  复用已有的 zip（跳过下载）
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, "ThirdParty", "node-mobile.lock.json")
CACHE_DIR = os.path.join(ROOT, "ThirdParty", ".cache")
UNPACK_ROOT = os.path.join(ROOT, "ThirdParty", "nodejs-mobile")
# 只解 xcframework：include/node/** 是给原生模块编译用的 500 个头文件，本项目用不到。
KEEP_PREFIX = "NodeMobile.xcframework/"


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock() -> dict:
    with open(LOCK, encoding="utf-8") as handle:
        return json.load(handle)


def download(url: str, target: str) -> None:
    print(f"downloading {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "YPlayer-fetch-nodejs-mobile"})
    with urllib.request.urlopen(request, timeout=900) as response, open(target, "wb") as handle:  # noqa: S310
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            handle.write(chunk)


def unpack(zip_path: str) -> int:
    written = 0
    with zipfile.ZipFile(zip_path) as archive:
        for info in archive.infolist():
            if not info.filename.startswith(KEEP_PREFIX):
                continue
            target = os.path.join(UNPACK_ROOT, info.filename)
            if info.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with archive.open(info) as source, open(target, "wb") as handle:
                while True:
                    chunk = source.read(1 << 20)
                    if not chunk:
                        break
                    handle.write(chunk)
            written += 1
    return written


def main() -> int:
    lock = load_lock()
    artifact = lock["artifact"]
    xcframework = os.path.join(UNPACK_ROOT, "NodeMobile.xcframework")

    if "--check" in sys.argv:
        if not os.path.exists(xcframework):
            print(f"MISSING: {xcframework}（先跑一次不带 --check 的取产物）")
            return 1
        print(f"OK: {xcframework}")
        return 0

    os.makedirs(CACHE_DIR, exist_ok=True)
    zip_path = os.environ.get("NODEJS_MOBILE_ZIP") or os.path.join(CACHE_DIR, artifact["file"])

    if not os.path.exists(zip_path) or os.path.getsize(zip_path) != artifact["bytes"]:
        download(artifact["url"], zip_path)

    size = os.path.getsize(zip_path)
    digest = sha256_of(zip_path)
    if size != artifact["bytes"] or digest != artifact["sha256"]:
        print(f"CHECKSUM MISMATCH bytes={size} sha256={digest}")
        return 1
    print(f"verified bytes={size} sha256={digest}")

    written = unpack(zip_path)
    print(f"unpacked {written} files into {UNPACK_ROOT}")
    print(f"xcframework={xcframework}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
