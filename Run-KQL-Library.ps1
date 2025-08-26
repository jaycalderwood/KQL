
<#
  KQL Library Console (Combined)
  • Normal & Resource-Scoped KQL flows
  • Cross-tenant/subscription workspace picker
  • M365 Defender Advanced Hunting (Graph)
  • Azure Resource Graph .arg runner
  • Utilities
#>
[CmdletBinding()]
param(
  [string]$LibraryRoot = (Join-Path -Path $PSScriptRoot -ChildPath 'KQL-Library'),
  [string]$DefaultTimespan = 'PT24H',
  [int]$ArgMax = 1000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section { param([string]$Text) Write-Host ('='*100) -ForegroundColor DarkGray; Write-Host " $Text" -ForegroundColor Cyan; Write-Host ('='*100) -ForegroundColor DarkGray }

function Ensure-Module {
  param([Parameter(Mandatory)][string]$Name, [string]$MinVersion)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    try {
      Write-Host "Installing module $Name..." -ForegroundColor Yellow
      if ($MinVersion) { Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -MinimumVersion $MinVersion }
      else { Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber }
    } catch {
      Write-Warning "Failed to auto-install $Name. You may need to run: Install-Module $Name -Scope CurrentUser"
    }
  }
  Import-Module $Name -ErrorAction Stop
}

function Connect-AzureIfNeeded {
  Ensure-Module Az.Accounts 2.15.0
  if (-not (Get-AzContext)) {
    Write-Host "Connecting to Azure..." -ForegroundColor Cyan
    Connect-AzAccount -UseDeviceAuthentication:$($PSVersionTable.PSEdition -eq 'Core') | Out-Null
  }
}

function Get-AllSubscriptions {
  $tenants = @()
  try { $tenants = Get-AzTenant | Sort-Object DisplayName } catch { }
  if (-not $tenants) {
    Connect-AzAccount -UseDeviceAuthentication:$($PSVersionTable.PSEdition -eq 'Core') | Out-Null
    $tenants = Get-AzTenant | Sort-Object DisplayName
  }
  $subsAll = @()
  foreach ($t in $tenants) {
    try { $subs = Get-AzSubscription -TenantId $t.TenantId -ErrorAction Stop }
    catch {
      Write-Warning ("Tenant {0} needs interactive login..." -f $t.TenantId)
      try { Connect-AzAccount -TenantId $t.TenantId -UseDeviceAuthentication:$($PSVersionTable.PSEdition -eq 'Core') | Out-Null; $subs = Get-AzSubscription -TenantId $t.TenantId -ErrorAction Stop }
      catch { Write-Warning ("Skipping tenant {0}: {1}" -f $t.TenantId, $_.Exception.Message); continue }
    }
    if ($subs) { $subsAll += ($subs | Select-Object @{n='TenantId';e={$t.TenantId}}, @{n='TenantName';e={$t.DisplayName}}, Name, Id) }
  }
  return $subsAll
}

function Get-AllWorkspaces {
  Ensure-Module Az.OperationalInsights 2.7.0
  $subs = Get-AllSubscriptions
  if (-not $subs) { throw "No subscriptions accessible." }
  $workspaces = @()
  foreach ($s in $subs) {
    try {
      Set-AzContext -Tenant $s.TenantId -SubscriptionId $s.Id | Out-Null
      $ws = Get-AzOperationalInsightsWorkspace -ErrorAction Stop
      foreach ($w in $ws) {
        $workspaces += [pscustomobject]@{
          WorkspaceName  = $w.Name
          ResourceGroup  = $w.ResourceGroupName
          Location       = $w.Location
          WorkspaceId    = $w.CustomerId
          Subscription   = $s.Name
          SubscriptionId = $s.Id
          TenantName     = $s.TenantName
          TenantId       = $s.TenantId
        }
      }
    } catch { Write-Warning ("Skipping subscription {0}: {1}" -f $s.Id, $_.Exception.Message) }
  }
  return $workspaces | Sort-Object TenantName, Subscription, ResourceGroup, WorkspaceName
}

