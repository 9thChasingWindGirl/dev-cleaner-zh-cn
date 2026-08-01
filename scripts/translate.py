#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import argparse
import json
import os
import re
import smtplib
import sys
import time
import urllib.error
import urllib.request
from email.header import Header
from email.mime.text import MIMEText
from email.utils import formataddr

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
    fallback_model = os.environ.get("LLM_FALLBACK_MODEL") or ""
    max_tokens = int(os.environ.get("LLM_MAX_TOKENS") or "8192")
    temperature = float(os.environ.get("LLM_TEMPERATURE") or "0.0")
    timeout = int(os.environ.get("LLM_TIMEOUT") or "300")
    # 每个文本段重试的轮数：每轮依次尝试 primary -> fallback
    max_rounds = int(os.environ.get("LLM_MAX_ROUNDS") or "3")
    # 0 表示不切段，整文件一次提交（适用于 512K 上下文/65.5K 输出的模型）
    chunk_lines = int(os.environ.get("LLM_CHUNK_LINES") or str(CHUNK_LINES))
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
        "fallback_model": fallback_model,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "timeout": timeout,
        "max_rounds": max_rounds,
        "chunk_lines": chunk_lines,
        "smtp": load_smtp_config(),
    }


def load_smtp_config():
    """解析 SMTP 配置；未配置 SMTP_HOST 时返回 None（不发送邮件）。"""
    host = os.environ.get("SMTP_HOST") or ""
    if not host:
        return None
    return {
        "host": host,
        "port": int(os.environ.get("SMTP_PORT") or "587"),
        "user": os.environ.get("SMTP_USER") or "",
        "password": os.environ.get("SMTP_PASSWORD") or "",
        "from_addr": os.environ.get("SMTP_FROM") or "",
        "to_addrs": [a.strip() for a in (os.environ.get("SMTP_TO") or "").split(",") if a.strip()],
        "use_tls": (os.environ.get("SMTP_USE_TLS") or "true").lower() in ("1", "true", "yes"),
    }


def send_smtp_alert(cfg, subject, body):
    """发送 SMTP 告警邮件；未配置 SMTP 或发送失败时仅打印错误，不中断流程。"""
    smtp = cfg.get("smtp")
    if not smtp:
        print("[alert] 未配置 SMTP（缺少 SMTP_HOST），跳过邮件通知", file=sys.stderr)
        return
    if not smtp["to_addrs"]:
        print("[alert] SMTP 未配置收件人（SMTP_TO），跳过邮件通知", file=sys.stderr)
        return
    from_addr = smtp["from_addr"] or smtp["user"]
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = Header(subject, "utf-8")
    msg["From"] = formataddr(("dev-cleaner-zh-cn", from_addr))
    msg["To"] = ", ".join(smtp["to_addrs"])
    try:
        if smtp["port"] == 465:
            server = smtplib.SMTP_SSL(smtp["host"], smtp["port"], timeout=30)
        else:
            server = smtplib.SMTP(smtp["host"], smtp["port"], timeout=30)
            if smtp["use_tls"]:
                server.starttls()
        if smtp["user"]:
            server.login(smtp["user"], smtp["password"])
        server.sendmail(from_addr, smtp["to_addrs"], msg.as_string())
        server.quit()
        print("[alert] SMTP 通知已发送至 {}".format(", ".join(smtp["to_addrs"])), file=sys.stderr)
    except Exception as e:
        print("[alert] SMTP 发送失败（不影响流程）: {}".format(e), file=sys.stderr)


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


