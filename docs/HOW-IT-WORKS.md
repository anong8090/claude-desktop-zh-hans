# 原理详解

这份文档解释"为什么要改这四处"，以及 Claude 换版本后怎么重新定位。

---

## 1. 界面文案到底在哪

Claude Desktop 是 Electron 应用，但有两层完全不同的 UI：

| 层 | 位置 | 内容 |
|---|---|---|
| 桌面壳层 | `Contents/Resources/*.json`（如 `zh-Hans.json`，664 条）、`app.asar` | 菜单栏、Dock 菜单、原生对话框 |
| **前端界面** | `Contents/Resources/ion-dist/` | **你看到的一切**：侧边栏、欢迎语、按钮、报错 |

**关键事实**：侧边栏的 `Cowork / Projects / Scheduled`、欢迎语 `You're here!`、报错 `Gateway returned an error`，在 `app.asar` 里**一条都搜不到**。

验证方法：

```bash
# 在 asar 里搜，命中数应为 0
python3 - <<'PY'
d = open('/Applications/Claude.app/Contents/Resources/app.asar','rb').read()
for s in [b"You're here!", b"How can I help you today?", b"Gateway returned an error"]:
    print(s, '->', d.count(s))
PY
```

所以改 `Resources/zh-Hans.json` 或 `config.json` 的 `locale` 都**不会**改变可见界面 —— 这是最容易走错的方向（我第一次就错在这）。

---

## 2. 前端怎么选语言

在 `ion-dist/assets/v1/shared-*.js` 里能找到这段逻辑（变量名压缩过，每版不同）：

```js
// 候选语言：账号 locale 优先，否则用浏览器 locale
locale: Ji( Gi(t?.locale) ?? new Intl.Locale(pe([navigator.language])).language )

// 精确名匹配，没有模糊回退
function Ey(e){ return Cy().find(x => x.toLowerCase() === e.toLowerCase()) ?? "en-US" }
```

两个结论：

1. **Gateway / 反代模式下 `t`（账号配置）为空**，语言完全由 `navigator.language` 决定 —— 也就是系统语言。这就是"登录有中文、反代没中文"的机制，不是账号语言丢了。
2. **匹配是全等比较，找不到就回落 `en-US`**。没有 `zh` → `zh-Hans` 的前缀回退。所以白名单里写错一个字符，界面就整体英文。

### 白名单长什么样

```js
["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"]
```

`zh-Hans` / `zh-CN` 都不在里面 —— **不是文件缺失，是名字没被登记**。

### 语言包文件名不符合 `xx-XX` 模式的坑

桌面壳层还有一个解析函数用 `/[a-z]{2}-[A-Z]{2}/` 过滤文件名：

```js
let t = /[a-z]{2}-[A-Z]{2}/
e.filter(f => t.test(f))     // zh-Hans.json 被过滤掉
```

`zh-Hans` 不匹配这个正则，所以即使 `Resources/zh-Hans.json` 存在也不会被选中。这是官方代码里的一个 bug，不影响前端（前端走 `ion-dist`），但会让人误以为"文件有了应该就行"。

---

## 3. 为什么白名单要写 `zh-Hans` + `zh-CN` 两个

主进程会给渲染进程下发 `--lang`。这个值**由系统区域推导**，不是你能直接指定的：

| 系统设置 | Chromium 归一化结果 |
|---|---|
| `AppleLocale = zh_CN`，`AppleLanguages = (zh-Hans)` | `--lang=zh-Hans` |
| `AppleLocale = zh-Hans_US`，`AppleLanguages = (zh-Hans-US, en-US)` | **`--lang=zh-CN`** |

实测：`open -a Claude.app --args --lang=zh-Hans` **压不过主进程**，渲染进程仍是 `zh-CN`。

于是同一套补丁在不同机器上表现不同：

- 系统语言是 `zh-Hans`（无地区后缀）的机器 → 只写 `zh-Hans` 就够
- 系统语言是 `zh-Hans-US`（简体中文 + 美国区，很常见）的机器 → `--lang=zh-CN`，**只写 `zh-Hans` 会整体变英文**

稳妥做法：白名单末尾写两个，`i18n/` 下也放两份内容相同的包。

```js
["en-US",...,"id-ID","zh-Hans","zh-CN"]
```

```bash
i18n/zh-Hans.json          # 同一份内容
i18n/zh-CN.json            # 别名副本
i18n/dynamic/zh-Hans.json
i18n/dynamic/zh-CN.json
```

`reinject.sh` 会自动做这件事。

---

## 4. 重签名：为什么必须带 entitlements

改动 `ion-dist` 内任何文件都会让原有的 `CodeResources` 校验失败，App 直接启动不了。必须重签名。

**不能**用 `codesign --deep --force --sign -`：

- `--deep` 会连带重签所有嵌套 helper，把官方签名一起换掉
- ad-hoc 签名（`--sign -`）**默认丢弃全部 entitlements**
- 丢掉的里面包含 `com.apple.security.virtualization`，这是**工作区 VM 必需项**
- 后果：Cowork / 工作区报 `installation appears to be invalid`，或直接无法启动

正确做法：

```bash
codesign --force --sign - \
  --entitlements resources/entitlements-adhoc.plist \
  /Applications/Claude.app
```

只签主 bundle。`entitlements-adhoc.plist` 这份模板已经剥掉了三项依赖真实 Team ID 的内容（`application-identifier`、`team-identifier`、`keychain-access-groups`），ad-hoc 签名带不了那些。

签名后自检：

```bash
codesign --verify /Applications/Claude.app && echo OK
codesign -d --entitlements :- /Applications/Claude.app 2>/dev/null \
  | grep -c com.apple.security.virtualization    # 应为 1
```

---

