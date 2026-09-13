#requires -Version 5.1
#requires -Modules Az.Accounts, Az.Compute, Az.Storage
<#
.SYNOPSIS
Fan out the AVD session host monitoring validation to every registered host and
collect one consolidated report.
.DESCRIPTION
Orchestrator that runs from an admin workstation/Cloud Shell. For each session host
registered to the host pool it:
  1. Resolves the underlying VM resource ID.
  2. Creates a short-lived, write-only blob SAS URL for that host's report.
  3. Injects Test-AVDSessionHostMonitoring.ps1 + Invoke-AVDMonitoringReportUpload.ps1
     into the VM through Run Command (RunPowerShellScript), which runs elevated as
     SYSTEM. The host runs the checks and PUTs its JSON report to the SAS URL.
  4. Downloads every report blob and merges them into one summary table and CSV.

Run Command caps inline output at 4,096 bytes, so hosts upload their full JSON report
to Storage instead of returning it inline. The SAS is anonymous and write-only; no
storage key or credential is placed on the session host.

The operator needs:
  - Read on the host pool and VMs (session host inventory, VM resource IDs).
  - Microsoft.Compute/virtualMachines/runCommand/action on each VM (Virtual Machine
    Contributor or higher).
  - Permission to create blob SAS (Storage Blob Data Contributor or a key-based
    context) and to read the reports container.

This is the multi-VM alternative to running Validate-AVDSessionHostMonitoring-Interactive.ps1
by hand. It is intentionally Run Command based rather than Azure Machine Configuration
(Guest Configuration), which is for continuous compliance state, not on-demand report
collection.
.EXAMPLE
$hpId = '/subscriptions/<sub>/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostPools/WPNS-AVD'
.\Invoke-AVDSessionHostReport.ps1 -HostPoolResourceId $hpId `
    -StorageAccountName stavdreports -StorageResourceGroupName rg-avd -ContainerName reports
.EXAMPLE
# Re-collect a report already uploaded without re-running the hosts
.\Invoke-AVDSessionHostReport.ps1 -HostPoolResourceId $hpId `
    -StorageAccountName stavdreports -StorageResourceGroupName rg-avd -ContainerName reports -CollectOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+/?$')]
    [string]$HostPoolResourceId,

    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$StorageResourceGroupName,
    [Parameter(Mandatory)][string]$ContainerName,

    [string]$OutputFolder = (Join-Path $PWD 'AVDReports'),
    [int]$SasExpiryMinutes = 30,
    [int]$MaxConcurrency = 10,
    [int]$WaitSeconds = 180,
    [int]$PollIntervalSeconds = 10,
    [switch]$CollectOnly,
    [switch]$SkipTestEvents
)

$ErrorActionPreference = 'Stop'
if (-not (Get-AzContext)) { throw 'Sign in with Connect-AzAccount first.' }

