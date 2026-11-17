<#
  一键更新并上传小程序新版本。

  把原本需要手动依次敲的四步串起来，避免漏步：

    1. 抓取并生成网页版数据      scripts/Update-EnsoData.ps1
    2. 由同一份 DATA 生成小程序数据与图片
                                 scripts/Build-MiniProgramData.mjs
    3. 跑三套自检                scripts/verify-*.mjs
    4. 上传新版本到微信后台     微信开发者工具 cli upload

  用法（版本号可省略——默认取「数据截止日」，如 2026.10.07）：

    # 完整流程：抓取 → 构建 → 自检 → 上传。双击仓库根目录的
    #    更新小程序.cmd
    # 即可；等价于：
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-And-Upload.ps1

    # 数据没变，只想把代码改动传上去
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-And-Upload.ps1 -NoDownload

    # 只重建 + 自检，先不上传
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-And-Upload.ps1 -NoUpload

    # 同一份数据补传代码改动：默认版本号会与上次重复，需显式区分
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-And-Upload.ps1 -NoDownload -Version 2026.10.07.2

    # 顺带把权威来源 report/ 同步到 GitHub Pages 的发布副本 docs/（默认不动 docs/）
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-And-Upload.ps1 -SyncDocs

  版本号策略：默认 =「数据截止日」。好处是不用维护任何状态文件，
  且从版本号就能看出这个版本装的是哪天为止的数据。

  上传失败会自动重试一次；仍失败时脚本列出可能原因并以 exit 1 结束。
  应急可改为在开发者工具里手动点「上传」。

  注意：**上传成功后仍需到微信后台【版本管理】手动【提交审核】**。
  这一步脚本刻意不代做——提审要填版本描述、勾功能页面、确认隐私声明与
  UGC 声明，都是有法律含义的声明项，不适合自动化。

  维护提醒：本文件含中文，必须保存为 **UTF-8 with BOM**。
  否则 Windows PowerShell 5.1 会按 GBK 解析而报语法错。
#>
param(
  [string]$Version = '',
  [string]$Desc = 'data refresh',
  [string]$MiniFrom = '',
  [switch]$NoDownload,
  [switch]$NoUpload,
  [switch]$SyncDocs
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Step([string]$n, [string]$t) {
  Write-Host ''
  Write-Host "==== $n  $t ====" -ForegroundColor Cyan
}
function Fail([string]$m) {
  Write-Host ''
  Write-Host "[失败] $m" -ForegroundColor Red
  exit 1
}
function RunNode([string]$file) {
  $p = Join-Path $PSScriptRoot $file
  if (-not (Test-Path $p)) {
    Write-Host "  跳过（文件不存在）: $file" -ForegroundColor DarkGray
    return
  }
  & node $p
  if ($LASTEXITCODE -ne 0) { Fail "$file 未通过（退出码 $LASTEXITCODE）" }
}

Write-Host "仓库: $repo"

# ── 1. 抓取 + 生成网页版 ──────────────────────────────────────────
Step '1/4' '抓取并生成网页版数据'
if ($NoDownload) {
  Write-Host '  已指定 -NoDownload，跳过抓取，沿用现有仪表盘（实际来源见下方）' -ForegroundColor DarkGray
} else {
  # 显式带上 -PublishDir docs：网页版报告与 Pages 副本必须同源，
  # 否则会出现「report\ 是今天的数据、docs\ 还是上一周的」这种两份不一致。
  & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot 'Update-EnsoData.ps1') -PublishDir docs
  if ($LASTEXITCODE -ne 0) { Fail 'Update-EnsoData.ps1 执行失败' }
}

# ── 2. 生成小程序数据 ────────────────────────────────────────────
Step '2/4' '生成小程序数据与图片'

# 数据来源（2026-10-15 查清）：两者**同源**，由 Update-EnsoData.ps1 一次写出同一个
# $html，内容完全相同，不存在"谁更权威"：
#   report/enso_dashboard.html  生成产物（被 gitignore，不入库）
#   docs/index.html             GitHub Pages 发布副本（入库，Pages 靠它）
# 默认两者一起刷新；若有人用 -NoPublish，则只有 report/ 是新的、docs/ 会落后。
# 所以小程序构建优先读 report/，这样 -NoPublish 场景下依然能拿到最新数据。
function Get-DataEnd([string]$p) {
  if (-not (Test-Path $p)) { return $null }
  $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
  $m = [regex]::Match($t, 'weeklyLast"?\s*:\s*"(\d{4}-\d{2}-\d{2})"')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}