## 5. Chromium 缓存的结构（语言包提取原理）

缓存位置：

```
~/Library/Application Support/Claude/Cache/Cache_Data/
~/Library/Application Support/Claude-3p/Cache/Cache_Data/     # 3p / 反代模式
```

单个条目是 Chromium **simple cache** 格式：

```
[24 字节文件头][key 文本][brotli 压缩的 body][stream 头 + EOF]
     ↑                ↑
  前 8 字节 magic     偏移 24 起
  fc fb 6d 1b a7 72 5c 30
  偏移 12 = key_length（u32 LE）
  body 起点 = 24 + key_length
```

- `key` 形如 `1/0/https://claude.ai/i18n/zh-Hans.json?v=d1dccd04b563` —— 直接匹配，不用猜
- `body` 长度取文件尾部响应头里的 `content-length`
- `content-encoding: br` → 用 brotli 解压（**Python 标准库没有 brotli**，所以脚本用 `node -e zlib.brotliDecompressSync`）

**性能坑**：这两个目录加起来可能有 **1 万+ 条目 / 数百 MB**。逐个 `open()` 读头部要 **40 秒**（CPU 只用 1.5 秒，瓶颈是 open 次数）。

优化：先按文件体积预筛（语言包压缩后 ~790 KB，远大于均值），再读 24 字节头部验 magic → **3 秒**。

---

## 6. 版本升级后怎么重新适配

Claude 每次发版都会：

1. 覆盖 `ion-dist/`（语言包和 JS 补丁全没了）
2. 重新生成打包后的变量名（`ry`、`yy`、`Ey` 这些都会变）

`reinject.sh` 不硬编码变量名，靠两处结构特征定位：

| 目标 | 定位方式 |
|---|---|
| 白名单数组 | 搜 `"id-ID"]` / `"id-ID","zh-Hans"]` / `"id-ID","zh-Hans","zh-CN"]` |
| 默认 locale | 正则 `(="en-US")(\s*,\s*\w+\s*=\s*\["en-US")` |

如果哪天两者都失效，报 `whitelist array not found`，说明前端结构变了。手工定位：

```bash
# 1) 找白名单
grep -rl '"id-ID"' /Applications/Claude.app/Contents/Resources/ion-dist/assets

# 2) 看数组现在长什么样（注意 BSD grep 的重复上限是 255，别写 {0,300}）
grep -o -a -E '\["en-US"[^]]{0,240}\]' /Applications/Claude.app/Contents/Resources/ion-dist/assets/v1/shared-*.js | sort -u

# 3) 找默认 locale 赋值
grep -rhoa -E '="en-US"' /Applications/Claude.app/Contents/Resources/ion-dist/assets/v1/*.js | sort | uniq -c

# 4) 看运行时实际要什么语言
pgrep -fl 'Claude Helper' | grep -o -- '--lang=[a-zA-Z_-]*' | sort -u
```

第 4 步是最关键的一步，也是验收脚本里唯一不能靠推断、必须实测的项。

---

## 7. 语言包合并与占位符校验

App 升级后，`en-US.json` 会出现新 key，你手上的 `zh-Hans.json` 是旧版。合并时**不能只看有没有译文**，必须校验 ICU 占位符。

`merge-zh.py` 的规则：

```
逐 key：
  1. 按 --base、--extra 顺序取第一个「非空且不等于英文原文」的译文
  2. 校验 ICU 顶层参数名集合与英文一致，不一致则回退英文
  3. 仍无译文的，按英文原样写入（保证 key 覆盖 100%，前端不会因缺 key 报错）
```

### 占位符校验必须按花括号深度扫描

不能用正则直接抓 `{xxx}`。看这个例子：

```
en: Saved draft · {count} {chars, plural, one {character} other {characters}}
zh: 已保存草稿 · {count} 个{chars, plural, other {字符}}
```

正则会把 `{character}`、`{characters}`、`{字符}` 都当成参数名 → 中英两边集合必然不等 → 把**完全合法**的译文误判成异常。

正确做法：只在**深度 0** 的 `{` 后面取标识符：

```python
def top_level_args(msg):
    names, depth, i, n = [], 0, 0, len(msg)
    while i < n:
        ch = msg[i]
        if ch == "{":
            if depth == 0:
                # 读 { 后面紧跟的标识符
                ...
                depth = 1
                i += 1
                continue
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        i += 1
    return sorted(set(names))
```

同理，中文把 `{n, plural, one{1 item} other{# items}}` 简化成 `{n} 项` 是**合法**的 —— 参数名没变，只是不再区分单复数。只比参数名集合，不比对花括号原文。

---

## 8. 官方有译但显示英文的几种情况

| 文字 | 原因 |
|---|---|
| `Artifacts` / `Cowork` | 官方中文包里值就是英文，产品名有意保留 |
| `Code` 标签、部分按钮 | 前端硬编码字符串，不走 i18n 词典 |
| 模型名 `Nvidia/nemotron-...`、`High` | 数据而非文案，或官方缺该 key |
| 新版本新增文案 | 语言包比 App 旧，`merge-zh.py` 或重取可补 |

判断某串属于哪一类：

```bash
R=/Applications/Claude.app/Contents/Resources/ion-dist/i18n
python3 - <<'PY'
import json
R='/Applications/Claude.app/Contents/Resources/ion-dist/i18n'
en=json.load(open(f'{R}/en-US.json')); zh=json.load(open(f'{R}/zh-Hans.json'))
for w in ['Artifacts','Cowork','Code','High']:
    ks=[k for k,v in en.items() if v==w]
    print(f'{w}: key={len(ks)} ->', [zh.get(k,'<缺>') for k in ks[:3]])
PY
```

值等于英文 → 官方没译；查不到 key → 前端硬编码。
