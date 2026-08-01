# -----------------------------------------------------------------------------
# Dev Cleanup Utility - Windows PowerShell Edition
# -----------------------------------------------------------------------------
# 版本：1.2.0
# 平台：Windows（PowerShell 5.1+）
# 仓库：https://github.com/jemishavasoya/dev-cleaner
# -----------------------------------------------------------------------------

param(
    [switch]$Help,
    [switch]$Version,
    [string]$FlutterDir,
    [string]$VsDir
)

# --- 全局变量 ---
$SCRIPT_VERSION = "1.2.0"
$GITHUB_REPO = "https://github.com/jemishavasoya/dev-cleaner"

# --- 错误跟踪 ---
$script:FailedItems = [System.Collections.ArrayList]::new()

# --- 估算状态 ---
$script:Estimates = @{}
$script:EstimatesReady = $false

# --- 辅助函数 ---

function Show-Logo {
    Write-Host ""
    Write-Host "██████╗ ███████╗██╗    ██╗     ██████╗██╗     ███████╗ █████╗ ███╗   ██╗███████╗██████╗" -ForegroundColor Cyan
    Write-Host "██╔══██╗██╔════╝██║    ██║    ██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║██╔════╝██╔══██╗" -ForegroundColor Cyan
    Write-Host "██║  ██║█████╗  ██║    ██║    ██║     ██║     █████╗  ███████║██╔██╗ ██║█████╗  ██████╔╝" -ForegroundColor Cyan
    Write-Host "██║  ██║██╔══╝  ╚██╗ ██╔╝     ██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║██╔══╝  ██╔══██╗" -ForegroundColor Cyan
    Write-Host "██████╔╝███████╗ ╚████╔╝      ╚██████╗███████╗███████╗██║  ██║██║ ╚████║███████╗██║  ██║" -ForegroundColor Cyan
    Write-Host "╚═════╝ ╚══════╝  ╚═══╝        ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-HeaderLine {
    param([string]$Char = "─")
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -lt 1) { $width = 80 }
    } catch {
        $width = 80  # 非交互会话的备用值
    }
    Write-Host ($Char * $width)
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "➤ $Title" -ForegroundColor Blue
    Write-HeaderLine "─"
}

function Write-Item {
    param(
        [string]$Icon,
        [string]$Color,
        [string]$Text
    )
    Write-Host "$Icon $Text" -ForegroundColor $Color
}

function Get-DiskSpace {
    $drive = Get-PSDrive -Name ($PWD.Drive.Name) -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        return "$freeGB GB"
    }
    return "未知"
}

# --- 估算辅助函数（只读：不会删除任何内容）---

function Get-PathSizeBytes {
    param([string[]]$Paths)
    [int64]$total = 0
    foreach ($pattern in $Paths) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $items = Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try {
                if ($item.PSIsContainer) {
                    $sum = (Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum).Sum
                    if ($sum) { $total += [int64]$sum }
                } else {
                    $total += [int64]$item.Length
                }
            } catch { }
        }
    }
    return $total
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB)     { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    elseif ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    elseif ($Bytes -ge 1KB) { return ("{0:N0} KB" -f ($Bytes / 1KB)) }
    else                    { return ("{0} B" -f $Bytes) }
}

# 将 Docker 尺寸字符串（Docker 使用十进制单位：B/kB/MB/GB/TB，
# 例如 "1.02GB"、"728.5MB"、"32.8kB"、"0B"）转换为字节，以便将 Docker 自身
# 报告的尺寸求和并像其他估算一样传入 Format-Size。后缀顺序很重要：
# kB/MB/GB/TB 都以 "B" 结尾，因此裸 "B" 的情况必须最后检查。Docker 始终
# 使用点号作为小数分隔符，因此使用 InvariantCulture。只读。
function Convert-DockerSize {
    param([string]$Size)
    if ([string]::IsNullOrWhiteSpace($Size)) { return [int64]0 }
    $s = $Size.Trim()
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        if     ($s -match '^([\d.]+)TB$') { return [int64]([double]::Parse($Matches[1], $ci) * 1e12) }
        elseif ($s -match '^([\d.]+)GB$') { return [int64]([double]::Parse($Matches[1], $ci) * 1e9) }
        elseif ($s -match '^([\d.]+)MB$') { return [int64]([double]::Parse($Matches[1], $ci) * 1e6) }
        elseif ($s -match '^([\d.]+)kB$') { return [int64]([double]::Parse($Matches[1], $ci) * 1e3) }
        elseif ($s -match '^([\d.]+)B$')  { return [int64][double]::Parse($Matches[1], $ci) }
    } catch { }
    return [int64]0
}

function Set-Estimate {
    param([string]$Key, [string]$Label)
    $script:Estimates[$Key] = $Label
}

# 为稳定的分类键返回 " (Estimate: <label>)"，若尚未计算则返回 ""。
# 键为字符串（非菜单编号），以便安全地重新编号。
function Get-Est {
    param([string]$Key)
    if (-not $script:EstimatesReady) { return "" }
    if ($script:Estimates.ContainsKey($Key) -and $script:Estimates[$Key]) {
        return " (Estimate: $($script:Estimates[$Key]))"
    }
    return ""
}

# --- 管理员提权函数 ---

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    if (-not (Test-Administrator)) {
        Write-Host "此脚本需要管理员权限。" -ForegroundColor Yellow
        Write-Host "正在以提权方式重新启动..." -ForegroundColor Yellow

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

        if ($FlutterDir) { $arguments += " -FlutterDir `"$FlutterDir`"" }
        if ($VsDir) { $arguments += " -VsDir `"$VsDir`"" }

        Start-Process PowerShell -Verb RunAs -ArgumentList $arguments
        exit
    }
}

# --- 错误跟踪函数 ---

function Remove-SafelyWithTracking {
    param(
        [string]$Path,
        [string]$Description
    )

    try {
        if (Test-Path $Path) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Item "✓" "Green" "已删除：$Description"
        }
    }
    catch {
        $script:FailedItems.Add([PSCustomObject]@{
            Path = $Path
            Reason = $_.Exception.Message
        }) | Out-Null
    }
}