function Select-LogAnalyticsWorkspace {
  Connect-AzureIfNeeded
  $all = Get-AllWorkspaces
  if (-not $all) { throw "No Log Analytics workspaces found." }
  $i=1; $index=@{};
  foreach ($item in $all) {
    Write-Host ("{0}) {1}  RG={2}  Sub={3}  Ten={4}  Loc={5}" -f $i, $item.WorkspaceName, $item.ResourceGroup, $item.Subscription, $item.TenantName, $item.Location)
    $index[$i] = $item; $i++
  }
  $sel = Read-Host "Enter the Index of the workspace to use"
  if (-not ($sel -as [int])) { throw "Invalid selection." }
  $selected = $index[[int]$sel]
  if (-not $selected) { throw "Invalid selection." }
  Set-AzContext -Tenant $selected.TenantId -SubscriptionId $selected.SubscriptionId | Out-Null
  return @{ WorkspaceId=$selected.WorkspaceId; ResourceGroup=$selected.ResourceGroup; Name=$selected.WorkspaceName; SubscriptionId=$selected.SubscriptionId; TenantId=$selected.TenantId }
}

function Invoke-LogAnalyticsQuery {
  param([Parameter(Mandatory)][string]$WorkspaceId,[Parameter(Mandatory)][string]$Query,[string]$Timespan,[datetime]$StartTime,[datetime]$EndTime)
  Write-Host "Running Log Analytics query..." -ForegroundColor Cyan
  if ($PSBoundParameters.ContainsKey('StartTime') -and $PSBoundParameters.ContainsKey('EndTime')) {
    return (Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -StartTime $StartTime -EndTime $EndTime).Results
  } else {
    if (-not $Timespan) { $Timespan = $DefaultTimespan }
    return (Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -Timespan $Timespan).Results
  }
}

function Ensure-Graph {
  Ensure-Module Microsoft.Graph 2.20.0
  if (-not (Get-MgContext)) { Connect-MgGraph -Scopes 'ThreatHunting.Read.All' -NoWelcome | Out-Null; Select-MgProfile -Name 'v1.0' }
}

function Invoke-DefenderHuntingQuery {
  param([Parameter(Mandatory)][string]$Query,[string]$Timespan='P30D')
  Ensure-Graph
  $body = @{ Query=$Query; Timespan=$Timespan } | ConvertTo-Json -Depth 5
  try {
    $res = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/security/runHuntingQuery' -Body $body -ContentType 'application/json'
    if ($res.value) { return ,(@($res.value) | ForEach-Object { [pscustomobject]$_ }) } else { return $null }
  } catch { Write-Error $_; return $null }
}

function Get-AllQueryFiles { param([string]$Root,[string[]]$Extensions=@('*.kql')); Get-ChildItem -Path $Root -Recurse -Include $Extensions -File | Sort-Object FullName }

function Pick-FromList { param([array]$Items,[string]$Prompt="Enter number(s), comma-separated")
  if (-not $Items -or -not $Items.Count) { throw "Nothing to choose from." }
  for($i=0;$i -lt $Items.Count;$i++){ $label=$Items[$i]; if($label -is [IO.FileInfo] -or $label -is [IO.DirectoryInfo]){ $label=$label.Name }; Write-Host ("{0}) {1}" -f ($i+1),$label) }
  $sel=Read-Host $Prompt
  $idx=@()
  if(-not [string]::IsNullOrWhiteSpace($sel)){ $idx=$sel -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { [int]$_ - 1 } }
  $selected = foreach($n in $idx){ if($n -ge 0 -and $n -lt $Items.Count){ $Items[$n] } }
  if (-not $selected) { throw "Invalid selection." }; return $selected
}

function Pick-QueryFiles { param([string]$Folder)
  $files=Get-ChildItem -Path $Folder -Filter *.kql -File | Sort-Object Name
  if(-not $files){ throw "No .kql files found in $Folder" }
  $sel=Pick-FromList -Items $files -Prompt "Enter number(s), comma-separated for batch"
  return @($sel | ForEach-Object { $_.FullName })
}

function Search-Queries { param([string]$Root,[string]$Keyword,[string[]]$Extensions=@('*.kql'))
  $all=Get-AllQueryFiles -Root $Root -Extensions $Extensions
  $hits=foreach($f in $all){ $c=Get-Content -Raw -Path $f.FullName; if($f.Name -match [regex]::Escape($Keyword) -or $c -match [regex]::Escape($Keyword)){ [pscustomobject]@{ Path=$f.FullName; Name=$f.Name } } }
  if(-not $hits){ Write-Host "No matches." -ForegroundColor Yellow; return @() }
  $paths=Pick-FromList -Items $hits.Path -Prompt "Enter number(s) to select (comma-separated)"
  return @($paths)
}

