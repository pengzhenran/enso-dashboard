<#
.SYNOPSIS
    把生成的页面与源码发布到 GitHub（走 api.github.com，绕开可能被阻断的 github.com git 通道）

.DESCRIPTION
    用 GitHub Git Data API 创建 blob → tree → commit → 更新分支引用，效果等价于一次 git push，
    但只需要 api.github.com 可达。国内网络常见 git push 被 reset、gh api 却能通，这个脚本就是为这种情况准备的。

    默认流程：先跑 Update-EnsoData.ps1 -PublishDir docs 重新生成页面，再上传下面 $DefaultPaths 里的全部文件。

.PARAMETER Repo
    owner/repo，默认 pengzhenran/enso-dashboard。

.PARAMETER Branch
    目标分支，默认 main。

.PARAMETER Message
    提交信息，默认带时间戳。

.PARAMETER Path
    要上传的文件（仓库相对路径）。默认上传页面、数据、脚本与工作流全套。

.PARAMETER SkipRegenerate
    跳过重新抓取/生成，直接上传现有文件（只想补文件时用）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Publish-ToGitHub.ps1

.EXAMPLE
    # 只更新页面，不重新抓数
    powershell -ExecutionPolicy Bypass -File .\scripts\Publish-ToGitHub.ps1 -SkipRegenerate -Path docs/index.html
#>
[CmdletBinding()]
param(
    [string]$Repo = 'pengzhenran/enso-dashboard',
    [string]$Branch = 'main',
    [string]$Message,
    [string[]]$Path,
    [switch]$SkipRegenerate
)

$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { throw '请以脚本方式运行（需要 $PSScriptRoot 定位项目根目录）' }
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Message) { $Message = 'ENSO 仪表盘更新 ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') }

$DefaultPaths = @(
    '.gitignore'
    'README.md'
    '.github/workflows/enso-pages.yml'
    'docs/index.html'
    'docs/.nojekyll'
    'data/processed/basemap.txt'
    'data/processed/nino_weekly.csv'
    'data/processed/enso_monthly.csv'
    'scripts/Update-EnsoData.ps1'
    'scripts/build-basemap.mjs'
    'scripts/serve-report.mjs'
    'scripts/verify-report.mjs'
)
if (-not $Path -or $Path.Count -eq 0) { $Path = $DefaultPaths }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('enso-publish-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

function Invoke-GhApi {
    param([string[]]$ApiArgs, [string]$InputFile, [int]$Attempts = 3)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $out = if ($InputFile) { & gh api @ApiArgs --input $InputFile 2>&1 | Out-String }
               else            { & gh api @ApiArgs 2>&1 | Out-String }
        if ($LASTEXITCODE -eq 0) { return $out }
        if ($attempt -eq $Attempts) { throw ("gh api 失败：gh api {0}`n{1}" -f ($ApiArgs -join ' '), $out.Trim()) }
        Start-Sleep -Seconds (3 * $attempt)
    }
}
function Write-Json {
    param([string]$Name, $Object)
    $f = Join-Path $TmpDir $Name
    [System.IO.File]::WriteAllText($f, ($Object | ConvertTo-Json -Compress -Depth 8), $Utf8NoBom)
    return $f
}
function Get-BranchHead {
    param([int]$Attempts = 1)
    try { return (Invoke-GhApi -ApiArgs @("repos/$Repo/git/ref/heads/$Branch") -Attempts $Attempts) | ConvertFrom-Json }
    catch { return $null }
}

