# dev-cleaner-zh-cn

[Dev Cleaner](https://github.com/jemishavasoya/dev-cleaner) 的简体中文汉化版（PowerShell 脚本 + 说明文档）。

本仓库通过 GitHub Actions **每周自动**从上游仓库拉取源文件 `dev-cleaner.ps1` 和 `README.md`，调用 LLM 把用户可见的文本翻译成简体中文，并发布到 GitHub Releases。

## 产物

每次上游有更新且翻译结果发生变化时，会自动发布一个新 Release：

| 附件 | 说明 |
|---|---|
| `dev-cleaner.zh-CN.ps1` | 汉化版脚本（UTF-8 BOM，适用于 Windows PowerShell 5.1+） |
| `README.zh-CN.md` | 汉化版说明文档（头部含源代码来源声明） |
| `upstream/dev-cleaner.ps1` | 上游原始脚本（供对照，同步时的原始版本） |
| `upstream/README.md` | 上游原始说明文档（供对照） |

Release 的 tag 命名格式：`zh-CN-v<上游版本>-<日期>`，例如 `zh-CN-v1.2.0-20260801`。

> 重要：输出文件保存为 **UTF-8 with BOM**。PowerShell 5.1 在没有 BOM 时会把中文解析成乱码，汉化版必须带 BOM 才能正常运行。

## 配置

### 1. 必须：配置 LLM API Key（Secret）

汉化依赖 LLM 翻译。在仓库 **Settings → Secrets and variables → Actions** 中添加：

| 名称 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `LLM_API_KEY` | Secret | ✅ | OpenAI 兼容接口的 API Key（OpenAI / DeepSeek / Moonshot 等均可） |

### 2. 可选：配置接口地址与模型（Variable）

在 **Settings → Secrets and variables → Actions → Variables** 中添加（不配则用默认值）：

| 名称 | 默认值 | 说明 |
|---|---|---|
| `LLM_BASE_URL` | `https://api.openai.com/v1` | 接口地址，例如 DeepSeek 用 `https://api.deepseek.com/v1` |
| `LLM_MODEL` | `gpt-4o-mini` | 模型名，例如 DeepSeek 用 `deepseek-chat` |

### 3. 权限

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
  ├─ 按 200 行分段调用 chat/completions（防止输出截断）
  ├─ 结构校验（中文存在、关键内容保留、行数合理、结尾一致）
  ├─ README 头部插入源代码来源声明
  └─ 输出 UTF-8 BOM 文件
        │
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
dev-cleaner.zh-CN.ps1                 # 汉化版脚本（由 workflow 生成并提交）
README.zh-CN.md                       # 汉化版说明文档（由 workflow 生成并提交）
upstream/                             # 上游原始文件与 ref 记录（由 workflow 生成）
```
