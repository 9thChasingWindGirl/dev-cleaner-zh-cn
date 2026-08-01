#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

# 分段大小（行），避免超出模型单次输出上限
CHUNK_LINES = 200

SYSTEM_PROMPT_PS1 = """You are localizing a PowerShell script from English into Simplified Chinese (简体中文).

Translate ONLY the user-facing text into Simplified Chinese:
- String literals shown to users, e.g. inside Write-Host, Write-Output, Write-Warning, Write-Error, Read-Host, [Console]::WriteLine, throw, and exit messages.
- The menu option labels and prompt messages.
- Prose inside comments (lines starting with #).

DO NOT modify anything else:
- Keep all code, logic, function names, variable names, parameter definitions, operators, paths, URLs, emoji, ASCII art / box-drawing characters, and -ForegroundColor values exactly as they are.
- Keep the same quote style (double or single) around each string; only replace the English text inside.
- Keep string interpolation like $var and $(...) intact inside translated text.
- Do not add or remove lines; keep the structure identical.
- Keep product names in English: Visual Studio, Android Studio, VSCode, Flutter, npm, Yarn, pnpm, NuGet, PlatformIO, Cordova, Electron, Docker, Gradle, SDK.

Consistent terminology:
- Clean / Cleaning / Cleanup / Clear -> 清理
- Cache(s) -> 缓存
- All Caches -> 全部缓存
- Dev Cleaner / Dev Cleanup Utility -> Dev Cleaner（开发清理工具）
- Remove / Removing / Deleted -> 删除 / 正在删除
- Measuring / Measure -> 正在计算 / 计算
- Exit -> 退出
- Confirm -> 确认
- Yes / No (y/N) -> 是 / 否（保持 (y/N) 不变）
- Please -> 请
- Running -> 正在运行
- Skipped -> 已跳过
- Estimated -> 预估

Output ONLY the translated script. Do NOT wrap it in Markdown code fences, do NOT add explanations, headers, or any text outside the script."""

SYSTEM_PROMPT_MD = """You are localizing a Markdown document (a README) from English into Simplified Chinese (简体中文).

Translate into Simplified Chinese:
- Prose paragraphs, headings, list items, table cell text, and link labels / alt text.

DO NOT change:
- Code blocks (fenced with ```) and inline code; their content stays as-is.
- URLs, image paths, HTML tags, badge URLs, and their structure.
- Markdown structure: heading levels, tables, lists, blockquotes, horizontal rules.
- Product names: Visual Studio, Android Studio, VSCode, Flutter, npm, Yarn, pnpm, NuGet, PlatformIO, Cordova, Electron, Docker, Gradle, SDK, Xcode, Homebrew.
- Keep emoji and icon text.

Consistent terminology:
- Clean / Cleaning / Cleanup / Clear -> 清理
- Cache(s) -> 缓存
- Dev Cleaner / Dev Cleanup Utility -> Dev Cleaner（开发清理工具）
- Remove / Removing / Deleted -> 删除 / 正在删除
- How to Use -> 使用方法
- Features -> 功能特性
- System Support -> 系统支持
- Troubleshooting -> 常见问题

Output ONLY the translated Markdown document. Do NOT wrap it in an extra code fence and do NOT add explanations outside the document."""

# here-string 开始标记 -> 结束标记（避免在 here-string 中间切段）
HERE_OPEN_TO_CLOSE = {'@"': '"@', "@'": "'@"}


def load_config():
    api_key = os.environ.get("LLM_API_KEY") or ""
    base_url = (os.environ.get("LLM_BASE_URL") or "https://api.openai.com/v1").rstrip("/")
    model = os.environ.get("LLM_MODEL") or "gpt-4o-mini"
    max_tokens = int(os.environ.get("LLM_MAX_TOKENS") or "8192")
    temperature = float(os.environ.get("LLM_TEMPERATURE") or "0.0")
    if not api_key:
        print(
            "缺少 LLM_API_KEY 环境变量：请在仓库 Settings → Secrets and variables → Actions "
            "中配置 LLM_API_KEY（OpenAI 兼容接口的 Key）",
            file=sys.stderr,
        )
        sys.exit(2)
    return {
        "api_key": api_key,
        "base_url": base_url,
        "model": model,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "timeout": 300,
    }


def split_into_chunks(lines, size=CHUNK_LINES):
    """按行切段；若处于 here-string 内部则等到结束标记再切。"""
    chunks = []
    current = []
    here_close = None
    for ln in lines:
        current.append(ln)
        if here_close is None:
            m = re.search(r'(@["\'])\s*$', ln)
            if m and m.group(1) in HERE_OPEN_TO_CLOSE:
                here_close = HERE_OPEN_TO_CLOSE[m.group(1)]
        else:
            if ln.rstrip() == here_close:
                here_close = None
        if here_close is None and len(current) >= size:
            chunks.append("\n".join(current))
            current = []
    if current:
        chunks.append("\n".join(current))
    return chunks