function Show-FailureSummary {
    if ($script:FailedItems.Count -gt 0) {
        Write-Host ""
        Write-Host "部分项目无法删除：" -ForegroundColor Yellow
        foreach ($item in $script:FailedItems) {
            Write-Host "  - $($item.Path)" -ForegroundColor Red
            Write-Host "    原因：$($item.Reason)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    $script:FailedItems.Clear()
}

# --- 清理函数 ---

function Clear-VisualStudio {
    param([string]$SearchDir = ".")

    Write-Item "✓" "Green" "正在从以下目录清理 Visual Studio 项目：$SearchDir"

    if (-not (Test-Path $SearchDir)) {
        Write-Item "✕" "Red" "未找到目录：$SearchDir"
        return
    }

    # 项目级清理
    $solutionFiles = Get-ChildItem -Path $SearchDir -Filter "*.sln" -Recurse -ErrorAction SilentlyContinue
    $projectFiles = Get-ChildItem -Path $SearchDir -Filter "*.csproj" -Recurse -ErrorAction SilentlyContinue

    $cleanedCount = 0

    foreach ($sln in $solutionFiles) {
        $slnDir = $sln.DirectoryName
        Write-Host "  正在清理解决方案：$slnDir" -ForegroundColor Cyan

        Remove-SafelyWithTracking -Path "$slnDir\.vs" -Description "$slnDir 中的 .vs 文件夹"
        $cleanedCount++
    }

    foreach ($proj in $projectFiles) {
        $projDir = $proj.DirectoryName
        Write-Host "  正在清理项目：$projDir" -ForegroundColor Cyan

        Remove-SafelyWithTracking -Path "$projDir\bin" -Description "$projDir 中的 bin 文件夹"
        Remove-SafelyWithTracking -Path "$projDir\obj" -Description "$projDir 中的 obj 文件夹"
        $cleanedCount++
    }

    if ($cleanedCount -gt 0) {
        Write-Item "✓" "Green" "已清理 $cleanedCount 个 Visual Studio 项目/解决方案"
    } else {
        Write-Item "ℹ️" "Yellow" "未在以下目录中找到 Visual Studio 项目：$SearchDir"
    }

    # 全局 Visual Studio 缓存
    Write-Item "✓" "Green" "正在清理全局 Visual Studio 缓存..."

    $vsVersions = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\VisualStudio" -Directory -ErrorAction SilentlyContinue
    foreach ($vsVersion in $vsVersions) {
        Remove-SafelyWithTracking -Path "$($vsVersion.FullName)\ComponentModelCache" -Description "ComponentModelCache"
        Remove-SafelyWithTracking -Path "$($vsVersion.FullName)\MEFCacheData" -Description "MEFCacheData"
        Remove-SafelyWithTracking -Path "$($vsVersion.FullName)\Designer\ShadowCache" -Description "Designer ShadowCache"
        Remove-SafelyWithTracking -Path "$($vsVersion.FullName)\ImageLibrary" -Description "ImageLibrary"
    }
}

function Clear-AndroidGradle {
    if (Test-Path "$env:USERPROFILE\.gradle") {
        Write-Item "✓" "Green" "正在清理 Gradle 缓存..."
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.gradle\caches" -Description "Gradle 缓存"
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.gradle\daemon" -Description "Gradle 守护进程"
        # 已下载的 Gradle 发行版；下次运行 wrapper 时会重新获取。
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.gradle\wrapper" -Description "Gradle wrapper 发行版"
    } else {
        Write-Item "✕" "Yellow" "未找到 Gradle 目录。已跳过。"
    }

    if (Test-Path "$env:USERPROFILE\.android") {
        Write-Item "✓" "Green" "正在清理 Android 工具缓存..."
        # ~/.android 下的旧版 AVD/构建缓存；按需重新生成。
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.android\cache" -Description "Android 缓存"
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.android\build-cache" -Description "Android 构建缓存"
    }

    Write-Item "✓" "Green" "正在清理 Android Studio 缓存..."
    $androidStudioPaths = @(
        "$env:LOCALAPPDATA\Google\AndroidStudio*",
        "$env:LOCALAPPDATA\JetBrains\AndroidStudio*"
    )

    foreach ($pattern in $androidStudioPaths) {
        $paths = Get-ChildItem -Path (Split-Path $pattern -Parent) -Filter (Split-Path $pattern -Leaf) -Directory -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            Remove-SafelyWithTracking -Path $path.FullName -Description "Android Studio 缓存：$($path.Name)"
        }
    }
}

function Clear-AndroidSdk {
    $sdkPath = "$env:LOCALAPPDATA\Android\Sdk"

    if (Test-Path $sdkPath) {
        Write-Item "✓" "Green" "正在清理旧版 Android SDK build-tools（保留最新 2 个版本）..."

        $buildToolsPath = "$sdkPath\build-tools"
        if (Test-Path $buildToolsPath) {
            $versions = Get-ChildItem -Path $buildToolsPath -Directory | Sort-Object Name -Descending
            $toRemove = $versions | Select-Object -Skip 2

            foreach ($version in $toRemove) {
                Remove-SafelyWithTracking -Path $version.FullName -Description "旧版 build-tools：$($version.Name)"
            }
        }

        Write-Item "✓" "Green" "正在清理 SDK 临时文件..."
        Remove-SafelyWithTracking -Path "$sdkPath\.temp" -Description "SDK 临时文件夹"
    } else {
        Write-Item "✕" "Yellow" "未找到 Android SDK。已跳过。"
    }
}

function Clear-Flutter {
    param([string]$SearchDir = ".")

    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        Write-Item "✕" "Yellow" "未找到 Flutter 命令。已跳过。"
        return
    }

    Write-Item "✓" "Green" "正在从以下目录递归清理 Flutter 项目：$SearchDir"

    if (-not (Test-Path $SearchDir)) {
        Write-Item "✕" "Red" "未找到目录：$SearchDir"
        return
    }

    $pubspecFiles = Get-ChildItem -Path $SearchDir -Filter "pubspec.yaml" -Recurse -ErrorAction SilentlyContinue
    $cleanedCount = 0

    foreach ($pubspec in $pubspecFiles) {
        $projectDir = $pubspec.DirectoryName
        Write-Host "  正在清理：$projectDir" -ForegroundColor Cyan

        Push-Location $projectDir

        # FVM 清理
        if (Test-Path ".fvm") {
            Write-Host "    正在删除 FVM 缓存..." -ForegroundColor DarkGray
            Remove-SafelyWithTracking -Path ".fvm" -Description "FVM 文件夹"
        }
        if (Test-Path ".fvmrc") {
            Remove-SafelyWithTracking -Path ".fvmrc" -Description "FVM 配置文件"
        }

        # Flutter 构建产物
        Write-Host "    正在删除 Flutter 构建产物..." -ForegroundColor DarkGray
        Remove-SafelyWithTracking -Path "build" -Description "build 文件夹"
        Remove-SafelyWithTracking -Path ".dart_tool" -Description ".dart_tool 文件夹"
        Remove-SafelyWithTracking -Path ".packages" -Description ".packages 文件"
        Remove-SafelyWithTracking -Path "pubspec.lock" -Description "pubspec.lock 文件"

        # Android 产物
        if (Test-Path "android") {
            Write-Host "    正在删除 Android 构建产物..." -ForegroundColor DarkGray
            Remove-SafelyWithTracking -Path "android\.gradle" -Description "Android Gradle 缓存"
            Remove-SafelyWithTracking -Path "android\build" -Description "Android 构建文件夹"
            Remove-SafelyWithTracking -Path "android\app\build" -Description "Android 应用构建文件夹"
        }

        # Windows 产物
        if (Test-Path "windows\flutter\ephemeral") {
            Write-Host "    正在删除 Windows 临时文件..." -ForegroundColor DarkGray
            Remove-SafelyWithTracking -Path "windows\flutter\ephemeral" -Description "Windows 临时文件夹"
        }

        Pop-Location
        $cleanedCount++
        Write-Host "  ✅ 已清理 $projectDir" -ForegroundColor Green
    }

    if ($cleanedCount -gt 0) {
        Write-Item "✓" "Green" "已清理 $cleanedCount 个 Flutter 项目"
    } else {
        Write-Item "ℹ️" "Yellow" "未在以下目录中找到 Flutter 项目：$SearchDir"
    }

    Write-Item "✓" "Green" "正在清理 Flutter 全局缓存..."
    try {
        flutter cache clean 2>$null
    } catch {
        Write-Item "✕" "Yellow" "无法清理 Flutter 全局缓存"
    }
}

