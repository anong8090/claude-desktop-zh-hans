// 关闭 Electron 的 asar 完整性校验 fuse（EnableEmbeddedAsarIntegrityValidation）。
//
// 为什么需要：Claude 4.x 的 Electron 打开了该 fuse，会在启动时校验 app.asar / ion-dist.asar
// 的头部哈希，且只认官方签名。一旦我们改动 asar 并 ad-hoc 重签，校验会直接 FATAL
// （Failed to get integrity for validatable asar archive）。
// 把 fuse 关掉即可跳过校验，代价是失去这一层完整性保护（本地自用场景可接受）。
//
// 用法：node patch-fuse.js [--dry-run] [二进制路径]
const fs = require('fs');

const MAGIC = 'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX';
const FUSES = [
  'RunAsNode',
  'EnableCookieEncryption',
  'EnableNodeOptionsEnvironmentVariable',
  'EnableNodeCliInspectArguments',
  'EnableEmbeddedAsarIntegrityValidation',
  'OnlyLoadAppFromAsar',
  'LoadBrowserProcessSpecificV8Snapshot',
  'GrantFileProtocolExtraPrivileges',
  'WasmTrapHandlers',
];
const TARGET_FUSE = 4; // EnableEmbeddedAsarIntegrityValidation

const dryRun = process.argv.includes('--dry-run');
const target = process.argv.find((a) => a.startsWith('/') && a.endsWith('Electron Framework'));
const bin = target || '/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework';

const buf = fs.readFileSync(bin);
const magic = Buffer.from(MAGIC);
let hits = 0;
let changed = 0;
let i = -1;
while ((i = buf.indexOf(magic, i + 1)) !== -1) {
  hits++;
  const base = i + 34; // magic(32) + version(1) + count(1)
  const before = String.fromCharCode(buf[base + TARGET_FUSE]);
  if (dryRun) {
    console.log(`  slice@${i}: ${FUSES[TARGET_FUSE]} = ${before}`);
    continue;
  }
  if (before === '1') {
    buf[base + TARGET_FUSE] = 0x30; // '1' -> '0'
    changed++;
  }
  console.log(`  slice@${i}: ${FUSES[TARGET_FUSE]} ${before} -> ${String.fromCharCode(buf[base + TARGET_FUSE])}`);
}
if (!hits) {
  console.error('未找到 fuse wire，二进制结构可能变化：' + bin);
  process.exit(1);
}
if (!dryRun && changed) {
  fs.writeFileSync(bin, buf);
  console.log(`已关闭 asar 完整性校验（${changed} 个架构）`);
} else if (!dryRun) {
  console.log('fuse 已是关闭状态，无需修改');
}
