<#
.SYNOPSIS
    ENSO 网页版日常自动更新：抓数 → 自检 → 发布到 GitHub Pages

.DESCRIPTION
    把三件必须按顺序做的事串起来，专供计划任务调用：

      1. 跑 Update-EnsoData.ps1        联网抓 CPC 数据，重建 report\ 与 docs\
      2. 跑 verify-report.mjs          两份都自检，不通过就中止、绝不发布
      3. 跑 Publish-ToGitHub.ps1       走 GitHub API 提交到 main，Pages 自动重建

    刻意不做的事：
      · 不碰微信小程序相关文件（发布清单本身就是网页版白名单）
      · 数据没变就不提交（比较 docs\index.html 的数据截止日 + 文件哈希）
      · 自检不过就不发布（避免把半成品推上线）

.PARAMETER NoDownload
    不联网，用 data\raw 缓存重建。用于"只改了模板、想快速上线"的场景。

.PARAMETER Force
    即使文件哈希完全未变也照常提交（正常情况下每页页头都带生成时间戳，
    哈希必然变化，所以这个开关基本用不到，留作兜底）。

.PARAMETER SkipPublish
    只抓数 + 自检，不推送。用于先看一眼结果。

.PARAMETER Quiet
    精简输出，适合计划任务日志。

.EXAMPLE
    # 计划任务调用的标准用法
    powershell -ExecutionPolicy Bypass -NoProfile -File .\scripts\Auto-Update-Web.ps1

.EXAMPLE
    # 只改了模板、不联网，直接上线
    powershell -ExecutionPolicy Bypass -NoProfile -File .\scripts\Auto-Update-Web.ps1 -NoDownload
#>
[CmdletBinding()]
param(
    [switch]$NoDownload,
    [switch]$Force,
    [switch]$SkipPublish,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Repo = Split-Path -Parent $PSScriptRoot
$script:LogDir = Join-Path $script:Repo 'data\logs'
$script:LogFile = Join-Path $script:LogDir ('auto-update-{0}.log' -f (Get-Date).ToString('yyyy-MM'))

function Stamp { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Stamp), $Text
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
    # 日志按月归档，避免无限增长；中文必须按 UTF-8 写
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Fail {
    param([string]$Message)
    Say "失败：$Message" 'Red'
    exit 1
}

function Get-PageFingerprint {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText((Resolve-Path $Path), [System.Text.Encoding]::UTF8)
    $tag = [regex]::Match($text, '"tag":"([^"]*)"').Groups[1].Value
    $n34 = [regex]::Match($text, '"n34":([-\d.]+)').Groups[1].Value
    $sha = (Get-FileHash $Path -Algorithm SHA256).Hash
    return [pscustomobject]@{ Tag = $tag; N34 = $n34; Hash = $sha }
}

function Run-Step {
    param([string]$Label, [scriptblock]$Body)
    Say "── $Label" 'Cyan'
    # 收集子步骤输出：成功时静默，失败时写进日志。
    # 必须同时接住「异常」与「非零退出码」两种失败 —— 只查 $LASTEXITCODE 的话，
    # 被调用脚本里的 throw 会因为 $ErrorActionPreference='Stop' 直接终止整个进程，
    # 日志里只剩一个退出码 1，完全查不出原因（这是实际踩过的坑）。
    $captured = ''
    try {
        $captured = & $Body 2>&1 | Out-String
    } catch {
        $captured = ($captured + "`r`n[异常] " + $_.Exception.Message)
        if ($_.ScriptStackTrace) { $captured += "`r`n[位置] " + $_.ScriptStackTrace }
        foreach ($l in ($captured.Trim() -split "`r?`n")) { Say "   | $l" 'DarkGray' }
        Fail "$Label（异常）"
    }
    if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
        if ($captured.Trim()) {
            foreach ($l in ($captured.Trim() -split "`r?`n")) { Say "   | $l" 'DarkGray' }
        }
        Fail "$Label（退出码 $LASTEXITCODE）"
    }
}

