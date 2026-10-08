#!/usr/bin/env python3
"""校验 App 图标资源（CI 阻断步骤）。

为什么需要：`AppIcon.appiconset` 里少一张图、尺寸不对、或者 iOS 图标带了 alpha 通道，
actool 有的是硬报错、有的**只是警告**，很容易带着问题进包（等 App Store 上传被拒才发现）。
这里用纯标准库解析 PNG 头（不依赖 Pillow），一次说清三件事：

1. `Contents.json` 是 Xcode 14+ 的「单尺寸 1024」形态，条目与文件名一一对应；
2. 文件确实是 1024×1024 的 PNG；
3. iOS 那张没有 alpha 通道（App Store 的 1024 营销图不接受透明）。

用法：python Scripts/check_app_icons.py
退出码：0 全部通过；1 有明细（每条都给出可读原因）。
"""

from __future__ import annotations

import json
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_SIZE = 1024
# PNG IHDR 的颜色类型：0 灰度、2 真彩、3 索引、4 灰度+alpha、6 真彩+alpha
ALPHA_COLOR_TYPES = (4, 6)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

TARGETS = (
    ("iOS", ("Apps", "YPlayer-iOS", "Assets.xcassets", "AppIcon.appiconset"), "ios", False),
    ("macOS", ("Apps", "YPlayer-macOS", "Assets.xcassets", "AppIcon.appiconset"), "macos", True),
)


def read_png_header(path: str):
    """返回 (width, height, color_type)；不是 PNG 或缺 IHDR 返回 None。"""
    with open(path, "rb") as handle:
        head = handle.read(33)
    if head[:8] != PNG_SIGNATURE or head[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", head[16:24])
    return width, height, head[25]


def check_target(label: str, parts: tuple, platform: str, allow_alpha: bool) -> list:
    problems = []
    relative = os.path.join(*parts)
    directory = os.path.join(ROOT, relative)
    manifest = os.path.join(directory, "Contents.json")
    if not os.path.exists(manifest):
        return ["%s：缺少 %s" % (label, os.path.join(relative, "Contents.json"))]

    with open(manifest, encoding="utf-8") as handle:
        try:
            payload = json.load(handle)
        except ValueError as error:
            return ["%s：Contents.json 不是合法 JSON：%s" % (label, error)]

    images = payload.get("images") or []
    if len(images) != 1:
        problems.append(
            "%s：期望 1 条图标记录（Xcode 14+ 单尺寸 1024 形态），实际 %d 条" % (label, len(images))
        )
        return problems

    entry = images[0]
    if entry.get("idiom") != "universal" or entry.get("platform") != platform:
        problems.append(
            "%s：条目应为 idiom=universal / platform=%s，实际 idiom=%s / platform=%s"
            % (label, platform, entry.get("idiom"), entry.get("platform"))
        )
    if entry.get("size") != "%dx%d" % (ICON_SIZE, ICON_SIZE):
        problems.append(
            "%s：条目 size 应为 %dx%d，实际 %s" % (label, ICON_SIZE, ICON_SIZE, entry.get("size"))
        )

    filename = entry.get("filename")
    if not filename:
        problems.append(
            "%s：条目没有 filename —— 图标会被静默漏掉（装出来是系统默认白图标）" % label
        )
        return problems

    path = os.path.join(directory, filename)
    if not os.path.exists(path):
        problems.append("%s：Contents.json 指向的 %s 不存在" % (label, os.path.join(relative, filename)))
        return problems

    header = read_png_header(path)
    if header is None:
        problems.append("%s：%s 不是合法 PNG（签名或 IHDR 缺失）" % (label, filename))
        return problems

    width, height, color_type = header
    if (width, height) != (ICON_SIZE, ICON_SIZE):
        problems.append(
            "%s：%s 尺寸 %dx%d，要求 %dx%d" % (label, filename, width, height, ICON_SIZE, ICON_SIZE)
        )
    if not allow_alpha and color_type in ALPHA_COLOR_TYPES:
        problems.append(
            "%s：%s 带 alpha 通道（color type %d）—— App Store 的 1024 图标不接受透明，"
            "用 Scripts/make_app_icons.py 重新生成" % (label, filename, color_type)
        )
    return problems


def main() -> int:
    problems = []
    for label, parts, platform, allow_alpha in TARGETS:
        found = check_target(label, parts, platform, allow_alpha)
        if found:
            problems.extend(found)
        else:
            print("OK   %s：%s（single-size %d，alpha=%s）" % (
                label,
                os.path.join(*parts),
                ICON_SIZE,
                "allowed" if allow_alpha else "forbidden",
            ))

    if problems:
        print("FAIL app icon assets:")
        for item in problems:
            print("  - " + item)
        return 1
    print("app icons look good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
