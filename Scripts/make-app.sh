#!/bin/bash
# 组装可运行的 MiscKit.app（本机 ad-hoc 签名，非沙盒）
# 用法: ./Scripts/make-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 构建产物必须放在 iCloud 同步目录之外：~/Documents 下的 file provider 会给产物贴
# com.apple.FinderInfo / com.apple.fileprovider.fpfs#P，codesign 会以
# "resource fork, Finder information, or similar detritus not allowed" 拒绝签名。
SCRATCH="${MISCKIT_SCRATCH:-$HOME/.cache/misckit-build}"

# ⚠ 成品目录也必须在同步区之外，不只是 SwiftPM 的中间产物。
# 实测：把 .app 组装在 ~/Documents 下，xattr -cr + codesign 都成功了，
# 但 file provider 会在签名之后回来给 bundle 顶层贴 com.apple.FinderInfo
# 与 com.apple.fileprovider.fpfs#P，于是终验 codesign --verify --strict 报
# "resource fork, Finder information, or similar detritus not allowed"
# —— 包其实是好的，只是被重新贴脏，而且什么时候贴不可预测。
APP="${MISCKIT_APP_DIR:-$SCRATCH/product}/MiscKit.app"

# 出包前先过个人信息门禁：有命中就拒绝出包。跳过只准显式 MISCKIT_SKIP_SCAN=1，
# 因为一旦允许"忘了跑"，这条规则就会一直输在同一个地方。
if [ "${MISCKIT_SKIP_SCAN:-0}" != "1" ]; then
    scan_log="$(mktemp -t misckit-scan)"
    if ! "$ROOT/Scripts/scan-secrets.sh" >"$scan_log" 2>&1; then
        tail -25 "$scan_log"
        rm -f "$scan_log"
        echo "个人信息扫描未通过，拒绝出包（确需跳过：MISCKIT_SKIP_SCAN=1）"
        exit 1
    fi
    tail -1 "$scan_log"
    rm -f "$scan_log"
fi

swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH"
BIN="$(swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)"

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/MiscKit" "$APP/Contents/MacOS/MiscKit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 图标由母版派生，跟 bundle 一起生成：仓库里不留 .icns，避免母版改了图标没跟上
"$ROOT/Scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns" >/dev/null
# 菜单栏单色标记是入库的美术资源，缺了就让打包失败，别留下一个空白托盘
cp "$ROOT/Resources/MenuBar/MiscKitMark.png" "$APP/Contents/Resources/MiscKitMark.png"
# SwiftPM 资源包（含 Localizable.strings）：随 .app 一起进 Contents/Resources，缺了会导致多语言文本回退为 key（B-13）
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
if [ ! -d "$APP/Contents/Resources/MiscKit_MiscKitCore.bundle" ]; then
    echo "缺少 MiscKit_MiscKitCore.bundle，拒绝出包"
    exit 1
fi

# Sparkle 自动更新框架：随 .app 进 Contents/Frameworks，缺了即拒——出包必须带更新能力。
# 用 ditto 而非 cp -R：framework 顶层是 Versions/Current 符号链接树，
# ditto 是 Apple 推荐的分发复制方式，能完整保留软链与权限。
if [ ! -d "$BIN/Sparkle.framework" ]; then
    echo "缺少 Sparkle.framework，拒绝出包"
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# ---------------------------------------------------------------------------
# 开发包与正式包分身份：debug 产物用 .dev bundle id，release 用正式 id
#
# 为什么要分：/Applications 那份（日常在用、存着真密钥）与 build/ 下的重建产物
# 一旦共用 bundle id 和同一个钥匙串 service，就互为陌生人——每换一份跑，全部密钥
# 的授权都要重敲一遍（授权按条目记，一个账户弹一个框）。分身份后重建产物根本
# 不去碰真密钥那一区。
#
# ⚠ 光换 bundle id 不够：钥匙串 service 名与 bundle id 无关，必须跟着分叉，
#   否则开发包的元数据仓（按 bundle id 隔离，是空的）会把正式包的真密钥
#   判成"没人引用的孤儿"。见 KeychainSecretStore.serviceForCurrentBundle。
# ---------------------------------------------------------------------------
if [ "$CONFIG" = "release" ]; then
    BUNDLE_ID="app.misckit.MiscKit"
    BUNDLE_NAME="MiscKit"
else
    BUNDLE_ID="app.misckit.MiscKit.dev"
    BUNDLE_NAME="MiscKit Dev"
fi
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$BUNDLE_NAME" "$APP/Contents/Info.plist"

