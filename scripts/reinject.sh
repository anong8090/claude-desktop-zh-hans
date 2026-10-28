#!/bin/zsh
#
# Claude 桌面端（第三方反代 / 3p / Gateway 模式）中文化 · 注入脚本 v3
#
# 背景：Claude 每次更新都会覆盖 Contents/Resources 下的前端资源，
#       中文语言包和代码改动会全部丢失。本脚本一键打回去。
#
# 用法：
#   ./scripts/reinject.sh              # 只注入（不重启 Claude）
#   ./scripts/reinject.sh --restart    # 注入后自动重启 Claude
#   ./scripts/reinject.sh --force      # 强制重打包/重签（即使检测到已注入）
#   ./scripts/reinject.sh --dry-run    # 只检查，不写任何文件
#
# 两种前端结构都支持（自动识别）：
#   A. Claude >= 4.29  Resources/ion-dist.asar   单文件，需解包→补丁→重打包→关完整性校验→重签
#   B. Claude <= 3.x   Resources/ion-dist/       目录，直接改文件
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
STAMP=$(date +%Y%m%d-%H%M%S)
BAK="$SCRIPT_DIR/backups"
WORK="${TMPDIR:-/tmp}/claude-zh-work"
ASAR_TOOL="$SCRIPT_DIR/asar-tool.js"

RESTART=0; DRY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --restart) RESTART=1 ;;
    --force)   FORCE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)

# ---------- 结构探测 ----------
if [[ -f "$RES/ion-dist.asar" ]]; then
  MODE=asar
elif [[ -d "$RES/ion-dist" ]]; then
  MODE=dir
else
  die "既没有 $RES/ion-dist.asar 也没有 $RES/ion-dist —— Claude 前端结构又变了，需人工适配"
fi

info "Claude 版本: $VER    结构模式: $MODE"
info "语言包: $PACK_ZIP"
info "动态包: $PACK_DYN"
info "签名模板: $ENT"
[[ $DRY -eq 1 ]] && info "DRY-RUN：不会写入任何文件"
[[ $DRY -eq 0 ]] && mkdir -p "$BAK"

# ---------- 白名单补丁（对给定 assets 目录操作）----------
# 三种状态都要认：原始 / 只加了单别名的中间态 / 目标态
patch_whitelist() {
  local ASSETS="$1"
  if grep -rq '"zh-Hans","zh-CN"\]' "$ASSETS" 2>/dev/null; then
    ok "白名单已含 zh-Hans + zh-CN，跳过代码补丁"
    return 0   # 无改动
  fi

  local LIST; LIST=$(mktemp)
  grep -rlE '"id-ID"\]|"id-ID","zh-Hans"\]' "$ASSETS" 2>/dev/null > "$LIST" || true
  [[ -s "$LIST" ]] || { rm -f "$LIST"; die "在 $ASSETS 下找不到白名单数组（前端结构变了，需人工适配）"; }

  if [[ $DRY -eq 1 ]]; then
    ok "将补丁 $(wc -l < "$LIST" | tr -d ' ') 个文件：$(tr '\n' ' ' < "$LIST")"
    CHANGED=1
    rm -f "$LIST"
    return 0
  fi

  if ! python3 - "$LIST" "$BAK" "$STAMP" <<'PY'
import os, re, shutil, sys
listfile, bakdir, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
files = [l.strip() for l in open(listfile, encoding='utf-8') if l.strip()]
assert files, "no candidate file"

short = '"id-ID"]'                    # 原始态
alias = '"id-ID","zh-Hans"]'          # 只加了单别名的中间态
full  = '"id-ID","zh-Hans","zh-CN"]'  # 目标态

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
  then
    rm -f "$LIST"
    die "白名单补丁失败（上面的 traceback 是原因），未改动任何文件"
  fi
  rm -f "$LIST"
  ok "代码补丁完成"
  CHANGED=1
  return 0
}

