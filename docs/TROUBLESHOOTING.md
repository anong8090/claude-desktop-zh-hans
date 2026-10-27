# 故障排查

按出现频率排序。每条都给了"怎么确认"，不要凭猜。

---

## 1. 装完还是英文

**第一步永远是这条**：

```bash
./scripts/verify.sh
```

看第 2 项。如果输出 `[ FAIL ] 白名单缺 xxx`，就是 locale 代码不匹配。

### 1.1 白名单缺运行时 `--lang` 值（最常见）

```bash
pgrep -fl 'Claude Helper' | grep -o -- '--lang=[a-zA-Z_-]*' | sort -u
# 例：--lang=zh-CN
```

如果这个值是 `zh-CN`，而白名单只有 `zh-Hans` → 界面全英文。
直接重跑 `./scripts/reinject.sh --restart`，它会补 `zh-CN` 别名和对应的包副本。

### 1.2 验证脚本本身在骗你

很多教程用的判断是：

```bash
L=$(pgrep -fl 'Claude Helper (Renderer)' | grep -o -- '--lang=[^ ]*' | cut -d= -f2)
grep -q "\"$L\"" "$F" && echo OK
```

两个问题，任一都会让**全英文也报通过**：

1. `pgrep -f 'Claude Helper (Renderer)'` —— 括号被当正则分组，**匹配 0 条**
2. `$L` 为空时 `grep -q ""` **恒为真**

本仓库的 `verify.sh` 在未运行时输出 `SKIP`，不会给你假阳性。

### 1.3 文件都对，但还是英文

**进程没重载。** 语言包是启动时读的。

```bash
killall Claude; sleep 3; open -a /Applications/Claude.app
```

文件已落盘的话，重开就生效，不用重跑补丁。

---

## 2. 工作区 / Cowork 报 `installation appears to be invalid`

**entitlements 丢了。** 重签名时漏了 `--entitlements`，或用了 `--deep`。

```bash
codesign -d --entitlements :- /Applications/Claude.app 2>/dev/null | grep -c virtualization
# 0 = 丢了，必须修
```

修：

```bash
codesign --force --sign - \
  --entitlements resources/entitlements-adhoc.plist \
  /Applications/Claude.app
codesign --verify /Applications/Claude.app && echo OK
```

注意：**不要把 `--deep` 加回来**。它会连带重签嵌套 helper，把官方签名也换掉，问题更大。

---

## 3. App 打不开 / 闪退

按顺序排查：

```bash
# 1) 签名是否完整
codesign --verify --verbose=2 /Applications/Claude.app 2>&1 | head -5

# 2) 是否有 quarantine 属性
xattr -l /Applications/Claude.app | head -5
xattr -dr com.apple.quarantine /Applications/Claude.app

# 3) 语言包 JSON 是否合法（写坏了会白屏）
for f in /Applications/Claude.app/Contents/Resources/ion-dist/i18n/*.json \
         /Applications/Claude.app/Contents/Resources/ion-dist/i18n/dynamic/*.json; do
  python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" || echo "BAD: $f"
done

# 4) 前端 JS 是否被改坏（对比备份）
ls scripts/backups/whitelist-*.js.bak
```

第 4 步有备份就直接覆盖回去，然后重签名：

```bash
cp scripts/backups/whitelist-<时间戳>-<文件名>.js \
   /Applications/Claude.app/Contents/Resources/ion-dist/assets/v1/<文件名>
codesign --force --sign - --entitlements resources/entitlements-adhoc.plist /Applications/Claude.app
```

还是不行就**重装**：官网 dmg 覆盖安装，官方签名一并恢复，中文补丁也随之消失（这就是最彻底的还原）。

---

## 4. 重跑脚本报 `whitelist array not found`

两种可能：

**A. 已经打过补丁了。** 数组现在是 `"id-ID","zh-Hans","zh-CN"]`，不再匹配原始模式。
本仓库的 `reinject.sh` 同时认三种状态（原始 / 单别名 / 双别名），不会报这个错。如果你用的是别处的脚本，换成本仓库的。

**B. Claude 改了前端结构。** 确认：

```bash
grep -rl '"id-ID"' /Applications/Claude.app/Contents/Resources/ion-dist/assets
```

