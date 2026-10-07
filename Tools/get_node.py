"""下载便携版 Node（只解出 node.exe），并校验 sha256。

Windows 上没法跑 iOS/macOS host，但 js2p 的 spider 服务本身是 Node 脚本，
所以本机 node 足以做 M1.6 的「真 bundle 端到端」契约实测。
"""

import hashlib
import os
import urllib.request
import zipfile

VER = "v22.11.0"
ARCHIVE = f"node-{VER}-win-x64"
BASE = f"https://nodejs.org/dist/{VER}"
CACHE = r"d:\worka\1\Tools\.cache"
NODE_DIR = os.path.join(CACHE, "node")
REPORT = r"d:\worka\1\Tools\out\get-node.txt"
ZIP_PATH = os.path.join(CACHE, ARCHIVE + ".zip")

lines = []


def log(text):
    lines.append(str(text))
    print(text)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


os.makedirs(NODE_DIR, exist_ok=True)
node_exe = os.path.join(NODE_DIR, "node.exe")

if os.path.exists(node_exe):
    log("node.exe already present")
else:
    if not os.path.exists(ZIP_PATH) or os.path.getsize(ZIP_PATH) < 1_000_000:
        url = f"{BASE}/{ARCHIVE}.zip"
        log(f"downloading {url}")
        urllib.request.urlretrieve(url, ZIP_PATH)  # noqa: S310
    log(f"zipBytes={os.path.getsize(ZIP_PATH)}")

    shasums = urllib.request.urlopen(f"{BASE}/SHASUMS256.txt", timeout=60).read().decode()  # noqa: S310
    expected = None
    for row in shasums.splitlines():
        parts = row.split()
        if len(parts) == 2 and parts[1] == f"{ARCHIVE}.zip":
            expected = parts[0]
    actual = sha256(ZIP_PATH)
    log(f"sha256Match={expected == actual} expected={expected} actual={actual}")

    with zipfile.ZipFile(ZIP_PATH) as zip_file:
        member = f"{ARCHIVE}/node.exe"
        with zip_file.open(member) as source, open(node_exe, "wb") as target:
            while True:
                chunk = source.read(1 << 20)
                if not chunk:
                    break
                target.write(chunk)
    log(f"nodeExeBytes={os.path.getsize(node_exe)}")

with open(REPORT, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
print("get-node-done")