function Clear-NpmYarnPnpm {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Item "✓" "Green" "正在清理 npm 缓存..."
        try {
            npm cache clean --force 2>$null
        } catch {
            Write-Item "✕" "Yellow" "无法清理 npm 缓存"
        }
    } else {
        Write-Item "✕" "Yellow" "未找到 npm。已跳过。"
    }

    if (Get-Command yarn -ErrorAction SilentlyContinue) {
        Write-Item "✓" "Green" "正在清理 yarn 缓存..."
        try {
            yarn cache clean 2>$null
        } catch {
            Write-Item "✕" "Yellow" "无法清理 yarn 缓存"
        }
    } else {
        Write-Item "✕" "Yellow" "未找到 yarn。已跳过。"
    }

    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        Write-Item "✓" "Green" "正在修剪 pnpm 存储..."
        try {
            pnpm store prune 2>$null
        } catch {
            Write-Item "✕" "Yellow" "无法修剪 pnpm 存储"
        }
    } else {
        Write-Item "✕" "Yellow" "未找到 pnpm。已跳过。"
    }

    # 手动清理 pnpm 缓存
    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\pnpm\store" -Description "pnpm 存储"
    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\pnpm-cache" -Description "pnpm 缓存"
}

function Clear-NuGet {
    Write-Item "✓" "Green" "正在清理 NuGet 缓存..."

    Remove-SafelyWithTracking -Path "$env:USERPROFILE\.nuget\packages" -Description "NuGet 全局包"
    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\NuGet\v3-cache" -Description "NuGet HTTP 缓存"
    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\NuGet\plugins-cache" -Description "NuGet 插件缓存"
    Remove-SafelyWithTracking -Path "$env:TEMP\NuGetScratch" -Description "NuGet 临时文件"

    # 备选方案：如果可用则使用 dotnet CLI
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        try {
            dotnet nuget locals all --clear 2>$null
            Write-Item "✓" "Green" "已通过 dotnet CLI 清理 NuGet 缓存"
        } catch {
            Write-Item "ℹ️" "Yellow" "已跳过 dotnet nuget locals 命令"
        }
    }
}

function Clear-PlatformIO {
    $pioBin = "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe"

    if (-not (Test-Path $pioBin)) {
        if (Get-Command pio -ErrorAction SilentlyContinue) {
            $pioBin = "pio"
        } else {
            Write-Item "✕" "Yellow" "未找到 PlatformIO。已跳过。"
            return
        }
    }

    Write-Item "✓" "Green" "正在清理 PlatformIO 项目构建..."

    $platformioFiles = Get-ChildItem -Path $env:USERPROFILE -Filter "platformio.ini" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.FullName -notmatch "\\Library\\" }

    foreach ($file in $platformioFiles) {
        $projectDir = $file.DirectoryName
        Write-Host "  正在运行 pio clean：$projectDir" -ForegroundColor Cyan

        Push-Location $projectDir
        try {
            & $pioBin run -t clean 2>$null
        } catch {
            Write-Item "✕" "Yellow" "无法清理 $projectDir"
        }
        Pop-Location
    }
}

function Clear-IdeCaches {
    Write-Item "✓" "Green" "正在清理 JetBrains IDE 缓存..."

    $jetBrainsVersions = Get-ChildItem -Path "$env:LOCALAPPDATA\JetBrains" -Directory -ErrorAction SilentlyContinue
    foreach ($version in $jetBrainsVersions) {
        Remove-SafelyWithTracking -Path "$($version.FullName)\caches" -Description "JetBrains 缓存：$($version.Name)"
        Remove-SafelyWithTracking -Path "$($version.FullName)\index" -Description "JetBrains 索引：$($version.Name)"
        Remove-SafelyWithTracking -Path "$($version.FullName)\tmp" -Description "JetBrains 临时文件：$($version.Name)"
    }

    Write-Item "✓" "Green" "正在清理 VSCode 缓存..."
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code\Cache" -Description "VSCode 缓存"
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code\CachedData" -Description "VSCode 缓存数据"
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code\CachedExtensionVSIXs" -Description "VSCode 缓存扩展 VSIX"
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code\User\workspaceStorage" -Description "VSCode 工作区存储"

    Write-Item "✓" "Green" "正在清理 VSCode Insiders 缓存..."
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code - Insiders\Cache" -Description "VSCode Insiders 缓存"
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code - Insiders\CachedData" -Description "VSCode Insiders 缓存数据"
}

function Clear-WindowsTemp {
    Write-Item "✓" "Green" "正在清理用户临时文件..."

    Get-ChildItem -Path $env:TEMP -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-SafelyWithTracking -Path $_.FullName -Description "用户临时文件：$($_.Name)"
    }

    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\Temp" -Description "本地临时文件夹"

    Write-Item "✓" "Green" "正在清空回收站..."
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Item "✓" "Green" "回收站已清空"
    } catch {
        Write-Item "✕" "Yellow" "无法清空回收站"
    }

    if (Test-Administrator) {
        Write-Item "✓" "Green" "正在清理系统临时文件（管理员）..."

        Get-ChildItem -Path "C:\Windows\Temp" -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-SafelyWithTracking -Path $_.FullName -Description "系统临时文件：$($_.Name)"
        }

        Write-Item "✓" "Green" "正在清理 Windows 更新缓存（可选）..."
        Get-ChildItem -Path "C:\Windows\SoftwareDistribution\Download" -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-SafelyWithTracking -Path $_.FullName -Description "Windows 更新：$($_.Name)"
        }
    } else {
        Write-Item "ℹ️" "Yellow" "系统临时文件清理需要管理员权限（已跳过）"
    }
}