$scriptRoot = $PSScriptRoot
$validationScriptPath = Join-Path $scriptRoot 'Test-AVDSessionHostMonitoring.ps1'
$uploadScriptPath = Join-Path $scriptRoot 'Invoke-AVDMonitoringReportUpload.ps1'
foreach ($p in @($validationScriptPath, $uploadScriptPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required companion script not found: $p" }
}

function Get-ArmJson([string]$Path) {
    $response = Invoke-AzRestMethod -Path $Path -Method GET -ErrorAction Stop
    if ([int]$response.StatusCode -ge 400) { throw "ARM GET failed ($($response.StatusCode)): $Path $($response.Content)" }
    $response.Content | ConvertFrom-Json
}
function Get-ArmList([string]$Path) {
    do {
        $page = Get-ArmJson $Path
        @($page.value) | Where-Object { $null -ne $_ }
        $Path = $page.nextLink
        if ($Path -match '^https://') { $Path = ([uri]$Path).PathAndQuery }
    } while ($Path)
}

# --- Storage context + container -------------------------------------------------
$storageAccount = Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -Name $StorageAccountName -ErrorAction Stop
$ctx = $storageAccount.Context
if (-not (Get-AzStorageContainer -Name $ContainerName -Context $ctx -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($ContainerName, 'Create reports container')) {
        New-AzStorageContainer -Name $ContainerName -Context $ctx -Permission Off | Out-Null
    }
}

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

# --- Session host inventory -------------------------------------------------------
$hosts = @(Get-ArmList "$($HostPoolResourceId.TrimEnd('/'))/sessionHosts?api-version=2024-04-03")
if (-not $hosts.Count) { throw 'No registered session hosts found for this host pool.' }

$targets = foreach ($sh in $hosts) {
    $vmId = [string]$sh.properties.resourceId
    if ($vmId -match '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/virtualMachines/[^/]+$') {
        $name = ($sh.name -split '/')[-1]
        [pscustomobject]@{ Name = $name; VmId = $vmId.TrimEnd('/'); BlobName = "$runId/$($name -replace '[^A-Za-z0-9_.-]', '_').json" }
    }
}
if (-not $targets.Count) { throw 'No session hosts with a resolvable VM resource ID.' }

# --- Build the script that runs inside the VM ------------------------------------
# The validation body is assigned to $ValidationScript as a single-quoted
# here-string; a lone single quote inside it would terminate the here-string, so
# the upload body invokes it via [scriptblock]::Create after we escape nothing --
# instead the validation body is emitted as a real scriptblock literal below.
$validationBody = [System.IO.File]::ReadAllText($validationScriptPath)
$uploadBody = [System.IO.File]::ReadAllText($uploadScriptPath)
# Keep only the upload body after its param() block.
$uploadBody = $uploadBody -replace '(?s)^.*?param\s*\(\s*\[Parameter\(Mandatory\)\]\[string\]\$ReportSasUrl\s*\)\s*', ''
# SAS URLs are URL-safe (no single quotes), so direct substitution is safe.
$innerTemplate = @'
$ReportSasUrl = '__SASURL__'
$ValidationScript = {
__VALIDATION__
}
__UPLOADBODY__
'@

# --- Fan out ----------------------------------------------------------------------
# Invoke-AzVMRunCommand is synchronous: it returns after the script finishes, and
# .Value[0].Message carries stdout (truncated to 4 KB). We only need the UPLOAD_OK
# marker line, which fits. On PowerShell 5.1 ForEach-Object -Parallel is unavailable,
# so hosts run sequentially there.
$canParallel = $PSVersionTable.PSVersion.Major -ge 7
$jobs = @()
if (-not $CollectOnly) {
    foreach ($t in $targets) {
        $sas = New-AzStorageBlobSASToken -Container $ContainerName -Blob $t.BlobName `
            -Permission 'w' -ExpiryTime (Get-Date).AddMinutes($SasExpiryMinutes) -Context $ctx -FullUri -ErrorAction Stop
        $inner = $innerTemplate.Replace('__SASURL__', $sas).Replace('__VALIDATION__', $validationBody).Replace('__UPLOADBODY__', $uploadBody)
        $jobs += [pscustomobject]@{ Target = $t; Script = $inner }
    }

    $mode = if ($canParallel) { "parallel ($MaxConcurrency at a time)" } else { 'sequential (PowerShell 5.1)' }
    Write-Host "Dispatching Run Command to $($jobs.Count) host(s), $mode..." -ForegroundColor Cyan

    $dispatch = {
        param($job)
        $t = $job.Target
        $tmp = Join-Path $env:TEMP ("avdrc-" + [guid]::NewGuid().ToString() + '.ps1')
        [System.IO.File]::WriteAllText($tmp, $job.Script)
        try {
            $rg = ($t.VmId -split '/')[4]
            $vm = ($t.VmId -split '/')[8]
            $out = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vm `
                -CommandId 'RunPowerShellScript' -ScriptPath $tmp -ErrorAction Stop
            $msg = if ($out.Value -and $out.Value[0].Message) { $out.Value[0].Message } else { '' }
            $status = if ($msg -match 'UPLOAD_OK') { 'OK' } elseif ($msg -match 'UPLOAD_FAIL') { "UPLOAD_FAIL" } else { 'NO MARKER' }
            [pscustomobject]@{ Host = $t.Name; Dispatch = $status }
        } catch {
            [pscustomobject]@{ Host = $t.Name; Dispatch = "FAIL: $($_.Exception.Message)" }
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    $dispatched = if ($canParallel) {
        $jobs | ForEach-Object -Parallel $dispatch -ThrottleLimit $MaxConcurrency
    } else {
        $jobs | ForEach-Object { & $dispatch $_ }
    }
    $dispatched | ForEach-Object {
        $color = if ($_.Dispatch -eq 'OK') { 'Green' } else { 'Red' }
        Write-Host ("  {0,-30} {1}" -f $_.Host, $_.Dispatch) -ForegroundColor $color
    }
}

# --- Collect ----------------------------------------------------------------------
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$all = @()
foreach ($t in $targets) {
    $blob = $null
    do {
        $blob = Get-AzStorageBlob -Container $ContainerName -Blob $t.BlobName -Context $ctx -ErrorAction SilentlyContinue
        if ($blob -or $CollectOnly) { break }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ((Get-Date) -lt $deadline)

    if (-not $blob) {
        Write-Host ("  {0,-30} NO REPORT (timed out)" -f $t.Name) -ForegroundColor DarkYellow
        continue
    }
    $local = Join-Path $OutputFolder ([IO.Path]::GetFileName($t.BlobName))
    Get-AzStorageBlobContent -Container $ContainerName -Blob $t.BlobName -Destination $local -Context $ctx -Force | Out-Null
    $report = Get-Content $local -Raw | ConvertFrom-Json
    foreach ($r in $report.Results) { $all += $r }
    Write-Host ("  {0,-30} collected {1} checks" -f $t.Name, @($report.Results).Count) -ForegroundColor Green
}

# --- Merge ------------------------------------------------------------------------
if ($all.Count) {
    $csv = Join-Path $OutputFolder "AVDMonitoring-$runId.csv"
    $all | Export-Csv -NoTypeInformation -Path $csv -Encoding UTF8

    Write-Host "`n===== SUMMARY (worst status per host) =====" -ForegroundColor Cyan
    $rank = @{ Error = 0; Fail = 1; Warning = 2; Info = 3; Pass = 4 }
    $all | Group-Object Resource | ForEach-Object {
        $worst = ($_.Group | Sort-Object { $rank[$_.Status] } | Select-Object -First 1)
        $fails = @($_.Group | Where-Object Status -in 'Fail', 'Error').Count
        $warns = @($_.Group | Where-Object Status -eq 'Warning').Count
        [pscustomobject]@{
            Host    = $_.Name
            Status  = $worst.Status
            FailErr = $fails
            Warn    = $warns
            Checks  = $_.Count
        }
    } | Sort-Object Status, Host | Format-Table -AutoSize

    Write-Host "Full detail CSV: $csv" -ForegroundColor Cyan
    Write-Host "Individual JSON reports: $OutputFolder" -ForegroundColor Cyan
} else {
    Write-Host "`nNo reports were collected. Check VM agent status, Run Command connectivity (port 443 to Azure), and the Storage firewall." -ForegroundColor Yellow
}
