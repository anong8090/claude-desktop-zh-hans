// 重打包 ion-dist.asar：注入中文语言包 + 放行 zh-Hans 白名单，并重算每个文件的 integrity。
//
// 用法：
//   node repack-ion.js --src <原 ion-dist.asar> --out <输出路径> \
//     --pack <zh-Hans.json> [--dynamic <dynamic-zh-Hans.json>]
//
// 说明：
//   - asar 头部 JSON 里每个文件都带 integrity（SHA256 + 4MB 分块），改了内容必须重算，
//     否则 Electron 会拒绝加载。
//   - 原始数据段是紧密排列的，所以只改「被替换文件」的 size 就会让后续所有 offset 错位，
//     这里统一用 effective size 重排，保证 offset 与写入顺序一致。
const fs = require('fs');
const crypto = require('crypto');

const BLOCK = 4194304;
// Web 端语言白名单（fy / Dy 两处），出现在 assets/v1/shared-*.js 里
// 前端是精确名匹配、没有模糊回退，而 macOS 的 zh-Hans-US 会被 Chromium 归一化成 zh-CN，
// 所以必须同时放行 zh-Hans 与 zh-CN 两个别名（见 docs/HOW-IT-WORKS.md）。
const TAIL = '"en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"';
const TARGET = '["zh-Hans","zh-CN",' + TAIL + ']';
const ORIG_RE = new RegExp('\\[' + TAIL + '\\]', 'g');          // 原始 11 种
const SINGLE_RE = new RegExp('\\["zh-Hans",' + TAIL + '\\]', 'g'); // 只加了单别名的中间态
const DONE_MARK = '["zh-Hans","zh-CN"';
const PATCH_FILE = '/assets/v1/shared-52-JcfRCCiW.js';

function arg(name, def) {
  const i = process.argv.indexOf('--' + name);
  return i > -1 ? process.argv[i + 1] : def;
}

const SRC = arg('src', '/Applications/Claude.app/Contents/Resources/ion-dist.asar');
const OUT = arg('out', '/tmp/ion-dist.new.bin');
const PACK = arg('pack');
const DYNAMIC = arg('dynamic');
if (!PACK) {
  console.error('缺少 --pack <zh-Hans.json>');
  process.exit(1);
}

function readHeader(p) {
  const fd = fs.openSync(p, 'r');
  const b = Buffer.alloc(16);
  fs.readSync(fd, b, 0, 16, 0);
  const payload = b.readUInt32LE(4);
  const len = b.readUInt32LE(12);
  const hb = Buffer.alloc(len);
  fs.readSync(fd, hb, 0, len, 16);
  return { fd, header: JSON.parse(hb.toString('utf8')), dataStart: 8 + payload };
}

function integrity(buf) {
  const hash = crypto.createHash('sha256').update(buf).digest('hex');
  const blocks = [];
  for (let i = 0; i < buf.length; i += BLOCK) {
    blocks.push(crypto.createHash('sha256').update(buf.subarray(i, Math.min(i + BLOCK, buf.length))).digest('hex'));
  }
  return { algorithm: 'SHA256', hash, blockSize: BLOCK, blocks };
}

const src = readHeader(SRC);
const h = src.header;

const leaves = [];
(function walk(node, pre) {
  for (const k of Object.keys(node.files || {})) {
    const v = node.files[k];
    if (v.files) walk(v, pre + '/' + k);
    else leaves.push({ path: pre + '/' + k, node: v, offset: Number(v.offset), size: v.size });
  }
})(h, '');
leaves.sort((a, b) => a.offset - b.offset);

// ---- 待注入内容 ----
const overrides = new Map();
const patchLeaf = leaves.find((l) => l.path === PATCH_FILE);
if (!patchLeaf) {
  console.error(`找不到补丁目标 ${PATCH_FILE}，说明前端产物名变了，需要重新定位白名单文件`);
  process.exit(2);
}
const patchBuf = Buffer.alloc(patchLeaf.size);
fs.readSync(src.fd, patchBuf, 0, patchLeaf.size, src.dataStart + patchLeaf.offset);
const js = patchBuf.toString('utf8');
if (js.includes(DONE_MARK)) {
  console.log('白名单已含 zh-Hans + zh-CN，跳过（幂等）');
} else {
  const hits = (js.match(ORIG_RE) || []).length + (js.match(SINGLE_RE) || []).length;
  ORIG_RE.lastIndex = 0;
  SINGLE_RE.lastIndex = 0;
  if (!hits) {
    console.error('白名单数组未找到：前端产物结构可能变化，需重新定位文件');
    process.exit(3);
  }
  const patched = js.replace(ORIG_RE, TARGET).replace(SINGLE_RE, TARGET);
  overrides.set(PATCH_FILE, Buffer.from(patched, 'utf8'));
  console.log(`白名单注入：${hits} 处（${PATCH_FILE}）`);
}

