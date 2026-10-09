"""找「注释里藏着代码」的行，只报告不改。

起因：`DownloadQueueTests.swift:154` 在 Windows 控制台里看着像
`// 说明        #expect(...)` —— 断言像是被注释吞掉了。
但 `fix_swallowed_code.py`（要求注释后至少两个空格）报 0 命中，
所以要么根本不是同一行、要么分隔不是普通空格。

判定放宽到：行内 `//` 的位置 **早于** `#expect(` / `#require(` / `XCTAssert` / `try `。
输出全用 ASCII 与数字下标（控制台编码会把中文吃掉，证据不能靠眼睛）。
"""

import io
import os
import sys

ROOTS = ["Packages", "Tests", "Apps"]
MARKERS = ("#expect(", "#require(", "XCTAssert", "try ", "await ")


def swift_files():
    for root in ROOTS:
        for base, _dirs, files in os.walk(root):
            if ".build" in base or "ThirdParty" in base:
                continue
            for name in files:
                if name.endswith(".swift"):
                    yield os.path.join(base, name)


def main():
    hits = 0
    for path in swift_files():
        text = io.open(path, encoding="utf-8").read()
        for number, line in enumerate(text.split("\n"), 1):
            comment = line.find("//")
            if comment < 0:
                continue
            for marker in MARKERS:
                at = line.find(marker)
                if at > comment:
                    hits += 1
                    print("{}:{} marker={} comment_at={} marker_at={} len={}".format(
                        path, number, marker.strip("( "), comment, at, len(line)))
    print("comment-swallowed-hits={}".format(hits))
    return 0


if __name__ == "__main__":
    sys.exit(main())
