#!/usr/bin/env bash
# Y-Player 本地闸门（M21P1）：四个 Python 检查 + （装了的话）SwiftFormat --lint。
#
# 用法：bash Scripts/check.sh     （在仓库任意目录都行，脚本会自己 cd 到仓库根）
# 退出码：全过 0，有任意一项没过 1 —— 可以直接当提交前的闸门。
#
# 抓不到的东西：**编译错误**（那要 Swift 编译器）。改完代码仍然先跑
#   swift test --package-path Packages/<包>
# 它同时是编译闸门，而且比 xcodebuild 快得多。

set -u
cd "$(dirname "$0")/.." || exit 1

PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python
if ! command -v "$PY" >/dev/null 2>&1; then
    echo "找不到 python3 / python —— 先装一个（macOS: brew install python3）"
    exit 1
fi

rc=0
run() {
    echo
    echo "== $*"
    "$@" || rc=1
}

run "$PY" Scripts/check_braces.py
run "$PY" Scripts/check_lint.py
run "$PY" Scripts/audit_duplicate_types.py
run "$PY" Scripts/check_visibility.py

if command -v swiftformat >/dev/null 2>&1; then
    run swiftformat --lint . --config .swiftformat \
        --exclude '.build,DerivedData,ThirdParty,Tools,.swiftpm,Packages/*/.build'
else
    echo
    echo "== swiftformat 没装（brew install swiftformat），跳过格式检查"
fi

echo
if [ "$rc" -eq 0 ]; then
    echo "✅ 本地闸门全过"
else
    echo "❌ 有检查没过（细节见上面）"
fi
exit "$rc"