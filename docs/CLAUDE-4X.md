# Claude Desktop 4.x 中文化说明（4.29.0 实测）

3.6556.x 的前端是 `Resources/ion-dist/` 目录；**4.x 换成了两个 asar 包**，注入方式和坑都不一样。本文记录 4.29.0 上与 3.x 的差异和可用做法。

---

## 一、结构变了：前端在 ion-dist.asar 里

```
Claude.app/Contents/Resources/
  app.asar          64 MB   桌面壳（主进程 / 各小窗口 / 托盘）
  ion-dist.asar    191 MB   Web 前端（claude.ai 的 SPA，含 4532 个文件）
  i18n/*.json       45 个    桌面壳文案（947 key，官方已含 zh-Hans / zh-Hant）
```

两套文案是**分开的**，缺一不可：

| 层 | 文件 | 4.29.0 官方是否自带中文 |
|---|---|---|
| 桌面壳（设置页、对话框、托盘） | `app.asar` → `resources/i18n/zh-Hans.json` | ✅ 自带（719 key，与 en-US 947 相比缺 228 个新产品文案） |
| Web 前端（侧边栏、输入框、会话区） | `ion-dist.asar` → `/i18n/*.json` | ❌ **只有 11 种语言，没有中文** |

`ion-dist.asar` 里只有 `de-DE en-US es-419 es-ES fr-FR hi-IN id-ID it-IT ja-JP ko-KR pt-BR` —— 和 3.x 完全一样的 11 种。所以 4.x 在反代（3p）模式下界面照样是英文。

---

## 二、语言怎么被选中的（4.x 新逻辑）

Web 前端 `assets/v1/shared-*.js` 里有两条白名单，都是 11 个语言写死的数组：

```js
fy = ["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"]  // 校验门
Dy = [ ...同上... ]                                                                              // navigator 兜底
```

选语言的顺序：`localStorage 用户选择` → `账号 locale`（反代态没有）→ `navigator.languages`。
而 Electron 的 `navigator.language` 由 `--lang` 决定，macOS 上系统的 `zh-Hans-US` 会被 Chromium 归一化成 **`zh-CN`**：

```
实测进程参数：--lang=zh-CN
```

`zh-CN` 既不在 `fy` 也不在 `Dy` 里 → 兜底 `en-US` → 界面英文。这和 3.x 的 `zh-Hans-US → zh-CN` 坑是同一个坑，只是判断代码换了地方。

**所以注入要做两件事**：把 `zh-Hans` 加进 `fy` / `Dy`（`Dy` 里同时会被推导出 `zh` 前缀，`zh-CN` 靠前缀命中），并把中文包放进 `/i18n/zh-Hans.json`。

桌面壳那边不看白名单，只看 `config.json` 里的 `locale`：

```
~/Library/Application Support/Claude-3p/config.json   ← 反代（3p）模式用的是这个目录
~/Library/Application Support/Claude/config.json      ← 正常登录模式
```

`locale: "zh-Hans"` + `resources/i18n/zh-Hans.json` 存在，壳就中文。两者都有时以 3p 目录为准。

---

## 三、三个必踩的坑（4.x 独有）

### 1. asar 完整性校验：改了 asar 直接 FATAL

Electron fuse `EnableEmbeddedAsarIntegrityValidation` 在 4.x 是**打开**的，启动时校验 asar 头部 SHA256，并且只认官方签名。改完 asar 再 ad-hoc 重签，启动就报：

```
FATAL:electron/shell/common/asar/archive.cc:256
Failed to get integrity for validatable asar archive: Resources/app.asar
```

改 `Info.plist` 里的 `ElectronAsarIntegrity` 哈希也没用（删掉这个 key 同样报错）。**唯一有效做法是把 fuse 关掉**：

```
Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework
  magic: dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX  (32 字节)
  之后：version(1) + fuseCount(1) + fuse 值（'0'/'1'）
  索引 4 = EnableEmbeddedAsarIntegrityValidation  →  改成 '0'
```

通用二进制要改 **两个架构各一处**。`scripts/patch-fuse.js` 处理这件事。

