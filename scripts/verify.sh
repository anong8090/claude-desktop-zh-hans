#!/bin/zsh
#
# 注入后验收。五项必查，全过才算成功。
#
#   ./scripts/verify.sh
#
# 退出码：0 全部通过；1 有项目失败。
#
# 兼容两种前端结构：
#   A. Claude >= 4.29  Resources/ion-dist.asar（不解包，直接从 asar 里读）
#   B. Claude <= 3.x   Resources/ion-dist/（直接读文件）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${CLAUDE_APP:-/Applications/Claude.app}"
RES="$APP/Contents/Resources"
ASAR_TOOL="$SCRIPT_DIR/asar-tool.js"
FAIL=0

pass() { print -r -- "  [ OK ] $*"; }
fail() { print -r -- "  [FAIL] $*"; FAIL=1; }
skip() { print -r -- "  [SKIP] $*"; }
note() { print -r -- "  [NOTE] $*"; }

# ---------- 结构探测 ----------
if [[ -f "$RES/ion-dist.asar" ]]; then
  MODE=asar; SRC="$RES/ion-dist.asar"
elif [[ -d "$RES/ion-dist" ]]; then
  MODE=dir;  SRC="$RES/ion-dist"
else
  print -r -- "[FAIL] 找不到 ion-dist.asar 或 ion-dist —— 前端结构变了"
  exit 1
fi

print -r -- ""
print -r -- "Claude 版本: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
print -r -- "前端结构   : $MODE"
print -r -- "系统区域   : $(defaults read -g AppleLocale 2>/dev/null || echo '?') / $(defaults read -g AppleLanguages 2>/dev/null | tr -d '\n' | tr -s ' ')"
print -r -- ""

# ---------- 统一读取器：让下面两个小节不关心是 asar 还是目录 ----------
pack_json() {   # $1 = i18n 下的相对路径，输出文件内容
  if [[ $MODE == asar ]]; then
    node "$ASAR_TOOL" cat "$SRC" "i18n/$1" 2>/dev/null
  else
    cat "$SRC/i18n/$1" 2>/dev/null
  fi
}

pack_count() {  # $1 = i18n 下的相对路径，输出条目数；不存在输出空
  pack_json "$1" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null
}

asset_cat() {   # $1 = 相对前端的完整路径（如 assets/v1/shared-52-xxx.js）
  if [[ $MODE == asar ]]; then
    node "$ASAR_TOOL" cat "$SRC" "$1" 2>/dev/null
  else
    cat "$SRC/$1" 2>/dev/null
  fi
}

# 1) 语言包在位
print -r -- "1) 语言包"
for rel in zh-Hans.json zh-CN.json dynamic/zh-Hans.json dynamic/zh-CN.json; do
  n=$(pack_count "$rel")
  if [[ -n "$n" ]]; then
    pass "$rel  $n 条"
  else
    fail "缺 i18n/$rel（或不是合法 JSON）"
  fi
done

# 2) 白名单与实际 locale 匹配
#    注意：Claude 未运行时读不到 --lang，此时必须 SKIP 而不是 PASS，
#    否则 grep -q "" 恒为真，界面全英文也会报通过。
print -r -- "2) 白名单 vs 运行时 locale"
L=$(pgrep -fl 'Claude Helper' 2>/dev/null | grep -o -- '--lang=[a-zA-Z_-]*' | head -1 | cut -d= -f2)
WL=$( { [[ $MODE == asar ]] && node "$ASAR_TOOL" list "$SRC" assets/v1/ 2>/dev/null; } \
      | grep -o 'assets/v1/shared-52-[^ ]*' | head -1 )
if [[ -z "$WL" ]]; then
  # 目录模式 / 版本命名变化时兜底
  WL="assets/v1/$(ls "$SRC/assets/v1" 2>/dev/null | grep -E '^shared-52-' | head -1)"
fi
if [[ -z "${L}" ]]; then
  skip "Claude 未运行，读不到运行时 --lang（先启动一次再验）"
