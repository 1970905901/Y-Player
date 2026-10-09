"""把指定区间的行按 ASCII 打出来：非 ASCII 字符一律换成 `?`。

为什么需要它：Windows 控制台的编码会把中文变成乱码，还可能**折行**，
于是「同一行」和「两行」看起来一样 —— 我在 `DownloadQueueTests.swift:154` 上
就被这样骗过一次，差点去「修」一行本来没问题的代码。

数字下标与 ASCII 不会骗人，所以判定代码结构一律先过这个工具。

用法：python Tools/out/show_ascii.py <file> <start> <end>
"""

import io
import sys


def main():
    if len(sys.argv) < 4:
        print("usage: show_ascii.py <file> <start> <end>")
        return 2
    path, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    lines = io.open(path, encoding="utf-8").read().split("\n")
    for number in range(max(1, start), min(len(lines), end) + 1):
        raw = lines[number - 1]
        ascii_only = "".join(ch if ord(ch) < 128 else "?" for ch in raw)
        print("{:>4}: {}".format(number, ascii_only))
    return 0


if __name__ == "__main__":
    sys.exit(main())
