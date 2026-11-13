#!/bin/bash
# 装进 /Applications，然后把正在跑的旧实例正常退出、拉起新的。
# 用法: ./Scripts/install.sh [--no-build]
#
# 「正常退出」用 NSRunningApplication.terminate()（等于点「退出」），不是 kill：
# kill -TERM 不会走 applicationWillTerminate，收尾逻辑全跳过。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${MISCKIT_SCRATCH:-$HOME/.cache/misckit-build}"
PRODUCT="$SCRATCH/product/MiscKit.app"
DEST="/Applications/MiscKit.app"
BUNDLE_ID="app.misckit.MiscKit"

if [ "${1:-}" != "--no-build" ]; then
    ( cd "$ROOT" && make app CONFIG=release )
fi

[ -d "$PRODUCT" ] || { echo "没有产物：$PRODUCT"; exit 1; }

# 先确认新产品是 release 身份，别把 .dev 装进 /Applications
PRODUCT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PRODUCT/Contents/Info.plist")"
[ "$PRODUCT_ID" = "$BUNDLE_ID" ] || { echo "产物身份是 $PRODUCT_ID，不是 $BUNDLE_ID"; exit 1; }

TOOL_DIR="$SCRATCH/tools"
QUITTER="$TOOL_DIR/misckit-quit"
mkdir -p "$TOOL_DIR"
if [ ! -x "$QUITTER" ] || [ "$ROOT/Scripts/quit-app.swift" -nt "$QUITTER" ]; then
    swiftc -O "$ROOT/Scripts/quit-app.swift" -o "$QUITTER" >/dev/null
fi

# 先把正在跑的旧实例退干净，再替换 /Applications/MiscKit.app，避免替换运行中二进制与资源包触发异常（B-14）
"$QUITTER" "$BUNDLE_ID"

ditto "$PRODUCT" "$DEST"
# 刷新 .app 目录时间戳并通知 LaunchServices 重新索引，避免 IconServices 继续返回旧图标缓存
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true

# 装了崩溃看门狗（LaunchAgent）就必须由 launchd 拉起，否则那份 watchdog 从此
# 只是挂在 launchd 上的一个空壳，不再守着任何进程。
DOMAIN="gui/$(id -u)"
WATCHDOG="app.misckit.MiscKit.watchdog"
if launchctl print "$DOMAIN/$WATCHDOG" >/dev/null 2>&1; then
    launchctl kickstart "$DOMAIN/$WATCHDOG"
else
    open "$DEST"
fi

sleep 1
INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")"
PID="$(pgrep -f "$DEST/Contents/MacOS/MiscKit" | head -1 || true)"
echo "已装 $INSTALLED ($BUILD)，运行中 pid=${PID:-无}"
[ -n "$PID" ] || { echo "新实例没起来"; exit 2; }