$reportEnd = Get-DataEnd (Join-Path $repo 'report\enso_dashboard.html')
$docsEnd   = Get-DataEnd (Join-Path $repo 'docs\index.html')
Write-Host ("  report/enso_dashboard.html  数据截止: " + $(if ($reportEnd) { $reportEnd } else { '(不存在)' }) + "   <- 生成产物，不入库；小程序读它")
Write-Host ("  docs/index.html             数据截止: " + $(if ($docsEnd) { $docsEnd } else { '(不存在)' }) + "   <- Pages 发布副本，入库")
if ($docsEnd -and $reportEnd -and $docsEnd -ne $reportEnd) {
  Write-Host "  [!] 两者不一致——通常不该发生（脚本默认同时刷新两者），可能用了 -NoPublish。" -ForegroundColor Yellow
  if ($SyncDocs) {
    Copy-Item (Join-Path $repo 'report\enso_dashboard.html') (Join-Path $repo 'docs\index.html') -Force
    Write-Host "      已按 -SyncDocs 把 report/ 同步到 docs/index.html" -ForegroundColor Green
  } else {
    Write-Host "      小程序不受影响（它读 report/）。加 -SyncDocs 可自动同步发布副本。" -ForegroundColor Yellow
  }
} elseif ($SyncDocs -and $reportEnd) {
  Copy-Item (Join-Path $repo 'report\enso_dashboard.html') (Join-Path $repo 'docs\index.html') -Force
  Write-Host "  已按 -SyncDocs 把 report/ 同步到 docs/index.html" -ForegroundColor DarkGray
}

$buildArgs = @((Join-Path $PSScriptRoot 'Build-MiniProgramData.mjs'))
if (-not [string]::IsNullOrWhiteSpace($MiniFrom)) { $buildArgs += @('--from', $MiniFrom) }
& node @buildArgs
if ($LASTEXITCODE -ne 0) { Fail 'Build-MiniProgramData.mjs 执行失败' }

# ── 3. 自检 ─────────────────────────────────────────────────────
Step '3/4' '自检'
RunNode 'verify-miniprogram.mjs'
RunNode 'verify-scripts.mjs'
RunNode 'verify-report.mjs'

# ── 4. 上传 ─────────────────────────────────────────────────────
if ($NoUpload) {
  Step '4/4' '上传（已跳过）'
  Write-Host '  已指定 -NoUpload。数据与自检均已完成，需要上传时去掉该参数。' -ForegroundColor Yellow
  exit 0
}

Step '4/4' '上传新版本到微信后台'

# 版本号默认为「数据截止日」（如 2026.10.07）：一眼看出这个版本装的是哪天为止的数据，
# 且不需要维护任何状态文件。同一天要补传代码改动时，用 -Version 显式覆盖即可。
if ([string]::IsNullOrWhiteSpace($Version)) {
  if ($reportEnd) {
    $Version = $reportEnd -replace '-', '.'
    Write-Host "  未指定 -Version，自动采用数据截止日作为版本号: $Version" -ForegroundColor DarkGray
  } else {
    Fail '读不到数据截止日，无法自动确定版本号；请用 -Version 显式指定'
  }
}

$cli = Get-ChildItem 'C:\Program Files (x86)\Tencent' -Recurse -Filter 'cli.bat' -ErrorAction SilentlyContinue |
       Select-Object -First 1 -ExpandProperty FullName
if (-not $cli) { Fail '找不到微信开发者工具的 cli.bat，请确认已安装开发者工具' }

# 这个环境变量若被继承，开发者工具会以纯 Node 方式启动、静默退出
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

