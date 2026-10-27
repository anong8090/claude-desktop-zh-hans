# 语言包不随仓库分发

`zh-Hans.json`（约 2.6 MB / 3.7 万条）**不在本仓库里**，`.gitignore` 已排除。

## 为什么

1. **版权**：这些译文是 Anthropic 的产品内容，不是本项目的作品。公开转载不合适。
2. **版本匹配**：语言包必须和 App 版本对齐。硬编码进仓库会让每个人都拿到同一份可能过期的包，
   而"从自己机器上取"永远是当前版本最准的。
3. **体积**：2.6 MB 的 JSON 放在 git 历史里，每次更新都翻倍。

## 怎么拿到

### 方式 A：从本机缓存提取（推荐）

```bash
./scripts/extract-zh-pack.sh
# -> packs/zh-Hans.json
```

前提：这台机器曾在中文界面下运行过 Claude。纯离线，3 秒。

### 方式 B：从已跑通的机器拷

```bash
scp 旧机器:~/Documents/claude-zh-hans/zh-Hans.json packs/zh-Hans.json
```

```bash
# 校验
python3 -c "import json;d=json.load(open('packs/zh-Hans.json'));print(len(d),'条')"
# 期望 ≥ 37000
```

### 方式 C：合并多份取并集

版本升级后，手上的包缺新 key 时：

```bash
./scripts/merge-zh.py \
  --en /Applications/Claude.app/Contents/Resources/ion-dist/i18n/en-US.json \
  --base packs/zh-Hans.json \
  --extra ~/Downloads/other-zh.json \
  --out packs/zh-Hans.merged.json
```

输出会打印 key 覆盖率和"值仍为英文"的条数，并对 ICU 占位符不匹配的条目自动回退英文。

## 目录里应该有什么

```
packs/
  README.md            # 本文件（进仓库）
  zh-Hans.json         # 语言包（不进仓库，本地生成）
  zh-Hans.merged.json  # 合并产物（不进仓库）
```

## 动态包

`resources/dynamic-zh-Hans.json`（49 条，模型档位 / 思考强度等动态文案）**有进仓库** ——
它体积极小、内容是通用 UI 标签，且缺失会导致模型选择器整片英文。
如果你也想自己生成，从 `ion-dist/i18n/dynamic/` 对应文件取即可。
