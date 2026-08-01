# how2use — dev-cleaner-zh-cn 使用与配置说明

> 本仓库根目录的 `README.md` 是**上游 README 的自动汉化版**（由 GitHub Actions 每周同步生成，头部含来源声明）。
> 本文档说明**本仓库自身**（自动同步汉化流水线）的配置与使用方法。

[Dev Cleaner](https://github.com/jemishavasoya/dev-cleaner) 的简体中文汉化版（PowerShell 脚本 + 说明文档）。

本仓库通过 GitHub Actions **每周自动**从上游仓库拉取源文件 `dev-cleaner.ps1` 和 `README.md`，调用 LLM 把用户可见的文本翻译成简体中文，并发布到 GitHub Releases。

## 产物

每次上游有更新且翻译结果发生变化时，会自动发布一个新 Release：

| 附件 | 说明 |
|---|---|
| `dev-cleaner.zh-CN.ps1` | 汉化版脚本（UTF-8 BOM，适用于 Windows PowerShell 5.1+） |
| `README.md` | 汉化版说明文档（即仓库根 README，头部含来源声明与使用说明指引） |
| `upstream/dev-cleaner.ps1` | 上游原始脚本（供对照，同步时的原始版本） |
| `upstream/README.md` | 上游原始说明文档（供对照） |

Release 的 tag 命名格式：`zh-CN-v<上游版本>-<日期>`，例如 `zh-CN-v1.2.0-20260801`。

> 重要：输出文件保存为 **UTF-8 with BOM**。PowerShell 5.1 在没有 BOM 时会把中文解析成乱码，汉化版必须带 BOM 才能正常运行。

## 配置

### 0. 推荐模型（可选）

免费大上下文模型推荐使用 **Agnes**：

- 官网：https://agnes-ai.com/
- API 平台：https://platform.agnes-ai.com/

### 1. 必须：配置 LLM API Key（Secret）

汉化依赖 LLM 翻译。在仓库 **Settings → Secrets and variables → Actions** 中添加：

| 名称 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `LLM_API_KEY` | Secret | ✅ | OpenAI 兼容接口的 API Key |

### 2. 可选：配置接口地址与模型（Variable）

在 **Settings → Secrets and variables → Actions → Variables** 中添加（不配则用默认值）：

| 名称 | 默认值 | 说明 |
|---|---|---|
| `LLM_BASE_URL` | `https://api.openai.com/v1` | OpenAI 兼容接口地址 |
| `LLM_MODEL` | `gpt-4o-mini` | 主模型名 |
| `LLM_FALLBACK_MODEL` | （空） | 备用模型：主模型请求失败/超时后自动切换 |
| `LLM_MAX_TOKENS` | `8192` | 单次请求最大输出 token 数；支持大输出的模型可调至 **65536** |
| `LLM_MAX_ROUNDS` | `3` | 每个文本段的重试轮数：每轮依次尝试 主模型 → 备用模型 |
| `LLM_TIMEOUT` | `300` | 单次 API 请求超时（秒） |
| `LLM_CHUNK_LINES` | `200` | 按多少行切一段提交；`0` = 不切段，整文件一次提交（适合大上下文模型） |

> **调大输出的推荐做法**：`LLM_MAX_TOKENS=65536`、`LLM_CHUNK_LINES=0`。
> 这样整份 1239 行的脚本一次提交即可完成，翻译更快、更连贯；若单次请求仍不稳定，
> 再把 `LLM_CHUNK_LINES` 调回 `200` 分段重试。

### 3. 可选：SMTP 告警（Secret + Variable）

所有轮次尝试结束后仍未翻译成功时，会发送一封失败通知邮件。不配置则跳过邮件，仅任务失败。

| 名称 | 类型 | 说明 |
|---|---|---|
| `SMTP_HOST` | Variable | SMTP 服务器地址（如 `smtp.example.com`），配置了它才会启用邮件通知 |
| `SMTP_PORT` | Variable | 端口，默认 `587`；SSL 端口 `465` 会自动使用 SSL |
| `SMTP_USER` | **Secret** | 登录用户名（通常与发件邮箱相同），含隐私信息，用 Secret 保护 |
| `SMTP_PASSWORD` | **Secret** | 登录密码 / 授权码 |
| `SMTP_FROM` | Variable | 发件人地址，默认取 `SMTP_USER`（不配置时不可见于日志） |
| `SMTP_TO` | **Secret** | 收件人邮箱（隐私信息，用 Secret 保护），多个用逗号分隔 |
| `SMTP_USE_TLS` | Variable | 是否启用 STARTTLS，默认 `true` |

> 说明：`SMTP_USER`、`SMTP_TO` 属于隐私信息，workflow 从 **Secrets** 读取（`${{ secrets.SMTP_USER }}`、`${{ secrets.SMTP_TO }}`），
> 不会出现在 workflow 日志中。

### 4. 权限

workflow 已声明 `permissions: contents: write`，提交汉化文件和发布 Release 均使用仓库内置的 `GITHUB_TOKEN`，无需额外配置。

## 运行方式

### 自动

每周一 03:00 UTC（北京时间周一 11:00）自动运行（见 `sync-upstream.yml` 中的 `schedule`）。

### 手动

仓库 **Actions** 页面选择 **同步上游并发布汉化版** → **Run workflow**，可指定：

- `upstream_ref`：上游 ref（commit SHA / tag / 分支名），默认固定在上游 commit `ec1037bbcf8e64614301dfb2020b4b8f4ee7289d`
- `upstream_file`：上游仓库内要汉化的文件路径，默认 `dev-cleaner.ps1`

## 工作流程说明

```
schedule / workflow_dispatch
        │
        ▼
下载上游文件 (curl raw.githubusercontent.com)
  ├─ dev-cleaner.ps1
  └─ README.md
        │
        ▼
LLM 汉化 (scripts/translate.py)
  ├─ 脚本：--kind ps1，只翻译用户可见字符串与注释，代码结构不动
  ├─ README：--kind md，翻译正文/标题/表格，保留代码块与链接
  ├─ 按行分段调用 chat/completions（LLM_CHUNK_LINES 可调，0 = 不切段）
  ├─ 每段：主模型 → 失败/超时 → 备用模型 → 失败 → 下一轮（LLM_MAX_ROUNDS）
  ├─ 结构校验（中文存在、关键内容保留、行数合理、结尾一致）
  ├─ README 头部插入来源声明 + how2use.md 使用说明指引
  └─ 输出 UTF-8 BOM 文件
        │
        ├─ 轮次耗尽仍失败 → SMTP 告警邮件（可选）→ 任务失败
        ▼
与上次结果比对 ── 无变化 → 结束（不重复发版）
        │ 有变化
        ▼
提交 + push + 创建 GitHub Release（附汉化版与原始文件）
```

## 本地测试（可选）

不调用 LLM，验证整条流水线：

```bash
# PowerShell 脚本
python scripts/translate.py --input upstream/dev-cleaner.ps1 --output /tmp/out.ps1 --mock

# Markdown 文档（含来源声明头部）
python scripts/translate.py --input upstream/README.md --output /tmp/out.md --kind md --mock
```

## 修改上游

默认锁定在上游 commit `ec1037bbcf8e64614301dfb2020b4b8f4ee7289d`（稳定可复现）。
如需跟随上游最新代码，手动运行时把 `upstream_ref` 填为 `main` 即可；若想长期跟随，把 `.github/workflows/sync-upstream.yml` 中 `UPSTREAM_REF` 的默认值改为 `main`。

## 目录结构

```
.github/workflows/sync-upstream.yml   # 定时同步 + 汉化 + 发布 workflow
scripts/translate.py                  # 汉化脚本（LLM 分段翻译 + 校验 + BOM 输出）
README.md                             # 上游 README 的汉化版（由 workflow 生成并提交，头部含来源声明）
how2use.md                            # 本仓库使用与配置说明（本文档）
dev-cleaner.zh-CN.ps1                 # 汉化版脚本（由 workflow 生成并提交）
upstream/                             # 上游原始文件与 ref 记录（由 workflow 生成）
```
