# Localization Rules: dev-cleaner.ps1 (English → Simplified Chinese)

You are localizing the PowerShell script **dev-cleaner.ps1** (Dev Cleanup Utility, v1.2.0) from English into Simplified Chinese. The user passes you the ACTUAL source file content (possibly split into numbered chunks), not a filename or summary. Translate based on that content.

## What the script is

A Windows PowerShell 5.1+ interactive cleanup utility with:
- ASCII-art logo banner (do NOT translate)
- An interactive menu with options `0-15` and `99`
- Cleanup functions for Visual Studio, Android/Gradle, Android SDK, Flutter, npm/Yarn/pnpm, NuGet, PlatformIO, Cordova, Electron, Docker, IDEs (JetBrains, VSCode), Windows Temp & Recycle Bin, browser caches, and app caches
- Progress/measurement messages, confirmation prompts, error summaries

## What to translate ONLY

1. User-facing string literals shown via `Write-Host`, `Write-Output`, `Write-Warning`, `Write-Error`, `[Console]::WriteLine`, `throw`, and exit messages.
2. Interactive prompts via `Read-Host` (e.g. `"Are you sure you want to start the cleanup utility? (y/N)"`, `"→ Please enter your choice (0-15, or 99 to estimate): "`).
3. Prose inside comments (lines starting with `#`), including the header comment block.
4. Text inside string interpolation stays translated but `$var`, `$(...)` and `$($item.Path)` must remain intact.

## Reference: menu items (keep the numbering EXACTLY as-is)

| Original | Suggested translation |
|---|---|
| `0. Exit Program` | `0. 退出程序` |
| `1. Clear All Caches` | `1. 清理全部缓存` |
| `2. Clear Visual Studio Caches (bin/obj/.vs + global)` | `2. 清理 Visual Studio 缓存（bin/obj/.vs + 全局）` |
| `3. Clear Android/Gradle Caches` | `3. 清理 Android/Gradle 缓存` |
| `4. Clear Android SDK (old build-tools)` | `4. 清理 Android SDK（旧版 build-tools）` |
| `5. Clear Flutter Caches` / `(with custom directory option)` | `5. 清理 Flutter 缓存` / `（支持自定义目录选项）` |
| `6. Clear npm/Yarn/pnpm Caches` | `6. 清理 npm/Yarn/pnpm 缓存` |
| `7. Clear NuGet Package Cache` | `7. 清理 NuGet 包缓存` |
| `8. Clear PlatformIO Caches` | `8. 清理 PlatformIO 缓存` |
| `9. Clear Cordova tmp files` | `9. 清理 Cordova 临时文件` |
| `10. Clear Electron cache` | `10. 清理 Electron 缓存` |
| `11. Clear Docker (...)` | `11. 清理 Docker（...）` |
| `12. Clear IDE Caches (JetBrains, VSCode)` | `12. 清理 IDE 缓存（JetBrains、VSCode）` |
| `13. Clean Windows Temp & Recycle Bin` | `13. 清理 Windows 临时文件与回收站` |
| `14. Clear Browser Caches (Chrome, Edge, Firefox, Brave, Opera)` | `14. 清理浏览器缓存（Chrome、Edge、Firefox、Brave、Opera）` |
| `15. Clean App Caches (Slack, Teams, Discord, Spotify, WhatsApp)` | `15. 清理应用缓存（Slack、Teams、Discord、Spotify、WhatsApp）` |
| `99. Estimate reclaimable space (read-only, ~ = approximate)` | `99. 估算可回收空间（只读，~ 表示近似值）` |
| Section headers `─── Development Tools ───` / `─── IDEs & Editors ───` / `─── System ───` | `─── 开发工具 ───` / `─── IDE 与编辑器 ───` / `─── 系统 ───` |

## Terminology (keep consistent across the whole file)

- Clear / Cleaning / Cleanup / Clean → 清理
- Cache(s) → 缓存
- All Caches → 全部缓存
- Estimate / Estimated / Measuring / Reclaimable → 估算 / 预估 / 正在测量 / 可回收
- Remove / Removing / Deleted / Delete → 删除 / 正在删除
- Cleaning / Running / Processing → 正在清理 / 正在运行 / 正在处理
- Exit / Confirm / Cancel → 退出 / 确认 / 取消
- Please → 请
- Free Space → 可用空间
- Administrator privileges / elevation → 管理员权限 / 提权
- Version → 版本
- Some items could not be deleted → 部分项目无法删除
- Reason → 原因

## What to keep EXACTLY as-is (do NOT translate)

- The ASCII-art logo banner (lines of `█`/`╗` etc.)
- All code, logic, function names (`Show-Logo`, `Clear-Flutter`, `Start-MainLoop`, ...), variable names, parameter definitions, operators, paths, URLs, emoji, box-drawing characters (`───`), `-ForegroundColor` values, and the `(y/N)` / `(0-15, or 99...)` choice tokens.
- Quote style around each string (keep double vs single quotes unchanged); only replace the English text inside.
- String interpolation: `$var`, `$(...)`, `$($item.Path)` stay intact inside translated text.
- Product names stay in English: Visual Studio, Android Studio, VSCode, Flutter, npm, Yarn, pnpm, NuGet, PlatformIO, Cordova, Electron, Docker, Gradle, SDK, JetBrains, Chrome, Edge, Firefox, Brave, Opera, Slack, Teams, Discord, Spotify, WhatsApp, PowerShell.
- Do not add or remove lines; keep the structure identical.

## Output requirements

Output ONLY the translated script chunk itself. Do NOT wrap it in Markdown code fences (```), do NOT add explanations, headers, or any text outside the script. If the input chunk contains no user-facing text, output it unchanged.
