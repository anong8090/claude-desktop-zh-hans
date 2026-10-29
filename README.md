# Claude 桌面端中文化（第三方反代 / Gateway 模式）

让 **Claude Desktop** 在**第三方 API 反代模式**下也显示中文界面。

> 实测环境：macOS · Claude Desktop **3.6556.2 / 4.29.0** · Apple Silicon
> 4.29.0 起前端从目录改为 `ion-dist.asar` 并启用完整性校验，脚本已自动适配（见下文「结构变化」）。

> [!IMPORTANT]
> **Claude Desktop 4.x（4.29.0 起）结构变了**：前端不再是 `ion-dist/` 目录，而是 `ion-dist.asar`，
> 且 Electron 打开了 asar 完整性校验 + 团队 ID 校验，3.x 的脚本直接跑会失败。
> `reinject.sh` 已能自动识别两种结构；若机器**没网、拉不到 `npx @electron/fuses`**，改用离线版
> `./scripts/inject-ion.sh`。原理与三个新坑见 **[docs/CLAUDE-4X.md](docs/CLAUDE-4X.md)**。

**English**: [README.en.md](README.en.md)

---

## 这个仓库解决什么问题

Claude Desktop 的界面语言有两条路径：

| 你的使用方式 | 语言从哪来 | 结果 |
|---|---|---|
| 用 claude.ai 账号登录 | 账号设置里的语言（`accountLocale`） | 可以选中文，正常 |
| 用 CC Switch 等工具接到第三方反代（Gateway / 3p） | 只剩系统语言 `navigator.language` | **界面全英文，且无法在设置里改** |

原因不是"账号语言丢了"，而是**App 里根本没有中文语言包可加载**：

```
/Applications/Claude.app/Contents/Resources/ion-dist/i18n/dynamic/
  de-DE  en-US  es-419  es-ES  fr-FR  hi-IN  id-ID  it-IT  ja-JP  ko-KR  pt-BR
  ↑ 11 种语言，没有中文
```

主语言包是**运行时从 `claude.ai/i18n/zh-Hans.json` 在线拉的**。登录态下能拉到，所以你登录时是中文；反代态没有 claude.ai 会话，拉不到，就回落 `en-US`。

这个仓库做的事：**把中文包落到本地磁盘，并把前端的语言白名单和默认 locale 改成中文**，让界面不再依赖网络和账号。

---

## 效果

| 位置 | 英文 | 中文 |
|---|---|---|
| 欢迎语 | You're here! | 您来啦！ |
| 输入框 | How can I help you today? | 今天我能为您做些什么？ |
| 推荐区 | Ideas for you | 为您推荐 |
| 侧边栏 | Projects / Scheduled / Customize | 项目 / 定时任务 / 自定义 |
| 账号区 | anong · Gateway | anong · 网关 |

覆盖率：

| 版本 | key 覆盖 | 实际中文化 |
|---|---|---|
| 3.6556.2 | 100% | 98.88% |
| 4.29.0 | 99.02%（39,095 / 39,482） | 同左 |

剩下几百条英文是官方包本身就没译的（`Artifacts`、`Cowork`、`Code` 等产品名），不是漏翻。

---

## 三层改动（缺一层就回落英文）

```
① 语言包落盘      ion-dist/i18n/zh-Hans.json + zh-CN.json（别名）
                  ion-dist/i18n/dynamic/zh-Hans.json + zh-CN.json
② 白名单注入      assets/v1/shared-*.js 里的语言数组追加 "zh-Hans","zh-CN"
③ 默认 locale     var ry="zh-Hans" / var yy="zh-Hans"（原为 "en-US"）
④ 重签名          必须带 --entitlements，否则工作区 VM 报废（见下）
```

### Claude 4.29+ 的结构变化（脚本已自动处理）

4.29.0 把原来可直接改的 `Resources/ion-dist/` **目录**打成了单个 `ion-dist.asar`（191 MB），
并在 `Info.plist` 里记录其 SHA256、启用 Electron fuse `EnableEmbeddedAsarIntegrityValidation`。
于是多出三步，少做任何一步都启动不了：

| 步骤 | 为什么 |
|---|---|
| 解包 → 补丁 → **重打包** | 前端不存在磁盘目录了，只能用 `scripts/asar-tool.js`（无依赖）解包再打回 |
| 关闭 `EnableEmbeddedAsarIntegrityValidation` | 重打包后哈希必然变化，而 ad-hoc 签名下 Electron 取不到 integrity → 启动直接 FATAL |
| 重签必须 `--deep` | 改 fuse 会让 `Electron Framework` 签名失效；framework 一旦 ad-hoc 重签，helper 若仍是官方 Team ID，library validation 会以 `different Team IDs` 拒绝加载 |

`reinject.sh` 会自动识别结构（`ion-dist.asar` 或 `ion-dist/`）并走对应分支，
`verify.sh` 也会直接从 asar 里读文件校验，不需要解包。

