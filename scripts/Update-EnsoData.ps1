<#
.SYNOPSIS
    ENSO 数据抓取 + HTML 仪表盘生成器（无第三方依赖，兼容 Windows PowerShell 5.1）

.DESCRIPTION
    从 NOAA/CPC 抓取最新 ENSO 指数（周/月），解析后：
      1. 写出 data\processed\nino_weekly.csv    （周 Niño 区指数）
      2. 写出 data\processed\enso_monthly.csv   （月 RONI / ONI / SOI）
      3. 生成 report\enso_dashboard.html        （自包含单文件，离线可看）

.PARAMETER Root
    项目根目录，默认脚本上一级目录。

.PARAMETER NoDownload
    不联网，直接用 data\raw 下的缓存文件重新生成 HTML/CSV。

.PARAMETER Open
    生成后用默认浏览器打开 HTML。

.PARAMETER PublishDir
    额外把页面写成 <PublishDir>\index.html（并放一个 .nojekyll），
    用于 GitHub Pages 等静态托管。

    **默认就是 docs** —— 也就是说本脚本每次运行都会同时刷新报告与线上副本，
    这样不会再出现「report\ 是新数据、docs\ 还是旧数据」的两份不一致。
    只想生成 report\ 时加 -NoPublish。

.PARAMETER NoPublish
    只写 report\enso_dashboard.html，不刷新 docs\ 发布副本。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-EnsoData.ps1

.EXAMPLE
    # 默认同时刷新 docs\；只想要本地报告时：
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-EnsoData.ps1 -NoPublish
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$NoDownload,
    [switch]$Open,
    [string]$PublishDir = 'docs',
    [switch]$NoPublish
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# 发布副本默认开启：report\ 与 docs\ 必须永远同源，否则容易出现「本地是新的、线上还是旧的」
if ($NoPublish) { $PublishDir = '' }

