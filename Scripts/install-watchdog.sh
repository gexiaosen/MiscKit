#!/bin/bash
# 给 /Applications 那份 MiscKit 装一个崩溃看门狗（LaunchAgent）。
#
# 为什么要它：macOS 27.2 的 SwiftUI 命中测试在刚重建过的视图树上偶发踩空
# （SIGSEGV，栈里一行业务代码都没有，见 Breadcrumbs 的 file.tap 记录）。根因在系统里，
# 我们改不掉，至少让面板崩了不用手动再开。
#
#   ./Scripts/install-watchdog.sh           装（幂等，可重复跑）
#   ./Scripts/install-watchdog.sh --remove  拆
#
# ⚠ 看门狗只 supervise 它自己拉起的那个进程：所以必须 RunAtLoad=true，
#   让面板始终由 launchd 带着跑。你若再手动 open，LaunchServices 只会把已跑着的
#   那个叫到前台，不会多出第二份——两份同时写索引是要出事的。
set -euo pipefail

LABEL="app.misckit.MiscKit.watchdog"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="/Applications/MiscKit.app/Contents/MacOS/MiscKit"
DOMAIN="gui/$(id -u)"
# 崩溃日志不落 /tmp：那是全机可见的公共目录（01777），默认 umask 下同机任何
# 非特权进程都能读到栈里的路径与用户名。放到自家的 Logs 下，目录 0700、文件 0600。
LOG_DIR="$HOME/Library/Logs/MiscKit"

if [ "${1:-}" = "--remove" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    echo "已拆除 $AGENT（下次登录起不再自动拉起）"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "找不到 $BIN —— 先把正式包装进 /Applications"
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <!-- 崩了才拉回来：菜单里正常退出（状态码 0）不重开，尊重你主动关它的意图 -->
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key><true/>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/watchdog.err</string>
</dict>
</plist>
PLIST

plutil -lint "$AGENT" > /dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout 不是同步的：服务还在退出时立刻 bootstrap 会报 "Bootstrap failed: 5:
# Input/output error"。plist 已改写、服务却没加载、进程也没了 —— 重装看门狗反而把
# 守护弄丢（2026-11-12 实测踩过一次）。给几拍重试，别让一次抖动变成"没在跑"。
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "$DOMAIN" "$AGENT" 2>/dev/null; then break; fi
    if [ "$attempt" = 5 ]; then
        echo "加载 $LABEL 失败（plist 已写好：$AGENT）"
        exit 1
    fi
    sleep 1
done
echo "已装 $AGENT"
launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
    | grep -E "state|pid|runs|last exit code" | sed 's/^ */  /' | head -6