关 fuse 这一步由 `scripts/patch-fuse.js` **直接改二进制**完成（改两个架构各一处），
不依赖 `npx @electron/fuses`，断网也能跑；只有二进制结构识别不出来时才回退到 npx。
4.x 的签名模板自动切到 `resources/entitlements-4x.plist`（多了 `disable-library-validation`）。

**为什么必须双别名**：前端选语言是**精确名匹配，没有模糊回退**。
而主进程下发的 `--lang` 由系统区域推导：

| 系统 `AppleLanguages` | Chromium 归一化后的 `--lang` | 白名单只写 `zh-Hans` 时 |
|---|---|---|
| `zh-Hans` | `zh-Hans` | 命中 ✅ |
| `zh-Hans-US`（简中 + 美国区，很常见） | **`zh-CN`** | **不命中 → 界面全英文** ❌ |

这条坑是换机器失败的第一原因，也是网上多数教程漏掉的一步。详见 [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)。

---

## 快速开始

### 前置

```bash
# 必需：macOS + Claude Desktop + python3 + node
ls -d /Applications/Claude.app
python3 --version && node --version
```

不需要 `sudo`——如果 App 是你自己拖进 `/Applications` 的，它通常归你所有：

```bash
ls -ld /Applications/Claude.app     # 期望 owner 是你，不是 root
```

### 四步

```bash
git clone https://github.com/anong8090/claude-desktop-zh-hans.git
cd claude-desktop-zh-hans

# 1) 从本机 Chromium 缓存提取官方中文包 -> packs/zh-Hans.json
./scripts/extract-zh-pack.sh

# 2) 注入（语言包 + 白名单 + 默认 locale + 重签名）
./scripts/reinject.sh --restart

# 3) 验收
./scripts/verify.sh

# 4) 人眼确认（只有截图/肉眼能证明结果）
open -a Claude.app
```

想先看会改什么、不写任何文件：

```bash
./scripts/reinject.sh --dry-run
```

### 为什么语言包要从缓存里"偷"

`https://claude.ai/i18n/zh-Hans.json` 有 Cloudflare 保护，`curl` 直连一律 **403**，伪装 UA 也无效。

但只要你在登录态下用过一次中文界面，App 就把这份包缓存在本地了：

```
~/Library/Application Support/Claude/Cache/Cache_Data/<hash>_0
```

`extract-zh-pack.sh` 直接解这个缓存文件（Chromium simple-cache + brotli），**纯离线，不需要登录，不需要梯子**。实测 3 秒。

> 该缓存条目是"你上次用中文时的版本"。若比当前 App 版本旧，会有部分 key 缺失 —— 用 `merge-zh.py` 合并或降低预期（缺失的只是新版本新增文案，不影响使用）。

---

## 目录

```
scripts/
  reinject.sh          主入口：白名单 + 语言包 + 重打包 + 重签名（3.x/4.x 自动识别，幂等，带 --dry-run）
  verify.sh            六项验收：语言包 / 白名单 / 签名 / fuse / locale / 残留
  asar-tool.js         无依赖 asar 读写（list / extract / pack / cat），4.29+ 必需
  inject-ion.sh        4.x 离线版：重打包 + 关 fuse + 深度重签，全程不联网（带 --dry-run）
  repack-ion.js        4.x 离线版重打包器：注入语言包 / 白名单，逐文件重算 integrity
  patch-fuse.js        直改二进制关 asar 完整性校验 fuse（reinject.sh 优先用它，离线替代 npx @electron/fuses）
  extract-zh-pack.sh   从本机 Chromium 缓存提取官方中文包（离线）
  merge-zh.py          多包合并 + ICU 占位符校验（跨版本补缺用）
resources/
  entitlements-adhoc.plist   ad-hoc 签名模板（3.x）
  entitlements-4x.plist      ad-hoc 签名模板（4.x，多了 disable-library-validation）
  dynamic-zh-Hans.json       动态文案 49 条（模型档位 / 思考强度）
docs/
  CLAUDE-4X.md         4.x 适配说明：结构差异、三个新坑、覆盖率
  HOW-IT-WORKS.md      原理详解、版本适配、语言包合并
  TROUBLESHOOTING.md   界面还是英文 / 工作区报错 / 启动即 FATAL
  FREE-TOKENS.md       免费 API 来源清单 + CC Switch 配置
packs/
  zh-Hans.json         不放仓库（见 packs/README.md），本地生成
```

---

## 语言包从哪来

**仓库不包含 `zh-Hans.json`**，原因有两个（详见 [packs/README.md](packs/README.md)）：

1. 那是 Anthropic 的翻译内容，公开转载不合适；
2. 语言包必须和 App 版本匹配，硬编码进仓库反而更容易过期。

三条获取路径，按推荐顺序：

| 方式 | 命令 | 适用 |
|---|---|---|
| 本机缓存提取 | `./scripts/extract-zh-pack.sh` | 这台机器用过中文界面 |
| 从已跑通的机器拷 | `scp` / U 盘拷到 `packs/zh-Hans.json` | 新机器 / 缓存被清过 |
| 合并多份取并集 | `./scripts/merge-zh.py --en <en-US.json> --base a.json --extra b.json --out out.json` | 版本升级后补缺 |

