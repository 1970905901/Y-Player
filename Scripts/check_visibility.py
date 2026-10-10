#!/usr/bin/env python3
"""跨文件可见性的两个预检（本机没有编译器时，把这两类编译错误提前抓出来）。

用法（仓库任意目录都行）：
    python3 Scripts/check_visibility.py
    python -X utf8 Scripts/check_visibility.py   # Windows
退出码：有 **error** 时 1，否则 0（warning 只提示）。

为什么有它（M04P19 连着踩了两次）：
1. `PlaybackView+Overlays.swift`（另一个文件）引用了 `PlaybackView.swift` 里的
   `@State private var subtitleSelection` —— 跨文件看不见 private；
2. `private func takePendingSubtitleTrack() -> PendingSubtitleTrack?` 写成 internal 后，
   被返回的 `PendingSubtitleTrack` 是 private 嵌套枚举 —— internal 签名不能出现 private 类型。

两条规则都**刻意收窄**（宁可漏报，也不误报 —— 与 check_lint.py 同一条纪律）：
- error：只在 **func 的签名**（从声明行到第一个 `{`）里找 private 嵌套类型 —— 局部变量、函数体都不看；
- warning：跨文件引用 private 成员时，**排除在引用文件里自己声明过同名局部**的情况。

⚠️ 覆盖不了：真正要编译器才知道的东西。改完代码仍然要让 YG 跑
`swift test --package-path Packages/<包>`（它才是真正的编译闸门）。
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TYPE_DECL = re.compile(
    r"^(?P<indent>\s*)(?:(?:public|internal|private|fileprivate|open|package|final)\s+)*"
    r"(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?P<kind>struct|class|actor|enum|extension)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)
FUNC_DECL = re.compile(
    r"^\s*(?P<attrs>(?:@\w+(?:\([^)]*\))?\s+)*)"
    r"(?P<access>public|internal|private|fileprivate|open|package)?\s*"
    r"(?P<mods>(?:static|class|final|nonisolated|mutating|override|convenience|required|@\w+\s+)*)"
    r"func\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)
PROPERTY_OR_FUNC = re.compile(
    r"^\s*(?P<attrs>(?:@\w+(?:\([^)]*\))?\s+)*)"
    r"(?P<access>public|internal|private|fileprivate|open|package)?\s*"
    r"(?P<mods>(?:static|class|final|nonisolated|mutating|override|convenience|required|weak|unowned|lazy|dynamic|indirect|@\w+\s+)*)"
    r"(?:func|var|let|init|subscript)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)?"
)


def swift_files():
    for root_name in ("Apps", "Packages"):
        for base, dirs, names in os.walk(os.path.join(ROOT, root_name)):
            dirs[:] = [name for name in dirs if name not in (".build", "DerivedData", ".swiftpm")]
            for name in names:
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


def private_nested_types(lines):
    """本文件里声明的 private 嵌套类型名（缩进 > 0 = 嵌套在别的类型里）。"""
    names = set()
    for line in lines:
        match = TYPE_DECL.match(line)
        if not match or not match.group("indent"):
            continue
        head = line.split(match.group("kind"))[0]
        if re.search(r"\bprivate\b", head):
            names.add(match.group("name"))
    return names


def signature(lines, start):
    """func 的签名：从声明行到第一个含 `{` 的行（含），最多 12 行。"""
    collected = []
    for index in range(start, min(start + 12, len(lines))):
        collected.append(lines[index])
        if "{" in lines[index]:
            break
    return " ".join(collected)


def private_type_signature_errors(relative, lines):
    private_types = private_nested_types(lines)
    if not private_types:
        return []
    findings = []
    for index, line in enumerate(lines):
        match = FUNC_DECL.match(line)
        if not match or match.group("access") in ("private", "fileprivate"):
            continue
        text = signature(lines, index)
        for name in sorted(private_types):
            if re.search(r"\b%s\b" % re.escape(name), text):
                findings.append(
                    "%s:%d [private-type-in-signature] func %s 的签名用到了 private 的 %s"
                    % (relative, index + 1, match.group("name"), name)
                )
    return findings


def declared_names(lines):
    """本文件里声明过的名字（含局部 let/var/func）—— 用来排除误报。"""
    names = set()
    for line in lines:
        match = PROPERTY_OR_FUNC.match(line)
        if match and match.group("name"):
            names.add(match.group("name"))
    return names


def private_member_names(lines):
    names = set()
    for line in lines:
        match = PROPERTY_OR_FUNC.match(line)
        if not match or match.group("access") not in ("private", "fileprivate"):
            continue
        if match.group("name"):
            names.add(match.group("name"))
    return names


def cross_file_warnings(per_file):
    owners = {}
    files_of = {}
    for relative, lines in per_file.items():
        for line in lines:
            match = TYPE_DECL.match(line)
            if not match:
                continue
            name = match.group("name")
            files_of.setdefault(name, set()).add(relative)
            if match.group("kind") != "extension":
                owners.setdefault(name, relative)

    findings = []
    for name, files in sorted(files_of.items()):
        if len(files) < 2 or name not in owners:
            continue
        main_file = owners[name]
        members = private_member_names(per_file[main_file])
        if not members:
            continue
        for relative in sorted(files):
            if relative == main_file:
                continue
            lines = per_file[relative]
            local_names = declared_names(lines)
            for index, line in enumerate(lines):
                if line.strip().startswith("//"):
                    continue
                for member in sorted(members):
                    if member in local_names:
                        continue
                    # 两个已知的误报形状：别的类型的同名成员（`X.content`）、命名的尾随闭包（`placeholder: {`）
                    if re.search(r"\.\s*%s\b" % re.escape(member), line):
                        continue
                    if re.search(r"\b%s\s*:" % re.escape(member), line):
                        continue
                    if re.search(r"\b%s\b" % re.escape(member), line):
                        findings.append(
                            "%s:%d [private-across-files] %s 的 private 成员 %s 在另一个文件里被引用"
                            % (relative, index + 1, name, member)
                        )
    return findings


def main() -> int:
    per_file = {}
    for path in sorted(swift_files()):
        try:
            text = io.open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        per_file[os.path.relpath(path, ROOT)] = text.split("\n")

    errors = []
    for relative, lines in sorted(per_file.items()):
        errors += private_type_signature_errors(relative, lines)
    warnings = cross_file_warnings(per_file)

    print("visibility-check-done files=%d errors=%d warnings=%d" % (len(per_file), len(errors), len(warnings)))
    for line in errors:
        print("  " + line)
    if warnings:
        print("  （下面这些是警告：可能是误报，看一眼再决定）")
        for line in warnings[:20]:
            print("  ⚠️ " + line)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())