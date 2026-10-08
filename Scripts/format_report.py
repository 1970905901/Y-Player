#!/usr/bin/env python3
"""临时诊断脚本（用完即删）：把 SwiftFormat 需要改动的地方以 GitHub annotations 形式吐出。

为什么需要它：SwiftFormat 的 lint 输出只进 job 日志，而 job 日志需要登录才能看；
annotations 不需要。本脚本在 CI 里跑 `swiftformat --lint`，失败就真跑一次 `swiftformat`
并用 `git diff` 把「哪一行会被怎么改」变成注解。
"""

import os
import subprocess

EXCLUDE = ".build,DerivedData,ThirdParty,Tools,.swiftpm,Packages/*/.build"
LINT = ["swiftformat", "--lint", ".", "--config", ".swiftformat", "--exclude", EXCLUDE]
FIX = ["swiftformat", ".", "--config", ".swiftformat", "--exclude", EXCLUDE]
LIMIT = 45


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    print("$ %s -> %s" % (" ".join(args), result.returncode))
    if result.stdout:
        print(result.stdout[-6000:])
    if result.stderr:
        print(result.stderr[-6000:], file=__import__("sys").stderr)
    return result


def main():
    lint = run(LINT)
    print("::notice::SwiftFormat lint returncode = %s" % lint.returncode)
    if lint.returncode == 0:
        return

    run(FIX)
    diff = subprocess.run(["git", "diff", "--unified=0"], capture_output=True, text=True, check=False).stdout
    entries = []
    path = "(unknown)"
    line = 0
    for row in diff.splitlines():
        if row.startswith("diff --git "):
            path = row.split(" b/")[-1]
        elif row.startswith("@@"):
            head = row.split("+", 1)[1].split("@@")[0].strip()
            line = int(head.split(",")[0])
        elif row.startswith("+") and not row.startswith("+++"):
            entries.append((path, line, "应改为：%s" % row[1:].strip()))
            line += 1
        elif row.startswith("-") and not row.startswith("---"):
            entries.append((path, line, "应删除：%s" % row[1:].strip()))

    for index, (file_path, file_line, message) in enumerate(entries[:LIMIT]):
        level = "error" if index < 8 else "notice"
        print("::%s file=%s,line=%s::%s" % (level, file_path, file_line, message[:180]))

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        body = "\n".join("%s:%s %s" % (item[0], item[1], item[2]) for item in entries[:800])
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### SwiftFormat 需要改动 %d 处\n\n```\n%s\n```\n" % (len(entries), body))

    raise SystemExit(1)


if __name__ == "__main__":
    main()