function Replace-TokensInQuery { param([string]$Query,[hashtable]$AutoTokens)
  $m=[regex]::Matches($Query,"{{([A-Za-z0-9_]+)}}"); $toks=@(); foreach($x in $m){ $toks+=$x.Groups[1].Value }; $toks=$toks | Select-Object -Unique
  foreach($t in $toks){
    if($AutoTokens -and $AutoTokens.ContainsKey($t) -and $AutoTokens[$t]){
      $Query=$Query.Replace("{{$t}}",[string]$AutoTokens[$t])
    }
  }
  # Prompt for any remaining tokens
  $m=[regex]::Matches($Query,"{{([A-Za-z0-9_]+)}}"); $toks=@(); foreach($x in $m){ $toks+=$x.Groups[1].Value }; $toks=$toks | Select-Object -Unique
  foreach($t in $toks){ $val=Read-Host ("Enter value for token {{{0}}}" -f $t); $Query=$Query.Replace("{{$t}}",$val) }
  return $Query
}

function Export-ResultsMaybe { param([object]$Data,[string]$Prefix)
  if(-not $Data){ return }
  $out=Read-Host "Export results to CSV? (y/n)"
  if($out -eq 'y'){
    $csv=Join-Path -Path $PSScriptRoot -ChildPath ("{0}_{1:yyyyMMdd_HHmmss}.csv" -f $Prefix,(Get-Date))
    $Data | Export-Csv -NoTypeInformation -Path $csv
    Write-Host "Saved: $csv" -ForegroundColor Green
  } else {
    $Data | Format-Table -AutoSize | Out-Host
  }
}

function Run-LogAnalyticsFlow {
  Connect-AzureIfNeeded; Ensure-Module Az.OperationalInsights 2.7.0
  $ws=Select-LogAnalyticsWorkspace
  Write-Section "Log Analytics: Query Selection"; Write-Host "[1] Pick by Category  [2] Search" -ForegroundColor Cyan
  $mode=Read-Host "Choose selection mode"; $paths=@()
  if($mode -eq '2'){
    $categories=Get-ChildItem -Directory -Path $LibraryRoot | Where-Object { $_.Name -notin @('Defender365AH','ResourceGraph') }
    $kw=Read-Host "Keyword to search in names/content"
    foreach($d in $categories){ $paths += Search-Queries -Root $d.FullName -Keyword $kw }
    $paths=$paths | Where-Object { $_ } | Select-Object -Unique
    if(-not $paths){ Write-Host "No matches." -ForegroundColor Yellow; return }
  } else {
    $categories=Get-ChildItem -Directory -Path $LibraryRoot | Where-Object { $_.Name -notin @('Defender365AH','ResourceGraph') }
    $picked=Pick-FromList -Items $categories -Prompt "Choose a category"
    $catPath=$picked[0].FullName; $paths=Pick-QueryFiles -Folder $catPath
  }
  Write-Section "Time Range"; $timeMode=Read-Host "Time mode: [1] Timespan (e.g., PT24H)  [2] Start/End"; $timespan=$DefaultTimespan; $start=$null; $end=$null
  if($timeMode -eq '2'){ $start=[datetime](Read-Host "Start time (e.g., 2025-08-15T00:00:00)"); $end=[datetime](Read-Host "End time   (e.g., 2025-08-16T00:00:00)") }
  else { $tsIn=Read-Host "Timespan [default: $DefaultTimespan]"; if(-not [string]::IsNullOrWhiteSpace($tsIn)){ $timespan=$tsIn } }
  foreach($file in $paths){
    Write-Section ("Running: {0}" -f $file)
    $q=Get-Content -Raw -Path $file
    $q=Replace-TokensInQuery -Query $q -AutoTokens $null
    $res=Invoke-LogAnalyticsQuery -WorkspaceId $ws.WorkspaceId -Query $q -Timespan $timespan -StartTime $start -EndTime $end
    Export-ResultsMaybe -Data $res -Prefix ("results_"+[IO.Path]::GetFileNameWithoutExtension($file))
  }
}

