#!/bin/bash
# 从 Resources/AppIcon/MiscKit-512.png 生成 AppIcon.icns（构建期派生产物，不入库）
# 用法: ./Scripts/make-icon.sh [输出路径]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/Resources/AppIcon/MiscKit-512.png"
OUT="${1:-$ROOT/build/AppIcon.icns}"

if [ ! -f "$MASTER" ]; then
    echo "缺少图标母版：$MASTER" >&2
    exit 1
fi

SIDE=$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/ {print $2}')
TALL=$(sips -g pixelHeight "$MASTER" | awk '/pixelHeight/ {print $2}')
if [ "$SIDE" != "$TALL" ]; then
    echo "图标母版必须是正方形，当前 ${SIDE}x${TALL}" >&2
    exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT
mkdir -p "$ICONSET"

# icns 的每个逻辑尺寸都要显式命名；母版没有的分辨率跳过，不做放大插值。
emit() { sips -Z "$1" -s format png "$MASTER" --out "$ICONSET/$2" >/dev/null; }
for px in 16 32 64 128 256 512; do
    [ "$px" -gt "$SIDE" ] && continue
    case "$px" in
        16)  emit 16 icon_16x16.png ;;
        32)  emit 32 icon_16x16@2x.png; emit 32 icon_32x32.png ;;
        64)  emit 64 icon_32x32@2x.png ;;
        128) emit 128 icon_128x128.png ;;
        256) emit 256 icon_128x128@2x.png; emit 256 icon_256x256.png ;;
        512) emit 512 icon_256x256@2x.png; emit 512 icon_512x512.png ;;
    esac
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "$OUT"