# ---------- 安装语言包（对给定 i18n 目录操作）----------
install_packs() {   # $1 = i18n 目录
  local IO="$1"
  mkdir -p "$IO/dynamic"
  install_file "$PACK_ZIP" "$IO/zh-Hans.json"         "静态包 zh-Hans"
  install_file "$PACK_DYN" "$IO/dynamic/zh-Hans.json" "动态包 zh-Hans"
  # zh-CN 别名副本：主进程下发的 --lang 由系统 locale 推出，可能是 zh-CN；
  # 前端按精确名称取包，两份必须同时存在，否则界面回落英文。
  install_file "$PACK_ZIP" "$IO/zh-CN.json"           "静态包 zh-CN（别名）"
  install_file "$PACK_DYN" "$IO/dynamic/zh-CN.json"   "动态包 zh-CN（别名）"
}

install_file() {   # $1=源 $2=目标 $3=描述；有改动返回 0，无改动返回 1
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
  cp "$1" "$2" || die "写入失败: $2"
  ok "$3 已安装"
  CHANGED=1
  return 0
}

# ---------- 覆盖率 ----------
report_coverage() {   # $1 = i18n 目录
  [[ $DRY -eq 1 ]] && return 0
  python3 - "$1" <<'PY'
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
}

# ---------- 签名 ----------
# 必须带 --entitlements：ad-hoc 签名（--sign -）默认丢弃全部 entitlements，
# 其中 com.apple.security.virtualization 是工作区 VM 必需项，丢了两件事会发生：
#   1) Cowork / 工作区报 "installation appears to be invalid"
#   2) 某些版本直接无法启动
#
# 两种结构的签法不同：
#   dir 模式：只签主 bundle。嵌套 helper 保留官方签名反而更稳。
#   asar 模式：必须 --deep 全部重签。因为改 fuse 会让 Electron Framework 签名失效，
#              而 framework 一旦被 ad-hoc 重签，helper 若仍是官方 Team ID，
#              library validation 会以 "different Team IDs" 拒绝加载（dyld 报错）。
sign_app() {
  info "ad-hoc 重签名（带 entitlements）..."
  if [[ $DRY -eq 1 ]]; then
    ok "将执行: codesign --force $([[ $MODE == asar ]] && print -r -- '--deep ')--sign - --entitlements $ENT \"$APP\""
    return 0
  fi

  if [[ $MODE == asar ]]; then
    local FW="$APP/Contents/Frameworks/Electron Framework.framework/Versions/A"
    [[ -d "$FW" ]] && codesign --force --sign - "$FW" >/dev/null 2>&1 || true
    codesign --force --deep --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1 || true
    codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.virtualization" \
      || die "签名后 virtualization entitlement 丢失，检查 $ENT"
    codesign --verify --deep --strict "$APP" 2>/dev/null || die "签名校验失败"
    ok "签名校验通过（--deep，virtualization entitlement 在位）"
  else
    codesign --force --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1 || true
    codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.virtualization" \
      || die "签名后 virtualization entitlement 丢失，检查 $ENT"
    codesign --verify "$APP" 2>/dev/null || die "签名校验失败"
    ok "签名校验通过（virtualization entitlement 在位）"
  fi
}

# ---------- asar 模式专用：关闭完整性校验 fuse ----------
# 4.29 起 Claude 在 Info.plist 里记录 ion-dist.asar 的 SHA256，
# 并开启 EnableEmbeddedAsarIntegrityValidation。重打包后哈希必然变化，
# 而 ad-hoc 签名下 Electron 取不到 integrity 数据，启动直接 FATAL。
disable_asar_integrity_fuse() {
  local out
  out=$(cd "$SCRIPT_DIR" && npx --yes @electron/fuses read --app "$APP" 2>/dev/null || true)
  if print -r -- "$out" | grep -q "EnableEmbeddedAsarIntegrityValidation is Enabled"; then
    info "关闭 EnableEmbeddedAsarIntegrityValidation fuse（重打包后必须）..."
    (cd "$SCRIPT_DIR" && npx --yes @electron/fuses write --app "$APP" \
        EnableEmbeddedAsarIntegrityValidation=off >/dev/null 2>&1) \
      || die "fuse 关闭失败（需要联网让 npx 拉 @electron/fuses）。手动执行：
      npx --yes @electron/fuses write --app \"$APP\" EnableEmbeddedAsarIntegrityValidation=off"
    ok "asar 完整性校验已关闭"
  else
    ok "asar 完整性校验已是关闭状态"
  fi
}

