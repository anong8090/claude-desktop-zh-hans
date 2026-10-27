# 免费 / 低价 API 来源清单 + CC Switch 配置

给 Claude Code / Claude Desktop 接第三方模型时用得上的免费额度来源。

**数据时点：2026-10-27。** 这类免费额度变动极快（下面第 1 节就是个例子），
所有数字都以你登录后控制台显示的为准——本文只标"大概的量级"和"哪条路最省事"。

---

## 0. 先说一条已经失效的

**GitHub Models 已于 2026-07-30 全面退役。** 操场、模型目录、推理 API、BYOK 全部下线，
`https://models.github.ai/inference` 已经不通了（老教程里的 `models.inference.ai.azure.com` 同样失效）。

时间线：

| 日期 | 事件 |
|---|---|
| 2026-06-16 | 停止新用户接入 |
| 2026-07-01 | 宣布全面退役 |
| 2026-07-16 / 07-23 | 两次预演停服 |
| **2026-07-30** | **彻底关闭**，无宽限期 |

官方给的迁移路径是 Azure AI Foundry —— 那要绑信用卡、按量计费，已经不是"免费"了。

所以现在**用 GitHub 账号拿不到可直接给 Claude Code 用的免费 API 端点**。
GitHub 账号唯一还有价值的地方是 Copilot 免费档（见第 4 节），但那是编辑器内的额度，不是 API。

---

## 1. 速查表

| 平台 | 门槛 | 免费额度（量级） | 端点 | Anthropic 原生协议 | 国内直连 |
|---|---|---|---|---|---|
| **AMD Radeon Token Factory** | 邮箱 | 每日积分制，约几百万 token/天 | `https://developer.amd.com.cn/radeon/api/v1` | ✅ **原生支持** | ✅ |
| **NVIDIA NIM** | 邮箱 + 手机验证 | ~40 RPM，**无日 token 上限** | `https://integrate.api.nvidia.com/v1` | ⚠️ OpenAI 兼容 | ⚠️ 需代理 |
| **Google AI Studio** | Google 账号 | Flash 类 15 RPM / 1500 RPD | `https://generativelanguage.googleapis.com/v1beta/openai/` | ❌ | ⚠️ 需代理 |
| **Groq** | 邮箱 | 30 RPM / 1.4 万 RPD（小模型） | `https://api.groq.com/openai/v1` | ❌ | ⚠️ |
| **Cerebras** | 邮箱 | 约 100 万 token/天 | `https://api.cerebras.ai/v1` | ❌ | ⚠️ |
| **OpenRouter** | 邮箱/GitHub | 200 RPD（`:free` 模型） | `https://openrouter.ai/api/v1` | ❌ | ⚠️ |
| **智谱 GLM** | 手机号 | 新用户赠送额度 | `https://open.bigmodel.cn/api/anthropic` | ✅ | ✅ |
| **硅基流动** | 手机号 | 注册赠送额度 + 部分模型免费 | `https://api.siliconflow.cn/v1` | ❌ | ✅ |
| **ModelScope 魔搭** | 阿里账号 | 每日 2000 次免费调用 | `https://api-inference.modelscope.cn/v1` | ❌ | ✅ |

> "Anthropic 原生协议"= 能直接填进 `ANTHROPIC_BASE_URL` 且走 `/v1/messages`。
> 不支持的需要中间层做 OpenAI → Anthropic 协议转换（CC Switch 的"本地路由/格式转换"能做一部分）。

---

## 2. AMD Radeon Token Factory（最推荐，尤其国内）

AMD 中国开发者平台 2025 年底开的免费推理通道，是目前**对 Claude Code 最友好**的一家：

- ✅ **原生同时支持 OpenAI 和 Anthropic 两种协议**，一把 key 两用
- ✅ 邮箱注册，**不用信用卡、不用国外手机号、不用梯子**
- ✅ 稳定性明显好于 NVIDIA 的免费档（那边 429 很常见）
- ⚠️ 速度一般（首字延迟可能十几秒），适合写稿/轻任务，别当高频主力

