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
- type_body_length（warning 300 / error 450）与 file_length（warning 500 / error 800）——
  纯行数统计，本机就能算准；CI 曾因 `LibavFFmpegSession` 类型体 501 > 450 红过一次（M04P17）
- platform_branch：`CatVodUI` 的**业务视图**里不许出现 `#available` / `#if os(...)`
  （`docs/UI 规范.md` 第二节：版本差异收进 `Sources/CatVodUI/Platform/` 基础件；
  `#if canImport(...)` 是「可选原生依赖」的能力探测，不算 —— 规范里有例外说明）

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
# 与 .swiftlint.yml 对齐（只有 error 判失败；warning 只提示）
TYPE_BODY_WARNING = 300
TYPE_BODY_ERROR = 450
FILE_LENGTH_WARNING = 500
FILE_LENGTH_ERROR = 800

# 版本分支只许出现在基础件里（`docs/UI 规范.md` 第二节）：业务视图写了就当场拦（M03P15）。
PLATFORM_BRANCH_PATTERN = re.compile(r"#available\(|#if\s+os\(|#elseif\s+os\(")
PLATFORM_BRANCH_PREFIX = "Packages/CatVodUI/Sources/CatVodUI/"
PLATFORM_BRANCH_DIR = "Packages/CatVodUI/Sources/CatVodUI/Platform/"


def platform_branch_hit(relative, line):
    """CatVodUI 业务视图里的版本分支 —— 命中就给一行提示（不在 `Platform/` 里的都不许）。"""
    normalised = relative.replace(os.sep, "/")
    if not normalised.startswith(PLATFORM_BRANCH_PREFIX):
        return False
    if normalised.startswith(PLATFORM_BRANCH_DIR):
        return False
    return bool(PLATFORM_BRANCH_PATTERN.search(line))


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


# 类型声明（含嵌套、含 extension；属性行 / 修饰符行不算 —— 与 SwiftLint 的 AST 口径近似）
TYPE_DECL = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|open|package|final)\s+)*"
    r"(?:@\w+\s+)*"
    r"(struct|class|actor|enum|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def type_body_sizes(lines):
    """每个类型声明的体行数（不算空行 / 纯注释行）—— type_body_length 口径。

    比 SwiftLint 略保守（把声明那一行也算进去），宁可多报一行，也别漏。
    """
    sizes = []
    for index, line in enumerate(lines):
        match = TYPE_DECL.match(line)
        if not match:
            continue
        depth = 0
        started = False
        body = 0
        cursor = index
        while cursor < len(lines):
            for char in lines[cursor]:
                if char == "{":
                    depth += 1
                    started = True
                elif char == "}":
                    depth -= 1
            stripped = lines[cursor].strip()
            if started and stripped and not stripped.startswith("//"):
                body += 1
            if started and depth == 0:
                break
            cursor += 1
        sizes.append((index + 1, match.group(1), match.group(2), body))
    return sizes


def structure_hits(relative, lines, report, warnings):
    """type_body_length / file_length：这两个只是数行数，本机算得准，别等 CI。"""
    for number, kind, name, body in type_body_sizes(lines):
        if body > TYPE_BODY_ERROR:
            report.append("%s:%d [type_body_length %d > %d] %s %s" % (
                relative, number, body, TYPE_BODY_ERROR, kind, name))
        elif body > TYPE_BODY_WARNING:
            warnings.append("%s:%d [type_body_length %d] %s %s" % (relative, number, body, kind, name))

    effective = sum(1 for line in lines if not line.strip().startswith("//"))
    if effective > FILE_LENGTH_ERROR:
        report.append("%s [file_length %d > %d]" % (relative, effective, FILE_LENGTH_ERROR))
    elif effective > FILE_LENGTH_WARNING:
        warnings.append("%s [file_length %d]" % (relative, effective))


def main() -> int:
    report = []
    warnings = []
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
            if platform_branch_hit(relative, stripped):
                report.append("%s:%d [platform_branch] 版本分支要收进 CatVodUI/Platform 基础件：%s"
                              % (relative, number, stripped[:90]))
            for name, pattern in PATTERNS:
                if pattern.search(line):
                    report.append("%s:%d [%s] %s" % (relative, number, name, stripped[:110]))
        structure_hits(relative, lines, report, warnings)

    print("lint-check-done scanned=%d hits=%d warnings=%d" % (scanned, len(report), len(warnings)))
    for line in report[:40]:
        print("  " + line)
    if warnings:
        print("  （警告不算失败，SwiftLint 的 warning 同样不阻断）")
        for line in warnings[:20]:
            print("  ⚠️ " + line)
    return 1 if report else 0


if __name__ == "__main__":
    sys.exit(main())