def call_llm(messages, cfg, model=None):
    url = "{}/chat/completions".format(cfg["base_url"])
    body = json.dumps(
        {
            "model": model or cfg["model"],
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


def strip_fences(text):
    """剥离模型输出外层包裹的 Markdown 代码围栏（```lang ... ```）。

    取第一对 ``` 之间的内容；若无围栏则原样返回。
    """
    lines = text.splitlines()
    start = None
    end = None
    for i, ln in enumerate(lines):
        if ln.strip().startswith("```"):
            if start is None:
                start = i + 1
            else:
                end = i
                break
    if start is not None and end is not None and end > start:
        return "\n".join(lines[start:end])
    return text


def validate_segment(text, kind):
    """逐段结构校验：失败返回错误列表。"""
    errors = []
    if not text.strip():
        errors.append("段内容为空")
    if kind == "ps1":
        if text.count("{") != text.count("}"):
            errors.append("段内花括号数量不匹配（可能被截断或结构被改动）")
        if text.strip().endswith("```"):
            errors.append("段结尾是未闭合的代码围栏，可能被截断")
        if "```" in text:
            errors.append("段内残留 Markdown 代码围栏")
    return errors


def translate_chunk(chunk_text, idx, total, cfg, system_prompt, kind, retries=3):
    """翻译一段：每轮依次尝试 primary 模型 -> fallback 模型，共 max_rounds 轮。

    返回通过结构校验的译文；全部轮次均失败则抛出 RuntimeError。
    """
    base_prompt = (
        "下面是待翻译文档的第 {}/{} 段（按顺序排列）。\n"
        "请按系统规则翻译这一段，只输出翻译后的这段内容本身，"
        "不要输出任何解释、标题或 Markdown 代码围栏。\n\n"
        "```\n{}\n```"
    ).format(idx, total, chunk_text)
    models = [cfg["model"]]
    if cfg.get("fallback_model"):
        models.append(cfg["fallback_model"])
    last_err = None
    for round_no in range(1, cfg["max_rounds"] + 1):
        for model in models:
            last_err = None
            for attempt in range(1, retries + 1):
                user_prompt = base_prompt
                if last_err:
                    user_prompt += (
                        "\n\n注意：你上一次的输出未通过校验（{}）。"
                        "请只输出代码本身，绝对不要使用 Markdown 代码围栏（```），"
                        "不要改动代码结构，不要截断内容。"
                    ).format(last_err)
                messages = [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ]
                try:
                    raw = call_llm(messages, cfg, model=model)
                except (urllib.error.HTTPError, urllib.error.URLError, RuntimeError) as e:
                    last_err = "API 调用失败: {}".format(e)
                    if attempt < retries:
                        time.sleep(2 * attempt)
                    continue
                # 剥离模型可能包裹的代码围栏，再做逐段结构校验
                cleaned = strip_fences(raw or "")
                seg_errors = validate_segment(cleaned, kind)
                if not seg_errors:
                    return cleaned
                last_err = "; ".join(seg_errors)
                print(
                    "[translate] 第 {}/{} 段，模型 {}，校验未通过（{}），重试 {}/{}...".format(
                        idx, total, model, last_err, attempt, retries
                    ),
                    file=sys.stderr,
                )
                if attempt < retries:
                    time.sleep(2 * attempt)
            print(
                "[translate] 第 {}/{} 段，模型 {} 失败（第 {} 轮）：{}".format(
                    idx, total, model, round_no, last_err
                ),
                file=sys.stderr,
            )
        # 本轮 primary + fallback 均失败，进入下一轮
        if round_no < cfg["max_rounds"]:
            print(
                "[translate] 第 {}/{} 段第 {} 轮全部模型失败，稍后进入第 {} 轮...".format(
                    idx, total, round_no, round_no + 1
                ),
                file=sys.stderr,
            )
            time.sleep(3 * round_no)
    # 所有轮次均失败：发送 SMTP 告警后抛出异常
    err_msg = (
        "第 {} 段翻译失败（已循环 {} 轮，模型 {}）: {}".format(
            idx, cfg["max_rounds"], " -> ".join(models), last_err
        )
        + ". 若反复出现花括号不匹配/截断，请尝试：1) 调大 LLM_MAX_TOKENS（如 16384）；"
        "2) 更换更稳定的模型（如 gpt-4o-mini / deepseek-chat）。"
    )
    send_smtp_alert(
        cfg,
        "[dev-cleaner-zh-cn] 汉化失败：第 {}/{} 段".format(idx, total),
        "翻译任务在多次尝试后仍未成功，详情：\n\n{}\n\n"
        "仓库/任务信息：\n- 输入文件：{}\n- 主模型：{}\n- 备用模型：{}\n"
        "- 循环轮数：{}\n\n请检查模型 API 状态或调整配置后重试。".format(
            err_msg,
            os.environ.get("UPSTREAM_FILE", "?"),
            cfg["model"],
            cfg.get("fallback_model") or "（未配置）",
            cfg["max_rounds"],
        ),
    )
    raise RuntimeError(err_msg)


def translate_chunk_with_split(chunk_text, idx, total, cfg, system_prompt, kind):
    """翻译一段；若校验持续失败，将该段二等分后分别翻译再拼接。"""
    try:
        return translate_chunk(chunk_text, idx, total, cfg, system_prompt, kind)
    except RuntimeError as e:
        lines = chunk_text.splitlines()
        if len(lines) < 8:
            raise
        mid = len(lines) // 2
        print(
            "[translate] 第 {}/{} 段翻译失败，拆分为两半重试: {}".format(idx, total, e),
            file=sys.stderr,
        )
        half_a = translate_chunk("\n".join(lines[:mid]), idx, total, cfg, system_prompt, kind)
        half_b = translate_chunk("\n".join(lines[mid:]), idx, total, cfg, system_prompt, kind)
        return half_a + "\n" + half_b


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
        if cfg["chunk_lines"] <= 0:
            chunks = [original.rstrip("\n")]
        else:
            chunks = split_into_chunks(original.splitlines(), cfg["chunk_lines"])
        total = len(chunks)
        print(
            "[translate] 共 {} 段，逐段调用 LLM（模型 {}，fallback: {}）...".format(
                total, cfg["model"], cfg["fallback_model"] or "无"
            ),
            file=sys.stderr,
        )
        parts = []
        for i, chunk in enumerate(chunks, 1):
            print("[translate] 翻译第 {}/{} 段...".format(i, total), file=sys.stderr)
            parts.append(translate_chunk_with_split(chunk, i, total, cfg, system_prompt, args.kind))
        translated = "\n".join(parts)
        translated = translated.strip() + "\n"

    errors = validate(original, translated, args.kind)
    if errors:
        for e in errors:
            print("[validate] FAIL: {}".format(e), file=sys.stderr)
        print(
            "[validate] 建议：1) 调大 LLM_MAX_TOKENS（如 16384）；"
            "2) 更换更稳定的模型（如 gpt-4o-mini / deepseek-chat）；"
            "3) 重新运行 workflow 观察段级校验输出。",
            file=sys.stderr,
        )
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
