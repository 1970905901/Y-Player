#!/usr/bin/env python3
"""把 ThirdParty/mpvkit.lock.json 的 binaryTarget 校验和与 MPVKit 上游 manifest 对齐。

为什么需要它：lock 文件的用途是「构建可复现 + 升级必须留痕」，而人工抄 30 个校验和
必然出错。MPVKit 的 `Package.swift` 里每个 binaryTarget 都写了 name/url/checksum，
所以**上游 manifest 才是唯一事实来源** —— 本脚本据此重写 lock 文件里的校验和段。

用法：
    python Tools/sync_mpvkit_lock.py            # 用 lock 里的 ref
    python Tools/sync_mpvkit_lock.py 1.0.0      # 指定 tag
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, "ThirdParty", "mpvkit.lock.json")
MANIFEST_URL = "https://raw.githubusercontent.com/mpvkit/MPVKit/{ref}/Package.swift"

TARGET_PATTERN = re.compile(
    r"\.binaryTarget\(\s*"
    r"name:\s*\"(?P<name>[^\"]+)\",\s*"
    r"url:\s*\"(?P<url>[^\"]+)\",\s*"
    r"checksum:\s*\"(?P<checksum>[0-9a-f]{64})\"",
    re.MULTILINE,
)

# 目标依赖块：`name: "_MPVKit"` / `name: "_FFmpeg"` 之后到 `],` 之间的那些 target 名。
# 为什么要按依赖图取而不是「名字不以 -GPL 结尾」：`Libsmbclient` 只被 -GPL 变体依赖，
# 用名字后缀滤会把它误算进 LGPL 集合。
DEPENDENCY_PATTERN = re.compile(
    r"name:\s*\"_(?P<target>MPVKit|FFmpeg)\",\s*dependencies:\s*\[(?P<body>[^\]]*)\]",
    re.MULTILINE,
)
TARGET_NAME_PATTERN = re.compile(r"\"([A-Za-z0-9_]+)\"")


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "YPlayer-sync-mpvkit"})
    with urllib.request.urlopen(request, timeout=120) as response:  # noqa: S310
        return response.read().decode("utf-8")


def main() -> int:
    with open(LOCK, encoding="utf-8") as handle:
        lock = json.load(handle)

    entry = next(item for item in lock["entries"] if item.get("name") == "MPVKit")
    ref = sys.argv[1] if len(sys.argv) > 1 else entry["ref"]
    manifest = fetch(MANIFEST_URL.format(ref=ref))

    found = {}
    urls = {}
    for match in TARGET_PATTERN.finditer(manifest):
        found[match.group("name")] = match.group("checksum")
        urls[match.group("name")] = match.group("url")

    if not found:
        print("未从 manifest 里解析到任何 binaryTarget —— 格式可能变了，停止")
        return 1

    print(f"manifest ref={ref} binaryTargets={len(found)}")

    # LGPL 变体实际用到的 target：从 `_MPVKit` / `_FFmpeg` 的依赖列表里取。
    lgpl_names: set[str] = set()
    for match in DEPENDENCY_PATTERN.finditer(manifest):
        for name in TARGET_NAME_PATTERN.findall(match.group("body")):
            if name in found:
                lgpl_names.add(name)

    if not lgpl_names:
        print("未能从依赖列表里解析出 LGPL 变体的 target —— manifest 格式可能变了，停止")
        return 1

    gpl_only = sorted(set(found) - lgpl_names)
    print(f"LGPL 变体用到 {len(lgpl_names)} 个 target；其余 {len(gpl_only)} 个只在 GPL 变体里：{gpl_only}")

    lgpl = {name: found[name] for name in sorted(lgpl_names)}
    entry["binaryTargetChecksums"] = lgpl
    entry["binaryTargetChecksumsSource"] = MANIFEST_URL.format(ref=ref)
    entry["unverifiedChecksums"] = []
    entry["ref"] = ref

    with open(LOCK, "w", encoding="utf-8") as handle:
        json.dump(lock, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print(f"已写入 {len(lgpl)} 条校验和；unverifiedChecksums 已清空")
    for name in sorted(lgpl):
        print(f"  {name}: {lgpl[name]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
