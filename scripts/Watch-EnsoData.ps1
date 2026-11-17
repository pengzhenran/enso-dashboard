<#
  ENSO 数据自动巡检。

  设计原则：**先判断数据有没有真的前进，没前进就静默退出**——
  不制造无意义的版本，也不每天拿通知骚扰你。

  一次运行的流程：
    1. 记下当前数据截止日（来自权威产物 report/enso_dashboard.html）
    2. 跑 Update-EnsoData.ps1 抓取（它默认同时刷新 report/ 与 docs/）
    3. 再读一次数据截止日
    4. 没变 → 记日志、安静退出（退出码 0）
       变了 → 调 Update-And-Upload.ps1 -NoDownload 走构建+自检+上传
    5. **无论成功还是失败都通知你**——沉默的失败比失败更糟

  判断依据是「数据截止日」而不是文件时间戳：文件天天被重写，
  但数据可能一周才前进一次。

  用法：
    powershell -ExecutionPolicy Bypass -File .\scripts\Watch-EnsoData.ps1
    ... -Force        忽略"数据没变"，强制走一遍构建+上传（测试用）
    ... -NoUpload     只巡检并构建，不上传
    ... -NoNotify     不弹通知（排查用）
    ... -TestNotify   只发一条测试通知然后退出

  维护提醒：本文件含中文，必须保存为 **UTF-8 with BOM**。
#>
param(
  [switch]$Force,
  [switch]$NoUpload,
  [switch]$NoNotify,
  [switch]$TestNotify,
  [switch]$NoPublish,
  [switch]$Heartbeat
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$logPath   = Join-Path $repo 'report\watch.log'
$stateDir  = Join-Path $repo 'report'
$noticeTxt = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ENSO更新情况.txt'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }

function Write-Log([string]$msg) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
  Write-Host $line
  try { Add-Content -Path $logPath -Value $line -Encoding UTF8 } catch { }
}

