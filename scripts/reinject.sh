#!/bin/zsh
#
# Claude 桌面端（第三方反代 / 3p / Gateway 模式）中文化 · 注入脚本
#
# 背景：Claude 每次更新都会用官方包覆盖 Contents/Resources/ion-dist/，
#       中文语言包和代码改动会全部丢失。本脚本一键打回去。
#
# 用法：
#   ./scripts/reinject.sh              # 只注入（不重启 Claude）
#   ./scripts/reinject.sh --restart    # 注入后自动重启 Claude
#   ./scripts/reinject.sh --dry-run    # 只检查，不写任何文件
#
# 特性：
#   - 幂等：可反复运行，不会重复打补丁
#   - 变量名无关：压缩后的变量名随版本变化，用正则定位
#   - 双别名：白名单同时含 zh-Hans / zh-CN，兼容不同系统区域（见 docs/HOW-IT-WORKS.md）
#   - 执行前自动备份被改动的文件到 backups/
#   - 结束打印覆盖率与签名校验结果

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${CLAUDE_APP:-/Applications/Claude.app}"
RES="$APP/Contents/Resources"
ION="$RES/ion-dist"
STAMP=$(date +%Y%m%d-%H%M%S)
BAK="$SCRIPT_DIR/backups"

RESTART=0
DRY=0
for a in "$@"; do
  case "$a" in
    --restart) RESTART=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) print -r -- "unknown arg: $a" >&2; exit 2 ;;
  esac
done

info() { print -r -- "--> $*"; }
ok()   { print -r -- "[ OK ] $*"; }
warn() { print -r -- "[WARN] $*" >&2; }
die()  { print -r -- "[FAIL] $*" >&2; exit 1; }

# ---------- 定位资源（兼容仓库结构与 ~/Documents/claude-zh-hans 结构）----------
find_pack() {
  local name="$1"
  for c in "$SCRIPT_DIR/$name" "$SCRIPT_DIR/../packs/$name" \
           "$SCRIPT_DIR/../resources/$name" "$HOME/Documents/claude-zh-hans/$name"; do
    [[ -f "$c" ]] && { print -r -- "$c"; return 0; }
  done
  return 1
}

PACK_ZIP=$(find_pack zh-Hans.json)         || die "找不到 zh-Hans.json。先跑 ./scripts/extract-zh-pack.sh 提取语言包（见 README）"
PACK_DYN=$(find_pack dynamic-zh-Hans.json) || die "找不到 dynamic-zh-Hans.json（仓库 resources/ 下应自带）"
ENT=$(find_pack entitlements-adhoc.plist)  || die "找不到 entitlements-adhoc.plist（仓库 resources/ 下应自带）"

[[ -d "$APP" ]] || die "找不到 $APP"
[[ -d "$ION" ]] || die "找不到 $ION —— Claude 可能改了目录结构，需要人工适配"

info "Claude 版本: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
info "语言包: $PACK_ZIP"
info "动态包: $PACK_DYN"
info "签名模板: $ENT"
[[ $DRY -eq 1 ]] && info "DRY-RUN：不会写入任何文件"
[[ $DRY -eq 0 ]] && mkdir -p "$BAK"

# ---------- 1. 语言白名单补丁 ----------
info "定位语言白名单文件 ..."
if grep -rq '"zh-Hans","zh-CN"\]' "$ION/assets" 2>/dev/null; then
  ok "白名单已含 zh-Hans + zh-CN，跳过代码补丁"
else
  LIST=$(mktemp)
  trap 'rm -f "$LIST"' EXIT
  # 已打过补丁的包可能停在 "id-ID","zh-Hans"] 这一中间态，两种都要认
  grep -rlE '"id-ID"\]|"id-ID","zh-Hans"\]' "$ION/assets" 2>/dev/null > "$LIST" || true
  [[ -s "$LIST" ]] || die "在 $ION/assets 下找不到白名单数组（前端结构变了，需人工适配）"

  if [[ $DRY -eq 1 ]]; then
    ok "将补丁 $(wc -l < "$LIST" | tr -d ' ') 个文件：$(tr '\n' ' ' < "$LIST")"
  else
    python3 - "$LIST" "$BAK" "$STAMP" <<'PY'
import os, re, shutil, sys
listfile, bakdir, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
files = [l.strip() for l in open(listfile, encoding='utf-8') if l.strip()]
assert files, "no candidate file"

short  = '"id-ID"]'                    # 原始态
alias  = '"id-ID","zh-Hans"]'          # 只加了单别名的中间态
full   = '"id-ID","zh-Hans","zh-CN"]'  # 目标态

patched = 0
for f in files:
    s = orig = open(f, encoding='utf-8').read()
    # 1a. 默认 locale: ="en-US",<var>=["en-US"  ->  ="zh-Hans",<var>=["en-US"
    s, n1 = re.subn(
        r'(=\s*"en-US")(\s*,\s*[A-Za-z_$][\w$]*\s*=\s*\[\s*"en-US")',
        r'="zh-Hans"\2', s, count=1)
    # 1b. 白名单数组补双别名
    n2 = s.count(short) + s.count(alias)
    if n2:
        s = s.replace(short, full).replace(alias, full)
    if s != orig:
        shutil.copy2(f, os.path.join(bakdir, "whitelist-%s-%s" % (stamp, os.path.basename(f))))
        open(f, 'w', encoding='utf-8').write(s)
        patched += 1
        print("    patched %s (default:%d, arrays:%d)" % (os.path.basename(f), n1, n2))