有输出 → 结构还在，只是模式变了，按 [HOW-IT-WORKS.md 第 6 节](HOW-IT-WORKS.md#6-版本升级后怎么重新适配)手工定位。
没输出 → 语言列表换了实现方式，需要重新分析 `shared-*.js`。提 issue 附版本号。

---

## 5. 只有部分界面是中文

正常。分三种情况，别混：

| 现象 | 判断 | 处理 |
|---|---|---|
| 产品名英文（`Artifacts`、`Cowork`） | 官方中文包里值就是英文 | 忽略 |
| 单个标签英文（`Code`、`New`） | 前端硬编码，不走词典 | 忽略（改 JS 收益不值） |
| 大段新功能文案英文 | 语言包比 App 旧 | 重取或合并 |

判断方法：

```bash
python3 - <<'PY'
import json
R='/Applications/Claude.app/Contents/Resources/ion-dist/i18n'
en=json.load(open(f'{R}/en-US.json')); zh=json.load(open(f'{R}/zh-Hans.json'))
have=set(en)&set(zh); same=[k for k in have if zh[k]==en[k]]
print(f'key 覆盖 {len(have)}/{len(en)} = {100*len(have)/len(en):.2f}%')
print(f'值仍英文 {len(same)} 条 -> 实际中文化 {100*(len(en)-len(same))/len(en):.2f}%')
PY
```

「key 覆盖 100% + 值仍英文几百条」= 官方没译，正常。
「key 覆盖 < 99%」= 语言包旧了，去 `extract-zh-pack.sh` 或 `merge-zh.py`。

---

## 6. `extract-zh-pack.sh` 找不到缓存

```
[FAIL] 没找到缓存条目。
```

原因与对策：

| 原因 | 对策 |
|---|---|
| 这台机器从没在中文界面下运行过 | 从已跑通的机器拷 `zh-Hans.json` 到 `packs/` |
| App 清过缓存 / 重装 | 同上 |
| 数据目录不是 `Claude` / `Claude-3p` | `ls ~/Library/Application Support/ \| grep -i claude` 看实际名字 |

脚本会同时查 `Claude` 和 `Claude-3p` 两个目录，按体积预筛（>100KB）后读头部验 magic，不会漏。

---

## 7. 我不确定改动生效了没

按这个顺序，从最硬的证据往最软的走：

```bash
# 1) 运行时实际要什么语言（最硬）
pgrep -fl 'Claude Helper' | grep -o -- '--lang=[a-zA-Z_-]*' | sort -u

# 2) 白名单里有没有这个值
grep -rho -a -E '\["en-US"[^]]{0,240}\]' \
  /Applications/Claude.app/Contents/Resources/ion-dist/assets | sort -u

# 3) 签名与 entitlements
codesign --verify /Applications/Claude.app && echo SIG_OK
codesign -d --entitlements :- /Applications/Claude.app 2>/dev/null | grep -c virtualization

# 4) 语言包在不在、多少条
ls -la /Applications/Claude.app/Contents/Resources/ion-dist/i18n/zh-*.json \
       /Applications/Claude.app/Contents/Resources/ion-dist/i18n/dynamic/zh-*.json
```

**日志不能证明结果。** 前端语言选择不打日志，只有肉眼/截图能确认界面语言。

---

## 8. 换机器怎么一次性搞定

拷贝三样东西过去，然后两条命令：

```
packs/zh-Hans.json                    # 语言包（必须带，缓存里不一定有）
resources/dynamic-zh-Hans.json        # 动态包
resources/entitlements-adhoc.plist    # 签名模板
```

```bash
./scripts/reinject.sh --restart
./scripts/verify.sh
```

不需要改系统语言，不需要 `defaults write`，不需要 `--lang` 启动参数 ——
那三条路在本文档对应的方案里**都是无效的**（见下节）。

---

## 9. 无效路径清单（别浪费时间试）

| 做法 | 为什么无效 |
|---|---|
| `defaults write com.anthropic.claudefordesktop AppleLanguages -array zh-CN` | 前端语言不由 App 级 AppleLanguages 决定；只有在白名单已含对应值时才"看起来有效"，是巧合 |
| `open -a Claude.app --args --lang=zh-CN` | 主进程会覆盖渲染进程的 `--lang`，传不进去 |
| 改 `config.json` 的 `locale` | 前端只在有账号配置时才读它，Gateway 模式下该字段被忽略 |
| 只替换 `Resources/zh-Hans.json` | 那是桌面壳层文案，不影响可见界面 |
| `defaults read -g AppleLanguages` 后改系统语言 | 改系统语言确实会改变 `--lang`，但用户不想要这个代价；本方案已用双别名规避 |