### 2. 重签名必须 `--deep`，否则 helper 起不来

只签外层 `.app` 时，helper 仍是 Anthropic 的原签名，而 `Electron Framework` 变成了 ad-hoc（无 Team ID），dyld 直接拒绝：

```
Library not loaded: @rpath/Electron Framework.framework/Electron Framework
Reason: mapping process and mapped file (non-platform) have different Team IDs
```

因此要用 `codesign --force --deep --sign -`，并额外带上 `com.apple.security.cs.disable-library-validation`（见 `resources/entitlements-4x.plist`）。`com.apple.security.virtualization` 务必保留，否则 Cowork 的虚拟机不可用。

### 3. asar 内部每个文件都带 integrity

`ion-dist.asar` 头部 JSON 里每个文件都有 `integrity: {algorithm, hash, blockSize: 4194304, blocks:[...]}`。**改了内容不重算就会加载失败**；新增文件同理。重打包脚本必须逐文件重算，并且注意：

- 原数据段是紧密排列的，**只替换文件内容就必须用「新 size」重排后续 offset**，否则从被改文件往后全部错位（本仓库的 `repack-ion.js` 第一版就踩了这个，表现为部分文件内容整体偏移 N 字节）。
- 写完要自检：把每个文件读出来重新算 SHA256 和头部比对，`integrityFailures` 必须为 0。

---

## 四、用法

```bash
# 语言包：从已登录中文界面的机器上取 claude.ai/i18n/zh-Hans.json，放到 packs/zh-Hans.json

# 主入口（3.x / 4.x 自动识别）
./scripts/reinject.sh --dry-run       # 先看会做什么，不写文件
./scripts/reinject.sh --restart       # 备份 + 注入 + 重签 + 重启
./scripts/verify.sh                   # 六项验收

# 离线版（4.x 专用，全程不联网，不依赖 npx）
./scripts/inject-ion.sh --dry-run
./scripts/inject-ion.sh
```

`reinject.sh`：退出 App → 解包 asar → 打白名单补丁 + 注入语言包 → 重打包 → 关 fuse → 深度 ad-hoc 重签 → 写 `locale: zh-Hans` → 重启 → 打印覆盖率。
它的 fuse 这一步**优先用本地 `patch-fuse.js` 直改二进制**（离线）；只有在二进制结构识别不出来时才回退到 `npx @electron/fuses`（需要联网）。

`inject-ion.sh`：同样是重打包 + 关 fuse + 深签，但用流式读写、**逐文件重算 integrity**（不依赖 Electron 的容错），参数化了 `--app` / `--pack`，适合拿来做 A/B 验证。`--dry-run` 会真的跑一遍重打包到 `/tmp` 并做完整性自检，能提前发现版本不兼容。

---

## 五、4.29.0 实测覆盖率

用当前版本官方 `zh-Hans.json`（39814 key）对 `ion-dist.asar` 的 `en-US.json`（39482 key）：

| 指标 | 数值 |
|---|---|
| key 覆盖 | 39017 / 39482 = **98.82%** |
| 未覆盖 key（回落英文） | 465（新版新增文案） |
| ICU 占位符风险 key | 0（多出的都是 `select/plural` 分支关键字，非参数名） |

桌面壳层：719 / 947 key，剩 228 条是 4.x 新增功能文案（Cowork、插件市场等），回落英文。

**已知仍为英文的词**：`Cowork`、`Code`、`Claude Code`、`Skills`、`Artifacts` 等产品名 —— 官方中文包本身就没译，不是漏翻。

---

## 六、副作用与版本升级

- **ad-hoc 签名**：`spctl` 会显示 rejected，这是必然结果，不影响本机打开
- **asar 完整性校验被关闭**：失去这一层保护（本地自用可接受）
- **`keychain-access-groups` 不在签名模板里**：passkey / WebAuthn 可能受影响（走网关 token 不受影响）
- **每次发版都会覆盖 asar，中文随之丢失**：需要重跑一次 `./scripts/reinject.sh --restart`
