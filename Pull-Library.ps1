<#
Pull-Library.ps1 (Hardened)
- Tries git first (clone/pull).
- If git fails/unavailable: auto-detect default branch via GitHub API, then download zip.
- Falls back to 'main'/'master' if API fails.
- Uses Expand-Archive when available (PS5+); else ZipFile ExtractToDirectory (2-arg overload).
- Enables TLS 1.2 to prevent IWR failures on older hosts.
- Clear diagnostics to avoid ambiguous "file not found".
#>
[CmdletBinding()]
param(
  [string]$RepoUrl = "https://github.com/jaycalderwood/KQL",
  [string]$ZipUrl,
  [string]$Branch,
  [string]$Destination = (Resolve-Path .).Path,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 for Invoke-WebRequest
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

function Test-Git { try { git --version | Out-Null; return $true } catch { return $false } }

function Get-GitRemoteName([string]$url){
  if([string]::IsNullOrWhiteSpace($url)){ return $null }
  return (Split-Path $url.TrimEnd('/') -Leaf).Replace('.git','')
}

function Get-GitHubDefaultBranch([string]$repoUrl){
  try {
    $api = $repoUrl.TrimEnd('/')
    if($api -match '^https://github.com/'){
      $api = $api -replace '^https://github.com/', 'https://api.github.com/repos/'
    } elseif($api -match '^git@github.com:'){
      $api = $api -replace '^git@github.com:', 'https://api.github.com/repos/'
    } else {
      return $null
    }
    $headers = @{ 'User-Agent' = 'KQL-Library-PullScript'; 'Accept'='application/vnd.github+json' }
    $r = Invoke-WebRequest -Headers $headers -Uri $api -UseBasicParsing
    if($r.StatusCode -ne 200){ return $null }
    $j = $r.Content | ConvertFrom-Json
    return $j.default_branch
  } catch {
    Write-Verbose "Default-branch probe failed: $($_.Exception.Message)"
    return $null
  }
}

function Get-GitHubZipUrl([string]$repoUrl, [string]$branch){
  if([string]::IsNullOrWhiteSpace($repoUrl) -or [string]::IsNullOrWhiteSpace($branch)){ return $null }
  $repoUrl = $repoUrl.TrimEnd('/')
  if($repoUrl -notmatch '^https://github.com/'){
    # attempt to normalize SSH style to https
    if($repoUrl -match '^git@github.com:(.+)$'){
      $repoUrl = 'https://github.com/' + $Matches[1]
    } else {
      return $null
    }
  }
  return "$repoUrl/archive/refs/heads/$branch.zip"
}

if(-not (Test-Path $Destination)){
  New-Item -ItemType Directory -Path $Destination | Out-Null
}

# 1) Try git
if(Test-Git){
  $remoteName = Get-GitRemoteName -url $RepoUrl
  $targetDir = Join-Path $Destination $remoteName
  try {
    if(Test-Path $targetDir){
      Write-Host "git: updating $targetDir ..." -ForegroundColor Cyan
      Push-Location $targetDir
      try { git pull --rebase --autostash }
      finally { Pop-Location }
      Write-Host "git: updated" -ForegroundColor Green
      return
    } else {
      Write-Host "git: cloning $RepoUrl to $targetDir ..." -ForegroundColor Cyan
      git clone $RepoUrl $targetDir
      Write-Host "git: cloned" -ForegroundColor Green
      return
    }
  } catch {
    Write-Warning "git path failed ($($_.Exception.Message)). Trying zip fallback..."
  }
} else {
  Write-Verbose "git not found — using zip fallback."
}

# 2) Zip fallback
if([string]::IsNullOrWhiteSpace($ZipUrl)){
  if([string]::IsNullOrWhiteSpace($Branch)){
    $Branch = Get-GitHubDefaultBranch -repoUrl $RepoUrl
    if([string]::IsNullOrWhiteSpace($Branch)){ $Branch = 'main' }
  }
  $ZipUrl = Get-GitHubZipUrl -repoUrl $RepoUrl -branch $Branch
}

if([string]::IsNullOrWhiteSpace($ZipUrl)){
  throw "Unable to determine a valid ZipUrl (RepoUrl='$RepoUrl', Branch='$Branch')."
}

# Validate the zip URL (HEAD)
try {
  $head = Invoke-WebRequest -Uri $ZipUrl -Method Head -UseBasicParsing
} catch {
  if(-not $Branch -or $Branch -eq 'main'){
    Write-Warning "Zip HEAD failed for branch 'main' ($($_.Exception.Message)). Trying 'master'..."
    $Branch = 'master'
    $ZipUrl = Get-GitHubZipUrl -repoUrl $RepoUrl -branch $Branch
    try {
      $head = Invoke-WebRequest -Uri $ZipUrl -Method Head -UseBasicParsing
    } catch {
      throw "Zip HEAD failed for both 'main' and 'master'. Provide -Branch or -ZipUrl explicitly. Last error: $($_.Exception.Message)"
    }
  } else {
    throw "Zip HEAD failed for $ZipUrl : $($_.Exception.Message)"
  }
}

$tmp = Join-Path $env:TEMP ("kql-lib-{0}.zip" -f (Get-Date -Format "yyyyMMddHHmmss"))
Write-Host "Downloading: $ZipUrl" -ForegroundColor Cyan
Invoke-WebRequest -Uri $ZipUrl -OutFile $tmp -UseBasicParsing

# Determine extraction folder
$remoteName = Get-GitRemoteName -url $RepoUrl
$extractRoot = $Destination
$branchFolder = Join-Path $extractRoot "$remoteName-$Branch"

# Prefer Expand-Archive
$useExpand = Get-Command Expand-Archive -ErrorAction SilentlyContinue
if($useExpand){
  if(Test-Path $branchFolder -and $Force){
    Write-Host "Clearing existing folder: $branchFolder" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $branchFolder
  }
  try {
    Expand-Archive -Path $tmp -DestinationPath $extractRoot -Force:$Force
  } catch {
    throw "Expand-Archive failed: $($_.Exception.Message). Try running with -Force or ensure write permissions."
  }
} else {
  # Fallback to ZipFile two-arg overload for Windows PowerShell
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if(Test-Path $branchFolder -and $Force){
    Write-Host "Clearing existing folder: $branchFolder" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $branchFolder
  }
  try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $extractRoot)
  } catch {
    throw "Zip extraction failed (ZipFile API): $($_.Exception.Message)."
  }
}

Remove-Item $tmp -Force

# Also mirror to a fixed folder name '<repo>' for convenience
$fixed = Join-Path $extractRoot $remoteName
if(Test-Path $branchFolder){
  if(Test-Path $fixed){
    if($Force){ Remove-Item -Recurse -Force $fixed } else { Write-Host "Note: '$fixed' already exists. Leaving extracted '$branchFolder' as-is." -ForegroundColor Yellow; return }
  }
  try {
    Rename-Item -Path $branchFolder -NewName $remoteName -Force:$Force
    Write-Host "Extracted to: $(Join-Path $extractRoot $remoteName)" -ForegroundColor Green
  } catch {
    Write-Warning "Rename step failed: $($_.Exception.Message). Use folder '$branchFolder'."
  }
} else {
  Write-Host "Extracted zip into: $extractRoot" -ForegroundColor Green
}
