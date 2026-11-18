#!/bin/bash
# 把签名证书上传进 GitHub Secrets，供 .github/workflows/release.yml 在 CI 里复用。
#
# 为什么需要它：ad-hoc 包的 designated requirement 就是 cdhash，而版本号写在
# Info.plist 里被 CodeDirectory 哈希覆盖 ⇒ 每发一版身份必变 ⇒ TCC 的文件夹授权
# 与钥匙串 ACL 记录全部作废。用固定证书签名后 DR 变成
# `identifier + anchor apple generic + leaf CN`，一次授权跨版本有效。
#
# 用法：
#   ./Scripts/upload-signing-cert.sh ~/Desktop/MiscKitSigning.p12
#
# p12 从哪来：钥匙串访问 → 登录 → 我的证书 → 右键
#   "Apple Development: gexiaosen@outlook.com (AK52JP2G5T)" → 导出 → 选 .p12 → 设密码。
# 导出时务必只选这一个身份（"我的证书"里的那一行），别把整串私钥一起导出去。
#
# 本脚本做三件事：校验 p12 → 用 stdin 直接写入两个 secret → 回读确认。
# base64 只在管道里过一手，不落盘、不进 shell 历史、不打印。
set -euo pipefail

REPO_SLUG="${MISCKIT_REPO:-gexiaosen/MiscKit}"

die() { echo "✗ $*" >&2; exit 1; }

[ $# -eq 1 ] || die "用法：$0 <证书.p12>"
P12="$1"
[ -f "$P12" ] || die "找不到文件：$P12"

command -v gh >/dev/null || die "没装 gh（brew install gh），或手动上传两个 secret 也行"
gh auth status >/dev/null 2>&1 || die "gh 未登录：gh auth login"

# 先确认这是一个带私钥的 PKCS#12，而不是只含证书的 .cer 改名
if ! openssl pkcs12 -in "$P12" -noout -passin pass: 2>/dev/null; then
    printf '证书密码（导出 .p12 时设的那个，输入不回显）：'
    read -rs P12_PASS
    echo
    [ -n "$P12_PASS" ] || die "密码为空"
    openssl pkcs12 -in "$P12" -noout -passin "pass:$P12_PASS" 2>/dev/null \
        || die "密码不对，或这个文件不是 PKCS#12"
else
    P12_PASS=""
fi

# 证书里必须有私钥，否则 CI 只能拿到公钥、codesign 会失败
openssl pkcs12 -in "$P12" -nocerts -noout -passin "pass:$P12_PASS" 2>/dev/null \
    | grep -q "BEGIN" || die "这个 p12 里没有私钥（只导出了证书）。重新导出时要在「我的证书」里选那条带钥匙图标的身份。"

echo "→ 写入 secret: MISCKIT_SIGNING_CERT_P12"
base64 -i "$P12" | tr -d '\n' | gh secret set MISCKIT_SIGNING_CERT_P12 --repo "$REPO_SLUG"

echo "→ 写入 secret: MISCKIT_SIGNING_CERT_PASSWORD"
if [ -z "$P12_PASS" ]; then
    printf 'p12 没有密码，CI 侧也留空；建议之后重导一份带密码的\n'
fi
printf '%s' "$P12_PASS" | gh secret set MISCKIT_SIGNING_CERT_PASSWORD --repo "$REPO_SLUG"

echo "✓ 已写入。确认清单："
gh secret list --repo "$REPO_SLUG" | grep -E "MISCKIT_SIGNING_CERT" || true
echo
echo "下一步：打 tag 发一版，CI 会用这个身份签名。"
echo "  · 换身份那一次，文件夹权限与钥匙串授权会**再问一轮**，点「始终允许」；"
echo "  · 之后任何版本都不再问。"
echo "  · 证书一年到期：过期后新签的包身份又变了，重跑本脚本上传新证书即可。"
echo
echo "提醒：证书私钥现在同时存在于 GitHub Secrets。仓库必须保持 private，"
echo "      并建议在 GitHub 上开启 secret 扫描告警；不用了随时删：gh secret delete MISCKIT_SIGNING_CERT_P12"
