#!/bin/bash
# 仓库个人信息自查：真名路径、邮箱、密钥样式、内网地址、会议号。
# 用法: ./Scripts/scan-secrets.sh            扫全仓 tracked 文件，有命中就非零退出
#       ./Scripts/scan-secrets.sh --selftest 正对照：每条规则都要对已知脏样本有反应
#
# ⚠ 三条设计约束，别在改的时候弄丢：
# 1. **规则本身不能含真实内部数据**。把真名（某内网段名、某客户文号）写进这个脚本，
#    脚本提交上去就变成泄漏源。真名清单放仓库外的文件（env SECRETS_DENYLIST 指过去）。
# 2. **空命中不等于干净**。踩过一次：`git diff --name-only` 把中文路径转成八进制，
#    脚本静默打开 0 个文件却报"0 命中"。所以这里断言覆盖文件数，并强制 core.quotePath=false。
# 3. **每条规则配一个豁免正则**，专门放合成样本（`123456789`、`10.0.0.1 example.test`、
#    `/Users/tester`）。没有豁免机制的门禁会天天误报，报多了就没人看，等于没有门禁。
# 只用 macOS 自带 bash 3.2 有的语法：没有 mapfile、没有关联数组、不用 ERE 反向引用。
set -euo pipefail
cd "$(dirname "$0")/.."