try {
    # ---------------------------------------------------------- 重新生成页面
    if (-not $SkipRegenerate) {
        Write-Host '[1/4] 重新抓取并生成页面 ...' -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot 'Update-EnsoData.ps1') -PublishDir docs | Out-Null
    } else {
        Write-Host '[1/4] 跳过生成（-SkipRegenerate）' -ForegroundColor DarkGray
    }

    # ---------------------------------------------------------- 分支状态（空仓库要先播种）
    # 空仓库上 Git Data API 会返回 409 "Git Repository is empty"，只能用 Contents API 建首个提交
    $head = Get-BranchHead
    if (-not $head) {
        Write-Host '[2/4] 仓库为空，先用 Contents API 播种首个提交 ...' -ForegroundColor Cyan
        $seed = Write-Json 'seed.json' @{
            message = '初始化仓库'
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                "# $Repo`n`n本仓库由 ``scripts/Publish-ToGitHub.ps1`` 发布，内容随后被覆盖。`n"))
        }
        Invoke-GhApi -ApiArgs @('-X', 'PUT', "repos/$Repo/contents/README.md") -InputFile $seed | Out-Null
        $head = Get-BranchHead -Attempts 3
        if (-not $head) { throw '播种后仍读不到分支，请检查 token 权限' }
    } else {
        Write-Host '[2/4] 分支已存在，将在其之上追加提交' -ForegroundColor Cyan
    }
    $parentSha = $head.object.sha
    $baseTreeSha = ((Invoke-GhApi -ApiArgs @("repos/$Repo/git/commits/$parentSha")) | ConvertFrom-Json).tree.sha
    Write-Host ("      当前 {0} 头指针 {1}" -f $Branch, $parentSha.Substring(0, 7)) -ForegroundColor DarkGray

    # ---------------------------------------------------------- 上传 blob
    Write-Host '[3/4] 上传文件 ...' -ForegroundColor Cyan
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $Path) {
        $full = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path $full)) { Write-Warning "跳过不存在的文件：$rel"; continue }
        $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($full))
        $body = Write-Json (([guid]::NewGuid().ToString('N')) + '.json') @{ content = $b64; encoding = 'base64' }
        $res = (Invoke-GhApi -ApiArgs @('-X', 'POST', "repos/$Repo/git/blobs") -InputFile $body) | ConvertFrom-Json
        $entries.Add(@{ path = $rel; mode = '100644'; type = 'blob'; sha = $res.sha })
        Write-Host ("      {0,-42} {1,8:N1} KB" -f $rel, ((Get-Item $full).Length / 1KB))
    }
    if ($entries.Count -eq 0) { throw '没有任何文件可上传' }

    # ---------------------------------------------------------- tree + commit + ref
    Write-Host '[4/4] 创建提交并更新分支 ...' -ForegroundColor Cyan
    $treeBody = @{ tree = $entries }
    if ($baseTreeSha) { $treeBody['base_tree'] = $baseTreeSha }
    $treeFile = Write-Json 'tree.json' $treeBody
    try {
        $tree = (Invoke-GhApi -ApiArgs @('-X', 'POST', "repos/$Repo/git/trees") -InputFile $treeFile -Attempts 1) | ConvertFrom-Json
    } catch {
        # token 缺少 workflow scope 时，GitHub 对 .github/workflows/* 一律返回 404。
        # 这里自动剔除工作流文件后重试，保证页面照常发布。
        $wf = @($entries | Where-Object { $_.path -like '.github/workflows/*' })
        if ($wf.Count -eq 0) { throw }
        Write-Warning ("token 缺少 workflow 权限，本次跳过 {0} 个工作流文件（其余文件照常发布）" -f $wf.Count)
        Write-Warning '要启用 Actions 自动发布：先执行 gh auth refresh -s workflow，再重跑本脚本'
        $entries = @($entries | Where-Object { $_.path -notlike '.github/workflows/*' })
        $treeBody = @{ tree = $entries }
        if ($baseTreeSha) { $treeBody['base_tree'] = $baseTreeSha }
        $treeFile = Write-Json 'tree.json' $treeBody
        $tree = (Invoke-GhApi -ApiArgs @('-X', 'POST', "repos/$Repo/git/trees") -InputFile $treeFile) | ConvertFrom-Json
    }

    $commitBody = @{ message = $Message; tree = $tree.sha; parents = @() }
    if ($parentSha) { $commitBody['parents'] = @($parentSha) }
    $commitFile = Write-Json 'commit.json' $commitBody
    $commit = (Invoke-GhApi -ApiArgs @('-X', 'POST', "repos/$Repo/git/commits") -InputFile $commitFile) | ConvertFrom-Json

    if ($parentSha) {
        $refFile = Write-Json 'ref.json' @{ sha = $commit.sha; force = $false }
        Invoke-GhApi -ApiArgs @('-X', 'PATCH', "repos/$Repo/git/refs/heads/$Branch") -InputFile $refFile | Out-Null
    } else {
        $refFile = Write-Json 'ref.json' @{ ref = "refs/heads/$Branch"; sha = $commit.sha }
        Invoke-GhApi -ApiArgs @('-X', 'POST', "repos/$Repo/git/refs") -InputFile $refFile | Out-Null
    }

    Write-Host ''
    Write-Host ("✓ 已发布 {0} 个文件" -f $entries.Count) -ForegroundColor Green
    Write-Host ("  提交    https://github.com/{0}/commit/{1}" -f $Repo, $commit.sha)
    Write-Host ("  仓库    https://github.com/{0}" -f $Repo)
    $pages = ''
    try { $pages = ((Invoke-GhApi -ApiArgs @("repos/$Repo/pages")) | ConvertFrom-Json).html_url } catch { }
    if ($pages) { Write-Host ("  站点    {0}" -f $pages) -ForegroundColor Green }
} finally {
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