### 领取

1. <https://developer.amd.com.cn/radeon/tokenfactory>
2. 邮箱或手机号登录
3. 在「Public Free Model APIs」里点任一免费模型卡片 → 复制 `sk-` 开头的 key

### 可用模型（部分）

| 模型 ID | 上下文 |
|---|---|
| `DeepSeek-V4-Flash` | 1,048,576 |
| `DeepSeek-V4-Flash-Vision-Exp` | 1,000,000 |
| `Qwen3.8-Flash-Next` | 262,144 |
| `GLM-5.3-Flash` | 262,144 |
| `MiniCPM5-2B` / `MiniCPM-V-4.7-1B` | 131K / 262K |

### 额度机制

积分制，不是扣钱：每天刷新一个配额，按输入/输出消耗计分，粗算**纯输入约几百万 token/天**。
滚动重置（从你当天第一个请求算起），时区按上海。具体数值看控制台。

### 两个实测坑

1. **只认白名单字段**：请求体里名单外的参数会被**静默忽略**（不报错也不生效）。
   `stop`、`seed`、`top_k` 这类调不动多半是撞在这。
2. **不认 `thinking` 字段**，会直接报错。要用 `reasoning_effort`。
   很多客户端默认带 `thinking`，这是接入失败最常见的原因——先发一句"只回复 OK"试通。

### 验证

```bash
# OpenAI 协议
curl -sS https://developer.amd.com.cn/radeon/api/v1/chat/completions \
  -H "Authorization: Bearer $AMD_KEY" -H "Content-Type: application/json" \
  -d '{"model":"DeepSeek-V4-Flash","messages":[{"role":"user","content":"只回复 OK"}]}'

# Anthropic 协议
curl -sS https://developer.amd.com.cn/radeon/api/v1/messages \
  -H "x-api-key: $AMD_KEY" -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{"model":"DeepSeek-V4-Flash","max_tokens":32,"messages":[{"role":"user","content":"只回复 OK"}]}'
```

---

## 3. NVIDIA NIM

- <https://build.nvidia.com> → 登录 → 任一模型页 → `Get API Key`，key 以 `nvapi-` 开头
- 免费档：**约 40 RPM / 每模型**，**不按 token 计费、无日配额** —— 这是它最大的优点
- 100+ 开源模型：Nemotron 3、Kimi K2.x、GLM-5.x、DeepSeek V4、Gemma 4……
- ⚠️ 需要手机验证（唯一的摩擦点）
- ⚠️ key 有有效期（6 或 12 个月，以控制台为准），到期前重新生成
- ⚠️ 免费档是共享基础设施的"善意配额"，没有 SLA，高峰 429 很常见

**接 Claude Code**（OpenAI 兼容，需转换层）：

```bash
export OPENAI_BASE_URL=https://integrate.api.nvidia.com/v1
export OPENAI_API_KEY=nvapi-xxxx
```

要用在 Claude Code / Claude Desktop 上，建议走 CC Switch 的本地路由做协议转换，
或直接用支持 Anthropic 协议的 AMD。

---

## 4. GitHub 账号现在还能给什么

| 项目 | 能不能当 API 用 | 说明 |
|---|---|---|
| ~~GitHub Models~~ | ❌ 已退役 | 2026-07-30 关闭 |
| Copilot Free | ❌ | $0，每月 2000 次补全 + 50 次 chat/agent，**只能编辑器内用**，且不给第三方模型选择 |
| Copilot Pro（$10/月） | ❌ 直接当 API | 含 $15 等值 AI Credits，可在 github.com 上跑 Claude Code / Codex agent，但不是 API 端点 |

结论：**别再指望 GitHub 账号拿免费 token 了。** 用它当代码托管和 CI 就好。

---

## 5. CC Switch 配置

