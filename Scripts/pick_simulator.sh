#!/usr/bin/env bash
# 选一个可用的 iPhone 模拟器并打印它的 UDID。
#
# 关键：**优先挑与当前 Xcode 的 iPhoneSimulator SDK 主版本一致的 runtime**。
# macos 运行镜像里自带的模拟器 runtime 往往比 workflow 里 pin 的 Xcode 新
# （实测实例：Xcode 16.4 + 镜像自带的 iOS 26.2 设备），拿新 runtime 跑旧 Xcode 的构建会先落到
# 那台设备上并打印 `Could not get trait set for device iPhone18,1 with version 26.2` 这类噪声。
# 注意：同一串报错里还有**第二层原因**（SwiftPM 产物双链接缺 `Ld`），与本脚本无关，
# 见 docs/构建与分发.md 的「已知的构建陷阱」21、22。
# 没有匹配的 runtime 时退回「最新的 iOS runtime」，不让脚本直接失败。
#
# 为什么用脚本而不是把 python 内联进 workflow：内联的多行 python 在 YAML 里极易出错，
# 而且放脚本里 CI 与本地可以跑同一份逻辑。
set -euo pipefail

SDK_MAJOR="$(xcrun --sdk iphonesimulator --show-sdk-version | cut -d. -f1)"
export SDK_MAJOR

xcrun simctl list devices available --json | python3 -c '
import json, os, re, sys

sdk_major = os.environ["SDK_MAJOR"]
devices = json.load(sys.stdin)["devices"]


def runtime_major(key):
    match = re.search(r"iOS-(\d+)", key)
    return match.group(1) if match else ""


def version_key(key):
    return [int(part) for part in re.findall(r"\d+", key)]


runtimes = sorted((key for key in devices if "iOS" in key), key=version_key, reverse=True)
ordered = [key for key in runtimes if runtime_major(key) == sdk_major] or runtimes

for runtime in ordered:
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit
raise SystemExit("no iPhone simulator available")
'