else
  print -r -- "  运行时 --lang = $L"
  if [[ -z "$WL" ]]; then
    skip "找不到白名单所在 chunk（shared-52-*），无法判断"
  else
    # 不用 grep 管道：grep -q 会提前关闭管道，配合 pipefail 会把 SIGPIPE 误判为失败
    WLC=$(asset_cat "$WL")
    if [[ "$WLC" == *"\"$L\""* ]]; then
      pass "白名单含 $L（$WL）"
    else
      fail "白名单缺 $L —— 界面会回落英文，跑 reinject.sh 补别名"
    fi
  fi
fi

# 3) 签名与 entitlements
print -r -- "3) 签名"
if [[ $MODE == asar ]]; then
  codesign --verify --deep --strict "$APP" 2>/dev/null
else
  codesign --verify "$APP" 2>/dev/null
fi && pass "codesign --verify 通过" || fail "codesign --verify 失败"

if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
  pass "virtualization entitlement 在位（工作区 VM 可用）"
else
  fail "virtualization entitlement 丢失 —— 工作区会报 installation invalid"
fi

# 4) asar 完整性校验 fuse（仅 4.29+）
print -r -- "4) asar 完整性校验 fuse"
if [[ $MODE != asar ]]; then
  skip "目录模式不需要"
else
  # 优先离线直读二进制（不依赖网络）；读不到再回退 npx
  FW="$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
  FUSEOUT=""
  if command -v node >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/patch-fuse.js" && -f "$FW" ]]; then
    FUSEOUT=$(node "$SCRIPT_DIR/patch-fuse.js" --dry-run "$FW" 2>/dev/null)
  fi
  if print -r -- "$FUSEOUT" | grep -q "EnableEmbeddedAsarIntegrityValidation = 0"; then
    pass "EnableEmbeddedAsarIntegrityValidation 已关闭（离线读取）"
  elif print -r -- "$FUSEOUT" | grep -q "EnableEmbeddedAsarIntegrityValidation = 1"; then
    fail "完整性校验仍开启 —— 重打包后启动会 FATAL，跑 reinject.sh --force 修掉"
  else
    FUSEOUT=$(cd "$SCRIPT_DIR" && npx --yes @electron/fuses read --app "$APP" 2>/dev/null)
    if print -r -- "$FUSEOUT" | grep -q "EnableEmbeddedAsarIntegrityValidation is Disabled"; then
      pass "EnableEmbeddedAsarIntegrityValidation 已关闭"
    elif print -r -- "$FUSEOUT" | grep -q "EnableEmbeddedAsarIntegrityValidation is Enabled"; then
      fail "完整性校验仍开启 —— 重打包后启动会 FATAL，跑 reinject.sh --force 修掉"
    else
      skip "读不到 fuse 状态（patch-fuse.js 未匹配到 magic，npx 也不可用）"
    fi
  fi
fi

# 5) 语言偏好存储一致（不是决定因素，但不一致会让排查混乱）
print -r -- "5) config.json 中的 locale（仅供参考，非决定因素）"
for d in Claude Claude-3p; do
  p="$HOME/Library/Application Support/$d/config.json"
  [[ -f "$p" ]] || { skip "$d/config.json 不存在"; continue; }
  v=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("locale"))' "$p" 2>/dev/null || echo '?')
  case "$v" in
    zh-Hans|zh-CN) pass "$d locale = $v" ;;
    *) note "$d locale = $v（不影响界面，决定因素是 --lang 与白名单）" ;;
  esac
done

# 6) 无效路径残留
print -r -- "6) 无效路径残留"
if defaults read com.anthropic.claudefordesktop AppleLanguages >/dev/null 2>&1; then
  note "存在 App 级 AppleLanguages 覆盖：$(defaults read com.anthropic.claudefordesktop AppleLanguages | tr -d '\n')"
  note "这不改变界面语言，但会干扰 --lang 判断，建议 defaults delete"
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
