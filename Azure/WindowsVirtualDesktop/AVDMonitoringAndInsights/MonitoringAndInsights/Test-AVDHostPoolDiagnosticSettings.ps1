#requires -Version 5.1
#requires -Modules Az.Accounts
<#
.SYNOPSIS
Read-only validation of AVD HostPool diagnostics, category coverage and destination.
.EXAMPLE
.\Test-AVDHostPoolDiagnosticSettings.ps1 -HostPoolResourceId $id -LogAnalyticsWorkspaceResourceId $lawId
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
    [pscustomobject]@{ Resource = ($resource -replace '.+/'); Check = $Check; Status = $Status; Details = $Details }
}

$resource = $HostPoolResourceId.Trim().TrimEnd('/')
$baseline = @('Checkpoint','Error','Management','Connection','HostRegistration','AgentHealthStatus')

$expected = $LogAnalyticsWorkspaceResourceId.Trim().TrimEnd('/')
$categories = @(Get-ArmList "$resource/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=2021-05-01-preview" |
    Where-Object { $_.properties.categoryType -eq 'Logs' })
$settings = @(Get-ArmList "$resource/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview")
Result 'AvailableCategories' 'Info' (($categories.name | Sort-Object) -join ', ')
$matching = @($settings | Where-Object { ([string]$_.properties.workspaceId).Trim().TrimEnd('/') -ieq $expected })
Result 'ExpectedDestination' $(if ($matching.Count) { 'Pass' } else { 'Fail' }) "$($matching.Count) settings target $expected"
foreach ($setting in $settings) {
    $enabledLogs = @($setting.properties.logs | Where-Object { $_.enabled -eq $true } |
        ForEach-Object {
            if ($_.categoryGroup) { "$($_.categoryGroup)" } else { "$($_.category)" }
        })
    Result "Setting:$($setting.name)" 'Info' ("Destination={0}; EnabledLogs={1}" -f $setting.properties.workspaceId,
        ($enabledLogs -join ', '))
}
$enabled = @($matching | ForEach-Object { $_.properties.logs } | Where-Object { $_.enabled -eq $true })
$allLogs = @($enabled | Where-Object { $_.categoryGroup -ieq 'allLogs' }).Count -gt 0
Result 'allLogs' $(if ($allLogs) { 'Pass' } else { 'Warning' }) 'Explicit coverage is checked separately; allLogs also includes future categories.'
foreach ($name in $baseline) {
    if ($name -notin $categories.name) { Result "Baseline:$name" 'Warning' 'Not advertised by this resource; review current Insights configuration workbook.' }
}
foreach ($category in $categories) {
    $coverage = @()
    if ($allLogs) { $coverage += 'allLogs' }
    if ($category.name -in @($enabled.category)) { $coverage += 'explicit category' }
    foreach ($entry in $enabled | Where-Object { $_.categoryGroup }) {
        if ($entry.categoryGroup -in @($category.properties.categoryGroups)) { $coverage += "group:$($entry.categoryGroup)" }
    }
    $coverage = @($coverage | Sort-Object -Unique)
    $covered = $coverage.Count -gt 0
    $status = if ($covered) { 'Pass' } elseif ($category.name -in $baseline) { 'Fail' } else { 'Warning' }
    $details = if ($covered) { "Covered by $($coverage -join ', ') at expected destination." } else { 'Not enabled at expected destination.' }
    Result "Category:$($category.name)" $status $details
}