if (fs.existsSync(PACK)) {
  const packBuf = fs.readFileSync(PACK);
  // 双别名：白名单里的 zh-Hans 与 zh-CN 都要有对应文件，否则精确匹配会落空
  overrides.set('/i18n/zh-Hans.json', packBuf);
  overrides.set('/i18n/zh-CN.json', packBuf);
  console.log(`主语言包：${packBuf.length} 字节（zh-Hans + zh-CN 双别名）`);
} else {
  console.error('语言包不存在：' + PACK);
  process.exit(4);
}
if (DYNAMIC && fs.existsSync(DYNAMIC)) {
  const dynBuf = fs.readFileSync(DYNAMIC);
  overrides.set('/i18n/dynamic/zh-Hans.json', dynBuf);
  overrides.set('/i18n/dynamic/zh-CN.json', dynBuf);
  console.log(`动态文案包：${dynBuf.length} 字节（双别名）`);
}

// ---- 重排 offset（含新增文件）----
const effSize = (l) => (overrides.has(l.path) ? overrides.get(l.path).length : l.size);
let cursor = 0;
for (const l of leaves) { l.newOffset = cursor; cursor += effSize(l); }

const added = [];
for (const [p, buf] of overrides) {
  if (leaves.some((l) => l.path === p)) continue;
  added.push({ path: p, buf, offset: cursor });
  cursor += buf.length;
}

function nodeAt(path, create) {
  const parts = path.split('/').filter(Boolean);
  let cur = h;
  for (let i = 0; i < parts.length - 1; i++) {
    if (!cur.files[parts[i]]) {
      if (!create) return null;
      cur.files[parts[i]] = { files: {} };
    }
    cur = cur.files[parts[i]];
  }
  const last = parts[parts.length - 1];
  if (create && !cur.files[last]) cur.files[last] = {};
  return cur.files[last] || null;
}

for (const a of added) {
  nodeAt(a.path, true);
  const n = nodeAt(a.path, false);
  n.size = a.buf.length;
  n.offset = String(a.offset);
  n.integrity = integrity(a.buf);
}

for (const l of leaves) {
  if (overrides.has(l.path)) {
    const buf = overrides.get(l.path);
    l.node.size = buf.length;
    l.node.integrity = integrity(buf);
  }
  l.node.offset = String(l.newOffset);
}

// ---- 写文件 ----
const json = JSON.stringify(h);
if (Buffer.byteLength(json) !== json.length) {
  console.error('头部含非 ASCII 字符，写入方式需要调整');
  process.exit(5);
}
const jsonLen = json.length;
const dataStart = Math.ceil((16 + jsonLen) / 4) * 4;
const padLen = dataStart - 16 - jsonLen;

const out = fs.openSync(OUT, 'w');
const prefix = Buffer.alloc(16);
prefix.writeUInt32LE(4, 0);
prefix.writeUInt32LE(dataStart - 8, 4);
prefix.writeUInt32LE(dataStart - 12, 8);
prefix.writeUInt32LE(jsonLen, 12);
fs.writeSync(out, prefix);
fs.writeSync(out, Buffer.from(json, 'latin1'));
if (padLen) fs.writeSync(out, Buffer.alloc(padLen));

const CHUNK = 4 * 1024 * 1024;
const buf = Buffer.alloc(CHUNK);
for (const l of leaves) {
  if (overrides.has(l.path)) { fs.writeSync(out, overrides.get(l.path)); continue; }
  let remaining = l.size;
  let pos = src.dataStart + l.offset;
  while (remaining > 0) {
    const n = Math.min(CHUNK, remaining);
    fs.readSync(src.fd, buf, 0, n, pos);
    fs.writeSync(out, buf, 0, n);
    pos += n; remaining -= n;
  }
}
for (const a of added) fs.writeSync(out, a.buf);

fs.fsyncSync(out);
fs.closeSync(out);
fs.closeSync(src.fd);

// ---- 自检：逐文件 sha256 与头部 integrity 比对 ----
function verify() {
  const v = readHeader(OUT);
  const list = [];
  (function walk(node, pre) {
    for (const k of Object.keys(node.files || {})) {
      const x = node.files[k];
      if (x.files) walk(x, pre + '/' + k);
      else list.push({ path: pre + '/' + k, node: x });
    }
  })(v.header, '');
  let bad = 0;
  for (const l of list) {
    const size = l.node.size;
    const off = v.dataStart + Number(l.node.offset);
    const b = Buffer.alloc(size);
    fs.readSync(v.fd, b, 0, size, off);
    const hh = crypto.createHash('sha256').update(b).digest('hex');
    if (!l.node.integrity || l.node.integrity.hash !== hh) { bad++; console.error('  校验失败：' + l.path); }
  }
  fs.closeSync(v.fd);
  return { files: list.length, bad };
}

const res = verify();
console.log(JSON.stringify({ out: OUT, size: fs.statSync(OUT).size, files: res.files, integrityFailures: res.bad }));
if (res.bad) process.exit(6);
process.exit(0);