[CC Switch](https://ccswitch.io) 是供应商切换器，支持 Claude Code / Claude Desktop / Codex / Gemini CLI，
内置 50+ 预设，也可以在托盘里一键切换。

```bash
brew install --cask cc-switch
```

### 5.1 加一个 Claude Code 供应商

点右上角 `+` →「自定义」，填：

| 字段 | 值（以 AMD 为例） |
|---|---|
| 名称 | `AMD-DeepSeek` |
| API Key | 你的 `sk-...` |
| 请求地址 | `https://developer.amd.com.cn/radeon/api/v1` |
| API 格式 | Anthropic Messages（原生） |
| 认证字段 | `ANTHROPIC_AUTH_TOKEN` |

保存后点「启用」，它会写进 `~/.claude/settings.json`：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://developer.amd.com.cn/radeon/api/v1",
    "ANTHROPIC_AUTH_TOKEN": "sk-xxxx"
  }
}
```

模型映射（可选，把 Opus/Sonnet/Haiku 三档指到不同模型）：

```
主模型      DeepSeek-V4-Flash
Haiku 档    DeepSeek-V4-Flash
Sonnet 档   DeepSeek-V4-Flash
Opus 档     Qwen3.8-Flash-Next
```

### 5.2 让 Claude Desktop 也走同一条通道

CC Switch 有独立的 **Claude Desktop** 页签（和 Claude Code 分开）。
加好供应商并启用后：

> **必须重启 Claude Desktop。** CC Switch 的官方文档写明：Claude Code 是热重载，Claude Desktop 需要重启。

重启后左下角身份会变成 `xxx · Gateway` —— 这就是反代模式，也是**本文档主仓库要解决的中文化场景**。

### 5.3 生效方式对照

| 工具 | 切供应商后 |
|---|---|
| Claude Code | 即时生效（热重载） |
| **Claude Desktop** | **需要重启 App** |
| Codex / OpenCode / OpenClaw | 关掉终端重开 |
| Gemini CLI / Grok Build | 重启 CLI |

### 5.4 顺手能用的两个功能

- **本地代理**（设置 → 高级 → 代理服务，默认端口 15721）：请求日志、用量统计、自动故障转移、熔断。免费额度容易 429，开这个能自动切备用供应商。
- **数据库备份**（设置 → 数据 → SQL 导入导出）：切供应商会重写配置，备份一下省得丢。

---

## 6. 组合建议

| 场景 | 建议 |
|---|---|
| 日常写代码、要求稳 | AMD（Anthropic 原生协议，国内直连） |
| 跑长上下文 / 批量 | AMD 的 1M 上下文模型 |
| 高频短请求 | NVIDIA NIM（无日 token 上限，但会 429） |
| 备用自动切换 | CC Switch 本地代理 + 挂 2~3 家 |
| 完全离线 | Ollama / LM Studio + CC Switch 本地供应商 |

---

## 7. 注意事项

- **别把免费额度当生产**。无 SLA、随时限速或调整政策，各家都写了"原型/实验用途"。
- **数据会经过第三方**。商业代码、客户资料不要丢进免费推理端点。国内平台还涉及数据出境/入境问题，按自己合规要求判断。
- **key 别进 git**。用 `~/.zshrc` 里的环境变量或 CC Switch 存储，不要写进仓库。
- **多账号平摊额度**通常违反服务条款，账号可能被封，不值得。
- 免费额度政策变化极快（GitHub Models 从宣布到关闭只用了一个月），接入前先看官方控制台。

---

## 参考

- NVIDIA NIM: <https://build.nvidia.com> · <https://docs.nvidia.com/nim/>
- AMD Token Factory: <https://developer.amd.com.cn/radeon/tokenfactory>
- CC Switch 文档: <https://ccswitch.io/zh/docs>
- GitHub Models 退役说明: [Migrate from GitHub Models to Microsoft Foundry Models](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/quickstart-github-models)