if (-not $Root) {
    if ($PSScriptRoot) { $Root = Split-Path -Parent $PSScriptRoot } else { $Root = (Get-Location).Path }
}
$RawDir = Join-Path $Root 'data\raw'
$ProcDir = Join-Path $Root 'data\processed'
$RepDir = Join-Path $Root 'report'
foreach ($d in @($RawDir, $ProcDir, $RepDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---------------------------------------------------------------- 数据源定义
$Sources = [ordered]@{
    'wksst9120.for'     = 'https://www.cpc.ncep.noaa.gov/data/indices/wksst9120.for'
    'rel_wksst9120.txt' = 'https://www.cpc.ncep.noaa.gov/data/indices/rel_wksst9120.txt'
    'oni.ascii.txt'     = 'https://www.cpc.ncep.noaa.gov/data/indices/oni.ascii.txt'
    'RONI.ascii.txt'    = 'https://www.cpc.ncep.noaa.gov/data/indices/RONI.ascii.txt'
    'Rnino34.ascii.txt' = 'https://www.cpc.ncep.noaa.gov/data/indices/Rnino34.ascii.txt'
    'soi'               = 'https://www.cpc.ncep.noaa.gov/data/indices/soi'
    'sstoi.indices'     = 'https://www.cpc.ncep.noaa.gov/data/indices/sstoi.indices'
    'ensodisc.html'     = 'https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/enso_advisory/ensodisc.shtml'
    'roni_outlook.html' = 'https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/enso/roni/outlook/'
    'roni_prob.html'    = 'https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/enso/roni/probabilities/'
}

function Get-CpcFile {
    param([string]$Name, [string]$Url)
    $path = Join-Path $RawDir $Name
    if ($NoDownload) {
        if (-not (Test-Path $path)) { throw "缺少缓存文件 $path（去掉 -NoDownload 重跑）" }
        $cached = if ($script:Meta.ContainsKey($Name)) { $script:Meta[$Name].lastModified } else { '' }
        if (-not $cached) { $cached = (Get-Item $path).LastWriteTimeUtc.ToString('r') }
        return [pscustomobject]@{ Text = [System.IO.File]::ReadAllText($path); LastModified = [string]$cached }
    }
    $resp = Invoke-WebRequest -Uri $Url -TimeoutSec 90 -UseBasicParsing -Headers @{ 'User-Agent' = 'enso-dashboard/1.0' }
    $text = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    $lm = $resp.Headers['Last-Modified']
    if (-not $lm) { $lm = (Get-Item $path).LastWriteTimeUtc.ToString('r') }
    $script:Meta[$Name] = [ordered]@{ url = $Url; lastModified = [string]$lm; fetchedAt = (Get-Date).ToString('s') }
    [pscustomobject]@{ Text = $text; LastModified = [string]$lm }
}

# 源站 Last-Modified 侧车文件：离线重建时也能显示真实的数据源更新时间
$MetaPath = Join-Path $RawDir '_meta.json'
$script:Meta = @{}
if (Test-Path $MetaPath) {
    try {
        $raw = [System.IO.File]::ReadAllText($MetaPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $script:Meta[$p.Name] = $p.Value }
    } catch { Write-Warning "忽略损坏的 _meta.json：$($_.Exception.Message)" }
}

function Convert-HtmlText {
    param([string]$s)
    if (-not $s) { return '' }
    $s = $s -replace '(?s)<[^>]+>', ''
    # 用数组而非哈希表：PowerShell 哈希键不区分大小写，&ntilde; 与 &Ntilde; 会冲突
    $map = @(
        @('&Ntilde;', 'Ñ'), @('&ntilde;', 'ñ'), @('&nbsp;', ' '), @('&amp;', '&'),
        @('&lt;', '<'), @('&gt;', '>'), @('&quot;', '"'), @('&#39;', "'"),
        @('&aacute;', 'á'), @('&eacute;', 'é'), @('&iacute;', 'í'),
        @('&oacute;', 'ó'), @('&uacute;', 'ú'), @('&deg;', '°'),
        @('&ndash;', '–'), @('&mdash;', '—')
    )
    foreach ($pair in $map) { $s = $s.Replace($pair[0], $pair[1]) }
    $s = [regex]::Replace($s, '&#(\d+);', { param($m) [char][int]$m.Groups[1].Value })
    return ($s -replace '\s+', ' ').Trim()
}

function Parse-Week {
    param([string]$s)
    try { return [datetime]::ParseExact($s, 'ddMMMyyyy', [Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

# ---------------------------------------------------------------- 抓取
if ($NoDownload) { Write-Host '[1/4] 使用本地缓存（-NoDownload）...' -ForegroundColor Cyan }
else { Write-Host '[1/4] 抓取 CPC 数据 ...' -ForegroundColor Cyan }
$files = @{}
$lm = @{}
foreach ($k in $Sources.Keys) {
    $r = Get-CpcFile -Name $k -Url $Sources[$k]
    $files[$k] = $r.Text
    $lm[$k] = $r.LastModified
    $disp = $r.LastModified
    if ($k -like '*.html') { $disp = "$disp  (动态页面，无参考价值)" }
    Write-Host ("      {0,-20} {1}" -f $k, $disp)
}
if (-not $NoDownload) {
    [System.IO.File]::WriteAllText($MetaPath, ($script:Meta | ConvertTo-Json -Depth 6),
        (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- 全球回归图 + 陆地底图
$MapDir = Join-Path $RawDir 'maps'
if (-not (Test-Path $MapDir)) { New-Item -ItemType Directory -Force -Path $MapDir | Out-Null }
$RegBase = 'https://www.cpc.ncep.noaa.gov/products/precip/CWlink/ENSO/regressions/'
$Regression = [ordered]@{
    'DJF' = [ordered]@{ temp = 'diag.temp.regr.DJF.png'; precip = 'diag.prec.regr.DJF.png' }
    'JJA' = [ordered]@{ temp = 'diag.temp.regr.JJA.png'; precip = 'diag.prec.regr.JJA.png' }
}
$mapData = [ordered]@{}
foreach ($season in $Regression.Keys) {
    $entry = [ordered]@{}
    foreach ($kind in @('temp', 'precip')) {
        $fname = $Regression[$season][$kind]
        $local = Join-Path $MapDir $fname
        if ((-not $NoDownload) -or (-not (Test-Path $local))) {
            try {
                Invoke-WebRequest -Uri ($RegBase + $fname) -TimeoutSec 60 -UseBasicParsing -OutFile $local
            } catch { Write-Warning "全球回归图下载失败 $fname : $($_.Exception.Message)" }
        }
        if (Test-Path $local) {
            $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($local))
            $entry[$kind] = "data:image/png;base64,$b64"
            Write-Host ("      map {0,-4} {1,-7} {2:N1} KB" -f $season, $kind, ((Get-Item $local).Length / 1KB))
        } else {
            $entry[$kind] = ''
        }
    }
    $mapData[$season] = $entry
}

# 陆地底图（Natural Earth 110m，由 Node 脚本简化生成）
$BasemapFile = Join-Path $ProcDir 'basemap.txt'
if (-not (Test-Path $BasemapFile)) {
    $nodeExe = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeExe) {
        Write-Host '      生成陆地底图（Natural Earth 110m）...'
        & $nodeExe.Source (Join-Path $PSScriptRoot 'build-basemap.mjs') | Out-Null
    } else {
        Write-Warning '未找到 node，跳过陆地底图；运行 node scripts\build-basemap.mjs 后重跑本脚本即可。'
    }
}
$basemapPath = if (Test-Path $BasemapFile) { [System.IO.File]::ReadAllText($BasemapFile).Trim() } else { '' }

# ---------------------------------------------------------------- 课题组二维码（页脚作者信息用）
# 唯一来源：仓库内 assets\qrcode.jpg（自定义二维码请直接替换该文件）
$QrAsset = Join-Path $Root 'assets\qrcode.jpg'
$qrFile = if (Test-Path $QrAsset) { $QrAsset } else { '' }
if (-not $qrFile) { Write-Warning 'assets\qrcode.jpg 不存在，页脚将不显示二维码' }
$qrcodeData = if ($qrFile) {
    'data:image/jpeg;base64,' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($qrFile))
} else { '' }
if ($qrFile) { Write-Host ("      qrcode {0,-28} {1,6:N1} KB" -f (Split-Path -Leaf $qrFile), ((Get-Item $qrFile).Length / 1KB)) }


# ---------------------------------------------------------------- 解析：周指数
Write-Host '[2/4] 解析指数 ...' -ForegroundColor Cyan

# 绝对周指数：SST + SSTA（SSTA 为负时与 SST 连写，故用配对正则）
$weeklyAbs = @{}
foreach ($line in ($files['wksst9120.for'] -split "`r?`n")) {
    $m = [regex]::Match($line, '^\s*(\d{2}[A-Z]{3}\d{4})\s+(.+?)\s*$')
    if (-not $m.Success) { continue }
    $pairs = [regex]::Matches($m.Groups[2].Value, '(-?\d+\.\d+)\s*(-?\d+\.\d+)')
    if ($pairs.Count -lt 4) { continue }
    $key = $m.Groups[1].Value
    $weeklyAbs[$key] = @(
        [double]$pairs[0].Groups[1].Value, [double]$pairs[0].Groups[2].Value,
        [double]$pairs[1].Groups[1].Value, [double]$pairs[1].Groups[2].Value,
        [double]$pairs[2].Groups[1].Value, [double]$pairs[2].Groups[2].Value,
        [double]$pairs[3].Groups[1].Value, [double]$pairs[3].Groups[2].Value
    )
}

# 相对周指数（RONI 口径的周版）
$weeklyRel = @{}
foreach ($line in ($files['rel_wksst9120.txt'] -split "`r?`n")) {
    $m = [regex]::Match($line, '^\s*(\d{2}[A-Z]{3}\d{4})\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s*$')
    if (-not $m.Success) { continue }
    $weeklyRel[$m.Groups[1].Value] = @(
        [double]$m.Groups[2].Value, [double]$m.Groups[3].Value,
        [double]$m.Groups[4].Value, [double]$m.Groups[5].Value
    )
}

# 合并周序列（取绝对与相对的并集键，按日期排序）
$weekRows = New-Object System.Collections.Generic.List[object]
$allWeeks = @($weeklyAbs.Keys + $weeklyRel.Keys | Sort-Object -Unique)
foreach ($w in $allWeeks) {
    $dt = Parse-Week $w
    if (-not $dt) { continue }
    $a = if ($weeklyAbs.ContainsKey($w)) { $weeklyAbs[$w] } else { @($null) * 8 }
    $b = if ($weeklyRel.ContainsKey($w)) { $weeklyRel[$w] } else { @($null) * 4 }
    $weekRows.Add([pscustomobject]@{
        Week    = $dt
        WeekTag = $w
        N12SST  = $a[0]; N12SSTA = $a[1]
        N3SST   = $a[2]; N3SSTA  = $a[3]
        N34SST  = $a[4]; N34SSTA = $a[5]
        N4SST   = $a[6]; N4SSTA  = $a[7]
        R12     = $b[0]; R3      = $b[1]
        R34     = $b[2]; R4      = $b[3]
    })
}
$weekRows = @($weekRows | Sort-Object Week)

# 月度：RONI / ONI（3 个月滑动季节值）
function Parse-SeasonFile {
    param([string]$Text, [switch]$HasTotal)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($Text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*([A-Z]{3})\s+(\d{4})\s+(-?\d+\.\d+)(?:\s+(-?\d+\.\d+))?\s*$')
        if (-not $m.Success) { continue }
        $anom = if ($HasTotal -and $m.Groups[4].Success) { [double]$m.Groups[4].Value } else { [double]$m.Groups[3].Value }
        $out.Add([pscustomobject]@{ Season = $m.Groups[1].Value; Year = [int]$m.Groups[2].Value; Anom = $anom })
    }
    return $out
}
$roniRows = Parse-SeasonFile -Text $files['RONI.ascii.txt']
$oniRows = Parse-SeasonFile -Text $files['oni.ascii.txt'] -HasTotal

# 月度 Niño3.4（相对，逐月）
$n34mRows = New-Object System.Collections.Generic.List[object]
foreach ($line in ($files['Rnino34.ascii.txt'] -split "`r?`n")) {
    $m = [regex]::Match($line, '^\s*(\d{4})\s+(\d{1,2})\s+(-?\d+\.\d+)\s*$')
    if ($m.Success) {
        $n34mRows.Add([pscustomobject]@{ Year = [int]$m.Groups[1].Value; Mon = [int]$m.Groups[2].Value; Anom = [double]$m.Groups[3].Value })
    }
}

# 月度 SOI（定宽、负值连写、-999.9 为缺测）
$soiRows = New-Object System.Collections.Generic.List[object]
foreach ($line in ($files['soi'] -split "`r?`n")) {
    $m = [regex]::Match($line, '^(\d{4})\s*(.+)$')
    if (-not $m.Success) { continue }
    $vals = [regex]::Matches($m.Groups[2].Value, '-?\d+\.\d+') | ForEach-Object { [double]$_.Value }
    if ($vals.Count -lt 12) { continue }
    for ($i = 0; $i -lt 12; $i++) {
        if ($vals[$i] -le -999) { continue }
        $soiRows.Add([pscustomobject]@{ Year = [int]$m.Groups[1].Value; Mon = $i + 1; Anom = $vals[$i] })
    }
}

# ---------------------------------------------------------------- 解析：官方展望
$status = [pscustomobject]@{ Alert = 'n/a'; Issued = ''; Next = ''; Synopsis = '' }
$t = $files['ensodisc.html']
$m = [regex]::Match($t, 'Alert System Status:[\s\S]{0,400}?<span[^>]*>([^<]+)</span>')
if ($m.Success) { $status.Alert = (Convert-HtmlText $m.Groups[1].Value) }
$m = [regex]::Match($t, 'DIAGNOSTIC DISCUSSION[\s\S]{0,600}?(\d{1,2}\s+[A-Z][a-z]+\s+\d{4})')
if ($m.Success) { $status.Issued = $m.Groups[1].Value }
$m = [regex]::Match($t, 'scheduled for\s*(?:<[^>]+>\s*)*(\d{1,2}\s+[A-Z][a-z]+\s+\d{4})')
if ($m.Success) { $status.Next = $m.Groups[1].Value }
$m = [regex]::Match($t, '(?s)Synopsis:[\s\S]{0,40}?<strong>([\s\S]*?)</strong>')
if ($m.Success) { $status.Synopsis = (Convert-HtmlText $m.Groups[1].Value) }

# 季节概率表（La Nina / Neutral / El Nino）
$prob = New-Object System.Collections.Generic.List[object]
$m = [regex]::Match($files['roni_prob.html'], '(?s)<table id="probabilities-table".*?</table>')
if ($m.Success) {
    foreach ($row in [regex]::Matches($m.Value, '(?s)<tr><th scope="row">.*?</tr>')) {
        $s = [regex]::Match($row.Value, '<abbr>([A-Z]{3})')
        $t2 = [regex]::Matches($row.Value, '<td>(\d+)</td>')
        if ($s.Success -and $t2.Count -ge 3) {
            $prob.Add([pscustomobject]@{
                Season = $s.Groups[1].Value
                La = [int]$t2[0].Groups[1].Value; Neu = [int]$t2[1].Groups[1].Value; El = [int]$t2[2].Groups[1].Value
            })
        }
    }
}

# RONI 分位数展望表（必须锚定 table id，否则会命中侧边栏的第一个 tbody）
$fcst = New-Object System.Collections.Generic.List[object]
$m = [regex]::Match($files['roni_outlook.html'], '(?s)id="outlook-table".*?<tbody>(.*?)</tbody>')
if ($m.Success) {
    foreach ($row in [regex]::Matches($m.Groups[1].Value, '(?s)<tr><th scope="row">.*?</tr>')) {
        $s = [regex]::Match($row.Value, '<abbr>([A-Z]{3})')
        $v = [regex]::Matches($row.Value, '<td>(-?\d+\.\d+)</td>') | ForEach-Object { [double]$_.Groups[1].Value }
        if ($s.Success -and $v.Count -ge 7) {
            $fcst.Add([pscustomobject]@{
                Season = $s.Groups[1].Value
                P05 = $v[0]; P15 = $v[1]; P25 = $v[2]; P50 = $v[3]; P75 = $v[4]; P85 = $v[5]; P95 = $v[6]
            })
        }
    }
}

if ($weekRows.Count -eq 0) { throw '周指数解析失败：请检查数据源格式是否变动。' }
$latest = $weekRows[-1]

# ---------------------------------------------------------------- 落盘 CSV
Write-Host '[3/4] 写出 CSV ...' -ForegroundColor Cyan
$weekRows | Select-Object @{n = 'week'; e = { $_.Week.ToString('yyyy-MM-dd') } }, WeekTag,
    N12SST, N12SSTA, N3SST, N3SSTA, N34SST, N34SSTA, N4SST, N4SSTA, R12, R3, R34, R4 |
    Export-Csv -Path (Join-Path $ProcDir 'nino_weekly.csv') -NoTypeInformation -Encoding UTF8

$soiMap = @{}
foreach ($r in $soiRows) { $soiMap["$($r.Year)-$($r.Mon)"] = $r.Anom }
$n34Map = @{}
foreach ($r in $n34mRows) { $n34Map["$($r.Year)-$($r.Mon)"] = $r.Anom }
$roniMap = @{}
foreach ($r in $roniRows) { $roniMap["$($r.Year)-$($r.Season)"] = $r.Anom }
$oniMap = @{}
foreach ($r in $oniRows) { $oniMap["$($r.Year)-$($r.Season)"] = $r.Anom }

$monthlyRows = New-Object System.Collections.Generic.List[object]
$now = Get-Date
$startMonth = Get-Date -Year 1950 -Month 1 -Day 1
$spanMonths = (($now.Year - $startMonth.Year) * 12) + ($now.Month - $startMonth.Month)
for ($i = $spanMonths; $i -ge 0; $i--) {
    $d = $now.AddMonths(-$i)
    $k = "$($d.Year)-$($d.Month)"
    $monthlyRows.Add([pscustomobject]@{
        ym = $d.ToString('yyyy-MM')
        rnino34 = if ($n34Map.ContainsKey($k)) { $n34Map[$k] } else { $null }
        soi = if ($soiMap.ContainsKey($k)) { $soiMap[$k] } else { $null }
    })
}
$monthlyRows | Export-Csv -Path (Join-Path $ProcDir 'enso_monthly.csv') -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- 组装 JSON
Write-Host '[4/4] 生成 HTML 仪表盘 ...' -ForegroundColor Cyan

# 图表内嵌完整历史（周：1981 年至今；月：1950 年至今），窗口长度由页面上的年数按钮控制
$chartWeeks = @($weekRows)
$chartMonthly = @($monthlyRows | Where-Object { $null -ne $_.rnino34 })

function R2($v) { if ($null -eq $v) { return $null } else { return [math]::Round([double]$v, 2) } }
function Arr($items) { return @($items) }

# 三个动态 HTML 页面的 Last-Modified 等于请求时刻，改显示"内容日期"
$outlookIssued = ''
$m = [regex]::Match($files['roni_outlook.html'], 'Issued\s+([A-Z][a-z]+\s+\d{4})')
if ($m.Success) { $outlookIssued = $m.Groups[1].Value }
$lmDisplay = @{}
foreach ($k in $lm.Keys) { $lmDisplay[$k] = $lm[$k] }
$lmDisplay['ensodisc.html'] = if ($status.Issued) { "内容日期 $($status.Issued)" } else { '动态页面' }
$lmDisplay['roni_outlook.html'] = if ($outlookIssued) { "内容日期 $outlookIssued" } else { '动态页面' }
$lmDisplay['roni_prob.html'] = $lmDisplay['roni_outlook.html']

$payload = [ordered]@{
    generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    status    = [ordered]@{ alert = $status.Alert; issued = $status.Issued; next = $status.Next; synopsis = $status.Synopsis }
    qrcode    = $qrcodeData
    span      = [ordered]@{
        weeklyFirst  = $chartWeeks[0].Week.ToString('yyyy-MM-dd')
        weeklyLast   = $chartWeeks[-1].Week.ToString('yyyy-MM-dd')
        weeklyN      = $chartWeeks.Count
        monthlyFirst = $chartMonthly[0].ym
        monthlyLast  = $chartMonthly[-1].ym
        monthlyN     = $chartMonthly.Count
    }
    weekly    = [ordered]@{
        labels = Arr($chartWeeks | ForEach-Object { $_.Week.ToString('yyyy-MM-dd') })
        n12    = Arr($chartWeeks | ForEach-Object { R2 $_.N12SSTA })
        n3     = Arr($chartWeeks | ForEach-Object { R2 $_.N3SSTA })
        n34    = Arr($chartWeeks | ForEach-Object { R2 $_.N34SSTA })
        n4     = Arr($chartWeeks | ForEach-Object { R2 $_.N4SSTA })
        r34    = Arr($chartWeeks | ForEach-Object { R2 $_.R34 })
    }
    basemap = $basemapPath
    maps    = $mapData
    weeklyLatest = [ordered]@{
        tag = $latest.Week.ToString('yyyy-MM-dd')
        n12 = R2 $latest.N12SSTA; n3 = R2 $latest.N3SSTA; n34 = R2 $latest.N34SSTA; n4 = R2 $latest.N4SSTA
        r12 = R2 $latest.R12; r3 = R2 $latest.R3; r34 = R2 $latest.R34; r4 = R2 $latest.R4
    }
    weeklyTable = Arr($weekRows | Select-Object -Last 8 | ForEach-Object {
            [ordered]@{ week = $_.Week.ToString('yyyy-MM-dd'); n12 = R2 $_.N12SSTA; n3 = R2 $_.N3SSTA
                        n34 = R2 $_.N34SSTA; n4 = R2 $_.N4SSTA; r34 = R2 $_.R34 }
        })
    monthly = [ordered]@{
        labels = Arr($chartMonthly | ForEach-Object { $_.ym })
        roni   = Arr($chartMonthly | ForEach-Object { R2 $_.rnino34 })
        soi    = Arr($chartMonthly | ForEach-Object { R2 $_.soi })
    }
    oniSeasonal = Arr(($oniRows | Select-Object -Last 8) | ForEach-Object { [ordered]@{ season = "$($_.Season) $($_.Year)"; v = R2 $_.Anom } })
    roniSeasonal = Arr(($roniRows | Select-Object -Last 8) | ForEach-Object { [ordered]@{ season = "$($_.Season) $($_.Year)"; v = R2 $_.Anom } })
    prob  = Arr($prob | ForEach-Object { [ordered]@{ season = $_.Season; la = $_.La; neu = $_.Neu; el = $_.El } })
    fcst  = Arr($fcst | ForEach-Object { [ordered]@{ season = $_.Season; p05 = $_.P05; p15 = $_.P15; p25 = $_.P25; p50 = $_.P50; p75 = $_.P75; p85 = $_.P85; p95 = $_.P95 } })
    sources = Arr(@(
            [ordered]@{ name = 'CPC 周度 ENSO 监测（实况）'; cadence = '每周（多为周四周五）'; url = 'https://www.cpc.ncep.noaa.gov/products/precip/CWlink/MJO/enso.shtml'; updated = $lm['wksst9120.for'] }
            [ordered]@{ name = 'CPC 周指数文本（本页数据）'; cadence = '每周'; url = 'https://www.cpc.ncep.noaa.gov/data/indices/wksst9120.for'; updated = $lm['wksst9120.for'] }
            [ordered]@{ name = 'CPC 周指数文本（相对/剔除增暖）'; cadence = '每周'; url = 'https://www.cpc.ncep.noaa.gov/data/indices/rel_wksst9120.txt'; updated = $lm['rel_wksst9120.txt'] }
            [ordered]@{ name = 'CPC 月度 ENSO 诊断（官方定级）'; cadence = '每月第二个周四'; url = 'https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/enso_advisory/ensodisc.shtml'; updated = $lmDisplay['ensodisc.html'] }
            [ordered]@{ name = 'CPC 官方 RONI 展望 / 概率'; cadence = '每月第二个周四'; url = 'https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/enso/roni/outlook/'; updated = $lmDisplay['roni_outlook.html'] }
            [ordered]@{ name = 'IRI/CPC 多模式 plume 预报'; cadence = '每月约 19 日'; url = 'https://iri.columbia.edu/our-expertise/climate/forecasts/enso/current/'; updated = '' }
            [ordered]@{ name = 'JMA エルニーニョ監視速報'; cadence = '每月约 10 日'; url = 'https://www.data.jma.go.jp/cpd/elnino/index.html'; updated = '' }
            [ordered]@{ name = 'BoM ENSO Wrap-Up（含每日 SOI）'; cadence = '每两周（周二）'; url = 'http://www.bom.gov.au/climate/enso/'; updated = '' }
            [ordered]@{ name = '国家气候中心（中国业务口径）'; cadence = '月度'; url = 'https://cmdp.ncc-cma.net/pred/cn_enso.php?product=cn_enso_bj'; updated = '' }
            [ordered]@{ name = 'NOAA PSL 月度指数库（ONI/RONI/MEI/SOI）'; cadence = '月度'; url = 'https://psl.noaa.gov/data/timeseries/month/'; updated = '' }
            [ordered]@{ name = 'CPC 周度演进/现状/预测 PDF'; cadence = '每周'; url = 'https://www.cpc.ncep.noaa.gov/products/analysis_monitoring/lanina/enso_evolution-status-fcsts-web.pdf'; updated = '' }
        ))
}
$json = $payload | ConvertTo-Json -Depth 12 -Compress

# ---------------------------------------------------------------- HTML 模板
# 模板外置为 scripts\dashboard.template.html：
#   · 网页版样式与交互全在其中，改版不必碰 PowerShell 的引号转义规则
#   · __ENSO_DATA__ 是数据占位符，生成时替换为压缩后的 JSON
#   · 模板里含 ${...} 模板字面量，必须用单引号 here-string 读入，否则 PowerShell 会展开变量
$template = [System.IO.File]::ReadAllText(
    (Join-Path $PSScriptRoot 'dashboard.template.html'),
    [System.Text.Encoding]::UTF8)
if (-not $template) { throw 'missing scripts\dashboard.template.html' }

$html = $template.Replace('__ENSO_DATA__', $json)
$outHtml = Join-Path $RepDir 'enso_dashboard.html'
[System.IO.File]::WriteAllText($outHtml, $html, (New-Object System.Text.UTF8Encoding($true)))

# ---------------------------------------------------------------- 静态托管副本（GitHub Pages 等）
# 默认写入 docs\index.html：report\ 与 docs\ 必须同源，避免线上落后于本地
$pagesHtml = ''
if ($PublishDir) {
    $pd = if ([System.IO.Path]::IsPathRooted($PublishDir)) { $PublishDir } else { Join-Path $Root $PublishDir }
    if (-not (Test-Path $pd)) { New-Item -ItemType Directory -Force -Path $pd | Out-Null }
    $pagesHtml = Join-Path $pd 'index.html'
    # 面向 Web 的副本不带 BOM（页面已声明 <meta charset="utf-8">）
    [System.IO.File]::WriteAllText($pagesHtml, $html, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $pd '.nojekyll'), '')
}

# ---------------------------------------------------------------- 控制台摘要
function Fmt-Anom {
    param($v, [int]$d = 1)
    if ($null -eq $v) { return 'n/a' }
    $x = [double]$v
    $s = $x.ToString("F$d")
    if ($x -gt 0) { $s = "+$s" }
    return $s
}

Write-Host ''
Write-Host ('=== 最新周（中心日 {0}）===' -f $latest.Week.ToString('yyyy-MM-dd')) -ForegroundColor Green
Write-Host ('  Niño1+2 {0,6}   Niño3 {1,6}   Niño3.4 {2,6}   Niño4 {3,6}   (距平 °C)' -f `
    (Fmt-Anom $latest.N12SSTA), (Fmt-Anom $latest.N3SSTA), (Fmt-Anom $latest.N34SSTA), (Fmt-Anom $latest.N4SSTA))
Write-Host ('  Niño3.4 相对 {0,6}' -f (Fmt-Anom $latest.R34)) -ForegroundColor DarkCyan
if ($roniRows.Count) {
    $r = $roniRows[-1]
    Write-Host ('  最新 RONI 季节值：{0} {1} = {2}' -f $r.Season, $r.Year, (Fmt-Anom $r.Anom 2))
}
if ($prob.Count) {
    Write-Host ('  官方概率：' + (($prob | Select-Object -First 4 | ForEach-Object { "$($_.Season) El=$($_.El)%" }) -join '  '))
}
Write-Host ''
Write-Host ('HTML : {0}' -f $outHtml) -ForegroundColor Green
Write-Host ('CSV  : {0}' -f (Join-Path $ProcDir 'nino_weekly.csv'))
Write-Host ('CSV  : {0}' -f (Join-Path $ProcDir 'enso_monthly.csv'))
if ($pagesHtml) { Write-Host ('Pages: {0}' -f $pagesHtml) -ForegroundColor Green }

if ($Open) { Start-Process $outHtml }