function Select-AzureResource {
  Connect-AzureIfNeeded; Ensure-Module Az.ResourceGraph 2.5.0
  $kw = Read-Host "Filter resources by name contains (leave blank for all)"
  $q = @"
Resources
| project id, name, type, resourceGroup, subscriptionId, location
| order by name asc
"@
  if ($kw) {
    $q = @"
Resources
| where name contains '{0}'
| project id, name, type, resourceGroup, subscriptionId, location
| order by name asc
"@ -f $kw.Replace("'", "''")
  }
  $rows = Search-AzGraph -Query $q -First 5000
  if(-not $rows){ throw "No resources found." }
  $i=1; $map=@{}
  foreach($r in $rows){
    Write-Host ("{0}) {1}  ({2})  RG={3}  Sub={4}  Loc={5}" -f $i, $r.name, $r.type, $r.resourceGroup, $r.subscriptionId, $r.location)
    $map[$i]=$r; $i++
  }
  $sel = Read-Host "Enter the Index of the resource to scope to"
  if (-not ($sel -as [int])) { throw "Invalid selection." }
  $r = $map[[int]$sel]
  if(-not $r){ throw "Invalid selection." }
  return [pscustomobject]@{
    ResourceId     = $r.id
    ResourceName   = $r.name
    ResourceGroup  = $r.resourceGroup
    SubscriptionId = $r.subscriptionId
    ResourceType   = $r.type
    Location       = $r.location
  }
}

function Run-ResourceScopedFlow {
  Connect-AzureIfNeeded; Ensure-Module Az.OperationalInsights 2.7.0
  $ws=Select-LogAnalyticsWorkspace
  $res = Select-AzureResource
  $auto = @{
    ResourceId     = $res.ResourceId
    ResourceName   = $res.ResourceName
    ResourceGroup  = $res.ResourceGroup
    SubscriptionId = $res.SubscriptionId
    ResourceType   = $res.ResourceType
    Location       = $res.Location
  }

  Write-Section "Resource-Scoped: Query Selection"
  $categories=Get-ChildItem -Directory -Path $LibraryRoot | Where-Object { $_.Name -notin @('Defender365AH','ResourceGraph') }
  $picked=Pick-FromList -Items $categories -Prompt "Choose a category"
  $catPath=Join-Path $picked[0].FullName 'ResourceScoped'
  if(-not (Test-Path $catPath)){ throw "No ResourceScoped folder for $($picked[0].Name). Rebuild the library." }
  $mode=Read-Host "[1] Pick files  [2] Search"; $paths=@()
  if($mode -eq '2'){
    $kw=Read-Host "Keyword to search"
    $paths=Search-Queries -Root $catPath -Keyword $kw
    if(-not $paths){ Write-Host "No matches." -ForegroundColor Yellow; return }
  } else {
    $paths=Pick-QueryFiles -Folder $catPath
  }

  Write-Section "Time Range"; $timeMode=Read-Host "Time mode: [1] Timespan (e.g., PT24H)  [2] Start/End"; $timespan=$DefaultTimespan; $start=$null; $end=$null
  if($timeMode -eq '2'){ $start=[datetime](Read-Host "Start time (e.g., 2025-08-15T00:00:00)"); $end=[datetime](Read-Host "End time   (e.g., 2025-08-16T00:00:00)") }
  else { $tsIn=Read-Host "Timespan [default: $DefaultTimespan]"; if(-not [string]::IsNullOrWhiteSpace($tsIn)){ $timespan=$tsIn } }

  foreach($file in $paths){
    Write-Section ("Running (Resource-Scoped): {0}" -f $file)
    $q=Get-Content -Raw -Path $file
    $q=Replace-TokensInQuery -Query $q -AutoTokens $auto
    $resRows=Invoke-LogAnalyticsQuery -WorkspaceId $ws.WorkspaceId -Query $q -Timespan $timespan -StartTime $start -EndTime $end
    Export-ResultsMaybe -Data $resRows -Prefix ("rscope_"+[IO.Path]::GetFileNameWithoutExtension($file))
  }
}

