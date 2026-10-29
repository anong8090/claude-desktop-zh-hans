#!/usr/bin/env bash
# Claude Desktop 4.x 中文化注入脚本（macOS / Apple Silicon 或 Intel）
#
# 适配：Claude Desktop 4.29.0（前端在 Resources/ion-dist.asar，语言包在 /i18n/*.json）
# 与 3.6556.x 的 ion-dist 目录结构不同，脚本按结构定位，不硬编码版本号。
#
# 流程：退出 App -> 备份 -> 重打包 ion-dist.asar（注入中文包 + 放行白名单）
#       -> 回写 Info.plist 哈希 -> 关闭 asar 完整性 fuse -> ad-hoc 深度重签
#       -> 写入 locale 配置 -> 重启 -> 打印验收结果
#
# 用法：
#   ./scripts/inject-ion.sh --pack packs/zh-Hans.json [--dynamic resources/dynamic-zh-Hans.json]
#   ./scripts/inject-ion.sh --dry-run          # 只看会做什么
#   ./scripts/inject-ion.sh --pack ... --no-restart
set -euo pipefail

APP="/Applications/Claude.app"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
PACK="$ROOT/packs/zh-Hans.json"
DYNAMIC="$ROOT/resources/dynamic-zh-Hans.json"
ENT="$ROOT/resources/entitlements-4x.plist"
RESTART=1
DRY=0
BACKUP_DIR="${HOME}/Library/Caches/claude-zh-hans"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack) PACK="$2"; shift 2;;
    --dynamic) DYNAMIC="$2"; shift 2;;
    --app) APP="$2"; shift 2;;
    --no-restart) RESTART=0; shift;;
    --dry-run) DRY=1; shift;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

RES="$APP/Contents/Resources"
ASAR="$RES/ion-dist.asar"
FW="$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
TS="$(date +%Y%m%d-%H%M%S)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "0. 前置检查"
[[ -d "$APP" ]] || { echo "找不到 $APP"; exit 1; }
[[ -f "$ASAR" ]] || { echo "找不到 ${ASAR}（不是 4.x 结构？）"; exit 1; }
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
echo "  Claude 版本: $VERSION"
echo "  语言包: $PACK ($( [[ -f "$PACK" ]] && wc -c <"$PACK" | tr -d ' ' || echo 0) 字节)"
command -v node >/dev/null || { echo "需要 node"; exit 1; }
command -v codesign >/dev/null || { echo "需要 codesign"; exit 1; }

if [[ $DRY -eq 1 ]]; then
  say "dry-run：仅检查，不写任何文件"
  node "$HERE/repack-ion.js" --src "$ASAR" --out /tmp/ion-dist.dryrun --pack "$PACK" --dynamic "$DYNAMIC" && \
    echo "  ✅ 重打包可行性检查通过" || echo "  ❌ 重打包会失败，见上方报错"
  node "$HERE/patch-fuse.js" --dry-run "$FW" 2>/dev/null || node "$HERE/patch-fuse.js" --dry-run
  exit 0
fi

say "1. 退出 Claude"
if pgrep -f "$APP/Contents/MacOS/Claude" >/dev/null; then
  pkill -f "$APP/Contents/MacOS/Claude" || true
  for _ in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/Claude" >/dev/null || break; sleep 0.5; done
fi
pgrep -f "$APP/Contents/MacOS/Claude" >/dev/null && { echo "  ❌ 退出失败，请手动退出后重试"; exit 1; }
echo "  已退出"

say "2. 备份（${BACKUP_DIR}）"
mkdir -p "$BACKUP_DIR"
if [[ ! -f "$BACKUP_DIR/Claude-$VERSION-original.tar" ]]; then
  tar -cf "$BACKUP_DIR/Claude-$VERSION-original.tar" -C /Applications "Claude.app"
  echo "  已备份: Claude-$VERSION-original.tar"
else
  echo "  已存在同版本备份，跳过"
fi
for c in "${HOME}/Library/Application Support/Claude/config.json" \
         "${HOME}/Library/Application Support/Claude-3p/config.json"; do
  [[ -f "$c" ]] && cp "$c" "$BACKUP_DIR/$(basename "$(dirname "$c")")-config-$TS.json" && echo "  已备份: $c"
done

say "3. 重打包 ion-dist.asar"
NEW="/tmp/ion-dist-$TS.bin"
node "$HERE/repack-ion.js" --src "$ASAR" --out "$NEW" --pack "$PACK" --dynamic "$DYNAMIC"

say "4. 替换 ion-dist.asar"
cp "$NEW" "$RES/ion-dist.asar.new"
mv -f "$RES/ion-dist.asar.new" "$ASAR"
echo "  新大小: $(wc -c <"$ASAR" | tr -d ' ') 字节"

say "5. 回写 Info.plist 内的 asar 完整性哈希"
NEWHASH="$(node -e '
const fs=require("fs"),crypto=require("crypto");
const p=process.argv[1];const fd=fs.openSync(p,"r");const b=Buffer.alloc(16);fs.readSync(fd,b,0,16,0);
const len=b.readUInt32LE(12);const hb=Buffer.alloc(len);fs.readSync(fd,hb,0,len,16);
process.stdout.write(crypto.createHash("sha256").update(hb).digest("hex"));
' "$ASAR")"
/usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/ion-dist.asar:hash $NEWHASH" "$APP/Contents/Info.plist" 2>/dev/null \
  && echo "  hash=$NEWHASH" \
  || echo "  Info.plist 无该字段，跳过（fuse 关闭后不影响）"

say "6. 关闭 asar 完整性校验 fuse"
node "$HERE/patch-fuse.js" "$FW"

say "7. ad-hoc 深度重签名"
codesign --force --deep --sign - --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP" && echo "  签名校验通过"

say "8. 写入界面语言配置"
node -e '
const fs=require("fs"),os=require("os"),path=require("path");
for (const d of ["Claude","Claude-3p"]) {
  const p=path.join(os.homedir(),"Library/Application Support",d,"config.json");
  if (!fs.existsSync(p)) continue;
  let j={}; try{j=JSON.parse(fs.readFileSync(p,"utf8"));}catch{ continue; }
  const before=j.locale;
  j.locale="zh-Hans";
  fs.writeFileSync(p,JSON.stringify(j));
  console.log(`  ${d}: locale ${before} -> zh-Hans`);
}
'

say "9. 验收"
[[ -f "$ASAR" ]] && echo "  ✅ asar 就位"
strings "$FW" >/dev/null 2>&1 || true
codesign -d --entitlements - "$APP" 2>&1 | grep -q "virtualization" \
  && echo "  ✅ virtualization entitlement 在位（Cowork 需要）" \
  || echo "  ⚠️  缺少 virtualization entitlement"
echo "  ℹ️  spctl 会显示 rejected（ad-hoc 签名的必然结果，不影响本机运行）"

if [[ $RESTART -eq 1 ]]; then
  say "10. 启动 Claude"
  open -a "$APP"
  sleep 8
  pgrep -f "$APP/Contents/MacOS/Claude" >/dev/null && echo "  ✅ 已启动" || echo "  ❌ 启动失败，查看 ~/Library/Logs/DiagnosticReports"
fi

say "完成。若界面仍是英文：完全退出后重开一次；仍不行看 docs/TROUBLESHOOTING.md"