function Clear-BrowserCaches {
    $browsers = @{
        "Chrome" = @{
            "Cache" = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
            "CodeCache" = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache"
        }
        "Edge" = @{
            "Cache" = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
            "CodeCache" = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"
        }
        "Brave" = @{
            "Cache" = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache"
            "CodeCache" = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Code Cache"
        }
        "Opera" = @{
            "Cache" = "$env:APPDATA\Opera Software\Opera Stable\Cache"
        }
        "Opera GX" = @{
            "Cache" = "$env:APPDATA\Opera Software\Opera GX Stable\Cache"
        }
    }

    foreach ($browser in $browsers.Keys) {
        $found = $false
        foreach ($cacheType in $browsers[$browser].Keys) {
            $path = $browsers[$browser][$cacheType]
            if (Test-Path $path) {
                $found = $true
                Remove-SafelyWithTracking -Path $path -Description "$browser $cacheType"
            }
        }
        if (-not $found) {
            Write-Item "✕" "Yellow" "$browser 缓存未找到。已跳过。"
        }
    }

    # Firefox（多个配置文件）
    $firefoxProfiles = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $firefoxProfiles) {
        Write-Item "✓" "Green" "正在清理 Firefox 缓存..."
        $profiles = Get-ChildItem -Path $firefoxProfiles -Directory -ErrorAction SilentlyContinue
        foreach ($profile in $profiles) {
            Remove-SafelyWithTracking -Path "$($profile.FullName)\cache2" -Description "Firefox 缓存：$($profile.Name)"
        }
    } else {
        Write-Item "✕" "Yellow" "未找到 Firefox 缓存。已跳过。"
    }
}

function Clear-AppContainers {
    Write-Item "✓" "Green" "正在清理应用容器缓存..."

    # Slack
    if (Test-Path "$env:APPDATA\Slack") {
        Remove-SafelyWithTracking -Path "$env:APPDATA\Slack\Cache" -Description "Slack 缓存"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Slack\Service Worker\CacheStorage" -Description "Slack Service Worker"
    }

    # Microsoft Teams 经典版
    if (Test-Path "$env:APPDATA\Microsoft\Teams") {
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\Cache" -Description "Teams 缓存"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\blob_storage" -Description "Teams blob 存储"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\databases" -Description "Teams 数据库"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\GPUCache" -Description "Teams GPU 缓存"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\IndexedDB" -Description "Teams IndexedDB"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\Local Storage" -Description "Teams 本地存储"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\tmp" -Description "Teams 临时文件"
    }

    # Microsoft Teams 新版
    $teamsNew = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"
    if (Test-Path $teamsNew) {
        Remove-SafelyWithTracking -Path $teamsNew -Description "Teams 新版缓存"
    }

    # Discord
    if (Test-Path "$env:APPDATA\discord") {
        Remove-SafelyWithTracking -Path "$env:APPDATA\discord\Cache" -Description "Discord 缓存"
        Remove-SafelyWithTracking -Path "$env:APPDATA\discord\Code Cache" -Description "Discord 代码缓存"
    }

    # Spotify
    if (Test-Path "$env:LOCALAPPDATA\Spotify") {
        Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\Spotify\Storage" -Description "Spotify 存储"
    }
    if (Test-Path "$env:APPDATA\Spotify") {
        Remove-SafelyWithTracking -Path "$env:APPDATA\Spotify" -Description "Spotify 数据"
    }

    # WhatsApp
    if (Test-Path "$env:LOCALAPPDATA\WhatsApp") {
        Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\WhatsApp\Cache" -Description "WhatsApp 缓存"
    }

    # WhatsApp UWP
    $whatsappUwp = Get-ChildItem -Path "$env:LOCALAPPDATA\Packages" -Filter "*WhatsApp*" -Directory -ErrorAction SilentlyContinue
    foreach ($pkg in $whatsappUwp) {
        Remove-SafelyWithTracking -Path "$($pkg.FullName)\LocalCache" -Description "WhatsApp UWP 缓存"
    }
}

function Clear-Cordova {
    $cordovaPath = "$env:USERPROFILE\.cordova"

    if (Test-Path $cordovaPath) {
        Write-Item "✓" "Green" "正在清理 Cordova 临时文件..."
        # Cordova 会在 lib\tmp* 下留下过时的 npm tarball/解压文件
        $tmpDirs = Get-ChildItem -Path "$cordovaPath\lib" -Filter "tmp*" -Force -ErrorAction SilentlyContinue
        foreach ($d in $tmpDirs) {
            Remove-SafelyWithTracking -Path $d.FullName -Description "Cordova 临时文件：$($d.Name)"
        }
    } else {
        Write-Item "✕" "Yellow" "未找到 Cordova。已跳过。"
    }
}

function Clear-Electron {
    $electronPath = "$env:LOCALAPPDATA\electron"

    if (Test-Path $electronPath) {
        Write-Item "✓" "Green" "正在清理 Electron 缓存..."
        # 缓存的预构建二进制文件；清空内容，保留 electron 期望的目录
        $items = Get-ChildItem -Path $electronPath -Force -ErrorAction SilentlyContinue
        foreach ($i in $items) {
            Remove-SafelyWithTracking -Path $i.FullName -Description "Electron 缓存：$($i.Name)"
        }
    } else {
        Write-Item "✕" "Yellow" "未找到 Electron。已跳过。"
    }
}

# -Interactive 通过二次提示提供更深度的 `prune -af`。"清理全部缓存"
# 不带此参数调用，因此批量运行不会意外删除带标签的镜像。
function Clear-Docker {
    param([switch]$Interactive)
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Item "✕" "Yellow" "未找到 Docker。已跳过。"
        return
    }
    # `Get-Command` 仅证明 CLI 存在；守护进程可能仍未运行。
    $dfOut = docker system df 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $dfOut) {
        Write-Item "✕" "Yellow" "Docker 守护进程未运行。已跳过。"
        return
    }
    Write-Item "✓" "Green" "Docker 磁盘使用情况："
    $dfOut | ForEach-Object { Write-Host $_ }

    # `prune -f` 删除已停止的容器、未使用的网络、悬空（未标记）镜像
    # 和未使用的构建缓存；-f 跳过 Docker 自身的确认（脚本已确认）。
    # `-a` 还会删除容器未使用的 EVERY 镜像，包括可能仅存在于私有
    # 注册表的带标签镜像——因此通过提示选择启用，不在批量"清理全部缓存"路径中。
    # （--volumes 在两种情况下均省略：它会删除命名卷数据，如数据库。）
    $pruneArgs = @('-f')
    if ($Interactive) {
        Write-Host ""
        Write-Host "是否也删除未使用但已标记的镜像？可释放更多空间，但需要重新拉取/重新构建（例如私有注册表镜像）。(y/N)：" -ForegroundColor Yellow
        $ans = Read-Host
        if ($ans -eq 'y') { $pruneArgs = @('-af') }
    }
    docker system prune @pruneArgs
}