# 字段：名字 | 命中正则 | 豁免正则（可空）
PATTERNS='绝对家目录	/Users/[A-Za-z0-9._-]+	/Users/tester|/Users/<|/Users/Shared|/Users/[^A-Za-z]
邮箱	[A-Za-z0-9._%+-]+@[A-Za-z][A-Za-z0-9-]*\.[A-Za-z]{2,}	example\.|\.test\b
私钥块	BEGIN [A-Z ]*PRIVATE KEY	
Base32 密钥样式	\b[A-Z2-7]{20,}\b	JBSWY3DPEHPK3PXP|ABCDEFGHIJKLMNOPQRSTUVWXYZ234567|GEZDGNBVGY3TQOJQ
十六进制长令牌	\b[0-9a-f]{32,}\b	12345678901234567890123456789012|deadbeef0123456789abcdef0123456789
内网 IP	\b(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b	10\.0\.[0-9]+\.[0-9]+|example\.test
会议号样式	(^|[^.0-9])[0-9]{9}([^0-9]|$)|[0-9]{3}[ -][0-9]{3}[ -][0-9]{3}	for |https?://|123[ -]?456[ -]?789|1234567891|[0-9]0{8}|000000000|111111111|222222222|333333333|444444444|555555555|666666666|777777777|888888888|999999999'

# 多行规则表读成三个并行数组
labels=(); hits=(); allows=()
while IFS=$'\t' read -r l h a; do
  [ -z "$l" ] && continue
  labels+=("$l"); hits+=("$h"); allows+=("${a:-}")
done <<EOF
$PATTERNS
EOF

if [ "${1:-}" = "--selftest" ]; then
  # 脏样本与规则表一一对应；少一条或某条规则写坏了，这里就红
  samples=('/Users/someone/x' 'a@b-c.com' 'BEGIN OPENSSH PRIVATE KEY' \
           'JBSWY3DPEHPK3PXPABCDEFGHIJKLMNOP' 'deadbeef0123456789abcdef0123456789' \
           '10.12.3.45 内网' '675290698')
  if [ "${#samples[@]}" -ne "${#labels[@]}" ]; then
    echo "正对照失败：规则 ${#labels[@]} 条、样本 ${#samples[@]} 条，对不上"
    exit 1
  fi
  bad=0
  for i in "${!labels[@]}"; do
    if printf '%s\n' "${samples[$i]}" | grep -Eq "${hits[$i]}"; then continue; fi
    echo "正对照失败：规则「${labels[$i]}」对已知脏样本没反应，它写坏了"
    bad=1
  done
  [ "$bad" -eq 0 ] || exit 1
  # 反对照：小数常量里的 9 位片段不是会议号。单位换算表里的 28.349523125
  # 曾让整条出包门禁失败，而它只是一个换算系数。
  for i in "${!labels[@]}"; do
    [ "${labels[$i]}" = "会议号样式" ] || continue
    if printf '%s\n' 'add("oz", .mass, d("28.349523125"))' | grep -Eq "${hits[$i]}"; then
      echo "反对照失败：小数常量里的 9 位片段被当成会议号"
      exit 1
    fi
  done
  # 遮蔽回归测试：前 8 行均为豁免样本，第 9 行为真脏样本，必须先过滤再截断（B-01）
  padded=$(printf '/Users/tester/1\n/Users/tester/2\n/Users/tester/3\n/Users/tester/4\n/Users/tester/5\n/Users/tester/6\n/Users/tester/7\n/Users/tester/8\n/Users/realuser/secret\n')
  filtered=$(printf '%s\n' "$padded" | grep -nE "${hits[0]}" | grep -Ev "${allows[0]}" | head -20 || true)
  if [ -z "$filtered" ]; then
    echo "正对照失败：超过 6 行豁免命中后的真实泄漏被截断漏检"
    exit 1
  fi
  echo "正对照通过：${#labels[@]} 类规则各命中一次"
  exit 0
fi

IGNORE_FILE="${SECRETS_IGNORE:-.secretsignore}"
DENYLIST_FILE="${SECRETS_DENYLIST:-.secretsdenylist}"
excluded() {
  [ -f "$IGNORE_FILE" ] || return 1
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    case "$g" in \#*) continue ;; esac
    case "$1" in $g|${g}/*) return 0 ;; esac
  done < "$IGNORE_FILE"
  return 1
}

deny_terms=()
if [ -f "$DENYLIST_FILE" ]; then
  while IFS= read -r term; do
    [ -z "$term" ] && continue
    case "$term" in \#*) continue ;; esac
    deny_terms+=("$term")
  done < "$DENYLIST_FILE"
fi

hits_found=0
scanned=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  case "$f" in
    *.png|*.icns|*.jpg|*.pdf|*.gz|*.heic) continue ;;
    Scripts/scan-secrets.sh) continue ;;   # 规则与脏样本本身，不算命中
  esac
  if excluded "$f"; then continue; fi
  scanned=$((scanned + 1))
  for i in "${!labels[@]}"; do
    # 先全量命中并做豁免过滤，再截断输出，避免豁免条目占满配额遮蔽后续真泄漏（B-01）
    out=$(grep -nE "${hits[$i]}" "$f" 2>/dev/null || true)
    [ -n "$out" ] || continue
    if [ -n "${allows[$i]}" ]; then
      out=$(printf '%s\n' "$out" | grep -Ev "${allows[$i]}" || true)
    fi
    [ -n "$out" ] || continue
    out=$(printf '%s\n' "$out" | head -20)
    while IFS= read -r line; do
      echo "· [${labels[$i]}] $f:$line"
      hits_found=$((hits_found + 1))
    done <<< "$out"
  done
  if [ "${#deny_terms[@]}" -gt 0 ]; then
    for term in "${deny_terms[@]}"; do
      out=$(grep -nF "$term" "$f" 2>/dev/null | head -10 || true)
      [ -n "$out" ] || continue
      while IFS= read -r line; do
        echo "· [外部黑名单] $f:$line"
        hits_found=$((hits_found + 1))
      done <<< "$out"
    done
  fi
done < <(git -c core.quotePath=false ls-files)

untracked_count=$(git -c core.quotePath=false ls-files --others --exclude-standard | wc -l | tr -d ' ')
if [ "$untracked_count" -gt 0 ]; then
  echo "注意：有 $untracked_count 个未跟踪且未被 .gitignore 忽略的文件未纳入扫描（git add 后会参与扫描）"
fi

echo "--- 扫了 $scanned 个文件，命中 $hits_found 处 ---"
if [ "$scanned" -lt 50 ]; then
  echo "覆盖数不足（$scanned），这次结论不算数"
  exit 1
fi
if [ "$hits_found" -gt 0 ]; then exit 1; fi
if [ "${#deny_terms[@]}" -gt 0 ]; then
  echo "干净（格式规则 + 外部黑名单 ${#deny_terms[@]} 条均未命中）"
else
  echo "干净（格式规则之外，真名清单在仓库外：SECRETS_DENYLIST/.secretsdenylist 未配置时不查真名）"
fi
