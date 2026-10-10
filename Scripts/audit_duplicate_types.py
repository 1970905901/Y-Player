#!/usr/bin/env python3
"""扫描「同一个模块里声明了同名类型」—— 这类冲突本地发现不了，只能等编译器报。

用法（仓库任意目录都行）：
    python3 Scripts/audit_duplicate_types.py
退出码：有同名冲突 1，没有 0。

为什么需要它：本地没有 Swift 工具链时，`swiftformat --lint` 只做**语法**解析、不做类型检查。
于是同一个模块里同时存在两个 `DanmakuSource` 这种情况，本地一路绿灯，
一到编译就是 `error: 'X' is ambiguous for type lookup in this context` ——
而且它会**挡住整个 job**，后面所有测试都是 skipped，看不到别的错。

判定：只看**顶层**类型（无缩进；`CodingKeys` / 嵌套 `Entry` 这类同名是语言允许的），
按 `Packages/<包>/Sources/<目标>/` 分组（同一目录树 = 同一个模块）。
不同模块同名也是允许的（例如 `HTTPRequest` 在 CatVodNet 与 FlyingFox 各有一个）。
"""

import io
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DECL = re.compile(
    r"^(?:public |internal |open |final |@MainActor |@Observable )*"
    r"(struct|enum|class|actor|protocol|typealias) ([A-Za-z_][A-Za-z0-9_]*)"
)


def targets():
    """产出 (模块目录, 文件列表)。"""
    packages = os.path.join(ROOT, "Packages")
    for package in sorted(os.listdir(packages)):
        sources = os.path.join(packages, package, "Sources")
        if not os.path.isdir(sources):
            continue
        # 目标是 Sources 下的一级目录（每个 target 一个目录）
        for target in sorted(os.listdir(sources)):
            target_path = os.path.join(sources, target)
            if not os.path.isdir(target_path):
                continue
            files = []
            for base, _, names in os.walk(target_path):
                for name in names:
                    if name.endswith(".swift"):
                        files.append(os.path.join(base, name))
            yield target_path, files


def main() -> int:
    duplicates = 0
    for target_path, files in targets():
        seen = defaultdict(list)
        for path in files:
            try:
                text = io.open(path, encoding="utf-8").read()
            except (OSError, UnicodeDecodeError):
                continue
            for number, line in enumerate(text.split("\n"), 1):
                match = DECL.match(line)
                if match:
                    seen[match.group(2)].append((path, number))
        clashes = {}
        for name, spots in seen.items():
            # 同一文件里出现两次：典型是 `#if os(macOS) … #else …` 的两个分支，语言允许，跳过
            if len(spots) > 1 and len({path for path, _ in spots}) > 1:
                clashes[name] = spots
        if not clashes:
            continue
        print("== %s" % os.path.relpath(target_path, ROOT))
        for name in sorted(clashes):
            print("   %s  ×%d" % (name, len(clashes[name])))
            for path, number in clashes[name]:
                print("      %s:%d" % (os.path.relpath(path, ROOT), number))
            duplicates += 1
    if duplicates == 0:
        print("没有同名类型冲突")
    else:
        print("\n共 %d 组，这些会变成 'ambiguous for type lookup'" % duplicates)
    return 1 if duplicates else 0


if __name__ == "__main__":
    sys.exit(main())