# --- 可回收空间估算 ---
# 只读：计算每个清理选项将删除的当前磁盘大小，然后 Show-Menu 在每个条目旁显示。
# 分类使用稳定的字符串键，以便安全地重新编号菜单。
# 重要：保持这些路径列表与上面的 Clear-* 函数同步。

function Invoke-EstimateAll {
    Write-Item "🔍" "Cyan" "正在计算估算值...（可能需要一些时间）"
    [int64]$total = 0
    [int64]$b = 0

    # Visual Studio - 仅全局缓存（~）；不扫描项目 bin/obj/.vs
    Write-Host "  正在测量 Visual Studio 缓存..." -ForegroundColor DarkGray
    $vsPaths = @()
    $vsVersions = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\VisualStudio" -Directory -ErrorAction SilentlyContinue
    foreach ($v in $vsVersions) {
        $vsPaths += "$($v.FullName)\ComponentModelCache"
        $vsPaths += "$($v.FullName)\MEFCacheData"
        $vsPaths += "$($v.FullName)\Designer\ShadowCache"
        $vsPaths += "$($v.FullName)\ImageLibrary"
    }
    $b = Get-PathSizeBytes $vsPaths
    Set-Estimate "visualstudio" ("~" + (Format-Size $b)); $total += $b

    # Android / Gradle
    Write-Host "  正在测量 Android/Gradle 缓存..." -ForegroundColor DarkGray
    $b = Get-PathSizeBytes @(
        "$env:USERPROFILE\.gradle\caches",
        "$env:USERPROFILE\.gradle\daemon",
        "$env:USERPROFILE\.gradle\wrapper",
        "$env:USERPROFILE\.android\cache",
        "$env:USERPROFILE\.android\build-cache",
        "$env:LOCALAPPDATA\Google\AndroidStudio*",
        "$env:LOCALAPPDATA\JetBrains\AndroidStudio*"
    )
    Set-Estimate "android" (Format-Size $b); $total += $b

    # Android SDK - 旧版 build-tools（保留最新 2 个）+ .temp
    Write-Host "  正在测量 Android SDK..." -ForegroundColor DarkGray
    $sdkPath = "$env:LOCALAPPDATA\Android\Sdk"
    $sdkPaths = @("$sdkPath\.temp")
    $btPath = "$sdkPath\build-tools"
    if (Test-Path $btPath) {
        $old = Get-ChildItem -Path $btPath -Directory -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -Skip 2
        foreach ($o in $old) { $sdkPaths += $o.FullName }
    }
    $b = Get-PathSizeBytes $sdkPaths
    Set-Estimate "androidsdk" (Format-Size $b); $total += $b

    # Flutter - 仅全局缓存（~）
    Write-Host "  正在测量 Flutter 全局缓存..." -ForegroundColor DarkGray
    $flPaths = @("$env:LOCALAPPDATA\Pub\Cache", "$env:APPDATA\Pub\Cache")
    $fcmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($fcmd) {
        $fbin = Split-Path $fcmd.Source -Parent
        if ($fbin) { $flPaths += (Join-Path $fbin "cache") }
    }
    $b = Get-PathSizeBytes $flPaths
    Set-Estimate "flutter" ("~" + (Format-Size $b)); $total += $b

    # npm / Yarn / pnpm（~）
    Write-Host "  正在测量 npm/Yarn/pnpm 缓存..." -ForegroundColor DarkGray
    $npmPaths = @("$env:LOCALAPPDATA\pnpm\store", "$env:LOCALAPPDATA\pnpm-cache")
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $nc = (npm config get cache 2>$null | Select-Object -First 1)
        if ($nc) { $nc = "$nc".Trim() }
        if ($nc -and $nc -ne "undefined" -and $nc -ne "null") { $npmPaths += (Join-Path $nc "_cacache") }
    }
    if (Get-Command yarn -ErrorAction SilentlyContinue) {
        $yd = (yarn cache dir 2>$null | Select-Object -First 1)
        if ($yd) { $npmPaths += "$yd".Trim() }
    }
    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        $pd = (pnpm store path 2>$null | Select-Object -First 1)
        if ($pd) { $npmPaths += "$pd".Trim() }
    }
    $b = Get-PathSizeBytes $npmPaths
    Set-Estimate "npm" ("~" + (Format-Size $b)); $total += $b

    # NuGet
    Write-Host "  正在测量 NuGet 缓存..." -ForegroundColor DarkGray
    $b = Get-PathSizeBytes @(
        "$env:USERPROFILE\.nuget\packages",
        "$env:LOCALAPPDATA\NuGet\v3-cache",
        "$env:LOCALAPPDATA\NuGet\plugins-cache",
        "$env:TEMP\NuGetScratch"
    )
    Set-Estimate "nuget" (Format-Size $b); $total += $b

    # PlatformIO - 仅全局缓存（~）
    Write-Host "  正在测量 PlatformIO 全局缓存..." -ForegroundColor DarkGray
    $b = Get-PathSizeBytes @("$env:USERPROFILE\.platformio\.cache")
    Set-Estimate "platformio" ("~" + (Format-Size $b)); $total += $b

    # IDE 缓存（JetBrains + VSCode）
    Write-Host "  正在测量 IDE 缓存..." -ForegroundColor DarkGray
    $idePaths = @(
        "$env:APPDATA\Code\Cache",
        "$env:APPDATA\Code\CachedData",
        "$env:APPDATA\Code\User\workspaceStorage",
        "$env:APPDATA\Code - Insiders\Cache",
        "$env:APPDATA\Code - Insiders\CachedData"
    )
    $jb = Get-ChildItem -Path "$env:LOCALAPPDATA\JetBrains" -Directory -ErrorAction SilentlyContinue
    foreach ($j in $jb) {
        $idePaths += "$($j.FullName)\caches"
        $idePaths += "$($j.FullName)\index"
        $idePaths += "$($j.FullName)\tmp"
    }
    $b = Get-PathSizeBytes $idePaths
    Set-Estimate "ide" (Format-Size $b); $total += $b

    # Windows 临时文件（~）- 不测量回收站/管理员系统临时文件
    Write-Host "  正在测量 Windows 临时文件..." -ForegroundColor DarkGray
    $b = Get-PathSizeBytes @("$env:TEMP", "$env:LOCALAPPDATA\Temp")
    Set-Estimate "windowstemp" ("~" + (Format-Size $b)); $total += $b

    # 浏览器缓存
    Write-Host "  正在测量浏览器缓存..." -ForegroundColor DarkGray
    $brPaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Code Cache",
        "$env:APPDATA\Opera Software\Opera Stable\Cache",
        "$env:APPDATA\Opera Software\Opera GX Stable\Cache"
    )
    $ffProfiles = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ffProfiles) {
        $profs = Get-ChildItem -Path $ffProfiles -Directory -ErrorAction SilentlyContinue
        foreach ($p in $profs) { $brPaths += "$($p.FullName)\cache2" }
    }
    $b = Get-PathSizeBytes $brPaths
    Set-Estimate "browser" (Format-Size $b); $total += $b

    # Cordova 临时文件
    Write-Host "  正在测量 Cordova 临时文件..." -ForegroundColor DarkGray
    $cordovaTmp = @()
    $cordovaDirs = Get-ChildItem -Path "$env:USERPROFILE\.cordova\lib" -Filter "tmp*" -Force -ErrorAction SilentlyContinue
    foreach ($t in $cordovaDirs) { $cordovaTmp += $t.FullName }
    $b = Get-PathSizeBytes $cordovaTmp
    Set-Estimate "cordova" (Format-Size $b); $total += $b

    # Electron 缓存
    Write-Host "  正在测量 Electron 缓存..." -ForegroundColor DarkGray
    $electronCache = @()
    $electronItems = Get-ChildItem -Path "$env:LOCALAPPDATA\electron" -Force -ErrorAction SilentlyContinue
    foreach ($e in $electronItems) { $electronCache += $e.FullName }
    $b = Get-PathSizeBytes $electronCache
    Set-Estimate "electron" (Format-Size $b); $total += $b

    # Docker 不是基于路径的：直接询问 Docker 本身（只读）。两个数值，
    # 因为选项 11 提供两种 prune 模式：
    #   -f  ：可回收的构建缓存 + 悬空（未标记）镜像
    #   -af ：上述内容 + 容器未使用的所有镜像（包括带标签的）
    # 可回收的构建缓存来自 `system df` 摘要（Docker 计算正确；仅其 Images 数据在使用
    # containerd 镜像存储时不可靠）。每个镜像的尺寸来自 `system df -v`，
    # 对 0 容器行求和 UNIQUE SIZE，以避免重复计算共享层。近似值，因此不加入字节总数。
    Write-Host "  正在测量 Docker 可回收空间..." -ForegroundColor DarkGray
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $dfFmt = docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $dfFmt) {
            $cacheTok = (($dfFmt | Where-Object { $_ -like 'Build Cache|*' }) -split '\|', 2)[1] -replace ' *\(.*', ''
            [int64]$cacheBytes = Convert-DockerSize $cacheTok
            # 解析 "Images space usage:" 表格。CREATED 是多词
            # （"4 days ago"），因此从右侧索引列：最后一列 = CONTAINERS，
            # 倒数第二列 = UNIQUE SIZE。悬空镜像的 REPOSITORY 为 <none>。
            [int64]$danglingBytes = 0
            [int64]$allUnusedBytes = 0
            $inImages = $false
            foreach ($line in (docker system df -v 2>$null)) {
                if ($line -match '^Images space usage:') { $inImages = $true; continue }
                if (-not $inImages) { continue }
                if ($line -match '^REPOSITORY') { continue }
                if ([string]::IsNullOrWhiteSpace($line)) { $inImages = $false; continue }
                $cols = $line.Trim() -split '\s+'
                if ($cols.Count -lt 3 -or $cols[-1] -ne '0') { continue }
                $uniq = Convert-DockerSize $cols[-2]
                $allUnusedBytes += $uniq
                if ($cols[0] -eq '<none>') { $danglingBytes += $uniq }
            }
            [int64]$fBytes = $cacheBytes + $danglingBytes
            [int64]$afBytes = $cacheBytes + $allUnusedBytes
            if ($afBytes -gt $fBytes) {
                Set-Estimate "docker" "~$(Format-Size $fBytes) → ~$(Format-Size $afBytes)（使用 -a）"
            } else {
                Set-Estimate "docker" "~$(Format-Size $fBytes)"
            }
        } else {
            Set-Estimate "docker" "n/a（守护进程未运行）"
        }
    } else {
        Set-Estimate "docker" "n/a（未找到 docker）"
    }

    # 应用容器
    Write-Host "  正在测量应用缓存..." -ForegroundColor DarkGray
    $acPaths = @(
        "$env:APPDATA\Slack\Cache",
        "$env:APPDATA\Slack\Service Worker\CacheStorage",
        "$env:APPDATA\Microsoft\Teams\Cache",
        "$env:APPDATA\Microsoft\Teams\blob_storage",
        "$env:APPDATA\Microsoft\Teams\databases",
        "$env:APPDATA\Microsoft\Teams\GPUCache",
        "$env:APPDATA\Microsoft\Teams\IndexedDB",
        "$env:APPDATA\Microsoft\Teams\Local Storage",
        "$env:APPDATA\Microsoft\Teams\tmp",
        "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams",
        "$env:APPDATA\discord\Cache",
        "$env:APPDATA\discord\Code Cache",
        "$env:LOCALAPPDATA\Spotify\Storage",
        "$env:APPDATA\Spotify",
        "$env:LOCALAPPDATA\WhatsApp\Cache"
    )
    $waUwp = Get-ChildItem -Path "$env:LOCALAPPDATA\Packages" -Filter "*WhatsApp*" -Directory -ErrorAction SilentlyContinue
    foreach ($w in $waUwp) { $acPaths += "$($w.FullName)\LocalCache" }
    $b = Get-PathSizeBytes $acPaths
    Set-Estimate "appcontainers" (Format-Size $b); $total += $b

    Set-Estimate "total" ("~" + (Format-Size $total))
    $script:EstimatesReady = $true
    Write-Item "✓" "Green" "估算已完成。~ 表示近似值。"
}

