#!/bin/zsh
#
# 从本机 Chromium 缓存里提取官方中文语言包。
#
# 为什么从这里取：
#   https://claude.ai/i18n/zh-Hans.json 有 Cloudflare 保护，curl 直连一律 403，
#   伪装 UA 也无效。但只要你在登录态下用过一次中文界面，App 就会把这份包
#   缓存到本地磁盘 —— 直接从缓存里解出来即可，纯离线。
#
# 用法：
#   ./scripts/extract-zh-pack.sh                    # 输出到 packs/zh-Hans.json
#   ./scripts/extract-zh-pack.sh /tmp/zh.json       # 指定输出
#
# 依赖：python3（定位）、node（brotli 解压，Python 标准库没有 brotli）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$SCRIPT_DIR/../packs/zh-Hans.json}"
OUT="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || (mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")" && pwd))/$(basename "$OUT")"

command -v node >/dev/null 2>&1 || { print -r -- "[FAIL] 需要 node（brotli 解压）" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { print -r -- "[FAIL] 需要 python3" >&2; exit 1; }

print -r -- "--> 在 Chromium 缓存中定位 i18n/zh-Hans.json ..."

# 缓存条目结构（Chromium simple cache）：
#   [24B 文件头][key][brotli body][stream 头 + EOF]
#   前 8 字节 magic = fc fb 6d 1b a7 72 5c 30
#   偏移 12 = key_length，偏移 24 起是 key 文本，body 起点 = 24 + key_length
#   长度取文件尾部响应头里的 content-length
# 缓存目录条目可达 1 万+，逐个 open 要 40 秒；先按体积预筛（语言包压缩后 ~790KB，
# 远大于均值）再读头部，实测可压到 2 秒内。
LOC=$(python3 - <<'PY'
import os, sys
MAGIC = bytes.fromhex("305c72a71b6dfbfc")
bases = [os.path.expanduser("~/Library/Application Support/%s/Cache/Cache_Data" % n)
         for n in ("Claude-3p", "Claude")]
MIN_SIZE = 100_000
best = None
for b in bases:
    if not os.path.isdir(b):
        continue
    with os.scandir(b) as it:
        for e in it:
            try:
                if not e.is_file() or e.stat().st_size < MIN_SIZE:
                    continue
                with open(e.path, "rb") as f:
                    h = f.read(24)
                    if len(h) < 24 or h[:8] != MAGIC:
                        continue
                    klen = int.from_bytes(h[12:16], "little")
                    if not (0 < klen < 4096):
                        continue
                    key = f.read(klen).decode("utf-8", "replace")
                if "i18n/zh-Hans.json" not in key:
                    continue
                mt = e.stat().st_mtime
                if best is None or mt > best[0]:
                    best = (mt, e.path, 24 + klen)
            except Exception:
                continue
if not best:
    sys.exit(1)
print(best[1])
print(best[2])
PY
) || {
  print -r -- ""
  print -r -- "[FAIL] 没找到缓存条目。" >&2
  print -r -- "" >&2
  print -r -- "可能原因：" >&2
  print -r -- "  1) 这台机器从没在中文界面下运行过 Claude（登录态可选中文时用一次即可生成缓存）" >&2
  print -r -- "  2) App 清过缓存（Claude → 设置 → 清理缓存 / 重装）" >&2
  print -r -- "  3) 换了数据目录（Claude-3p 与 Claude 两个目录都查过了）" >&2
  print -r -- "" >&2
  print -r -- "替代方案：从已经跑通的机器拷一份 zh-Hans.json 过来，放到 packs/ 下。" >&2
  exit 1
}

CPATH=$(print -r -- "$LOC" | sed -n 1p)
CSTART=$(print -r -- "$LOC" | sed -n 2p)
print -r -- "    缓存条目: $CPATH"
print -r -- "    body 起点: $CSTART"

node -e '
const fs = require("fs"), zlib = require("zlib");
const [p, startStr, out] = process.argv.slice(1);
const d = fs.readFileSync(p);
const m = d.toString("latin1").match(/content-length:\s*(\d+)/i);
const s = Number(startStr);
const L = m ? parseInt(m[1], 10) : d.length - s;
const body = d.subarray(s, s + L);
let raw;
try { raw = zlib.brotliDecompressSync(body); }
catch (e) { try { raw = zlib.inflateSync(body); } catch (e2) { throw new Error("解压失败，缓存条目可能被截断"); } }
const n = Object.keys(JSON.parse(raw.toString("utf8"))).length;
if (n < 1000) throw new Error("只解出 " + n + " 条，不是完整语言包");
fs.writeFileSync(out, raw);
console.log("    OK entries=" + n + " bytes=" + raw.length);
' "$CPATH" "$CSTART" "$OUT"

print -r -- "--> 已写入 $OUT"
print -r -- ""
print -r -- "下一步："
print -r -- "  ./scripts/reinject.sh --restart"
print -r -- "  ./scripts/verify.sh"
print -r -- ""
print -r -- "若 App 版本比这份包新，会有一部分 key 缺失（新版本新增文案），"
print -r -- "补法见 docs/HOW-IT-WORKS.md 的「语言包合并」一节。"