# 从仪表盘里读数据截止日
function Get-DataEnd([string]$p) {
  if (-not (Test-Path $p)) { return $null }
  $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
  $m = [regex]::Match($t, 'weeklyLast"?\s*:\s*"(\d{4}-\d{2}-\d{2})"')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

# 通知：Windows 通知中心（PowerShell 5.1 可直接调 WinRT，无需装模块），
# 并始终在桌面留一份纯文本，防止通知被漏看或被系统静音。
function Send-Notice([string]$title, [string]$message, [string]$detail) {
  try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
    $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $nodes = $tpl.GetElementsByTagName('text')
    [void]$nodes.Item(0).AppendChild($tpl.CreateTextNode($title))
    [void]$nodes.Item(1).AppendChild($tpl.CreateTextNode($message))
    $toast = New-Object Windows.UI.Notifications.ToastNotification $tpl
    # 用 PowerShell 自己的 AUMID：它是已注册的，不需要额外安装任何东西
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
    Write-Log '通知已发出（Windows 通知中心）'
  } catch {
    Write-Log ('通知中心不可用（' + $_.Exception.Message + '），已改为桌面文本')
  }
  try {
    $body = @(
      'ENSO 小程序自动巡检',
      '',
      '标题: ' + $title,
      '摘要: ' + $message,
      '',
      $detail,
      '',
      '时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
      '日志: ' + $logPath
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($noticeTxt, $body, (New-Object System.Text.UTF8Encoding($true)))
  } catch { Write-Log ('写桌面文本失败: ' + $_.Exception.Message) }

  # 推到手机（微信 / 邮件）。配置来自 .notify.json，该文件已被 gitignore。
  Send-Phone $title ($message + "`r`n`r`n" + $detail)
}

# 读取手机推送配置；文件不存在或没启用就静默跳过
$configPath = Join-Path $repo '.notify.json'
$notifyCfg = $null
if (Test-Path $configPath) {
  try { $notifyCfg = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
  catch { Write-Log ('通知配置解析失败（将只发本机通知）: ' + $_.Exception.Message) }
}

function Send-Phone([string]$title, [string]$body) {
  if (-not $notifyCfg) { return }

  # ── 微信推送 ──────────────────────────────────────────────
  if ($notifyCfg.wechat -and $notifyCfg.wechat.enabled) {
    $w = $notifyCfg.wechat
    try {
      if (-not $w.key -and -not $w.url) { throw 'wechat.enabled 为 true，但 key 和 url 都是空的' }
      # ⚠️ 不能只看"有没有抛异常"：这些服务出错时（配额超限、key 失效）
      # 仍可能返回 HTTP 200，只在响应体里写错误码。必须解析响应体校验，
      # 否则推送会静默失败——你会以为有通知，其实收不到。
      $resp = $null
      switch ($w.type) {
        'serverchan' {
          $u = if ($w.url) { $w.url } else { 'https://sctapi.ftqq.com/' + $w.key + '.send' }
          $resp = Invoke-RestMethod -Uri $u -Method Post -Body @{ title = $title; desp = $body } -TimeoutSec 20
          if ($null -ne $resp.data -and $null -ne $resp.data.errno -and [int]$resp.data.errno -ne 0) {
            throw ('Server酱返回错误: ' + $resp.data.error)
          }
          if ($null -ne $resp.code -and [int]$resp.code -ne 0) {
            throw ('Server酱返回 code=' + $resp.code + ' ' + $resp.message)
          }
        }
        'pushplus' {
          $u = if ($w.url) { $w.url } else { 'https://www.pushplus.plus/send' }
          $json = @{ token = $w.key; title = $title; content = $body } | ConvertTo-Json -Compress
          $resp = Invoke-RestMethod -Uri $u -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 20
          if ($null -ne $resp.code -and [int]$resp.code -ne 200) { throw ('PushPlus返回 code=' + $resp.code + ' ' + $resp.msg) }
        }
        'wecom' {
          if (-not $w.url) { throw 'wecom 需要填 url（群机器人完整 webhook 地址）' }
          $json = @{ msgtype = 'text'; text = @{ content = ($title + "`n" + $body) } } | ConvertTo-Json -Depth 4 -Compress
          $resp = Invoke-RestMethod -Uri $w.url -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 20
          if ($null -ne $resp.errcode -and [int]$resp.errcode -ne 0) { throw ('企业微信返回 errcode=' + $resp.errcode + ' ' + $resp.errmsg) }
        }
        'bark' {
          if (-not $w.url) { throw 'bark 需要填 url' }
          $u = $w.url.TrimEnd('/') + '/' + [uri]::EscapeDataString($title) + '/' + [uri]::EscapeDataString($body)
          $resp = Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 20
          if ($null -ne $resp.code -and [int]$resp.code -ne 200) { throw ('Bark返回 code=' + $resp.code) }
        }
        default { throw ('未知的推送类型: ' + $w.type + '（支持 serverchan / pushplus / wecom / bark）') }
      }
      Write-Log ('微信推送已发出并确认成功（' + $w.type + '）')
    } catch {
      Write-Log ('微信推送失败: ' + $_.Exception.Message)
    }
  }

  # ── 邮件 ──────────────────────────────────────────────────
  if ($notifyCfg.email -and $notifyCfg.email.enabled) {
    $e = $notifyCfg.email
    try {
      if (-not $e.user -or -not $e.authCode -or -not $e.to) { throw 'email 的 user / authCode / to 有空项' }
      $msg = New-Object System.Net.Mail.MailMessage
      $msg.From = New-Object System.Net.Mail.MailAddress($e.user)
      foreach ($to in ($e.to -split '[,;]')) { if ($to.Trim()) { [void]$msg.To.Add($to.Trim()) } }
      $msg.Subject = $title
      $msg.Body = $body
      $msg.BodyEncoding = [System.Text.Encoding]::UTF8
      $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
      # 注意：.NET 自带客户端只支持 587 + STARTTLS，不支持 465 的隐式 SSL
      $client = New-Object System.Net.Mail.SmtpClient($e.smtp, [int]$e.port)
      $client.EnableSsl = [bool]$e.ssl
      $client.Credentials = New-Object System.Net.NetworkCredential($e.user, $e.authCode)
      $client.Timeout = 30000
      $client.Send($msg)
      $client.Dispose()
      Write-Log ('邮件已发出 -> ' + $e.to)
    } catch {
      Write-Log ('邮件发送失败: ' + $_.Exception.Message)
    }
  }

  if ($notifyCfg.wechat -and $notifyCfg.wechat.enabled) { }
  elseif ($notifyCfg.email -and $notifyCfg.email.enabled) { }
  else {
    Write-Log '手机推送未启用（.notify.json 里 wechat/email 的 enabled 都是 false）'
  }
}

if ($TestNotify) {
  Write-Host ''
  if (-not $notifyCfg) {
    Write-Host '.notify.json 不存在——只有本机通知。' -ForegroundColor Yellow
    Write-Host '请复制 scripts\notify.config.example.json 为 .notify.json 后填写。' -ForegroundColor Yellow
  } else {
    Write-Host '当前启用的渠道：' -ForegroundColor Cyan
    Write-Host ('  微信推送: ' + $(if ($notifyCfg.wechat.enabled) { '已启用 (' + $notifyCfg.wechat.type + ')' } else { '未启用' }))
    Write-Host ('  邮件    : ' + $(if ($notifyCfg.email.enabled) { '已启用 -> ' + $notifyCfg.email.to } else { '未启用' }))
  }
  Write-Host ''
  Send-Notice 'ENSO 巡检测试通知' '这是一条测试，说明通知链路可用。' "无需处理。`r`n若你手机上收到了，自动化的推送就没问题。"
  Write-Host ''
  Write-Host '已尝试发送测试通知（本机 + 已启用的手机渠道）。桌面也会生成 ENSO更新情况.txt' -ForegroundColor Green
  Write-Host ('日志: ' + $logPath) -ForegroundColor DarkGray
  exit 0
}

Write-Log '========== 开始巡检 =========='

$reportPath = Join-Path $repo 'report\enso_dashboard.html'

# ⚠️ 判据是"**服务器上已上传的数据**是否已等于源数据"，而不是"源相对上次有没有变"，
# 也不只是"包内数据 == 源"。两个坑都是真踩到的：
#   1. 只看"源有没有变"：某次上传失败后，第二天源不再前进 → 会静默跳过，新数据永远传不上去。
#   2. 只看"包内 == 源"：构建成功、上传失败时两者仍然相等 → 误判"无需更新"，
#      上传永远不再重试（2026-10-20 发现的洞）。
# 所以基线优先取 report/uploaded.txt（由 Update-And-Upload.ps1 上传成功后写入），
# 它记录的是**服务器上真实的版本**；记录缺失时才退回包内数据。
$uploadedFile = Join-Path $stateDir 'uploaded.txt'
$uploadedEnd = $null
if (Test-Path $uploadedFile) {
  try { $uploadedEnd = (Get-Content $uploadedFile -TotalCount 1 -Encoding UTF8).Trim() } catch { }
}
$pkgEnd = Get-DataEnd (Join-Path $repo 'miniprogram\data\meta.js')
$srcEnd = Get-DataEnd $reportPath
if (-not $srcEnd) { $srcEnd = Get-DataEnd (Join-Path $repo 'docs\index.html') }
$baseline = if ($uploadedEnd) { $uploadedEnd } else { $pkgEnd }
Write-Log ('已上传数据截止日    : ' + $(if ($uploadedEnd) { $uploadedEnd } else { '(无记录，改用包内数据)' }))
Write-Log ('小程序包内数据截止日: ' + $(if ($pkgEnd) { $pkgEnd } else { '(读不到)' }))
Write-Log ('抓取前源数据截止日  : ' + $(if ($srcEnd) { $srcEnd } else { '(读不到)' }))

# ── 1. 抓取 ────────────────────────────────────────────────────
try {
  & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot 'Update-EnsoData.ps1') -PublishDir docs
  if ($LASTEXITCODE -ne 0) { throw "Update-EnsoData.ps1 退出码 $LASTEXITCODE" }
} catch {
  Write-Log ('抓取失败: ' + $_.Exception.Message)
  if (-not $NoNotify) {
    Send-Notice 'ENSO 巡检失败：抓取' '抓取数据源失败，本次未做任何更新。' ('原因: ' + $_.Exception.Message + "`r`n数据未被改动，线上仍是你上次提审的版本。")
  }
  exit 1
}

# ── 2. 数据前进没有？ ─────────────────────────────────────────
$after = Get-DataEnd $reportPath
Write-Log ('抓取后数据截止日: ' + $(if ($after) { $after } else { '(读不到)' }))

if (-not $Force -and $baseline -and $after -and $baseline -eq $after) {
  Write-Log '已上传的数据已与源一致，无需更新（不产生新版本、不打扰你）'

  # 可选心跳：数据长期不变时，如果自动化哪天静默停了（任务被禁用/误删、
  # 开发者工具登录失效），你会一直以为"没消息就是没新数据"。所以每 7 天
  # 至少发一条"我还活着"。用 -Heartbeat 开启。
  if ($Heartbeat -and -not $NoNotify) {
    $stampFile = Join-Path $stateDir 'heartbeat.txt'
    $last = $null
    if (Test-Path $stampFile) {
      try { $last = [datetime]::Parse((Get-Content $stampFile -Raw -Encoding UTF8).Trim()) } catch { }
    }
    $due = (-not $last) -or ((New-TimeSpan -Start $last -End (Get-Date)).TotalDays -ge 7)
    if ($due) {
      Send-Notice 'ENSO 巡检正常（暂无新数据）' ('数据仍是 ' + $after + '，没有新数据。') "这条是每 7 天一次的心跳，用来确认自动化还在运行。`r`n不需要你做任何事。`r`n`r`n如果超过 7 天没收到任何消息（连心跳都没有），说明自动巡检可能已经停了。"
      try { [System.IO.File]::WriteAllText($stampFile, (Get-Date -Format 'o'), (New-Object System.Text.UTF8Encoding($false))) } catch { }
      Write-Log '已发送心跳'
    } else {
      Write-Log ('心跳未到期（上次 ' + $last.ToString('yyyy-MM-dd HH:mm') + '，7 天一次）')
    }
  }
  exit 0
}
if (-not $Force -and (-not $after)) {
  Write-Log '读不到数据截止日，保守起见不做更新'
  if (-not $NoNotify) { Send-Notice 'ENSO 巡检异常' '抓取完成但读不到数据截止日，未做更新。' '请手工检查 report/enso_dashboard.html 是否正常生成。' }
  exit 1
}

if ($baseline) {
  Write-Log ('需要更新：已上传 ' + $baseline + ' -> 源 ' + $after + '，开始构建并上传')
} else {
  Write-Log ('无基线可比，保守执行一次构建+上传（源 ' + $after + '）')
}

# ── 3. 构建 + 自检 + 上传（抓取already做过，故 -NoDownload）──────
$uploadArgs = @('-NoDownload')
if ($NoUpload) { $uploadArgs += '-NoUpload' }
try {
  & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot 'Update-And-Upload.ps1') @uploadArgs
  $code = $LASTEXITCODE
} catch {
  $code = 1
  Write-Log ('构建/上传阶段异常: ' + $_.Exception.Message)
}

