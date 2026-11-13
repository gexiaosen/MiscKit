#!/bin/bash
# 打包拖拽安装 dmg：MiscKit.app + /Applications 快捷方式。
# 用法: ./Scripts/make-dmg.sh <MiscKit.app 路径> <输出.dmg 路径>
#
# 纯 hdiutil，零外部依赖（不用 create-dmg）：挂载后用户把 app 拖到
# Applications 链接即完成安装。UDZO 压缩格式兼容性最稳。
# Sparkle 支持 dmg 更新通道，同一产物既给新用户下载也给老用户自动更新。
set -euo pipefail

APP="${1:?用法: make-dmg.sh <MiscKit.app> <输出.dmg>}"
DMG="${2:?缺少输出 dmg 路径}"

if [ ! -d "$APP" ]; then
    echo "找不到 .app：$APP"
    exit 1
fi
APP_DIR="$(cd "$(dirname "$APP")" && pwd)"
APP_NAME="$(basename "$APP" .app)"
DMG_DIR="$(cd "$(dirname "$DMG")" && pwd)"
DMG_PATH="$DMG_DIR/$(basename "$DMG")"

# staging 必须在 iCloud 同步区之外（理由同 make-app.sh 的 SCRATCH 约定），
# 且打完即删——里面只是临时摆位。
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/misckit-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -format UDZO -ov -quiet "$DMG_PATH"

# 终验：挂载镜像确认两个入口都在，防"空壳 dmg 交出去"
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/misckit-verify.XXXXXX")"
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY" -quiet "$DMG_PATH"
trap 'hdiutil detach "$VERIFY" -quiet >/dev/null 2>&1 || true; rm -rf "$STAGING" "$VERIFY"' EXIT
test -d "$VERIFY/$APP_NAME.app" || { echo "dmg 内缺少 $APP_NAME.app，拒绝交付"; exit 1; }
test -L "$VERIFY/Applications" || { echo "dmg 内缺少 Applications 快捷方式，拒绝交付"; exit 1; }

echo "$DMG_PATH"