合并脚本会做 **ICU 占位符校验**：中文把 `{n, plural, one{...} other{...}}` 简化成 `{n} 个` 是合法的，但参数名写错（`{count}` → `{mount}`）会在运行时抛错，这类 key 会被自动回退英文。

---

## 验收标准

`./scripts/verify.sh` 全过才算成功。核心是这四项：

```
1) 语言包          i18n/ 下四个文件都在（zh-Hans + zh-CN 各两份）
2) 白名单          白名单必须含运行时 --lang 的实际值（不是你以为的那个值）
3) 签名           codesign --verify 通过
4) entitlements   com.apple.security.virtualization 在位
```

第 2 项最容易误判 —— `Claude 未运行时读不到 --lang`，很多脚本此时 `grep -q ""` **恒为真**，界面全英文也报 OK。本仓库的 `verify.sh` 在未运行时输出 `SKIP` 而不是 `PASS`。

---

## 常见问题（详见 docs/TROUBLESHOOTING.md）

| 现象 | 原因 | 修法 |
|---|---|---|
| 装完还是英文 | 白名单缺运行时 `--lang` 值（多半缺 `zh-CN` 别名） | `./scripts/verify.sh` 看第 2 项 |
| 文件都对，还是英文 | 进程没重载 | 完全退出 Claude 再开（`--restart`） |
| 工作区报 `installation appears to be invalid` | 重签名丢了 virtualization entitlement | 用仓库的 `resources/entitlements-adhoc.plist` 重签 |
| 启动即 `FATAL: Failed to get integrity for validatable asar archive` | 4.29+ 重打包后没关完整性校验 fuse | `reinject.sh --force` 会自动关；手动见 docs/TROUBLESHOOTING.md |
| `dyld: ... different Team IDs` | 4.29+ 只签了 framework 没 `--deep` | 4.29+ 必须 `--deep` 统一重签 |
| 部分界面英文 | 语言包比 App 旧 / 官方未译 | `extract-zh-pack.sh` 重取，或 `merge-zh.py` 合并 |
| 重跑脚本 `whitelist array not found` | 已打过补丁，数组不是原始形态 | 用本仓库的 `reinject.sh`（同时认三种状态） |
| App 更新后中文没了 | `ion-dist` 被官方包覆盖（4.29+ 是整个 asar 被替换） | 重跑 `./scripts/reinject.sh --restart` |

---

## 卸载 / 还原

```bash
# 目录模式（<= 3.x）：删掉语言包即可，前端回落 en-US
rm -f /Applications/Claude.app/Contents/Resources/ion-dist/i18n/{zh-Hans,zh-CN}.json
rm -f /Applications/Claude.app/Contents/Resources/ion-dist/i18n/dynamic/{zh-Hans,zh-CN}.json

# asar 模式（4.29+）：还原注入脚本留下的原始包备份
ls scripts/backups/ion-dist-*-original.asar
ditto scripts/backups/ion-dist-4.29.0-original.asar \
      /Applications/Claude.app/Contents/Resources/ion-dist.asar

# 两种模式都要重签（带 entitlements，别用裸 --sign -）
codesign --force --deep --sign - \
  --entitlements resources/entitlements-adhoc.plist /Applications/Claude.app
```

最彻底的还原是重装 Claude Desktop（官网 dmg 覆盖安装，官方签名一并恢复）。

---

## 关于 CC Switch

如果你用 [CC Switch](https://ccswitch.io) 管理供应商，注意：

- 它切换供应商时会**重写** `~/Library/Application Support/Claude/config.json`
- `config.json` 里的 `locale` **不是**决定界面语言的因素（决定因素是 `--lang` 与白名单）
- 所以切供应商**不会**破坏本方案的中文化，但切完要**重启 Claude Desktop**（CC Switch 的文档也这么写）

免费 API 来源清单与 CC Switch 具体配置见 **[docs/FREE-TOKENS.md](docs/FREE-TOKENS.md)**。

---

## 免责声明

- 本项目**与 Anthropic 无任何关联**，未获其授权或认可。
- 修改 App 包会破坏官方代码签名（本仓库用 ad-hoc 重签名替代）。副作用：系统不再信任该 App 的官方身份，某些依赖公证的检查可能失败；请自行评估。
- 请仅用于**个人使用已合法获得的 Claude Desktop**。是否违反服务条款、是否用于分发或商业用途，由使用者自行判断与承担。
- 语言包版权归 Anthropic 所有，本仓库不包含、也不分发语言包内容。
- macOS 每次系统大版本更新、Claude 每次发版都可能改变前端结构，脚本按结构定位而非硬编码路径，但不保证永久有效。失效时提 issue，附版本号与 `verify.sh` 输出。

## License

脚本与文档：[MIT](LICENSE)
语言包内容：不适用（未包含）
