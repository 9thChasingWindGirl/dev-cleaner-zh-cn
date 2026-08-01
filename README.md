# dev-cleaner-zh-cn

[Dev Cleaner](https://github.com/jemishavasoya/dev-cleaner) 的简体中文汉化版仓库。

> 本 README 由 GitHub Actions **每周自动同步上游**并汉化生成（头部含源代码来源声明）。
> 同步尚未运行的首次初始化期间，本文件为临时占位说明；workflow 首次运行后会以
> 上游 README 的汉化版（带来源声明）覆盖本文件。

## 内容导航

- **上游 README 汉化版**：即本文件本身（workflow 生成后），介绍 Dev Cleaner 工具的功能与使用方法
- **本仓库使用与配置说明**：见 [how2use.md](how2use.md)（自动同步、LLM 汉化、fallback、SMTP 告警等流水线的配置）

## 快速开始

1. 下载汉化版脚本：在 [Releases](https://github.com/jemishavasoya/dev-cleaner-zh-cn/releases) 页面获取 `dev-cleaner.zh-CN.ps1`
2. 以管理员身份打开 Windows PowerShell 运行：`.\dev-cleaner.zh-CN.ps1`
3. 更详细的配置（LLM Key、模型、SMTP 通知等）见 [how2use.md](how2use.md)

## 目录结构

```
.github/workflows/sync-upstream.yml   # 定时同步 + 汉化 + 发布 workflow
scripts/translate.py                  # 汉化脚本（LLM 分段翻译 + 校验 + BOM 输出）
README.md                             # 上游 README 的汉化版（workflow 生成，头部含来源声明）
how2use.md                            # 本仓库使用与配置说明
dev-cleaner.zh-CN.ps1                 # 汉化版脚本（workflow 生成并提交）
upstream/                             # 上游原始文件与 ref 记录（workflow 生成）
```