Say ('=' * 58) 'DarkGray'
Say "ENSO 网页版自动更新启动" 'Green'

# ─────────────────────────────────────────────── 0. 前置检查
$generator = Join-Path $PSScriptRoot 'Update-EnsoData.ps1'
$verifier = Join-Path $PSScriptRoot 'verify-report.mjs'
$publisher = Join-Path $PSScriptRoot 'Publish-ToGitHub.ps1'
foreach ($f in @($generator, $verifier, $publisher)) {
    if (-not (Test-Path $f)) { Fail "缺少必需文件：$f" }
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail '找不到 node，自检无法运行' }

# ─────────────────────────────────────────────── 1. 抓数 + 生成
$before = Get-PageFingerprint (Join-Path $script:Repo 'docs\index.html')
Say ("发布前数据截止日：{0}（Niño3.4 {1}）" -f $(if ($before) { $before.Tag } else { '无' }),
     $(if ($before) { $before.N34 } else { '—' }))

$genArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $generator)
if ($NoDownload) { $genArgs += '-NoDownload' }
Run-Step '抓取 CPC 数据并重建 report\ 与 docs\' {
    & powershell @genArgs | Out-Null
    $global:LASTEXITCODE = $LASTEXITCODE
}

$after = Get-PageFingerprint (Join-Path $script:Repo 'docs\index.html')
if (-not $after) { Fail '生成后仍找不到 docs\index.html' }
Say ("生成后数据截止日：{0}（Niño3.4 {1}）" -f $after.Tag, $after.N34)

# ─────────────────────────────────────────────── 2. 自检（两道）
Run-Step '自检 report\ 版本' { & node $verifier (Join-Path $script:Repo 'report\enso_dashboard.html') | Out-Null }
Run-Step '自检 docs\ 发布副本' { & node $verifier (Join-Path $script:Repo 'docs\index.html') | Out-Null }
Say '自检通过：35 项 × 2 份' 'Green'

# ─────────────────────────────────────────────── 3. 是否需要发布
$dataChanged = (-not $before) -or ($before.Tag -ne $after.Tag) -or ($before.N34 -ne $after.N34)
$fileChanged = (-not $before) -or ($before.Hash -ne $after.Hash)

if (-not $fileChanged) {
    Say '页面内容与上次完全一致，无需发布。' 'DarkGray'
    Say ('=' * 58) 'DarkGray'
    exit 0
}
if (-not $dataChanged) {
    # 页头带生成时间戳，每次重建哈希都会变，所以不能把"哈希变了"当成"数据变了"。
    # 数据没变但页面变了，说明模板/样式刚动过 —— 照常发布。
    Say ("数据未变（仍为 {0}），页面内容有更新（多为模板/样式改动），照常发布。" -f $after.Tag) 'Yellow'
}

if ($SkipPublish) {
    Say '已指定 -SkipPublish，停在生成阶段。' 'Yellow'
    Say ('=' * 58) 'DarkGray'
    exit 0
}

# ─────────────────────────────────────────────── 4. 发布
$msg = if ($dataChanged) {
    '自动更新：数据到 {0}（Niño3.4 {1}）' -f $after.Tag, $after.N34
} else {
    '自动更新：页面改版（数据仍为 {0}）' -f $after.Tag
}
Run-Step '走 GitHub API 发布到 main' {
    # 刻意不再嵌套一层 powershell.exe：在计划任务环境里，
    # "powershell 再调 powershell -File" 出问题时连子进程输出都拿不到，
    # 日志里只剩一个退出码 1（15:06 与 15:12 两次都是这样）。
    # 同进程按脚本调用，错误能正常抛出并被上面捕获记录。
    & $publisher -SkipRegenerate -Message $msg
}

Say ("已发布：{0}" -f $msg) 'Green'
Say ('=' * 58) 'DarkGray'
exit 0