# ── 读取 CLI 输出的唯一正确姿势 ────────────────────────────────────
# ⚠️ 绝不要用管道直接捕获开发者工具 CLI 的输出。
# CLI 是 Electron/Node 进程，stdout 一律是 **UTF-8** 字节（cli.bat 自己还先 chcp 65001），
# 而 Windows PowerShell 用 [Console]::OutputEncoding 解码管道——中文机器上默认 CP936/GBK，
# 于是 CLI 的 "√ upload" 被解成 "鈭?upload"，-match '√ upload' 永远为假。
# 后果（2026-10-15 实际踩到）：上传**其实成功了**，脚本却连报两次失败，还白传了一遍。
# 对策：让 cmd 把原始字节写进临时文件，再按 UTF-8 显式读回，彻底绕开控制台代码页。
# 另：只设 [Console]::OutputEncoding 也能修好解码，但那会连带改变本脚本自身中文输出的
# 编码，在 CP936 控制台里反而把脚本自己的提示弄花，所以选写文件这条路。
function Invoke-DevToolsCli([string]$cliPath, [string]$arguments, [int]$TimeoutSec = 300) {
  $logFile = Join-Path $env:TEMP ("enso-devtools-{0}.log" -f [guid]::NewGuid().ToString('N'))
  $timedOut = $false
  $exitCode = -1
  $text = ''
  try {
    # ⚠️ 必须带硬超时：开发者工具**没在运行时**，CLI 会尝试拉起 IDE 并永久阻塞。
    # 2026-10-20 实际踩到：08:00 的自动巡检卡死 90 分钟，计划任务在 30 分钟时限被强杀
    # （LastTaskResult=0x41306），CLI 子进程成了孤儿继续挂着。所以改用
    # Start-Process + WaitForExit(ms)，超时后 taskkill /T 连子进程一起收掉。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'cmd.exe'
    $psi.Arguments = '/c ""' + $cliPath + '" ' + $arguments + ' > "' + $logFile + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
      $timedOut = $true
      try { & taskkill /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
      try { $proc.Kill() } catch { }
      $exitCode = -1
    } else {
      $exitCode = $proc.ExitCode
    }
    if (Test-Path $logFile) { $text = [System.IO.File]::ReadAllText($logFile, [System.Text.Encoding]::UTF8) }
    if ($timedOut) { $text += "`n[timeout] 等待超过 ${TimeoutSec} 秒，已强制终止（开发者工具可能没在运行）" }
  } finally {
    Remove-Item $logFile -ErrorAction SilentlyContinue
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; TimedOut = $timedOut }
}

# ── 前置：确保开发者工具在运行 ─────────────────────────────────
# 这是 2026-10-20 卡死 90 分钟的真正根因：IDE 没运行时 CLI 会去拉起它并可能永久阻塞。
# 所以先确认有带窗口的 IDE 进程；没有就主动启动并等它就绪（最多 90 秒）。
$ideRunning = Get-Process -ErrorAction SilentlyContinue |
              Where-Object { $_.ProcessName -match '微信' -and $_.MainWindowTitle }
if (-not $ideRunning) {
  Write-Host '  开发者工具未运行，正在启动…' -ForegroundColor Yellow
  $ideExe = Get-ChildItem (Split-Path $cli) -Filter '*.exe' -File -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
  if ($ideExe) {
    Start-Process -FilePath $ideExe.FullName | Out-Null
    for ($i = 0; $i -lt 45; $i++) {
      Start-Sleep -Seconds 2
      $ideRunning = Get-Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessName -match '微信' -and $_.MainWindowTitle }
      if ($ideRunning) { break }
    }
  }
  if ($ideRunning) { Write-Host '  开发者工具已就绪' -ForegroundColor DarkGray }
  else { Write-Host '  [!] 90 秒内未见窗口，仍继续尝试（大概率会超时，请看下面的原因清单）' -ForegroundColor Yellow }
}

# 前置检查：没登录就别浪费一次上传。islogin 失败或返回非 true 都算未登录。
Write-Host '  检查登录状态…'
$loginOut = (Invoke-DevToolsCli $cli 'islogin').Text
if ($loginOut -notmatch '"login"\s*:\s*true') {
  Fail '开发者工具未登录或登录已过期——请打开开发者工具扫码登录后重试'
}
Write-Host '  登录正常' -ForegroundColor DarkGray

Write-Host "  cli    : $cli"
Write-Host "  项目   : $(Join-Path $repo 'miniprogram')"
Write-Host "  版本   : $Version"
Write-Host "  说明   : $Desc"