assert patched, "nothing patched (前端结构变了？)"
PY
    ok "代码补丁完成"
  fi
fi

# ---------- 2. 安装语言包 ----------
info "安装中文语言包 ..."
IO="$ION/i18n"
[[ -d "$IO/dynamic" ]] || { [[ $DRY -eq 0 ]] && mkdir -p "$IO/dynamic"; }

install_file() {   # $1=源 $2=目标 $3=描述
  if [[ -f "$2" ]]; then
    if cmp -s "$1" "$2"; then
      ok "$3 已是最新"
      return 0
    fi
    # 字节不同但 JSON 语义相同（缩进/键序差异）就不要重写，避免无谓重签名
    if python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
a = json.load(open(sys.argv[1], encoding='utf-8'))
b = json.load(open(sys.argv[2], encoding='utf-8'))
raise SystemExit(0 if a == b else 1)
PY
    then
      ok "$3 内容等价（仅格式差异），跳过"
      return 0
    fi
  fi
  if [[ $DRY -eq 1 ]]; then
    ok "$3 需要写入 -> $2"
    return 0
  fi
  [[ -f "$2" ]] && cp "$2" "$BAK/$(basename "$2" .json)-$STAMP.json" 2>/dev/null || true
  cp "$1" "$2"
  ok "$3 已安装"
}

install_file "$PACK_ZIP" "$IO/zh-Hans.json"            "静态包 zh-Hans"
install_file "$PACK_DYN" "$IO/dynamic/zh-Hans.json"    "动态包 zh-Hans"
# zh-CN 别名副本：主进程下发的 --lang 由系统 locale 推出，可能是 zh-CN；
# 前端按精确名称取包，两份必须同时存在，否则界面回落英文。
install_file "$PACK_ZIP" "$IO/zh-CN.json"              "静态包 zh-CN（别名）"
install_file "$PACK_DYN" "$IO/dynamic/zh-CN.json"      "动态包 zh-CN（别名）"

# ---------- 3. 覆盖率 ----------
if [[ $DRY -eq 0 ]]; then
  python3 - "$IO" <<'PY'
import json, os, sys
R = sys.argv[1]
try:
    en = json.load(open(os.path.join(R, 'en-US.json')))
    zh = json.load(open(os.path.join(R, 'zh-Hans.json')))
except Exception as e:
    print("    [warn] 覆盖率检查跳过: %s" % e); raise SystemExit(0)
have = set(en) & set(zh)
same = [k for k in have if zh[k] == en[k]]
pct  = 100.0 * len(have) / len(en)
real = 100.0 * (len(en) - len(same)) / len(en)
print("    key 覆盖: %d/%d = %.2f%%" % (len(have), len(en), pct))
print("    实际中文化: %.2f%%（%d 条值仍为英文，官方也未译）" % (real, len(same)))
if pct < 99.9:
    miss = [k for k in en if k not in zh]
    print("    %d 条 key 缺失 -> 语言包比 App 旧，重跑 extract-zh-pack.sh 或 merge-zh.py" % len(miss))
    for k in miss[:5]:
        print("      - %s" % str(en[k])[:60])
PY
fi

# ---------- 4. 重签名 ----------
# 必须带 --entitlements。ad-hoc 签名（--sign -）默认丢弃全部 entitlements，
# 其中 com.apple.security.virtualization 是工作区 VM 必需项，丢了两件事会发生：
#   1) Cowork / 工作区报 "installation appears to be invalid"
#   2) 某些版本直接无法启动
# 只签主 bundle，不要用 --deep：嵌套 helper 保留官方签名反而更稳。
info "ad-hoc 重签名（带 entitlements）..."
if [[ $DRY -eq 1 ]]; then
  ok "将执行: codesign --force --sign - --entitlements $ENT \"$APP\""
else
  codesign --force --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1 || true
  codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.virtualization" \
    || die "签名后 virtulalization entitlement 丢失，检查 $ENT"
  codesign --verify "$APP" 2>/dev/null || die "签名校验失败"
  ok "签名校验通过（virtualization entitlement 在位）"
fi

# ---------- 5. 可选重启 ----------
if [[ $RESTART -eq 1 && $DRY -eq 0 ]]; then
  info "重启 Claude ..."
  for p in $(pgrep -f "Claude.app" 2>/dev/null || true); do kill "$p" 2>/dev/null || true; done
  sleep 2
  for p in $(pgrep -f "Claude.app" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
  sleep 1
  open -a "$APP"
  sleep 6
  pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 \
    && ok "Claude 已重启" || info "Claude 未自动起来，请手动打开"
else
  pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 \
    && info "Claude 正在运行：退出后重新打开才生效（或加 --restart）" \
    || info "完成，启动 Claude 即可生效"
fi
