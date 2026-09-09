#requires -Version 5.1
#requires -Modules Az.Accounts
<#
.SYNOPSIS
Checks each registered host's AMA extension, DCRs and Event/Perf destination routes.
.DESCRIPTION
Uses the session host resourceId, supports VMs in other resource groups, and
reports each DCR's XPath, counters and transforms for review. Read-only.
.EXAMPLE
.\Test-AVDDCRAssociation.ps1 -HostPoolResourceId $hpId -LogAnalyticsWorkspaceResourceId $lawId
#>
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+/?$')][string]$HostPoolResourceId,
 [Parameter(Mandatory)][ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+/?$')][string]$LogAnalyticsWorkspaceResourceId
)

$ErrorActionPreference = 'Stop'
if (-not (Get-AzContext)) { throw 'Sign in with Connect-AzAccount first.' }
$results = [System.Collections.Generic.List[pscustomobject]]::new()
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
function Result([string]$Check, [string]$Status, [string]$Details) {
    $results.Add([pscustomobject]@{ Resource = ($resource -replace '.+/'); Check = $Check; Status = $Status; Details = $Details })
}

$resource = $HostPoolResourceId.Trim().TrimEnd('/')
$lawId = $LogAnalyticsWorkspaceResourceId.Trim().TrimEnd('/')
$hosts = @(Get-ArmList "$resource/sessionHosts?api-version=2024-04-03")
if (-not $hosts.Count) { Result 'SessionHostInventory' 'Fail' 'No registered session hosts found.'; return }
foreach ($sessionHost in $hosts) {
    $resource = $sessionHost.id
    $vmId = [string]$sessionHost.properties.resourceId
    if ($vmId -notmatch '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/virtualMachines/[^/]+$') {
        Result 'VMResourceId' 'Fail' "Missing or unsupported VM resource ID: $vmId"; continue
    }
    $resource = $vmId
    Result 'AVDAgent' 'Info' "State=$($sessionHost.properties.status); Version=$($sessionHost.properties.agentVersion); LastHeartbeat=$($sessionHost.properties.lastHeartBeat)"
    $vmIdentity = $null
    try {
        $vmIdentity = (Get-ArmJson "$($vmId)?api-version=2024-03-01").identity
        Result 'VMManagedIdentity' $(if ($vmIdentity.type -and $vmIdentity.type -ne 'None') { 'Pass' } else { 'Fail' }) "IdentityType=$($vmIdentity.type)"
    } catch { Result 'VMManagedIdentity' 'Error' $_.Exception.Message }
    try {
        $extensions = @(Get-ArmList "$vmId/extensions?api-version=2024-03-01")
        $ama = @($extensions | Where-Object { $_.properties.publisher -eq 'Microsoft.Azure.Monitor' -and $_.properties.type -eq 'AzureMonitorWindowsAgent' })
        Result 'AMAExtension' $(if (@($ama | Where-Object { $_.properties.provisioningState -eq 'Succeeded' }).Count) { 'Pass' } else { 'Fail' }) (
            ($ama | ForEach-Object { "$($_.name): $($_.properties.provisioningState); automaticUpgrade=$($_.properties.enableAutomaticUpgrade)" }) -join '; ')
        foreach ($extension in $ama) {
            if (-not $vmIdentity) {
                Result 'AMAIdentitySelection' 'Warning' 'VM identity was absent or unreadable; identity selection cannot be validated.'
                continue
            }
            $selection = $extension.properties.settings.authentication.managedIdentity
            if (-not $selection) {
                Result 'AMAIdentitySelection' $(if ($vmIdentity.type -match 'SystemAssigned') { 'Pass' } else { 'Fail' }) 'No explicit identity selection: system-assigned identity is required.'
                continue
            }
            $identifier = [string]$selection.'identifier-name'
            $value = [string]$selection.'identifier-value'
            $matchesIdentity = $false
            foreach ($assigned in @($vmIdentity.userAssignedIdentities.PSObject.Properties)) {
                if (-not $assigned -or [string]::IsNullOrWhiteSpace($value)) { continue }
                if (($identifier -eq 'mi_res_id' -and $assigned.Name -ieq $value) -or
                    ($identifier -eq 'client_id' -and $assigned.Value.clientId -ieq $value) -or
                    ($identifier -eq 'object_id' -and $assigned.Value.principalId -ieq $value)) {
                    $matchesIdentity = $true
                }
            }
            Result 'AMAIdentitySelection' $(if ($matchesIdentity) { 'Pass' } else { 'Fail' }) "$identifier=$value; must match a user-assigned identity attached to this VM."
        }
    } catch { Result 'AMAExtension' 'Error' $_.Exception.Message }
    try { $associations = @(Get-ArmList "$vmId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11") }
    catch { Result 'DCRAssociations' 'Error' $_.Exception.Message; continue }
    $ruleIds = @($associations | ForEach-Object { $_.properties.dataCollectionRuleId } | Where-Object { $_ } | Sort-Object -Unique)
    Result 'DCRAssociations' $(if ($ruleIds.Count) { 'Pass' } else { 'Fail' }) "$($ruleIds.Count) DCR(s); DCE-only associations do not count."
    $routes = @{ 'Microsoft-Event' = $false; 'Microsoft-Perf' = $false }
    $unreadable = $false
    foreach ($ruleId in $ruleIds) {
        try {
            $rule = (Get-ArmJson "$($ruleId)?api-version=2023-03-11").properties
            Result 'DCR' $(if ($rule.provisioningState -eq 'Succeeded') { 'Pass' } else { 'Warning' }) "$ruleId; ProvisioningState=$($rule.provisioningState)"
            $destinations = @($rule.destinations.logAnalytics | Where-Object {
                ([string]$_.workspaceResourceId).Trim().TrimEnd('/') -ieq $lawId
            } | ForEach-Object { $_.name })
            foreach ($source in @($rule.dataSources.windowsEventLogs)) {
                if ($source) { Result 'EventXPath' 'Info' "$ruleId : $($source.xPathQueries -join '; ')" }
            }
            foreach ($source in @($rule.dataSources.performanceCounters)) {
                if ($source) { Result 'PerformanceCounters' 'Info' "$ruleId : interval=$($source.samplingFrequencyInSeconds)s; $($source.counterSpecifiers -join '; ')" }
            }
            foreach ($stream in @('Microsoft-Event','Microsoft-Perf')) {
                $sources = if ($stream -eq 'Microsoft-Event') { @($rule.dataSources.windowsEventLogs) } else { @($rule.dataSources.performanceCounters) }
                $hasSource = @($sources | Where-Object { $stream -in $_.streams -and (($_.xPathQueries.Count -gt 0) -or ($_.counterSpecifiers.Count -gt 0)) }).Count -gt 0
                foreach ($flow in @($rule.dataFlows)) {
                    $targetMatches = @($flow.destinations | Where-Object { $_ -in $destinations }).Count -gt 0
                    if ($hasSource -and $stream -in $flow.streams -and $targetMatches -and (-not $flow.outputStream -or $flow.outputStream -eq $stream)) {
                        $routes[$stream] = $true
                        Result "Route:$stream" 'Info' "$ruleId; transformKql=$($flow.transformKql)"
                        if ($flow.transformKql -and $flow.transformKql.Trim() -ne 'source') {
                            Result "Transform:$stream" 'Warning' 'Custom transformation may filter records; verify ingestion with KQL.'
                        }
                    }
                }
            }
        } catch { $unreadable = $true; Result 'DCRRead' 'Error' "$ruleId : $($_.Exception.Message)" }
    }
    foreach ($stream in @('Microsoft-Event','Microsoft-Perf')) {
        $status = if ($routes[$stream]) { 'Pass' } elseif ($unreadable) { 'Error' } else { 'Fail' }
        Result "ExpectedWorkspaceRoute:$stream" $status 'Pass means source and route exist; review XPath/counter coverage and verify ingestion separately.'
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " AVD DCR Association Report" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$resW = 14; $chkW = 32; $stsW = 7
Write-Host ("{0,-$resW} {1,-$chkW} {2,-$stsW} Details" -f 'Resource','Check','Status') -ForegroundColor White
Write-Host ("{0,-$resW} {1,-$chkW} {2,-$stsW} -------" -f '--------','-----','------') -ForegroundColor DarkGray
foreach ($r in $results) {
    $stsColor = switch ($r.Status) { 'Pass' { 'Green' } 'Fail' { 'Red' } 'Warning' { 'Yellow' } 'Error' { 'Red' } default { 'White' } }
    Write-Host ("{0,-$resW} " -f $r.Resource) -NoNewline
    Write-Host ("{0,-$chkW} " -f $r.Check) -NoNewline
    Write-Host ("{0,-$stsW} " -f $r.Status) -ForegroundColor $stsColor -NoNewline
    Write-Host $r.Details
}

$pass = @($results | Where-Object { $_.Status -eq 'Pass' }).Count
$fail = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
$warn = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$err = @($results | Where-Object { $_.Status -eq 'Error' }).Count
$hostsChecked = @($results | Where-Object { $_.Check -eq 'AVDAgent' }).Count

Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host " Hosts checked  : $hostsChecked" -ForegroundColor White
Write-Host " Pass           : $pass" -ForegroundColor Green
Write-Host " Fail           : $fail" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
Write-Host " Warnings       : $warn" -ForegroundColor $(if ($warn) { 'Yellow' } else { 'Green' })
Write-Host " Errors         : $err" -ForegroundColor $(if ($err) { 'Red' } else { 'Green' })
Write-Host "----------------------------------------`n" -ForegroundColor Cyan

$noDcr = @($results | Where-Object { $_.Check -eq 'DCRAssociations' -and $_.Status -eq 'Fail' })
if ($noDcr.Count) {
    Write-Host "[ACTION REQUIRED] No DCRs associated with these session hosts." -ForegroundColor Red
    Write-Host "  The Log Analytics workspace has no data collection rules routing" -ForegroundColor Red
    Write-Host "  Windows Event Logs or Performance Counters to your workspace.`n" -ForegroundColor Red
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    1. Create DCRs for Microsoft-Event and Microsoft-Perf streams" -ForegroundColor Yellow
    Write-Host "    2. Associate the DCRs with each session host VM" -ForegroundColor Yellow
    Write-Host "    3. Re-run this script to verify ingestion routes`n" -ForegroundColor Yellow
}
