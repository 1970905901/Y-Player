#!/usr/bin/env bash
# 选一个可用的 iPhone 模拟器并打印它的 UDID。
#
# 为什么用脚本而不是把 python 内联进 workflow：内联的多行 python 在 YAML 里极易出错，
# 而且放脚本里 CI 与本地可以跑同一份逻辑。
set -euo pipefail

xcrun simctl list devices available --json | python3 -c '
import json, sys

devices = json.load(sys.stdin)["devices"]
# 取最新 iOS runtime 里的第一个 iPhone。
for runtime in sorted((key for key in devices if "iOS" in key), reverse=True):
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit
raise SystemExit("no iPhone simulator available")
'