# ── 3.5 发布网页版到 GitHub（api.github.com，不走 git push）──────
# 本机到 github.com 的 git 通道会被 reset，所以发布走 GitHub REST API。
$publishOk = $true
if ($code -eq 0 -and -not $NoUpload -and -not $NoPublish) {
  Write-Log '发布网页版到 GitHub（api.github.com）'
  try {
    $pubOut = & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot 'Publish-ToGitHub.ps1') -SkipRegenerate 2>&1
    $pubCode = $LASTEXITCODE
    $pubLine = (($pubOut | Out-String) -split "`r?`n" | Where-Object { $_ -match '✓|https://github.com/-/commit|commit/|站点|失败|错误' } | Select-Object -First 2) -join ' | '
    if ($pubCode -ne 0) {
      $publishOk = $false
      Write-Log ('网页版发布失败（exit ' + $pubCode + '）：' + $pubLine)
    } else {
      Write-Log ('网页版已发布：' + $pubLine)
    }
  } catch {
    $publishOk = $false
    Write-Log ('网页版发布异常: ' + $_.Exception.Message)
  }
}

# ── 4. 通知（成功与失败都通知）────────────────────────────────
$version = $after -replace '-', '.'
if ($code -eq 0) {
  Write-Log '全部完成'
  if ($NoUpload) {
    if (-not $NoNotify) {
      Send-Notice 'ENSO 数据已更新（未上传）' ('数据到 ' + $after + '，已构建并通过自检。') ("本次加了 -NoUpload，没有上传。`r`n需要上传时运行：更新小程序.cmd")
    }
  } else {
    if (-not $NoNotify) {
      $pubTxt = if ($publishOk) { '网页版已同步发布。' } else { '⚠ 网页版发布失败，需人工处理（见 report/watch.log）。' }
      Send-Notice 'ENSO 数据已更新并上传' ('数据到 ' + $after + '，版本 ' + $version + ' 已上传。' + $pubTxt) ("下一步（需手动）：微信后台 → 管理 → 版本管理 → 开发版本 → 提交审核`r`n版本号: " + $version)
    }
  }
  exit 0
} else {
  Write-Log ('失败，退出码 ' + $code)
  if (-not $NoNotify) {
    Send-Notice 'ENSO 更新失败' ('数据到 ' + $after + '，但构建或上传失败。') ("退出码: " + $code + "`r`n详细日志: " + $logPath + "`r`n常见原因: 开发者工具未登录 / AppID 冲突 / 进程堆积。")
  }
  exit $code
}
