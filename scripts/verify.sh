#!/bin/zsh
#
# 注入后验收。四项必查，全过才算成功。
#
#   ./scripts/verify.sh
#
# 退出码：0 全部通过；1 有项目失败。

set -uo pipefail

APP="${CLAUDE_APP:-/Applications/Claude.app}"
ION="$APP/Contents/Resources/ion-dist"
FAIL=0

pass() { print -r -- "  [ OK ] $*"; }
fail() { print -r -- "  [FAIL] $*"; FAIL=1; }
skip() { print -r -- "  [SKIP] $*"; }

print -r -- ""
print -r -- "Claude 版本: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
print -r -- "系统区域   : $(defaults read -g AppleLocale 2>/dev/null || echo '?') / $(defaults read -g AppleLanguages 2>/dev/null | tr -d '\n' | tr -s ' ')"
print -r -- ""

# 1) 语言包在位
print -r -- "1) 语言包"
for f in "$ION/i18n/zh-Hans.json" "$ION/i18n/zh-CN.json" \
         "$ION/i18n/dynamic/zh-Hans.json" "$ION/i18n/dynamic/zh-CN.json"; do
  if [[ -f "$f" ]]; then
    n=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$f" 2>/dev/null || echo '?')
    pass "$(basename "$(dirname "$f")")/$(basename "$f")  $n 条"
  else
    fail "缺 $f"
  fi
done

# 2) 白名单与实际 locale 匹配
#    注意：Claude 未运行时读不到 --lang，此时必须 SKIP 而不是 PASS，
#    否则 grep -q "" 恒为真，界面全英文也会报通过。
print -r -- "2) 白名单 vs 运行时 locale"
L=$(pgrep -fl 'Claude Helper' 2>/dev/null | grep -o -- '--lang=[a-zA-Z_-]*' | head -1 | cut -d= -f2)
if [[ -z "${L}" ]]; then
  skip "Claude 未运行，读不到运行时 --lang（先启动一次再验）"
else
  print -r -- "  运行时 --lang = $L"
  if grep -rq "\"$L\"" "$ION/assets" 2>/dev/null; then
    pass "白名单含 $L"
  else
    fail "白名单缺 $L —— 界面会回落英文，跑 reinject.sh 补别名"
  fi
fi

# 3) 签名与 entitlements
print -r -- "3) 签名"
if codesign --verify "$APP" 2>/dev/null; then
  pass "codesign --verify 通过"
else
  fail "codesign --verify 失败"
fi
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
  pass "virtualization entitlement 在位（工作区 VM 可用）"
else
  fail "virtualization entitlement 丢失 —— 工作区会报 installation invalid"
fi

# 4) 语言偏好存储一致（不是决定因素，但不一致会让排查混乱）
print -r -- "4) config.json 中的 locale（仅供参考，非决定因素）"
for d in Claude Claude-3p; do
  p="$HOME/Library/Application Support/$d/config.json"
  [[ -f "$p" ]] || { skip "$d/config.json 不存在"; continue; }
  v=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("locale"))' "$p" 2>/dev/null || echo '?')
  case "$v" in
    zh-Hans|zh-CN) pass "$d locale = $v" ;;
    *) print -r -- "  [NOTE] $d locale = $v（不影响界面，决定因素是 --lang 与白名单）" ;;
  esac
done

# 5) 常见无效路径的残留检查
print -r -- "5) 无效路径残留"
if defaults read com.anthropic.claudefordesktop AppleLanguages >/dev/null 2>&1; then
  print -r -- "  [NOTE] 存在 App 级 AppleLanguages 覆盖：$(defaults read com.anthropic.claudefordesktop AppleLanguages | tr -d '\n')"
  print -r -- "         这不改变界面语言，但会干扰 --lang 判断，建议 defaults delete"
else
  pass "无 AppleLanguages 覆盖（干净）"
fi

print -r -- ""
if [[ $FAIL -eq 0 ]]; then
  print -r -- "结论：通过。若界面仍是英文，退出 Claude 重开（文件已落盘，进程未重载）。"
else
  print -r -- "结论：有失败项，见上。排查顺序见 docs/TROUBLESHOOTING.md"
fi
exit $FAIL
