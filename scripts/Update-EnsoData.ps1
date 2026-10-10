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
    用于 GitHub Pages 等静态托管，例如 -PublishDir docs。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-EnsoData.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Update-EnsoData.ps1 -PublishDir docs
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$NoDownload,
    [switch]$Open,
    [string]$PublishDir
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

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
$template = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ENSO 监测仪表盘</title>
<style>
  :root{
    --bg:#0b1220; --panel:#131c2e; --panel2:#18233a; --line:#25324d;
    --fg:#e6edf7; --muted:#93a3bd; --accent:#38bdf8;
    --n12:#f97316; --n3:#ef4444; --n34:#38bdf8; --n4:#a78bfa; --rel:#22d3ee;
    --warn:#fbbf24; --bad:#f87171; --good:#34d399;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);
       font:14px/1.6 "Segoe UI","Microsoft YaHei",system-ui,-apple-system,sans-serif}
  a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline}
  .wrap{max-width:1180px;margin:0 auto;padding:22px 18px 60px}
  header{display:flex;flex-wrap:wrap;gap:14px;align-items:flex-end;justify-content:space-between;
         padding-bottom:14px;border-bottom:1px solid var(--line)}
  h1{margin:0;font-size:22px;letter-spacing:.4px}
  .sub{color:var(--muted);font-size:12.5px}
  .badge{display:inline-block;padding:3px 10px;border-radius:999px;font-weight:600;font-size:13px;
         background:rgba(251,191,36,.14);color:var(--warn);border:1px solid rgba(251,191,36,.35)}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:18px 0 6px}
  .card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);
        border-radius:12px;padding:13px 15px}
  .card .k{color:var(--muted);font-size:12px}
  .card .v{font-size:26px;font-weight:700;line-height:1.25;font-variant-numeric:tabular-nums}
  .card .t{color:var(--muted);font-size:11.5px}
  .pos{color:var(--bad)} .neg{color:var(--accent)}
  section{background:var(--panel);border:1px solid var(--line);border-radius:12px;
          padding:16px 18px;margin-top:16px}
  h2{margin:0 0 4px;font-size:16px}
  h2 .hint{color:var(--muted);font-weight:400;font-size:12.5px;margin-left:8px}
  canvas{width:100%;height:260px;display:block}
  table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
  th,td{padding:7px 9px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}
  th:first-child,td:first-child{text-align:left}
  thead th{color:var(--muted);font-weight:600;font-size:12.5px;position:sticky;top:0;background:var(--panel)}
  tbody tr:hover{background:rgba(56,189,248,.06)}
  .scroll{overflow:auto;max-height:420px;border-radius:8px}
  .legend{display:flex;flex-wrap:wrap;gap:14px;color:var(--muted);font-size:12.5px;margin:8px 0 2px}
  .legend i{display:inline-block;width:13px;height:3px;border-radius:2px;margin-right:5px;vertical-align:middle}
  .note{color:var(--muted);font-size:12.5px;margin-top:10px}
  .syn{background:rgba(56,189,248,.07);border-left:3px solid var(--accent);border-radius:0 8px 8px 0;
       padding:10px 13px;margin-top:10px;font-size:13.5px}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px}
  @media(max-width:820px){.grid2{grid-template-columns:1fr}}
  /* ---- 影响区地图 ---- */
  .mapbar{display:flex;flex-wrap:wrap;gap:14px;align-items:center;justify-content:space-between;margin:12px 0 8px}
  .switch{display:flex;gap:6px}
  .switch button{background:var(--panel2);color:var(--muted);border:1px solid var(--line);
                 border-radius:8px;padding:6px 13px;font:inherit;font-size:13px;cursor:pointer;transition:.15s}
  .switch button:hover{color:var(--fg)}
  .switch button.on{background:rgba(56,189,248,.16);color:var(--fg);border-color:var(--accent)}
  .mapbox{background:#0a1526;border:1px solid var(--line);border-radius:10px;padding:8px;overflow:hidden}
  #impactMap{width:100%;height:auto;display:block}
  .ocean{fill:#0a1526}
  .land{fill:#1e2b44;stroke:#3a4a6b;stroke-width:.3}
  .zone{stroke-width:0}
  .zone.wet{fill:#38bdf8}
  .zone.dry{fill:#f59e0b}
  .zone.warm{fill:#ef4444}
  .zone.cool{fill:#a78bfa}
  .marker{fill:#0b1220;stroke:#e6edf7;stroke-width:.45}
  .marktext{fill:#e6edf7;font-size:4.6px;text-anchor:middle;dominant-baseline:central;font-weight:700}
  .nino34{fill:rgba(34,211,238,.10);stroke:#22d3ee;stroke-width:.5;stroke-dasharray:1.8 1.4}
  .maplabel{fill:#22d3ee;font-size:4.4px;text-anchor:middle;font-weight:600}
  .sw{display:inline-block;width:11px;height:11px;border-radius:3px;margin-right:5px;vertical-align:-1px;opacity:.55}
  .sw.wet{background:#38bdf8}.sw.dry{background:#f59e0b}.sw.warm{background:#ef4444}.sw.cool{background:#a78bfa}
  .sw.box{background:rgba(34,211,238,.12);border:1.4px dashed #22d3ee;border-radius:2px;width:12px;height:9px}
  .figmap{margin:0 0 12px}
  .figmap img{width:100%;border-radius:8px;border:1px solid var(--line);display:block}
  .figmap figcaption{color:var(--muted);font-size:12px;margin-top:6px}
  /* ---- 图表工具条 ---- */
  .chartbar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;margin-top:8px}
  .chartbar .note{margin:0;font-variant-numeric:tabular-nums}
  .mini{background:var(--panel2);color:var(--muted);border:1px solid var(--line);border-radius:7px;
        padding:4px 10px;font:inherit;font-size:12px;cursor:pointer;white-space:nowrap}
  .mini:hover{color:var(--fg);border-color:var(--accent)}
  canvas{cursor:crosshair}
  /* ---- 页脚作者信息卡片 ---- */
  .author{display:flex;gap:26px;align-items:flex-start;flex-wrap:wrap;margin-top:20px;
          background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);
          border-radius:12px;padding:16px 18px}
  .who-info h3{margin:0 0 8px;font-size:14px;color:var(--fg);border-left:3px solid var(--accent);padding-left:9px}
  .who-info p{margin:4px 0;font-size:13px;line-height:1.7;color:var(--muted)}
  .who-info b{color:var(--fg)}
  .who-info a{color:var(--accent)}
  .who-qr{margin-left:auto;text-align:center}
  .who-qr img{width:104px;height:104px;border-radius:8px;background:#fff;padding:3px;display:block;margin:0 auto}
  .who-qr p{margin:6px 0 0;font-size:12px;color:var(--muted)}
  footer{margin-top:14px}
  .conf{letter-spacing:1px;font-size:12px}
  .conf.hi{color:var(--good)} .conf.mid{color:var(--warn)} .conf.lo{color:var(--muted)}
  footer{color:var(--muted);font-size:12px;margin-top:22px;text-align:center}
  code{background:var(--panel2);padding:1px 6px;border-radius:5px;font-size:12.5px}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>ENSO 监测仪表盘 <span class="badge" id="alertBadge">—</span></h1>
      <div class="sub">数据源：NOAA/CPC（周指数、月度诊断、官方 RONI 概率展望）　·　生成时间 <span id="gen">—</span></div>
    </div>
    <div class="sub" id="issued"></div>
  </header>

  <div class="cards" id="cards"></div>

  <section>
    <h2>官方结论<span class="hint">NOAA CPC ENSO Diagnostic Discussion</span></h2>
    <div class="syn" id="synopsis">—</div>
    <div class="note" id="nextDisc"></div>
  </section>

  <section>
    <h2>周 Niño 区海温距平<span class="hint" id="hintWeekly">OISST v2.1 / 1991–2020 基准</span></h2>
    <div class="legend">
      <span><i style="background:var(--n12)"></i>Niño1+2</span>
      <span><i style="background:var(--n3)"></i>Niño3</span>
      <span><i style="background:var(--n34)"></i>Niño3.4</span>
      <span><i style="background:var(--n4)"></i>Niño4</span>
      <span><i style="background:var(--rel)"></i>Niño3.4 相对值（R 口径）</span>
    </div>
    <canvas id="cvWeekly"></canvas>
    <div class="chartbar">
      <div class="switch" id="spanWeekly">
        <button type="button" data-years="1">1 年</button>
        <button type="button" data-years="3" class="on">3 年</button>
        <button type="button" data-years="5">5 年</button>
        <button type="button" data-years="10">10 年</button>
        <button type="button" data-years="20">20 年</button>
        <button type="button" data-years="0">全部</button>
      </div>
      <span class="note" id="rangeWeekly"></span>
      <button type="button" class="mini" id="resetWeekly">复位</button>
    </div>
    <div class="scroll" style="margin-top:12px">
      <table id="tblWeekly">
        <thead><tr><th>周（中心日）</th><th>Niño1+2</th><th>Niño3</th><th>Niño3.4</th><th>Niño4</th><th>Niño3.4 相对</th></tr></thead>
        <tbody></tbody>
      </table>
    </div>
  </section>

  <section>
    <h2>典型受影响区域（预报地图）<span class="hint">El Niño 遥相关 · 历史合成/回归倾向，非确定性预报</span></h2>
    <div class="mapbar">
      <div class="switch" id="seasonSwitch">
        <button type="button" data-season="DJF" class="on">DJF（峰值季）</button>
        <button type="button" data-season="JJA">JJA（次年夏季）</button>
      </div>
      <div class="legend">
        <span><i class="sw wet"></i>偏多雨 / 洪涝</span>
        <span><i class="sw dry"></i>偏干旱</span>
        <span><i class="sw warm"></i>偏暖</span>
        <span><i class="sw cool"></i>偏凉</span>
        <span><i class="sw box"></i>Niño3.4 监测区</span>
      </div>
    </div>
    <div class="mapbox">
      <svg id="impactMap" viewBox="0 0 360 180" preserveAspectRatio="xMidYMid meet" role="img"
           aria-label="El Niño 典型影响区示意图（等经纬度投影，太平洋居中）">
        <rect class="ocean" x="0" y="0" width="360" height="180"></rect>
        <path id="landPath" class="land" d=""></path>
        <g id="zoneLayer"></g>
        <rect class="nino34" id="nino34Box" x="10" y="85" width="50" height="10" rx="1"></rect>
        <text class="maplabel" id="nino34Label" x="35" y="82.5">Niño3.4</text>
        <g id="markerLayer"></g>
      </svg>
    </div>
    <div class="grid2" style="margin-top:14px">
      <div>
        <table id="tblImpact">
          <thead><tr><th>#</th><th>区域</th><th>倾向</th><th>把握度</th></tr></thead>
          <tbody></tbody>
        </table>
        <div class="note" id="impactNote"></div>
      </div>
      <div>
        <figure class="figmap">
          <img id="imgTemp" alt="NOAA CPC 全球 ENSO 温度线性回归图">
          <figcaption id="capTemp"></figcaption>
        </figure>
        <figure class="figmap">
          <img id="imgPrec" alt="NOAA CPC 全球 ENSO 降水线性回归图">
          <figcaption id="capPrec"></figcaption>
        </figure>
      </div>
    </div>
  </section>

  <div class="grid2">
    <section>
      <h2>近月相对 Niño3.4（RONI 逐月）<span class="hint" id="hintMonthly">月度 · 可缩放</span></h2>
      <canvas id="cvMonthly" style="height:230px"></canvas>
      <div class="chartbar">
        <div class="switch" id="spanMonthly">
          <button type="button" data-years="1">1 年</button>
          <button type="button" data-years="5">5 年</button>
          <button type="button" data-years="10" class="on">10 年</button>
          <button type="button" data-years="30">30 年</button>
          <button type="button" data-years="0">全部</button>
        </div>
        <span class="note" id="rangeMonthly"></span>
        <button type="button" class="mini" id="resetMonthly">复位</button>
      </div>
    </section>
    <section>
      <h2>CPC 官方 RONI 分位展望<span class="hint">未来 9 个重叠 3 月季</span></h2>
      <canvas id="cvFan" style="height:230px"></canvas>
      <div class="legend"><span><i style="background:var(--n34)"></i>中位（P50）</span><span><i style="background:rgba(56,189,248,.35)"></i>P5–P95 区间</span></div>
    </section>
  </div>

  <div class="grid2">
    <section>
      <h2>El Niño / 中性 / La Niña 概率<span class="hint">CPC 官方展望</span></h2>
      <div class="scroll" style="max-height:360px">
        <table id="tblProb">
          <thead><tr><th>季节</th><th>La Niña</th><th>中性</th><th>El Niño</th></tr></thead>
          <tbody></tbody>
        </table>
      </div>
    </section>
    <section>
      <h2>RONI 分位数值<span class="hint">P5 / P25 / P50 / P75 / P95</span></h2>
      <div class="scroll" style="max-height:360px">
        <table id="tblFcst">
          <thead><tr><th>季节</th><th>P5</th><th>P25</th><th>P50</th><th>P75</th><th>P95</th></tr></thead>
          <tbody></tbody>
        </table>
      </div>
    </section>
  </div>

  <section>
    <h2>季节指数历史值<span class="hint">3 个月滑动</span></h2>
    <div class="grid2">
      <div class="scroll"><table id="tblOni"><thead><tr><th>ONI 季节</th><th>Anomaly</th></tr></thead><tbody></tbody></table></div>
      <div class="scroll"><table id="tblRoni"><thead><tr><th>RONI 季节</th><th>Anomaly</th></tr></thead><tbody></tbody></table></div>
    </div>
  </section>

  <section>
    <h2>数据源与更新节奏</h2>
    <div class="scroll">
      <table id="tblSrc">
        <thead><tr><th>来源</th><th>更新频率</th><th>源站最后修改</th></tr></thead>
        <tbody></tbody>
      </table>
    </div>
    <div class="note">
      <b>口径提醒</b>：ONI（ERSSTv5，1971–2000 基准，含全球增暖）／RONI（ERSSTv6，1991–2020 基准，已扣除 20°N–20°S 热带平均增暖，CPC 现行官方验证指标）／周 Niño3.4（OISST v2.1）三者数值不可混用；
      阈值判定与趋势比较请全程使用同一套指数。ENSO 官方指数<b>不存在日频标准产品</b>，周频已是最高时效。
    </div>
  </section>

  <section class="author" id="author">
    <div class="who-info">
      <h3>作者</h3>
      <p><b>彭桢燃</b>（Zhenran Peng）· 中国地质大学（武汉）</p>
      <p>邮箱：<a href="mailto:zhenran.peng@cug.edu.cn">zhenran.peng@cug.edu.cn</a></p>
      <p>课题组：地球重力与人类生活（TVGG）</p>
      <p>GitHub：<a href="https://github.com/pengzhenran" target="_blank" rel="noopener">github.com/pengzhenran</a></p>
    </div>
    <div class="who-qr" id="whoQr">
      <img id="qrImg" alt="课题组公众号二维码" decoding="async">
      <p>课题组公众号</p>
    </div>
  </section>

  <footer>由 <code>scripts\Update-EnsoData.ps1</code> 自动生成 · 数据版权归各来源机构所有 · 本页仅供监测参考，不构成预报结论</footer>
</div>

<script>
const DATA = __ENSO_DATA__;
const C = {n12:'#f97316',n3:'#ef4444',n34:'#38bdf8',n4:'#a78bfa',rel:'#22d3ee',
           grid:'#25324d',fg:'#e6edf7',muted:'#93a3bd'};
const MON = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const SEASONMON = {DJF:'Dec–Feb',JFM:'Jan–Mar',FMA:'Feb–Apr',MAM:'Mar–May',AMJ:'Apr–Jun',
                   MJJ:'May–Jul',JJA:'Jun–Aug',JAS:'Jul–Sep',ASO:'Aug–Oct',SON:'Sep–Nov',
                   OND:'Oct–Dec',NDJ:'Nov–Jan'};

function cls(v){ return v===null||v===undefined ? '' : (v>=0 ? 'pos' : 'neg'); }
function fmt(v,d){ if(v===null||v===undefined) return '–'; return (v>0?'+':'') + v.toFixed(d===undefined?1:d); }

/* ---------- 卡片 ---------- */
(function(){
  const L = DATA.weeklyLatest;
  document.getElementById('alertBadge').textContent = DATA.status.alert || 'n/a';
  document.getElementById('gen').textContent = DATA.generated;
  document.getElementById('issued').textContent = DATA.status.issued ? ('诊断发布日期：' + DATA.status.issued) : '';
  document.getElementById('synopsis').textContent = DATA.status.synopsis || '（未取到诊断文本，请访问 CPC 页面）';
  document.getElementById('nextDisc').textContent = DATA.status.next ? ('下次官方诊断：' + DATA.status.next) : '';

  const elProb = (DATA.prob.find(p=>p.season==='SON') || DATA.prob[0] || {el:'–'});
  const cards = [
    {k:'周 Niño3.4 距平',   v:fmt(L.n34), cls:cls(L.n34), t:'中心日 ' + L.tag},
    {k:'周 Niño3.4 相对值', v:fmt(L.r34), cls:cls(L.r34), t:'剔除热带平均增暖'},
    {k:'周 Niño3 距平',     v:fmt(L.n3),  cls:cls(L.n3),  t:'中心日 ' + L.tag},
    {k:'周 Niño1+2 距平',   v:fmt(L.n12), cls:cls(L.n12), t:'中心日 ' + L.tag},
    {k:'El Niño 概率',      v:elProb.el + '%', cls:'', color:'var(--warn)', t:'官方展望（' + elProb.season + '）'},
    {k:'官方状态',          v:(DATA.status.alert||'').replace(' Advisory',''), cls:'', color:'var(--warn)', t:DATA.status.issued||''}
  ];
  document.getElementById('cards').innerHTML = cards.map(c=>
    '<div class="card"><div class="k">'+c.k+'</div>' +
    '<div class="v" style="'+(c.color?('color:'+c.color):'')+'">' +
    (c.cls ? '<span class="'+c.cls+'">'+c.v+'</span>' : c.v) +
    '</div><div class="t">'+c.t+'</div></div>'
  ).join('');
})();

/* ---------- 通用绘图 ---------- */
function prep(cv){
  const dpr = window.devicePixelRatio || 1;
  const w = cv.clientWidth || 600, h = cv.clientHeight || 240;
  cv.width = Math.round(w*dpr); cv.height = Math.round(h*dpr);
  const g = cv.getContext('2d');
  g.setTransform(dpr,0,0,dpr,0,0);
  g.clearRect(0,0,w,h);
  return {g:g, w:w, h:h, pad:{l:48,r:14,t:12,b:26}};
}
function drawFrame(s, ymin, ymax, xlabels){
  const g=s.g, p=s.pad, W=s.w-p.l-p.r, H=s.h-p.t-p.b;
  g.font='11px Segoe UI,Microsoft YaHei,sans-serif'; g.textBaseline='middle';
  for(let i=0;i<=4;i++){
    const y = p.t + H*i/4, val = ymax - (ymax-ymin)*i/4;
    g.strokeStyle=C.grid; g.lineWidth=1;
    g.beginPath(); g.moveTo(p.l, y+.5); g.lineTo(p.l+W, y+.5); g.stroke();
    g.fillStyle=C.muted; g.textAlign='right';
    g.fillText(val.toFixed(1), p.l-7, y);
  }
  if(ymin<0 && ymax>0){
    const y0 = p.t + H*(ymax/(ymax-ymin));
    g.strokeStyle='#4b5f85'; g.setLineDash([4,3]);
    g.beginPath(); g.moveTo(p.l,y0); g.lineTo(p.l+W,y0); g.stroke(); g.setLineDash([]);
  }
  g.fillStyle=C.muted; g.textAlign='center';
  const n = xlabels.length;
  [0, Math.floor(n/2), n-1].forEach((i,k)=>{
    if(i<0||i>=n) return;
    g.textAlign = k===0?'left':(k===2?'right':'center');
    g.fillText(xlabels[i], p.l + W*(n<2?0.5:i/(n-1)), s.h-11);
  });
  return {W:W,H:H};
}
/* ================= 可缩放时间轴图表引擎 =================
   cfg = { labels:[显示用标签], tips:[完整日期 'YYYY-…'], series:[{name,color,data,width,dash,unit}],
           band:{lo,hi}?, type:'line'|'bar', zoom:bool, readout:'id', reset:'id',
           spanControl:'id', defaultYears:number, minSpan:int }
   交互：年数按钮切换窗口 · 滚轮缩放（以光标为锚点）· 拖动平移 · 单击定位显示日期与数值 · 双击/复位回默认年数
================================================================ */
function makeChart(cv, cfg){
  const PAD = {l:48, r:14, t:12, b:26};
  const n = cfg.labels.length;
  const st = {lo:0, hi:n-1, mark:null, hover:null};
  let geo = null, drag = null, dragged = false;

  const clampWin = (lo, hi) => {
    const minSpan = Math.min(cfg.minSpan || 8, n-1);
    const span = Math.max(minSpan, Math.min(n-1, Math.round(hi-lo)));
    // 必须取整：小数索引会让数组取值变成 undefined，整张图会静默失效
    st.lo = Math.max(0, Math.min(n-1-span, Math.round(lo)));
    st.hi = st.lo + span;
  };

  // 纯字符串运算求"往前 N 年"的截断日期，避免 Date 解析与时区问题
  const shiftYears = (tip, years) => (parseInt(tip.slice(0, 4), 10) - years) + tip.slice(4);
  const setSpan = (years) => {
    if (!years) { st.lo = 0; st.hi = n-1; }
    else {
      const cut = shiftYears(cfg.tips[n-1], years);
      let i = cfg.tips.findIndex(t => t >= cut);
      if (i < 0) i = 0;
      st.lo = i; st.hi = n-1;
    }
    clampWin(st.lo, st.hi);
  };
  const px = (e) => { const r = cv.getBoundingClientRect(); return (e.clientX-r.left)*(cv.clientWidth/(r.width||1)); };
  const idxAt = (x) => {
    const W = geo.W;
    const t = Math.max(0, Math.min(1, (x-PAD.l)/W));
    return Math.max(st.lo, Math.min(st.hi, Math.round(st.lo + t*(st.hi-st.lo))));
  };

  function tooltip(g, x, y, lines, color){
    g.font = '11.5px Segoe UI,Microsoft YaHei,sans-serif';
    g.textBaseline = 'middle';
    let w = 0;
    lines.forEach(l => { w = Math.max(w, g.measureText(l.t).width); });
    const bw = w + 18, bh = lines.length*15 + 12;
    let bx = x + 12; if (bx + bw > geo.w - 4) bx = x - 12 - bw;
    let by = Math.max(4, Math.min(geo.h - bh - 4, y - bh/2));
    g.fillStyle = 'rgba(9,16,29,.94)';
    g.strokeStyle = color || C.grid; g.lineWidth = 1;
    g.beginPath();
    if (g.roundRect) { g.roundRect(bx, by, bw, bh, 6); } else { g.rect(bx, by, bw, bh); }
    g.fill(); g.stroke();
    g.textAlign = 'left';
    lines.forEach((l, i) => {
      g.fillStyle = l.c || C.fg;
      g.fillText(l.t, bx + 9, by + 13 + i*15);
    });
  }

  function render(){
    clampWin(st.lo, st.hi);
    const s = prep(cv);
    geo = {w:s.w, h:s.h};
    const p = s.pad, g = s.g;
    const vis = [];
    for (let i = st.lo; i <= st.hi; i++) vis.push(i);
    const labels = vis.map(i => cfg.labels[i]);
    const series = cfg.series.map(se => ({...se, data: vis.map(i => se.data[i])}));
    const band = cfg.band ? {lo: vis.map(i => cfg.band.lo[i]), hi: vis.map(i => cfg.band.hi[i])} : null;

    let vals = [];
    series.forEach(se => { vals = vals.concat(se.data.filter(v => v !== null && v !== undefined)); });
    if (band) vals = vals.concat(band.lo.filter(v=>v!=null), band.hi.filter(v=>v!=null));
    if (!vals.length) return;
    let ymin = Math.min.apply(null, vals), ymax = Math.max.apply(null, vals);
    if (cfg.type === 'bar') { ymin = Math.min(ymin, -0.5); ymax = Math.max(ymax, 0.5); }
    const sp = (ymax - ymin) || 1; ymin -= sp*0.12; ymax += sp*0.12;

    const f = drawFrame(s, ymin, ymax, labels);
    geo.W = f.W; geo.H = f.H; geo.pad = p; geo.ymin = ymin; geo.ymax = ymax;
    const m = labels.length;
    const X = i => p.l + (m < 2 ? f.W/2 : f.W*i/(m-1));
    const Y = v => p.t + f.H*(ymax - v)/(ymax - ymin);

    if (band) {
      g.fillStyle = 'rgba(56,189,248,.16)'; g.beginPath();
      let started = false;
      for (let i=0;i<m;i++){ if (band.hi[i]==null) continue; const x=X(i),y=Y(band.hi[i]);
        if(!started){g.moveTo(x,y);started=true;} else g.lineTo(x,y); }
      for (let i=m-1;i>=0;i--){ if (band.lo[i]==null) continue; g.lineTo(X(i),Y(band.lo[i])); }
      g.closePath(); g.fill();
    }

    if (cfg.type === 'bar') {
      const bw = Math.max(1.2, f.W/m*0.68);
      const y0 = Y(0);
      for (let i=0;i<m;i++){
        const v = series[0].data[i]; if (v==null) continue;
        const x = p.l + f.W*(i+0.5)/m - bw/2;
        g.fillStyle = v>=1.5?'#f87171' : (v>=0.5?'#fb923c' : (v<=-0.5?'#38bdf8':'#64748b'));
        const y = Y(v);
        g.fillRect(x, Math.min(y,y0), bw, Math.max(1, Math.abs(y-y0)));
      }
    } else {
      series.forEach(se => {
        g.strokeStyle = se.color; g.lineWidth = se.width || 1.8;
        if (se.dash) g.setLineDash(se.dash);
        g.beginPath(); let started = false;
        for (let i=0;i<m;i++){
          const v = se.data[i]; if (v==null){started=false;continue;}
          const x = X(i), y = Y(v);
          if(!started){g.moveTo(x,y);started=true;} else g.lineTo(x,y);
        }
        g.stroke(); g.setLineDash([]);
      });
    }

    // ---- 定位线 / 悬停：显示该点日期与数值 ----
    const active = (st.mark != null) ? st.mark : st.hover;
    if (active != null && active >= st.lo && active <= st.hi) {
      const i = active - st.lo, x = X(i);
      g.strokeStyle = st.mark != null ? C.fg : '#5b6f92';
      g.lineWidth = 1; g.setLineDash([3,3]);
      g.beginPath(); g.moveTo(x, p.t); g.lineTo(x, p.t + f.H); g.stroke(); g.setLineDash([]);
      if (cfg.type !== 'bar') {
        series.forEach(se => {
          const v = se.data[i]; if (v==null) return;
          g.fillStyle = se.color; g.beginPath(); g.arc(x, Y(v), 3, 0, Math.PI*2); g.fill();
        });
      }
      const lines = [{t: cfg.tips[active], c: C.fg}];
      cfg.series.forEach(se => {
        const v = se.data[active];
        lines.push({t: se.name + '  ' + (v==null ? '–' : (v>0?'+':'') + v.toFixed(se.digits == null ? 1 : se.digits) + (se.unit||'')),
                    c: se.color});
      });
      const mid = cfg.type === 'bar' ? Y(series[0].data[i] ?? 0) : Y((ymin+ymax)/2);
      tooltip(g, x, mid, lines, C.grid);
    }

    if (cfg.readout) {
      const el = document.getElementById(cfg.readout);
      if (el) {
        const a = cfg.tips[st.lo], b = cfg.tips[st.hi];
        let txt = '窗口 ' + a + ' → ' + b + '（' + (st.hi-st.lo+1) + ' / ' + n + ' 点）';
        if (st.mark != null) txt += '　▍选中 ' + cfg.tips[st.mark];
        txt += '　· 年数按钮 / 滚轮缩放 · 拖动平移 · 单击定位 · 双击复位';
        el.textContent = txt;
      }
    }
  }

  if (cfg.zoom) {
    cv.addEventListener('wheel', e => {
      e.preventDefault();
      const x = px(e);
      const r = cv.getBoundingClientRect();
      const t = Math.max(0, Math.min(1, (x - PAD.l) / (geo.W || 1)));
      const span = st.hi - st.lo;
      const anchor = st.lo + t*span;
      const factor = e.deltaY > 0 ? 1.2 : 0.83;
      const nspan = Math.max(Math.min(cfg.minSpan || 8, n-1), Math.min(n-1, span*factor));
      clampWin(anchor - t*nspan, anchor - t*nspan + nspan);
      render();
    }, {passive:false});

    cv.addEventListener('mousedown', e => { drag = {x:e.clientX, lo:st.lo, hi:st.hi}; dragged = false; cv.style.cursor='grabbing'; });
    window.addEventListener('mouseup', () => {
      if (drag) { drag = null; cv.style.cursor = 'crosshair'; }
    });
    cv.addEventListener('mousemove', e => {
      const x = px(e);
      if (drag) {
        const dx = e.clientX - drag.x;
        if (Math.abs(dx) > 2) dragged = true;
        const r = cv.getBoundingClientRect();
        const plotW = (r.width||1) - PAD.l - PAD.r;
        const span = drag.hi - drag.lo;
        const shift = -dx / plotW * span;
        clampWin(drag.lo + shift, drag.lo + shift + span);
        render();
        return;
      }
      st.hover = idxAt(x);
      render();
    });
    cv.addEventListener('mouseleave', () => { st.hover = null; render(); });
    cv.addEventListener('dblclick', () => { resetView(); });
    cv.style.cursor = 'crosshair';

    const rb = cfg.reset ? document.getElementById(cfg.reset) : null;
    if (rb) rb.addEventListener('click', () => { resetView(); });

    // 年数按钮：切换窗口长度（以最新数据为右端）
    if (cfg.spanControl) {
      const btns = document.querySelectorAll('#' + cfg.spanControl + ' button');
      if (btns && btns.length) {
        btns.forEach(b => b.addEventListener('click', () => {
          btns.forEach(x => { if (x.classList) x.classList.remove('on'); });
          if (b.classList) b.classList.add('on');
          setSpan(+(b.dataset ? b.dataset.years : 0));
          render();
        }));
      }
    }
  }

  function resetView(){
    setSpan(cfg.zoom ? (cfg.defaultYears || 0) : 0);
    st.mark = null;
    render();
  }

  cv.addEventListener('click', e => {
    const i = idxAt(px(e));
    if (dragged) { dragged = false; return; }
    st.mark = (st.mark === i) ? null : i;
    render();
  });

  if (cfg.defaultYears) setSpan(cfg.defaultYears);
  render();
  return {render: render, state: st, setSpan: setSpan};
}


/* ---------- 表格渲染 ---------- */
document.querySelector('#tblWeekly tbody').innerHTML = DATA.weeklyTable.slice().reverse().map(r=>
  '<tr><td>'+r.week+'</td><td class="'+cls(r.n12)+'">'+fmt(r.n12)+'</td><td class="'+cls(r.n3)+'">'+fmt(r.n3)+
  '</td><td class="'+cls(r.n34)+'">'+fmt(r.n34)+'</td><td class="'+cls(r.n4)+'">'+fmt(r.n4)+
  '</td><td class="'+cls(r.r34)+'">'+fmt(r.r34)+'</td></tr>').join('');

document.querySelector('#tblProb tbody').innerHTML = DATA.prob.map(r=>
  '<tr><td>'+r.season+' <span style="color:var(--muted)">'+(SEASONMON[r.season]||'')+'</span></td><td>'+r.la+
  '%</td><td>'+r.neu+'%</td><td style="font-weight:600">'+r.el+'%</td></tr>').join('');

document.querySelector('#tblFcst tbody').innerHTML = DATA.fcst.map(r=>
  '<tr><td>'+r.season+' <span style="color:var(--muted)">'+(SEASONMON[r.season]||'')+'</span></td><td>'+
  r.p05.toFixed(2)+'</td><td>'+r.p25.toFixed(2)+'</td><td style="font-weight:600">'+r.p50.toFixed(2)+
  '</td><td>'+r.p75.toFixed(2)+'</td><td>'+r.p95.toFixed(2)+'</td></tr>').join('');

document.querySelector('#tblOni tbody').innerHTML = DATA.oniSeasonal.slice().reverse().map(r=>
  '<tr><td>'+r.season+'</td><td class="'+cls(r.v)+'">'+fmt(r.v,2)+'</td></tr>').join('');
document.querySelector('#tblRoni tbody').innerHTML = DATA.roniSeasonal.slice().reverse().map(r=>
  '<tr><td>'+r.season+'</td><td class="'+cls(r.v)+'">'+fmt(r.v,2)+'</td></tr>').join('');

document.querySelector('#tblSrc tbody').innerHTML = DATA.sources.map(s=>
  '<tr><td><a href="'+s.url+'" target="_blank" rel="noopener">'+s.name+'</a></td><td style="text-align:right">'+
  s.cadence+'</td><td style="text-align:right;color:var(--muted)">'+(s.updated||'—')+'</td></tr>').join('');

/* ---------- 典型影响区地图 ---------- */
// lon/lat 为区域框的 [最小, 最大]；type: wet 多雨 / dry 干旱 / warm 偏暖 / cool 偏凉
// conf: 3 高（多数事件一致）2 中 1 低（文献中差异较大）
const IMPACTS = {
  DJF: [
    {n:1,  name:'秘鲁—厄瓜多尔沿海',        lon:[-85,-75], lat:[-10, 2], type:'wet',  conf:3, note:'异常多雨、洪涝与山洪（东部型事件最典型）'},
    {n:2,  name:'阿根廷北部—巴西南部—乌拉圭', lon:[-62,-48], lat:[-35,-22], type:'wet',  conf:3, note:'雨季降水偏多、河流水位上升'},
    {n:3,  name:'巴西东北部',               lon:[-48,-35], lat:[-12, -2], type:'dry',  conf:2, note:'旱季更干，干旱风险上升'},
    {n:4,  name:'中美洲—加勒比',            lon:[-92,-60], lat:[  8, 20], type:'dry',  conf:2, note:'降水偏少、暖冬'},
    {n:5,  name:'美国南部—墨西哥湾沿岸',     lon:[-110,-82], lat:[ 25, 33], type:'wet',  conf:3, note:'风暴路径偏南，多雨偏冷'},
    {n:6,  name:'加利福尼亚—美西南',        lon:[-125,-113], lat:[ 33, 42], type:'wet',  conf:2, note:'冬季降水偏多（受事件型态影响较大）'},
    {n:7,  name:'美国北部—加拿大南部',       lon:[-130,-70], lat:[ 45, 60], type:'warm', conf:3, note:'显著偏暖，取暖度日下降'},
    {n:8,  name:'东非（肯尼亚—坦桑尼亚）',   lon:[ 32, 42], lat:[ -8,  8], type:'wet',  conf:2, note:'短雨季降水偏多'},
    {n:9,  name:'南部非洲（津巴布韦—南非北部）', lon:[20, 38], lat:[-28,-12], type:'dry', conf:3, note:'雨季推迟/降水偏少，粮食风险'},
    {n:10, name:'印尼—马来西亚—菲律宾南部',  lon:[ 95,135], lat:[ -8,  8], type:'dry',  conf:3, note:'对流东移，干旱与森林火险升高'},
    {n:11, name:'澳大利亚东部',             lon:[135,155], lat:[-35,-12], type:'dry',  conf:3, note:'偏干偏热、热浪与火险'},
    {n:12, name:'印度南部—斯里兰卡',         lon:[ 72, 85], lat:[  5, 18], type:'wet',  conf:2, note:'东北季风降水偏多'},
    {n:13, name:'中国华南—江南',            lon:[105,122], lat:[ 20, 32], type:'wet',  conf:2, note:'冬春水汽输送偏强、阴雨偏多；北方多暖冬'}
  ],
  JJA: [
    {n:1,  name:'印度',                     lon:[ 70, 90], lat:[  8, 30], type:'dry',  conf:2, note:'季风偏弱、降水偏少（事件衰减年更明显）'},
    {n:2,  name:'印尼—澳大利亚北部',         lon:[ 95,140], lat:[-12,  5], type:'dry',  conf:3, note:'干旱延续至次年旱季'},
    {n:3,  name:'澳大利亚东部',             lon:[140,155], lat:[-38,-15], type:'dry',  conf:2, note:'降水偏少、霜冻风险变化'},
    {n:4,  name:'美国中部—南部',            lon:[-105,-85], lat:[30, 45], type:'wet',  conf:2, note:'强对流与洪涝偏多'},
    {n:5,  name:'中国长江流域',             lon:[105,122], lat:[ 25, 35], type:'wet',  conf:2, note:'梅雨偏强、洪涝风险上升'},
    {n:6,  name:'日本—东北亚',              lon:[130,145], lat:[ 32, 45], type:'cool', conf:2, note:'夏季偏凉、日照偏少'},
    {n:7,  name:'加勒比—中美洲',            lon:[-90,-60], lat:[ 10, 22], type:'dry',  conf:2, note:'飓风活动受抑制、降水偏少'},
    {n:8,  name:'亚马逊北部',               lon:[-70,-55], lat:[ -5,  5], type:'dry',  conf:1, note:'降水偏少、火险升高'},
    {n:9,  name:'西非萨赫勒',               lon:[-15, 15], lat:[ 10, 18], type:'wet',  conf:1, note:'季风降水偏多（信噪比较低）'},
    {n:10, name:'阿根廷北部—巴西南部',       lon:[-65,-48], lat:[-38,-22], type:'wet',  conf:2, note:'冬季降水偏多'}
  ]
};
const TYPE_CN = {wet:'偏多雨', dry:'偏干旱', warm:'偏暖', cool:'偏凉'};
const CONF = {3:['●●●','hi','高'], 2:['●●○','mid','中'], 1:['●○○','lo','低']};
const SEASON_CN = {DJF:'DJF（12–2 月，峰值季）', JJA:'JJA（6–8 月，次年夏季）'};

function renderImpact(season){
  const list = IMPACTS[season] || [];
  document.getElementById('zoneLayer').innerHTML = list.map(z=>{
    const x = z.lon[0]+180, y = 90-z.lat[1], w = z.lon[1]-z.lon[0], h = z.lat[1]-z.lat[0];
    return '<rect class="zone '+z.type+'" x="'+x.toFixed(1)+'" y="'+y.toFixed(1)+'" width="'+w.toFixed(1)+
           '" height="'+h.toFixed(1)+'" rx="1.5" opacity="0.34"></rect>';
  }).join('');
  document.getElementById('markerLayer').innerHTML = list.map(z=>{
    const cx = (z.lon[0]+z.lon[1])/2+180, cy = 90-(z.lat[0]+z.lat[1])/2;
    return '<circle class="marker" cx="'+cx.toFixed(1)+'" cy="'+cy.toFixed(1)+'" r="3.3"></circle>'+
           '<text class="marktext" x="'+cx.toFixed(1)+'" y="'+cy.toFixed(1)+'">'+z.n+'</text>';
  }).join('');
  document.querySelector('#tblImpact tbody').innerHTML = list.map(z=>{
    const c = CONF[z.conf];
    return '<tr><td style="color:var(--muted)">'+z.n+'</td><td>'+z.name+
           '<div style="color:var(--muted);font-size:12px;font-weight:400;white-space:normal">'+z.note+'</div></td>'+
           '<td style="color:'+(z.type==='wet'?'var(--n34)':z.type==='dry'?'var(--warn)':
             z.type==='warm'?'var(--bad)':'var(--n4)')+'">'+TYPE_CN[z.type]+'</td>'+
           '<td><span class="conf '+c[1]+'" title="'+"把握度：" + c[2]+'">'+c[0]+'</span></td></tr>';
  }).join('');

  const im = (DATA.maps && DATA.maps[season]) || {};
  const t = document.getElementById('imgTemp'), p = document.getElementById('imgPrec');
  t.src = im.temp || ''; p.src = im.precip || '';
  t.style.display = im.temp ? 'block' : 'none';
  p.style.display = im.precip ? 'block' : 'none';
  document.getElementById('capTemp').textContent = '图：NOAA/CPC 全球 ENSO 温度线性回归 · ' + SEASON_CN[season];
  document.getElementById('capPrec').textContent = '图：NOAA/CPC 全球 ENSO 降水线性回归 · ' + SEASON_CN[season]+
    '　（红/蓝＝暖/冷或干/湿倾向；斜线区表示相关显著）';
  document.getElementById('impactNote').innerHTML =
    '倾向来自历史 El Niño 事件的合成与线性回归（CPC 全球回归、Ropelewski &amp; Halpert 1987/1996 等），'+
    '表示<b>发生概率的相对偏移</b>而非确定结果；事件强度、空间型（东部型／中部型）与年代际背景都会改变分布。'+
    '底图为 Natural Earth 110m 简化陆地轮廓，色块为示意范围，非精确边界。';
}

const landPath = document.getElementById('landPath');
if (DATA.basemap) { landPath.setAttribute('d', DATA.basemap); }
document.getElementById('nino34Label').textContent =
  'Niño3.4  ' + fmt(DATA.weeklyLatest.n34) + '°C';
document.querySelectorAll('#seasonSwitch button').forEach(btn=>{
  btn.addEventListener('click', ()=>{
    document.querySelectorAll('#seasonSwitch button').forEach(b=>b.classList.remove('on'));
    btn.classList.add('on');
    renderImpact(btn.dataset.season);
  });
});
renderImpact('DJF');

/* ---------- 页脚作者信息与课题组二维码 ---------- */
(function(){
  const img = document.getElementById('qrImg');
  const box = document.getElementById('whoQr');
  if (img && DATA.qrcode) { img.src = DATA.qrcode; }
  else if (box) { box.style.display = 'none'; }   // 取不到二维码时只保留作者文字
})();

/* ---------- 绘图调用 ---------- */
function shortDate(s){ return s.slice(2,7).replace('-','/'); }
const CHARTS = [];

// 标题里写明实际可用的数据跨度（由脚本注入，避免写死）
if (DATA.span) {
  const s = DATA.span;
  document.getElementById('hintWeekly').textContent =
    'OISST v2.1 / 1991–2020 基准 · 数据 ' + s.weeklyFirst + ' → ' + s.weeklyLast + '（' + s.weeklyN + ' 周）';
  document.getElementById('hintMonthly').textContent =
    '月度 · 数据 ' + s.monthlyFirst + ' → ' + s.monthlyLast + '（' + s.monthlyN + ' 个月）';
}

// 周 Niño 区：可缩放时间轴 + 年数窗口
CHARTS.push(makeChart(document.getElementById('cvWeekly'), {
  labels: DATA.weekly.labels.map(shortDate),
  tips:   DATA.weekly.labels,
  type:   'line',
  zoom:   true,
  minSpan: 8,
  readout: 'rangeWeekly',
  reset:   'resetWeekly',
  spanControl: 'spanWeekly',
  defaultYears: 3,
  series: [
    {name:'Niño1+2', color:C.n12, data:DATA.weekly.n12, unit:'°C'},
    {name:'Niño3',   color:C.n3,  data:DATA.weekly.n3,  unit:'°C'},
    {name:'Niño3.4', color:C.n34, data:DATA.weekly.n34, width:2.4, unit:'°C'},
    {name:'Niño4',   color:C.n4,  data:DATA.weekly.n4,  unit:'°C'},
    {name:'Niño3.4 相对', color:C.rel, data:DATA.weekly.r34, dash:[5,4], unit:'°C'}
  ]
}));

// 月度相对 Niño3.4：可缩放时间轴 + 年数窗口
CHARTS.push(makeChart(document.getElementById('cvMonthly'), {
  labels: DATA.monthly.labels.map(shortDate),
  tips:   DATA.monthly.labels,
  type:   'bar',
  zoom:   true,
  minSpan: 6,
  readout: 'rangeMonthly',
  reset:   'resetMonthly',
  spanControl: 'spanMonthly',
  defaultYears: 10,
  series: [{name:'相对 Niño3.4', color:C.n34, data:DATA.monthly.roni, unit:'°C'}]
}));

// 季节预报扇形：仅 9 个点，不缩放
if (DATA.fcst.length) {
  CHARTS.push(makeChart(document.getElementById('cvFan'), {
    labels: DATA.fcst.map(r=>r.season),
    tips:   DATA.fcst.map(r=>r.season + '（' + (SEASONMON[r.season]||'') + '）'),
    type:   'line',
    zoom:   false,
    series: [{name:'RONI P50', color:C.n34, data:DATA.fcst.map(r=>r.p50), width:2.4}],
    band:   {lo: DATA.fcst.map(r=>r.p05), hi: DATA.fcst.map(r=>r.p95)}
  }));
}

window.addEventListener('resize', () => { CHARTS.forEach(c => c.render()); });
</script>
</body>
</html>
'@

$html = $template.Replace('__ENSO_DATA__', $json)
$outHtml = Join-Path $RepDir 'enso_dashboard.html'
[System.IO.File]::WriteAllText($outHtml, $html, (New-Object System.Text.UTF8Encoding($true)))

# ---------------------------------------------------------------- 静态托管副本（GitHub Pages 等）
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