def call_llm(messages, cfg):
    url = "{}/chat/completions".format(cfg["base_url"])
    body = json.dumps(
        {
            "model": cfg["model"],
            "messages": messages,
            "temperature": cfg["temperature"],
            "max_tokens": cfg["max_tokens"],
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": "Bearer {}".format(cfg["api_key"]),
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=cfg["timeout"]) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise RuntimeError("API 响应格式异常: {}".format(json.dumps(data)[:500]))


def translate_chunk(chunk_text, idx, total, cfg, system_prompt, retries=3):
    user_prompt = (
        "下面是待翻译文档的第 {}/{} 段（按顺序排列）。\n"
        "请按系统规则翻译这一段，只输出翻译后的这段内容本身，"
        "不要输出任何解释、标题或 Markdown 代码围栏。\n\n"
        "```\n{}\n```"
    ).format(idx, total, chunk_text)
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            return call_llm(messages, cfg)
        except (urllib.error.HTTPError, urllib.error.URLError, RuntimeError) as e:
            last_err = e
            if attempt < retries:
                time.sleep(2 * attempt)
    raise RuntimeError("第 {} 段翻译失败（已重试 {} 次）: {}".format(idx, retries, last_err))


def validate_ps1(original, translated):
    """PowerShell 结构校验：失败返回错误列表。"""
    errors = []
    if "```" in translated:
        errors.append("输出包含 Markdown 代码围栏，疑似未按指令返回")
    if not re.search(r"[\u4e00-\u9fff]", translated):
        errors.append("未检测到中文字符，翻译可能未执行")
    for marker in ("function Show-Logo", "function Start-MainLoop", "$SCRIPT_VERSION"):
        if marker not in translated:
            errors.append("缺少关键代码片段: {}".format(marker))
    lo = len(original.splitlines())
    lt = len(translated.splitlines())
    if lo > 0 and not (0.85 <= lt / lo <= 1.15):
        errors.append("行数异常: 原文 {} 行, 译文 {} 行".format(lo, lt))
    if translated.count("{") != translated.count("}"):
        errors.append("花括号数量不匹配")
    tail_o = original.rstrip().splitlines()[-1].strip() if original.strip() else ""
    tail_t = translated.rstrip().splitlines()[-1].strip() if translated.strip() else ""
    if tail_o and tail_o != tail_t:
        errors.append("文件结尾不一致: 原文 {!r} != 译文 {!r}".format(tail_o, tail_t))
    return errors


def validate_md(original, translated):
    """Markdown 结构校验：失败返回错误列表。"""
    errors = []
    if not re.search(r"[\u4e00-\u9fff]", translated):
        errors.append("未检测到中文字符，翻译可能未执行")
    nonempty = [ln for ln in translated.splitlines() if ln.strip()]
    if not nonempty or not nonempty[0].lstrip().startswith("#"):
        errors.append("文档开头不是 Markdown 标题（#）")
    lo = len(original.splitlines())
    lt = len(translated.splitlines())
    if lo > 0 and not (0.7 <= lt / lo <= 1.3):
        errors.append("行数异常: 原文 {} 行, 译文 {} 行".format(lo, lt))
    return errors


def validate(original, translated, kind):
    if kind == "md":
        return validate_md(original, translated)
    return validate_ps1(original, translated)


def mock_translate(text, kind):
    """测试模式：验证整条流水线，不调用 LLM。"""
    if kind == "md":
        out = []
        inserted = False
        for ln in text.splitlines():
            if not inserted and ln.strip() and not ln.lstrip().startswith("#"):
                out.append("汉化测试：{}".format(ln))
                inserted = True
            else:
                out.append(ln)
        return "\n".join(out)
    pattern = re.compile(r'^(\s*(?:Write-Host|Write-Output|Write-Warning|Write-Error|Read-Host)\b[^"\r\n]*")')
    out = []
    for ln in text.splitlines():
        m = pattern.match(ln)
        if m and '"' in ln[m.end():]:
            ln = ln[: m.end()] + "汉化测试：" + ln[m.end():]
        out.append(ln)
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="汉化上游仓库源文件")
    ap.add_argument("--input", required=True, help="上游原始文件路径")
    ap.add_argument("--output", required=True, help="汉化后输出路径")
    ap.add_argument("--kind", choices=("ps1", "md"), default="ps1", help="输入类型（默认 ps1）")
    ap.add_argument("--header", default="", help="插入到输出文件头部的声明文本（来源说明）")
    ap.add_argument("--mock", action="store_true", help="不调用 API，用占位中文测试流水线")
    args = ap.parse_args()

    with open(args.input, "r", encoding="utf-8-sig", newline="") as f:
        original = f.read()

    if args.mock:
        translated = mock_translate(original, args.kind)
        print("[translate] mock 模式，未调用 LLM", file=sys.stderr)
    else:
        cfg = load_config()
        system_prompt = SYSTEM_PROMPT_MD if args.kind == "md" else SYSTEM_PROMPT_PS1
        chunks = split_into_chunks(original.splitlines(), CHUNK_LINES)
        total = len(chunks)
        print(
            "[translate] 共 {} 段，逐段调用 LLM（模型 {}）...".format(total, cfg["model"]),
            file=sys.stderr,
        )
        parts = []
        for i, chunk in enumerate(chunks, 1):
            print("[translate] 翻译第 {}/{} 段...".format(i, total), file=sys.stderr)
            parts.append(translate_chunk(chunk, i, total, cfg, system_prompt))
        translated = "\n".join(parts)
        translated = translated.strip() + "\n"

    errors = validate(original, translated, args.kind)
    if errors:
        for e in errors:
            print("[validate] FAIL: {}".format(e), file=sys.stderr)
        sys.exit(1)

    # 头部声明（来源说明）在正文之前插入
    if args.header:
        translated = args.header.rstrip() + "\n\n" + translated

    # UTF-8 BOM：Windows PowerShell 5.1 识别中文必需（markdown 亦保持一致）
    with open(args.output, "w", encoding="utf-8-sig", newline="") as f:
        f.write(translated)
    print("[translate] 完成: {}（{} 行, UTF-8 BOM）".format(args.output, len(translated.splitlines())))


if __name__ == "__main__":
    main()
