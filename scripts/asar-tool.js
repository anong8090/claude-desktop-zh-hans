#!/usr/bin/env node
/*
 * asar-tool.js — 无依赖 asar 读写工具（供 reinject.sh 使用）
 *
 * 用法:
 *   node asar-tool.js list    <archive> [prefix]
 *   node asar-tool.js extract <archive> <outdir>
 *   node asar-tool.js pack    <srcdir>  <outfile>
 *   node asar-tool.js cat     <archive> <path>      # 单文件输出到 stdout（验收脚本用）
 *
 * 说明:
 *   - pack 时 offset 写成字符串（Electron 28+ / @electron/asar v4 格式），
 *     Electron 运行时可正常读取（已在 Claude 4.29.0 验证）。
 *   - 不写 integrity 字段，配合关闭 EnableEmbeddedAsarIntegrityValidation fuse。
 *   - 只用 writeFileSync，不用流式写入（部分环境下会被沙盒策略拦截）。
 */
const fs = require('fs');
const path = require('path');

function readHeader(archive) {
  const fd = fs.openSync(archive, 'r');
  const b = Buffer.alloc(16);
  fs.readSync(fd, b, 0, 16, 0);
  const jsonLen = b.readUInt32LE(12);    // header pickle 内的字符串长度
  const headerPickleSize = b.readUInt32LE(4); // 整个 header pickle 长度（含 4 字节自身长度字段）
  const hb = Buffer.alloc(jsonLen);
  fs.readSync(fd, hb, 0, jsonLen, 16);
  fs.closeSync(fd);
  // 数据区起点 = sizeBuf(8) + headerPickleSize，注意 header pickle 内部有 4 字节对齐 padding
  return { header: JSON.parse(hb.toString('utf8')), dataStart: 8 + headerPickleSize };
}

function walk(node, prefix, cb) {
  for (const [name, val] of Object.entries(node.files || {})) {
    const p = prefix ? prefix + '/' + name : name;
    if (val.files) walk(val, p, cb);
    else cb(p, val);
  }
}

function list(archive, prefix) {
  const { header } = readHeader(archive);
  const files = [];
  walk(header, '', (p, v) => files.push({ p, size: v.size, unpacked: v.unpacked }));
  const match = prefix ? files.filter(f => f.p.startsWith(prefix)) : files;
  for (const f of match) console.log(f.size, f.p + (f.unpacked ? ' [unpacked]' : ''));
  console.log('TOTAL', match.length);
}

function extract(archive, outdir) {
  const { header, dataStart } = readHeader(archive);
  const fd = fs.openSync(archive, 'r');
  let n = 0;
  walk(header, '', (p, v) => {
    if (v.unpacked) return;
    const target = path.join(outdir, p);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    const buf = Buffer.alloc(v.size || 0);
    if (v.size > 0) fs.readSync(fd, buf, 0, v.size, dataStart + Number(v.offset));
    fs.writeFileSync(target, buf);
    n++;
  });
  fs.closeSync(fd);
  console.log('extracted', n, 'files ->', outdir);
}

function collect(dir, base) {
  const files = {};
  const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
  for (const e of entries) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) files[e.name] = { files: collect(abs) };
    else if (e.isFile()) files[e.name] = { size: fs.statSync(abs).size, _abs: abs };
  }
  return files;
}

function pack(src, out) {
  const tree = collect(src, '');
  const order = [];
  (function assign(node) {
    for (const key of Object.keys(node)) {
      const n = node[key];
      if (n.files) assign(n.files);
      else {
        const off = order.length ? order[order.length - 1].offset + order[order.length - 1].size : 0;
        n.offset = String(off);
        order.push({ abs: n._abs, offset: off, size: n.size });
        delete n._abs;
      }
    }
  })(tree);

  const jsonBuf = Buffer.from(JSON.stringify({ files: tree }), 'utf8');
  const pad = (4 - ((4 + jsonBuf.length) % 4)) % 4;
  const payloadSize = 4 + jsonBuf.length + pad;
  const headerBuf = Buffer.alloc(8 + jsonBuf.length + pad);
  headerBuf.writeUInt32LE(payloadSize, 0);
  headerBuf.writeUInt32LE(jsonBuf.length, 4);
  jsonBuf.copy(headerBuf, 8);

  const sizeBuf = Buffer.alloc(8);
  sizeBuf.writeUInt32LE(4, 0);
  sizeBuf.writeUInt32LE(headerBuf.length, 4);

  const parts = [sizeBuf, headerBuf];
  for (const f of order) parts.push(fs.readFileSync(f.abs));
  const buf = Buffer.concat(parts);
  fs.writeFileSync(out, buf);
  console.log('packed', order.length, 'files,', buf.length, 'bytes ->', out);
}

function cat(archive, target) {
  const { header, dataStart } = readHeader(archive);
  let hit = null;
  walk(header, '', (p, v) => { if (p === target) hit = v; });
  if (!hit) { console.error('not found in asar: ' + target); process.exit(2); }
  if (hit.unpacked) { console.error('is unpacked, read from app.asar.unpacked: ' + target); process.exit(3); }
  const fd = fs.openSync(archive, 'r');
  const buf = Buffer.alloc(hit.size || 0);
  if (hit.size > 0) fs.readSync(fd, buf, 0, hit.size, dataStart + Number(hit.offset));
  fs.closeSync(fd);
  process.stdout.write(buf);
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === 'list') list(a, b || '');
else if (cmd === 'extract') extract(a, b);
else if (cmd === 'pack') pack(a, b);
else if (cmd === 'cat') cat(a, b);
else {
  console.error('usage: asar-tool.js list|extract|pack|cat <args>');
  process.exit(1);
}