# ================= 主流程 =================

if [[ $MODE == asar ]]; then
  NODE="$(command -v node 2>/dev/null || true)"
  if [[ -z "$NODE" ]]; then
    for c in "$HOME"/.workbuddy/binaries/node/versions/*/bin/node \
             /opt/homebrew/bin/node /usr/local/bin/node \
             "$HOME"/.nvm/versions/node/*/bin/node; do
      [[ -x "$c" ]] && NODE="$c" && break
    done
  fi
  [[ -x "${NODE:-}" ]] || die "asar 模式需要 node（用于解包/重打包）"
  [[ -f "$ASAR_TOOL" ]] || die "缺 $ASAR_TOOL"

  # 原始 asar 备份（每版本只备份一次）
  BK="$BAK/ion-dist-$VER-original.asar"
  if [[ -f "$BK" ]]; then
    ok "已存在原始包备份 $(basename "$BK")"
  elif [[ $DRY -eq 0 ]]; then
    info "备份原始 asar -> $(basename "$BK")"
    ditto "$RES/ion-dist.asar" "$BK" || die "备份失败"
  fi

  info "解包 ion-dist.asar ..."
  rm -rf "$WORK"; mkdir -p "$WORK"
  "$NODE" "$ASAR_TOOL" extract "$RES/ion-dist.asar" "$WORK/dist" >/dev/null || die "解包失败"

  CHANGED=0
  patch_whitelist "$WORK/dist/assets"
  install_packs "$WORK/dist/i18n"
  report_coverage  "$WORK/dist/i18n"

  if [[ $CHANGED -eq 0 && $FORCE -eq 0 ]]; then
    ok "已是最新（$VER），无需重打包"
    rm -rf "$WORK"
  else
    info "重新打包 asar ..."
    "$NODE" "$ASAR_TOOL" pack "$WORK/dist" "$WORK/ion-dist.bin" >/dev/null || die "打包失败"
    if [[ $DRY -eq 1 ]]; then
      ok "DRY-RUN：将写回 $RES/ion-dist.asar"
    else
      info "写回 $RES/ion-dist.asar ..."
      ditto "$WORK/ion-dist.bin" "$RES/ion-dist.asar" || die "写回失败"
      ok "asar 已更新（$(du -h "$RES/ion-dist.asar" | cut -f1)）"
      disable_asar_integrity_fuse
      sign_app
      # 探测缓存不删不会重新探测，工作区状态可能停留在旧结果
      rm -f "$HOME/Library/Application Support/Claude-3p/vm-support-probe.json" 2>/dev/null || true
    fi
    rm -rf "$WORK"
  fi

else
  ION="$RES/ion-dist"

  CHANGED=0
  patch_whitelist "$ION/assets"
  install_packs "$ION/i18n"
  report_coverage  "$ION/i18n"

  if [[ $CHANGED -eq 1 || $FORCE -eq 1 ]]; then
    sign_app
  else
    ok "文件与签名都无需变动"
  fi
fi

# ---------- 可选重启 ----------
if [[ $RESTART -eq 1 && $DRY -eq 0 ]]; then
  info "重启 Claude ..."
  for p in $(pgrep -f "Claude.app" 2>/dev/null || true); do kill "$p" 2>/dev/null || true; done
  sleep 2
  for p in $(pgrep -f "Claude.app" 2>/dev/null || true); do kill -9 "$p" 2>/dev/null || true; done
  sleep 1
  open -a "$APP"
  sleep 8
  if pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1; then
    ok "Claude 已重启"
    probe="$HOME/Library/Application Support/Claude-3p/vm-support-probe.json"
    if [[ -f "$probe" ]]; then info "工作区探测: $(cat "$probe")"; fi
  else
    warn "Claude 未起来。查日志：log show --predicate 'process == \"Claude\"' --last 2m"
    warn "asar 模式下常见原因是 fuse 没关闭，或签名 Team ID 不一致（见 docs/TROUBLESHOOTING.md）"
  fi
else
  pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 \
    && info "Claude 正在运行：退出后重新打开才生效（或加 --restart）" \
    || info "完成，启动 Claude 即可生效"
fi
