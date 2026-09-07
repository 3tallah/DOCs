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
    [pscustomobject]@{ Resource = $resource; Check = $Check; Status = $Status; Details = $Details }
}

$resource = $HostPoolResourceId.TrimEnd('/')
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
                ([string]$_.workspaceResourceId).TrimEnd('/') -ieq $LogAnalyticsWorkspaceResourceId.TrimEnd('/')
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
