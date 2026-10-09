"""找出「注释把代码吞掉」的行并拆开。

背景：`DownloadQueueTests.swift` 里有一条
`// 说明...        #expect(...)` —— 注释和断言挤在同一行，**断言等于被注释掉了**，
测试看着有、从来没跑过。这类问题编译器不报、lint 也常放过，只能静态扫。

规则：同一行上「注释开头」之后又出现 `#expect(` / `#require(` / `try ` 等代码，
且注释与代码之间有两个以上空格 —— 拆成两行，缩进沿用行首。

用法：
  python Tools/out/fix_swallowed_code.py          # 只报告
  python Tools/out/fix_swallowed_code.py --fix    # 真改（按 UTF-8 读写，不动别的行）
"""

import io
import os
import re
import sys

ROOTS = ["Packages", "Tests", "Apps", "Scripts"]
CODE_MARKERS = ("#expect(", "#require(", "try ", "await ", "XCTAssert")
PATTERN = re.compile(r"^(\s*)(//[^\n]*?)(\s{2,})(#?(?:expect|require)\(|XCTAssert|try |await )")


def swift_files():
    for root in ROOTS:
        for base, _dirs, files in os.walk(root):
            if ".build" in base or "ThirdParty" in base:
                continue
            for name in files:
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


def main():
    fix = "--fix" in sys.argv
    hits = 0
    for path in swift_files():
        text = io.open(path, encoding="utf-8").read()
        lines = text.split("\n")
        changed = False
        for index, line in enumerate(lines):
            match = PATTERN.match(line)
            if not match:
                continue
            indent, comment, _spaces, code = match.groups()
            lines[index] = "{}{}\n{}{}".format(indent, comment, indent, code + line[match.end():])
            changed = True
            hits += 1
            print("{}:{} [{}]".format(path, index + 1, code.rstrip("(")))
        if changed and fix:
            io.open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
    print("swallowed-code-hits={}".format(hits))
    return 0


if __name__ == "__main__":
    sys.exit(main())