# ---------------------------------------------------------------------------
# 签名身份：决定钥匙串会不会反复弹授权框
#
# 2026-10-21 在本机实测（不是查文档）：
#   · ad-hoc 的 designated requirement 就是 cdhash，改一行代码重建 → 读自己写的
#     钥匙串条目返回 -25293 → 用户被要求重新授权一次。
#   · 换**自签证书**（已进系统信任域、Code Signing 策略）不解决问题：DR 变成
#     `identifier + certificate root` 之后，重建仍 -25293。
#   · 用 `--requirements` 手工钉死表达式也不解决，同样 -25293。
#   · 换 **Apple Development 证书**（免费个人团队）就解决了：DR 变成
#     `identifier + anchor apple generic + certificate leaf[subject.CN]`，与 cdhash
#     无关；连改两次代码重建、cdhash 换两次，读自己写的条目都是 0。
#   ⇒ 只有 Apple 签发身份所推导的 requirement 会被 securityd 记住。
#   · 新建的 Apple Development 证书若被 `find-identity -v` 判为无效（只剩不带 -v
#     才列得出来），根因通常是本机没装签发链的中间证书，报 CSSMERR_TP_NOT_TRUSTED。
#     一次性补上即可，不需要管理员密码：
#       curl -o /tmp/g3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
#       security add-certificates /tmp/g3.cer
#
# ⚠ 因此这里**刻意不签任何 entitlement**：把 `keychain-access-groups` 签进去，
#   无论 ad-hoc、自签还是这张免费个人团队的 Apple Development 证书，进程一启动
#   就被 SIGKILL（实测）。data-protection 钥匙串随之不可用（-34018），iCloud 同步
#   仍然要付费 Developer ID —— 但弹框问题不靠它，靠上面的身份切换。
# ---------------------------------------------------------------------------
# ⚠ 探测命令一律带 `|| true`：本脚本开着 `set -euo pipefail`，而 `grep` 没匹配就退 1
#   —— 漏掉会让命令替换返回非零，脚本**在 codesign 之前静默退出**，留下一个只带
#   SwiftPM 临时签名、`--verify --strict` 直接报错的 .app（2026-10-21 实测踩过）。
IDENTITY="${MISCKIT_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"(Apple Development|Developer ID Application): [^"]*"' | head -1 \
        | sed 's/^"//; s/"$//' || true)"
fi

xattr -cr "$APP" 2>/dev/null || true
SIGN_ARGS=(--force --sign "${IDENTITY:--}")
if [ -n "$IDENTITY" ]; then
    SIGN_ARGS+=(--options runtime)
fi
# Sparkle.framework 从内到外逐层签：XPC → Updater.app → Autoupdate → framework。
# 官方 SPM 分发自带 ad-hoc 预签，但必须用本包同一身份覆盖重签：
#   · 本机 Apple Development + Hardened Runtime 路线下，Library Validation
#     会拒载与自己不同身份的第三方框架（Sparkle 官方文档明确此要求）；
#   · CI ad-hoc 路线无 Runtime，但重签保持全链身份一致，行为可预期。
# 签名顺序不可颠倒：嵌套体（XPC/Updater.app/Autoupdate）必须先于宿主 framework。
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    for nested in "$FW/Versions/B/XPCServices/"*.xpc "$FW/Versions/B/Updater.app"; do
        [ -e "$nested" ] || continue
        codesign "${SIGN_ARGS[@]}" "$nested"
    done
    if [ -f "$FW/Versions/B/Autoupdate" ]; then
        codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/Autoupdate"
    fi
    codesign "${SIGN_ARGS[@]}" "$FW"
fi
for bundle in "$APP/Contents/Resources/"*.bundle; do
    [ -e "$bundle" ] || continue
    codesign "${SIGN_ARGS[@]}" "$bundle"
done
codesign "${SIGN_ARGS[@]}" "$APP"

if [ -n "$IDENTITY" ]; then
    echo "签名: $IDENTITY"
else
    echo "签名: ad-hoc —— ⚠ 每次重建都会换 cdhash，OTP 会反复弹钥匙串授权框"
    echo "      解法：Xcode → Settings → Accounts → Manage Certificates → + Apple Development"
    echo "      （证书被判 invalid 时先补 WWDR 中间证书，见本文件顶部实测记录）"
fi

# 终验：签名没做成就要打包失败，别把"看起来打好了、其实一启动就被系统拒"的包交出去
codesign --verify --deep --strict "$APP"
codesign -dr- "$APP" 2>&1 | tail -1 | sed 's/^/      /' || true
echo "包身份: $BUNDLE_ID"
if [ "$BUNDLE_ID" != "app.misckit.MiscKit" ]; then
    echo "      与 /Applications 那份的钥匙串、设置完全隔离；可同时运行，"
    echo "      ⌥Z 归先启动的那个；双击修饰键要单独给一次「输入监控」权限"
    echo "      （走 NSEvent 全局监听，不用辅助功能——见 HotkeyCenter 的选型注释）。"
fi

echo "$APP"