# ⚠️ 判定上传是否成功，三条经验都是踩坑换来的：
#   1. 不能只看 $LASTEXITCODE——CLI 上传失败时会把 [error] 打在输出里，却仍以 0 退出
#      （2026-10-15 AppID 冲突那次，脚本报了"上传完成"、exit code 0）。
#      既然它在失败时不可靠，成功时也就不必拿它当必要条件；只打印出来备查。
#   2. 必须看到成功标记。CLI 内置两套符号：Windows 交互式下用 "√"，
#      而 TERM=xterm-256color 或 CI 环境下换成 "✔"，所以两个都要认。
#   3. 输出的读取方式必须对（见 Invoke-DevToolsCli）——否则第 2 条永远不成立，
#      这正是 2026-10-15 第二次踩坑（把成功判成失败，白白重复上传）的原因。
#   兜底：CLI 成功后会打印上传结果表（表头 size (Byte)），这是 ASCII 证据，
#   不受控制台代码页影响；只在没有 [error] 时才认它，并明确提示去后台复核。
#   另：CLI 偶发失败（工程冲突、进程堆积）重试一次常能过去，故自动重试一轮。
$maxAttempts = 2
$ok = $false
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
  if ($attempt -gt 1) {
    Write-Host ''
    Write-Host "  第 $($attempt-1) 次上传失败，5 秒后重试…" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
  $up = Invoke-DevToolsCli $cli ("upload --project `"$(Join-Path $repo 'miniprogram')`" --version $Version --desc `"$Desc`" --lang zh")
  Write-Host $up.Text

  $hasMark  = $up.Text -match '[√✔]\s*upload'
  $hasTable = $up.Text -match 'size \(Byte\)'
  $hasError = $up.Text -match '\[error\]'
  $ok = (-not $hasError) -and ($hasMark -or $hasTable)

  Write-Host ("  判定：exit={0}  成功标记={1}  结果表={2}  错误标记={3} → {4}" -f `
    $up.ExitCode, $hasMark, $hasTable, $hasError, $(if ($ok) { '成功' } else { '失败' })) -ForegroundColor DarkGray
  if ($ok -and -not $hasMark) {
    Write-Host '  [!] 没看到 √ upload，仅凭上传结果表判定为成功——请到后台【版本管理】确认该版本确实在列。' -ForegroundColor Yellow
  }

  if ($ok) { break }
}

if (-not $ok) {
  Write-Host ''
  Write-Host '可能原因（按可能性排序）：' -ForegroundColor Yellow
  Write-Host '  1. 同一个 AppID 在多个工程里同时打开——开发者工具不允许。' -ForegroundColor Yellow
  Write-Host '     检查 miniprogram-proto 是否也用着生产 AppID 并开着；把它关掉或改成 touristappid。' -ForegroundColor Yellow
  Write-Host '  2. 开发者工具进程堆积过多——全部关掉后重开再试。' -ForegroundColor Yellow
  Write-Host '  3. 未登录或登录过期——用 cli islogin 检查。' -ForegroundColor Yellow
  Write-Host '  4. 也可能"其实传上去了、但没认出来"——先看上面那行判定：若 成功标记 与 结果表' -ForegroundColor Yellow
  Write-Host '     都是 False，请把 CLI 原始输出贴出来再查（多半又踩到控制台编码）。' -ForegroundColor Yellow
  Write-Host "     最终事实以微信后台【版本管理】里有没有 $Version 这个开发版本为准。" -ForegroundColor Yellow
  Write-Host ''
  Write-Host '应急：在开发者工具里手动点工具栏的「上传」，版本填上面显示的版本号即可。' -ForegroundColor Cyan
  Fail "上传失败（已试 $maxAttempts 次）"
}

Write-Host ''
Write-Host '上传完成。' -ForegroundColor Green

# 记录"服务器上到底是哪个版本"。巡检脚本以此为主要判据。
# 若只比对"包内 vs 源"，一旦构建成功而上传失败，两者相等，巡检会误判"无需更新"，
# 于是上传永远不再重试——这是 2026-10-20 发现的设计漏洞。
try {
  [System.IO.File]::WriteAllText(
    (Join-Path $repo 'report\uploaded.txt'),
    ($reportEnd + "`n" + $Version + "`n" + (Get-Date -Format 'o')),
    (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ('  已记录上传状态: ' + $reportEnd) -ForegroundColor DarkGray
} catch {
  Write-Host ('  [!] 写上传状态失败（不影响本次上传）: ' + $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host '下一步（需手动）：微信后台 → 管理 → 版本管理 → 开发版本 → 找到该版本 → 提交审核' -ForegroundColor Green
