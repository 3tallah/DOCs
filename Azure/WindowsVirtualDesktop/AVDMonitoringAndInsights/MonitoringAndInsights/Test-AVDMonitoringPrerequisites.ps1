#requires -Version 5.1
<#
.SYNOPSIS
Checks the operator's modules, Azure context and read access to the three target resources.
.DESCRIPTION
Read-only. Does not install modules, sign in, change context or modify execution policy.
Resource GET access does not imply permission to query logs or inspect every child resource.
.EXAMPLE
.\Test-AVDMonitoringPrerequisites.ps1 -HostPoolResourceId $hpId -AVDWorkspaceResourceId $wsId -LogAnalyticsWorkspaceResourceId $lawId
#>
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+/?$')][string]$HostPoolResourceId,
 [Parameter(Mandatory)][ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.DesktopVirtualization/workspaces/[^/]+/?$')][string]$AVDWorkspaceResourceId,
 [Parameter(Mandatory)][ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+/?$')][string]$LogAnalyticsWorkspaceResourceId
)
$ErrorActionPreference = 'Stop'
function Result([string]$Check,[string]$Status,[string]$Details) {
    [pscustomobject]@{ Resource='Operator'; Check=$Check; Status=$Status; Details=$Details }
}
Result 'PowerShell' 'Pass' "$($PSVersionTable.PSVersion); $($PSVersionTable.PSEdition)"
$accountsReady = $false
foreach ($moduleName in @('Az.Accounts','Az.OperationalInsights')) {
    $available = @(Get-Module -ListAvailable -Name $moduleName | Sort-Object Version -Descending)
    if ($available.Count) {
        try {
            Import-Module $moduleName -ErrorAction Stop
            Result "Module:$moduleName" 'Pass' ([string]$available[0].Version)
            if ($moduleName -eq 'Az.Accounts') { $accountsReady = $true }
        } catch { Result "Module:$moduleName" 'Error' $_.Exception.Message }
    } else {
        Result "Module:$moduleName" $(if ($moduleName -eq 'Az.Accounts') { 'Fail' } else { 'Warning' }) 'Not installed. Az.OperationalInsights is needed only for automated ingestion queries.'
    }
}
if (-not $accountsReady) { return }
$context = Get-AzContext
if (-not $context) { Result 'AzureContext' 'Fail' 'Run Connect-AzAccount in the intended tenant first.'; return }
Result 'AzureContext' 'Info' "Tenant=$($context.Tenant.Id); Subscription=$($context.Subscription.Id); Environment=$($context.Environment.Name)"
foreach ($target in @(
    @{Id=$HostPoolResourceId; Api='2024-04-03'; Name='HostPool'},
    @{Id=$AVDWorkspaceResourceId; Api='2024-04-03'; Name='AVDWorkspace'},
    @{Id=$LogAnalyticsWorkspaceResourceId; Api='2022-10-01'; Name='LogAnalyticsWorkspace'}
)) {
    try {
        $id = $target.Id.TrimEnd('/')
        $response = Invoke-AzRestMethod -Path "$($id)?api-version=$($target.Api)" -Method GET -ErrorAction Stop
        if ([int]$response.StatusCode -ge 400) { throw "HTTP $($response.StatusCode): $($response.Content)" }
        $resource = $response.Content | ConvertFrom-Json
        Result "ReadAccess:$($target.Name)" 'Pass' $id
        if ($target.Name -eq 'LogAnalyticsWorkspace') {
            Result 'LogAnalyticsWorkspaceId' 'Info' "Use this GUID for Test-AVDLogAnalyticsIngestion.ps1: $($resource.properties.customerId)"
        }
    } catch { Result "ReadAccess:$($target.Name)" 'Error' $_.Exception.Message }
}
Result 'NextChecks' 'Info' 'Run diagnostic-settings and DCR checks, then ingestion queries. Resource-read success is not proof of data-plane query permissions or ingestion.'
