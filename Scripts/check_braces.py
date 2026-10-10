#!/usr/bin/env python3
"""括号/引号平衡自查（Windows 侧盲写 Swift 时用）。

为什么需要它：本机（Windows）没有 Swift 工具链，这类结构性错误在 Mac / CI 上要等一轮编译
才发现，这里能提前一秒抓到。**脚本进版本库**（M21P1）之后，Mac 上也能跑同一条命令，
两边看的是同一份规则。

用法（在仓库任意目录都行，路径按脚本位置推）：
    python3 Scripts/check_braces.py
退出码：有问题 1，没问题 0（可以直接接在 `&&` 后面当闸门）。
"""

import glob
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TARGETS = [
    # 递归 + 通配整个 Packages：漏掉过东西才改成这样 —— 旧名单是手写的固定几行，
    # 于是 `CatVodUI/Sources/CatVodUI/Platform/`（不匹配 `*.swift`）与 `CatVodUI` 的测试
    # 一直在扫描范围之外（M02P16 那轮新增的两个文件正好都在洞外才发现）。
    "Packages/*/Sources/**/*.swift",
    "Packages/*/Tests/**/*.swift",
    "Apps/**/*.swift",
]

# 第三方源码与构建产物不扫（`.build` 里是依赖副本，报错也不是我们写的）。
EXCLUDE = ("/.build/", "/DerivedData/", "/ThirdParty/")


def scan(path):
    """粗扫 Swift 源码的括号平衡（跳过注释与字符串）。

    只抓结构性错误（漏/多花括号），不做语法分析 —— 目的是在本地（没有 Swift 编译器时）
    提前发现「插入点落错位置」这类事故。
    """
    text = io.open(path, encoding="utf-8").read()
    errors = []
    depth = 0
    paren = 0
    index = 0
    line = 1
    length = len(text)
    while index < length:
        char = text[index]
        if char == "\n":
            line += 1
            index += 1
            continue
        if text.startswith("//", index):
            newline = text.find("\n", index)
            index = length if newline < 0 else newline
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            if end < 0:
                errors.append("line %d: 块注释没有收尾" % line)
                break
            line += text.count("\n", index, end)
            index = end + 2
            continue
        if text.startswith('"""', index):
            end = text.find('"""', index + 3)
            if end < 0:
                errors.append("line %d: 多行字符串没有收尾" % line)
                break
            line += text.count("\n", index, end)
            index = end + 3
            continue
        # 原始字符串 `#"..."#` / `##"..."##`：结束标记是 `"` + 同样数量的 `#`
        # （不认这个的话，`#"{"id":"x"}"#` 这类 JSON 片段会被当成「字符串提前结束」，括号统计跟着失真）
        if char == "#":
            hashes = 0
            cursor = index
            while cursor < length and text[cursor] == "#":
                hashes += 1
                cursor += 1
            if cursor < length and text[cursor] == '"':
                terminator = '"' + "#" * hashes
                end = text.find(terminator, cursor + 1)
                if end < 0:
                    errors.append("line %d: 原始字符串没有收尾" % line)
                    break
                line += text.count("\n", index, end)
                index = end + len(terminator)
                continue
        if char == '"':
            cursor = index + 1
            while cursor < length:
                if text[cursor] == "\\":
                    cursor += 2
                    continue
                if text[cursor] == '"':
                    break
                if text[cursor] == "\n":
                    errors.append("line %d: 字符串字面量跨行未闭合" % line)
                    break
                cursor += 1
            index = cursor + 1
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth < 0:
                errors.append("line %d: 多余的 `}`" % line)
                depth = 0
        elif char == "(":
            paren += 1
        elif char == ")":
            paren -= 1
            if paren < 0:
                errors.append("line %d: 多余的 `)`" % line)
                paren = 0
        index += 1
    return errors, depth, paren


def extra_checks(path):
    """行级小检查（SwiftLint 的 `vertical_whitespace` / `trailing_whitespace` 在 CI 上会拦）：
    连续空行 > 1、行尾空白。"""
    problems = []
    lines = io.open(path, encoding="utf-8").read().split("\n")
    blanks = 0
    for number, line in enumerate(lines, start=1):
        if line.strip() == "":
            blanks += 1
            if blanks > 1:
                problems.append("line %d: 连续空行超过一行" % number)
        else:
            blanks = 0
        if line != line.rstrip():
            problems.append("line %d: 行尾有空白" % number)
    return problems


def main():
    paths = set()
    for pattern in TARGETS:
        for path in glob.glob(os.path.join(ROOT, pattern), recursive=True):
            # Windows 上 glob 给的是反斜杠路径；统一成正斜杠再判排除项、再去重、再打印。
            normalized = path.replace("\\", "/")
            if any(marker in normalized for marker in EXCLUDE):
                continue
            paths.add(os.path.relpath(path, ROOT))
    files = sorted(paths)
    problems = 0
    for path in files:
        errors, depth, paren = scan(os.path.join(ROOT, path))
        errors = extra_checks(os.path.join(ROOT, path)) + errors
        if errors or depth != 0 or paren != 0:
            problems += 1
            print("%s: 花括号深度 %d / 圆括号深度 %d" % (path, depth, paren))
            for message in errors[:5]:
                print("    " + message)
    print("check-braces-done：%d 个文件有问题（共查 %d）" % (problems, len(files)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())