function Run-DefenderFlow {
  Ensure-Module Microsoft.Graph 2.20.0
  if (-not (Get-MgContext)) { Connect-MgGraph -Scopes 'ThreatHunting.Read.All' -NoWelcome | Out-Null; Select-MgProfile -Name 'v1.0' }
  $defPath=Join-Path $LibraryRoot 'Defender365AH'
  if(-not (Test-Path $defPath)){ throw "Defender365AH folder not found at $defPath" }
  Write-Section "Defender AH: Query Selection"; Write-Host "[1] Pick from folder  [2] Search" -ForegroundColor Cyan; $mode=Read-Host "Choose selection mode"; $paths=@()
  if($mode -eq '2'){ $kw=Read-Host "Keyword to search in names/content"; $paths=Search-Queries -Root $defPath -Keyword $kw; if(-not $paths){ return } } else { $paths=Pick-QueryFiles -Folder $defPath }
  $span=Read-Host "Timespan (ISO 8601, e.g. P7D) [default: P30D]"; if([string]::IsNullOrWhiteSpace($span)){ $span='P30D' }
  foreach($file in $paths){
    Write-Section ("Running: {0}" -f $file)
    $q=Get-Content -Raw -Path $file
    $q=Replace-TokensInQuery -Query $q -AutoTokens $null
    $rows=Invoke-DefenderHuntingQuery -Query $q -Timespan $span
    Export-ResultsMaybe -Data $rows -Prefix ("defender_"+[IO.Path]::GetFileNameWithoutExtension($file))
  }
}

function Run-ResourceGraphFlow {
  Connect-AzureIfNeeded; Ensure-Module Az.ResourceGraph 2.5.0; $rgPath=Join-Path $LibraryRoot 'ResourceGraph'
  if(-not (Test-Path $rgPath)){ throw "ResourceGraph folder not found: $rgPath" }
  $files=Get-ChildItem -Path $rgPath -Filter *.arg -File | Sort-Object Name
  if(-not $files){ throw "No .arg query files in $rgPath" }
  $paths=Pick-FromList -Items $files -Prompt "Enter number(s), comma-separated for batch"
  foreach($p in $paths){
    $q=Get-Content -Raw -Path $p.FullName
    Write-Section ("ARG: {0}" -f $p.Name)
    $res=Search-AzGraph -Query $q -First $ArgMax
    Export-ResultsMaybe -Data $res -Prefix ("arg_"+[IO.Path]::GetFileNameWithoutExtension($p.Name))
  }
}

function Utilities {
  Write-Section "Utilities"
  Write-Host "1) List workspaces" -ForegroundColor Cyan
  Write-Host "2) Show library index (packs & files)"
  Write-Host "3) Open library folder"
  Write-Host "4) Back"
  $sel = Read-Host "Choose"
  switch ($sel) {
    '1' { $ws = Get-AllWorkspaces; $ws | Format-Table TenantName, Subscription, ResourceGroup, WorkspaceName, Location -AutoSize | Out-Host }
    '2' { $idxFile = Join-Path $LibraryRoot 'PacksIndex.json'; if (Test-Path $idxFile) { (Get-Content -Raw $idxFile) | Out-Host } else { Write-Host "Index not found: $idxFile" -ForegroundColor Yellow } }
    '3' { $p = Resolve-Path $LibraryRoot; Write-Host "Opening $p..."; Start-Process $p }
    default { return }
  }
}

function Show-Menu {
  Clear-Host
  Write-Host "=== KQL Library (Combined) ===" -ForegroundColor Green
  Write-Host "1) Run Log Analytics / Sentinel query (pick/search, batch)"
  Write-Host "2) Run Microsoft 365 Defender Advanced Hunting query (pick/search, batch)"
  Write-Host "3) Run Azure Resource Graph query (.arg)"
  Write-Host "4) Run Resource-Scoped Log Analytics query (auto-filter by selected Azure resource)"
  Write-Host "5) Utilities"
  Write-Host "6) Exit"
  return (Read-Host "Choose an option")
}

while($true){
  switch(Show-Menu){
    '1'{ Run-LogAnalyticsFlow }
    '2'{ Run-DefenderFlow }
    '3'{ Run-ResourceGraphFlow }
    '4'{ Run-ResourceScopedFlow }
    '5'{ Utilities }
    '6'{ break }
    default{ break }
  }
}