# --- 菜单显示 ---

function Show-Menu {
    Clear-Host
    $currentFreeSpace = Get-DiskSpace

    Show-Logo
    Write-Host "  版本：v$SCRIPT_VERSION" -ForegroundColor DarkGray
    Write-Item "✨" "Green" "可用空间：$currentFreeSpace"
    Write-Host ""
    Write-SectionHeader "可用选项："
    Write-Host " 0. 退出程序" -ForegroundColor Red
    Write-Host (" 1. 清理全部缓存" + (Get-Est 'total')) -ForegroundColor Green
    Write-Host "─── 开发工具 ───" -ForegroundColor DarkGray
    Write-Host (" 2. 清理 Visual Studio 缓存（bin/obj/.vs + 全局）" + (Get-Est 'visualstudio')) -ForegroundColor Green
    Write-Host (" 3. 清理 Android/Gradle 缓存" + (Get-Est 'android')) -ForegroundColor Green
    Write-Host (" 4. 清理 Android SDK（旧版 build-tools）" + (Get-Est 'androidsdk')) -ForegroundColor Green
    Write-Host " 5. 清理 Flutter 缓存 " -NoNewline -ForegroundColor Green
    Write-Host ("（支持自定义目录选项）" + (Get-Est 'flutter')) -ForegroundColor DarkGray
    Write-Host (" 6. 清理 npm/Yarn/pnpm 缓存" + (Get-Est 'npm')) -ForegroundColor Green
    Write-Host (" 7. 清理 NuGet 包缓存" + (Get-Est 'nuget')) -ForegroundColor Green
    Write-Host (" 8. 清理 PlatformIO 缓存" + (Get-Est 'platformio')) -ForegroundColor Green
    Write-Host (" 9. 清理 Cordova 临时文件" + (Get-Est 'cordova')) -ForegroundColor Green
    Write-Host ("10. 清理 Electron 缓存" + (Get-Est 'electron')) -ForegroundColor Green
    Write-Host ("11. 清理 Docker（清理容器、悬空镜像和构建缓存；在删除未使用的带标签镜像前会询问）" + (Get-Est 'docker')) -ForegroundColor Green
    Write-Host "─── IDE 与编辑器 ───" -ForegroundColor DarkGray
    Write-Host ("12. 清理 IDE 缓存（JetBrains、VSCode）" + (Get-Est 'ide')) -ForegroundColor Green
    Write-Host "─── 系统 ───" -ForegroundColor DarkGray
    Write-Host ("13. 清理 Windows 临时文件与回收站" + (Get-Est 'windowstemp')) -ForegroundColor Green
    Write-Host ("14. 清理浏览器缓存（Chrome、Edge、Firefox、Brave、Opera）" + (Get-Est 'browser')) -ForegroundColor Green
    Write-Host ("15. 清理应用缓存（Slack、Teams、Discord、Spotify、WhatsApp）" + (Get-Est 'appcontainers')) -ForegroundColor Green
    Write-Host ""
    Write-Host "99. 估算可回收空间（只读，~ 表示近似值）" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "→ 请输入您的选择（0-15，或 99 进行估算）： " -NoNewline
}

