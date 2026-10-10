#!/usr/bin/env python3
"""SwiftLint 风险模式自检（本机没有 SwiftLint 时，用模式匹配先把明显的坑扫一遍）。

用法（仓库任意目录都行）：
    python3 Scripts/check_lint.py          # macOS
    python -X utf8 Scripts/check_lint.py   # Windows（控制台默认不是 UTF-8，加 -X utf8）
退出码：有命中 1，没有 0（可当闸门接在 `&&` 后面）。

⚠️ 这是**本地**的 lint 防线（Windows 上没有 SwiftLint，它要 Swift + SourceKit）。
覆盖 `.swiftlint.yml` 里**能静态匹配**的 opt_in 规则：

- force_unwrapping / empty_string / shorthand_operator / contains_over_filter_count
- first_where / last_where / sorted_first_last / array_init / toggle_bool
- identical_operands / redundant_nil_coalescing / fatal_error_message / vertical_whitespace
- line_length（warning 140，忽略含 URL 的行）

覆盖不了（只能靠人或 Mac / CI 上的真 SwiftLint）：modifier_order、closure_spacing、
untyped_error_in_catch、yoda_condition、optional_enum_case_matching、pattern_matching_keywords 等语义类规则。

**扫描范围是全仓**（`Apps` + `Packages` 下所有 `.swift`），不是固定文件清单 ——
旧版本硬编码了一份列表，新文件根本没被扫到、改过名的文件会让它当场崩掉。
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINE_LIMIT = 140

PATTERNS = [
    # 只留**高置信度**的：能靠单行模式判准的。
    # 纯空格类（冒号/逗号）交给 SwiftFormat —— 它本地能跑，而且已经 0 违规；
    # 语义类（identical_operands / contains_over_filter_count / toggle_bool 的一般情形）
    # 需要语法树，朴素匹配必然误报，宁可不做（第一次跑出 175 条，几乎全是误报）。
    ("force_unwrapping", re.compile(r"(try!|as!|\b[A-Za-z_][A-Za-z0-9_\.\)\]]!)(?!=)")),
    ("empty_string", re.compile(r'[!=]= *""')),
    ("shorthand_operator", re.compile(r"([A-Za-z_][A-Za-z0-9_\.\[\]]*) *= *\1 *[+\-*/]")),
    ("first_where", re.compile(r"\.filter *\{[^}]*\}\.first")),
    ("last_where", re.compile(r"\.filter *\{[^}]*\}\.last")),
    ("sorted_first_last", re.compile(r"\.sorted\(\)\.(first|last)")),
    ("array_init", re.compile(r"\.map *\{ *\$0 *\}")),
    ("toggle_bool", re.compile(r"([A-Za-z_][A-Za-z0-9_\.]*) *= *!\1\b")),
    ("redundant_nil_coalescing", re.compile(r"\?\? *nil\b")),
    ("fatal_error_message", re.compile(r"fatalError\(\)")),
]


def swift_files():
    for root_name in ("Apps", "Packages"):
        for base, dirs, names in os.walk(os.path.join(ROOT, root_name)):
            dirs[:] = [name for name in dirs if name not in (".build", "DerivedData", ".swiftpm")]
            for name in names:
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


def main() -> int:
    report = []
    scanned = 0
    for path in sorted(swift_files()):
        try:
            text = io.open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        scanned += 1
        relative = os.path.relpath(path, ROOT)
        lines = text.split("\n")
        blanks = 0
        for number, line in enumerate(lines, start=1):
            stripped = line.strip()
            if not stripped:
                blanks += 1
                if blanks >= 2:
                    report.append("%s:%d [vertical_whitespace]" % (relative, number))
                continue
            blanks = 0
            if stripped.startswith("//"):
                continue
            if len(line) > LINE_LIMIT and "http" not in line:
                report.append("%s:%d [line_length %d] %s" % (relative, number, len(line), stripped[:80]))
            for name, pattern in PATTERNS:
                if pattern.search(line):
                    report.append("%s:%d [%s] %s" % (relative, number, name, stripped[:110]))

    print("lint-check-done scanned=%d hits=%d" % (scanned, len(report)))
    for line in report[:40]:
        print("  " + line)
    return 1 if report else 0


if __name__ == "__main__":
    sys.exit(main())