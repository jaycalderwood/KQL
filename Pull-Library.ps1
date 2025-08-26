
<#
Pull-Library.ps1
Fetches the latest KQL Library either via git (RepoUrl) or direct zip (ZipUrl).
Usage examples:
  .\Pull-Library.ps1 -RepoUrl "https://github.com/you/KQL-Library.git" -Destination "."
  .\Pull-Library.ps1 -ZipUrl  "https://example.com/KQL-Library.zip"   -Destination "."
#>
[CmdletBinding()]
param(
  [string]$RepoUrl,
  [string]$ZipUrl,
  [string]$Destination = (Resolve-Path .).Path,
  [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Git { try { git --version | Out-Null; return $true } catch { return $false } }

if([string]::IsNullOrWhiteSpace($RepoUrl) -and [string]::IsNullOrWhiteSpace($ZipUrl)){
  throw "Provide -RepoUrl (git) or -ZipUrl (direct zip)."
}

if($RepoUrl){
  if(Test-Git){
    $folder = Join-Path $Destination ((Split-Path $RepoUrl -Leaf).Replace('.git',''))
    if(Test-Path $folder){
      Write-Host "Updating existing repo at $folder..." -ForegroundColor Cyan
      Push-Location $folder
      try { git pull --rebase --autostash } finally { Pop-Location }
    } else {
      Write-Host "Cloning $RepoUrl to $Destination..." -ForegroundColor Cyan
      git clone $RepoUrl $folder
    }
  } else {
    Write-Warning "git not found. Falling back to zip if provided."
    if(-not $ZipUrl){ throw "git not available and no -ZipUrl provided." }
  }
}

if($ZipUrl){
  $tmp = Join-Path $env:TEMP ("kql-lib-{0}.zip" -f (Get-Date -Format "yyyyMMddHHmmss"))
  Write-Host "Downloading zip..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri $ZipUrl -OutFile $tmp
  $target = Join-Path $Destination "KQL-Library"
  if(Test-Path $target -and $Force){ Remove-Item -Recurse -Force $target }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($tmp, $Destination, $true)
  Remove-Item $tmp -Force
  Write-Host "Extracted to $Destination" -ForegroundColor Green
}