# --- 主循环 ---

function Start-MainLoop {
    while ($true) {
        Show-Menu
        $choice = Read-Host

        Write-Host ""
        $initialFreeSpace = Get-DiskSpace

        switch ($choice) {
            "0" {
                Write-Host "正在退出清理工具。再见！" -ForegroundColor Green
                return
            }
            "1" {
                Write-SectionHeader "执行全部清理任务"
                Clear-VisualStudio -SearchDir $script:VsSearchDir
                Clear-AndroidGradle
                Clear-AndroidSdk
                Clear-Flutter -SearchDir $script:FlutterSearchDir
                Clear-NpmYarnPnpm
                Clear-NuGet
                Clear-PlatformIO
                Clear-Cordova
                Clear-Electron
                Clear-Docker
                Clear-IdeCaches
                Clear-WindowsTemp
                Clear-BrowserCaches
                Clear-AppContainers
            }
            "2" {
                Write-SectionHeader "执行 Visual Studio 清理"
                Write-Host "当前 Visual Studio 搜索目录：$script:VsSearchDir" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "请输入自定义目录路径，或按 Enter 使用当前设置：" -ForegroundColor Yellow
                $customVsDir = Read-Host

                if ($customVsDir -and (Test-Path $customVsDir)) {
                    Write-Host "使用交互式覆盖：$customVsDir" -ForegroundColor Cyan
                    Clear-VisualStudio -SearchDir $customVsDir
                } elseif ($customVsDir) {
                    Write-Host "目录不存在：$customVsDir" -ForegroundColor Red
                    Write-Host "回退到：$script:VsSearchDir" -ForegroundColor Yellow
                    Clear-VisualStudio -SearchDir $script:VsSearchDir
                } else {
                    Clear-VisualStudio -SearchDir $script:VsSearchDir
                }
            }
            "3" {
                Write-SectionHeader "执行 Android/Gradle 清理"
                Clear-AndroidGradle
            }
            "4" {
                Write-SectionHeader "执行 Android SDK 清理"
                Clear-AndroidSdk
            }
            "5" {
                Write-SectionHeader "执行 Flutter 清理"
                Write-Host "当前 Flutter 搜索目录：$script:FlutterSearchDir" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "请输入自定义目录路径，或按 Enter 使用当前设置：" -ForegroundColor Yellow
                $customFlutterDir = Read-Host

                if ($customFlutterDir -and (Test-Path $customFlutterDir)) {
                    Write-Host "使用交互式覆盖：$customFlutterDir" -ForegroundColor Cyan
                    Clear-Flutter -SearchDir $customFlutterDir
                } elseif ($customFlutterDir) {
                    Write-Host "目录不存在：$customFlutterDir" -ForegroundColor Red
                    Write-Host "回退到：$script:FlutterSearchDir" -ForegroundColor Yellow
                    Clear-Flutter -SearchDir $script:FlutterSearchDir
                } else {
                    Clear-Flutter -SearchDir $script:FlutterSearchDir
                }
            }
            "6" {
                Write-SectionHeader "执行 npm/Yarn/pnpm 清理"
                Clear-NpmYarnPnpm
            }
            "7" {
                Write-SectionHeader "执行 NuGet 缓存清理"
                Clear-NuGet
            }
            "8" {
                Write-SectionHeader "执行 PlatformIO 清理"
                Clear-PlatformIO
            }
            "9" {
                Write-SectionHeader "执行 Cordova 清理"
                Clear-Cordova
            }
            "10" {
                Write-SectionHeader "执行 Electron 清理"
                Clear-Electron
            }
            "11" {
                Write-SectionHeader "执行 Docker 清理"
                Clear-Docker -Interactive
            }
            "12" {
                Write-SectionHeader "执行 IDE 缓存清理"
                Clear-IdeCaches
            }
            "13" {
                Write-SectionHeader "执行 Windows 临时文件与回收站清理"
                Clear-WindowsTemp
            }
            "14" {
                Write-SectionHeader "执行浏览器缓存清理"
                Clear-BrowserCaches
            }
            "15" {
                Write-SectionHeader "执行应用缓存清理"
                Clear-AppContainers
            }
            "99" {
                Write-SectionHeader "估算可回收空间"
                Invoke-EstimateAll
                # 只读：跳过前后摘要，并使用刚计算的估算值重新绘制菜单。
                continue
            }
            default {
                Write-Host "无效选择。请输入 0 到 15 之间的数字。" -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }
        }

        Show-FailureSummary

        $finalFreeSpace = Get-DiskSpace
        Write-Host ""
        Write-Host "✅ 清理任务完成！" -ForegroundColor Green
        Write-Host "清理前磁盘空间：$initialFreeSpace" -ForegroundColor Blue
        Write-Host "清理后磁盘空间：$finalFreeSpace" -ForegroundColor Blue
        Write-Host ""
        Write-Host "按 Enter 返回菜单..." -NoNewline
        Read-Host
    }
}

# --- 入口点 ---

# 处理 -Help 参数
if ($Help) {
    Write-Host @"
Dev Cleanup Utility v$SCRIPT_VERSION
适用于 Windows 开发环境的强大清理工具

用法：.\dev-cleaner.ps1 [选项]

选项：
  -Help               显示此帮助信息
  -Version            显示版本信息
  -FlutterDir 路径    设置 Flutter 清理的自定义目录（默认：当前目录）
                      示例：.\dev-cleaner.ps1 -FlutterDir "C:\Projects"
  -VsDir 路径         设置 Visual Studio 清理的自定义目录（默认：当前目录）
                      示例：.\dev-cleaner.ps1 -VsDir "C:\Projects\DotNet"

交互式菜单：
  选项 99 估算每个条目的可回收空间，并使用 "(Estimate: <大小>)" 重新绘制菜单。
  该选项为只读（不会删除任何内容）。前缀 "~" 表示近似值；Flutter、
  PlatformIO 和 Visual Studio 的估算仅涵盖全局缓存。

示例：
  .\dev-cleaner.ps1                                    # 运行交互式菜单
  .\dev-cleaner.ps1 -FlutterDir "C:\Dev\Flutter"       # 自定义 Flutter 搜索目录
  .\dev-cleaner.ps1 -VsDir "C:\Dev\DotNet"             # 自定义 VS 搜索目录
  .\dev-cleaner.ps1 -FlutterDir "D:\Projects" -VsDir "D:\VS"  # 同时设置两个自定义目录

环境变量：
  `$env:FLUTTER_SEARCH_DIR = "C:\Projects\Flutter"
  `$env:VS_SEARCH_DIR = "C:\Projects\DotNet"

仓库：$GITHUB_REPO
"@
    exit 0
}

# 处理 -Version 参数
if ($Version) {
    Write-Host "Dev Cleaner v$SCRIPT_VERSION"
    Write-Host "适用于 Windows 开发环境的强大清理工具"
    Write-Host "仓库：$GITHUB_REPO"
    exit 0
}

# 确定 Flutter 搜索目录（优先级：命令行 > 环境变量 > 默认）
$script:FlutterSearchDir = "."
$script:FlutterDirSource = "默认"

if ($env:FLUTTER_SEARCH_DIR) {
    $script:FlutterSearchDir = $env:FLUTTER_SEARCH_DIR
    $script:FlutterDirSource = "环境变量"
}

if ($FlutterDir) {
    $script:FlutterSearchDir = $FlutterDir
    $script:FlutterDirSource = "命令行"
}

# 验证 Flutter 目录
if ($script:FlutterSearchDir -ne "." -and -not (Test-Path $script:FlutterSearchDir)) {
    Write-Host "警告：Flutter 搜索目录不存在：$script:FlutterSearchDir" -ForegroundColor Yellow
    Write-Host "正在回退到当前目录。" -ForegroundColor Yellow
    $script:FlutterSearchDir = "."
    $script:FlutterDirSource = "默认"
}

# 确定 Visual Studio 搜索目录（优先级：命令行 > 环境变量 > 默认）
$script:VsSearchDir = "."
$script:VsDirSource = "默认"

if ($env:VS_SEARCH_DIR) {
    $script:VsSearchDir = $env:VS_SEARCH_DIR
    $script:VsDirSource = "环境变量"
}

if ($VsDir) {
    $script:VsSearchDir = $VsDir
    $script:VsDirSource = "命令行"
}

# 验证 VS 目录
if ($script:VsSearchDir -ne "." -and -not (Test-Path $script:VsSearchDir)) {
    Write-Host "警告：Visual Studio 搜索目录不存在：$script:VsSearchDir" -ForegroundColor Yellow
    Write-Host "正在回退到当前目录。" -ForegroundColor Yellow
    $script:VsSearchDir = "."
    $script:VsDirSource = "默认"
}

# 请求提权
Request-Elevation

# 初始确认
Clear-Host
Write-Host "--- Dev Cleanup Utility ---" -ForegroundColor Red
Write-Host "此脚本将永久删除您系统中的缓存文件。"
Write-Host "请在继续之前仔细查看选项。"
Write-Host ""

# 报告搜索目录
if ($script:FlutterSearchDir -ne ".") {
    Write-Host "Flutter 搜索目录：$script:FlutterSearchDir" -ForegroundColor Cyan
    switch ($script:FlutterDirSource) {
        "环境变量" { Write-Host "  （通过 FLUTTER_SEARCH_DIR 环境变量设置）" -ForegroundColor DarkGray }
        "命令行" { Write-Host "  （通过 -FlutterDir 命令行参数设置）" -ForegroundColor DarkGray }
    }
    Write-Host ""
} else {
    Write-Host "Flutter 搜索目录：当前目录（默认）" -ForegroundColor DarkGray
    Write-Host ""
}

if ($script:VsSearchDir -ne ".") {
    Write-Host "Visual Studio 搜索目录：$script:VsSearchDir" -ForegroundColor Cyan
    switch ($script:VsDirSource) {
        "环境变量" { Write-Host "  （通过 VS_SEARCH_DIR 环境变量设置）" -ForegroundColor DarkGray }
        "命令行" { Write-Host "  （通过 -VsDir 命令行参数设置）" -ForegroundColor DarkGray }
    }
    Write-Host ""
} else {
    Write-Host "Visual Studio 搜索目录：当前目录（默认）" -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "⚠️ 此操作对已删除文件不可逆。⚠️" -ForegroundColor Yellow
Write-Host "请在运行前关闭所有开发应用程序（Visual Studio、Android Studio、VSCode 等）。" -ForegroundColor Yellow
Write-Host ""
$initialConfirm = Read-Host "您确定要启动清理工具吗？(y/N)"

if ($initialConfirm -ne "y" -and $initialConfirm -ne "Y") {
    Write-Host "已取消清理工具。"
    exit 0
}

# 启动主循环
Start-MainLoop
