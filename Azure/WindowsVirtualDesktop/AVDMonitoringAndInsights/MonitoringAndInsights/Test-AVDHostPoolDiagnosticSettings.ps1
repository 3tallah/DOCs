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
    [pscustomobject]@{ Resource = $resource; Check = $Check; Status = $Status; Details = $Details }
}

$resource = $HostPoolResourceId.TrimEnd('/')
$baseline = @('Checkpoint','Error','Management','Connection','HostRegistration','AgentHealthStatus')

$expected = $LogAnalyticsWorkspaceResourceId.TrimEnd('/')
$categories = @(Get-ArmList "$resource/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=2021-05-01-preview" |
    Where-Object { $_.properties.categoryType -eq 'Logs' })
$settings = @(Get-ArmList "$resource/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview")
Result 'AvailableCategories' 'Info' (($categories.name | Sort-Object) -join ', ')
$matching = @($settings | Where-Object { ([string]$_.properties.workspaceId).TrimEnd('/') -ieq $expected })
Result 'ExpectedDestination' $(if ($matching.Count) { 'Pass' } else { 'Fail' }) "$($matching.Count) settings target $expected"
foreach ($setting in $settings) {
    Result "Setting:$($setting.name)" 'Info' ("Destination={0}; EnabledLogs={1}" -f $setting.properties.workspaceId,
        ((@($setting.properties.logs | Where-Object { $_.enabled -eq $true }) | ForEach-Object { "$($_.category)$($_.categoryGroup)" }) -join ', '))
}
$enabled = @($matching | ForEach-Object { $_.properties.logs } | Where-Object { $_.enabled -eq $true })
$allLogs = @($enabled | Where-Object { $_.categoryGroup -ieq 'allLogs' }).Count -gt 0
Result 'allLogs' $(if ($allLogs) { 'Pass' } else { 'Warning' }) 'Explicit coverage is checked separately; allLogs also includes future categories.'
foreach ($name in $baseline) {
    if ($name -notin $categories.name) { Result "Baseline:$name" 'Warning' 'Not advertised by this resource; review current Insights configuration workbook.' }
}
foreach ($category in $categories) {
    $covered = $allLogs -or ($category.name -in $enabled.category)
    foreach ($entry in $enabled) {
        if ($entry.categoryGroup -and $entry.categoryGroup -in @($category.properties.categoryGroups)) { $covered = $true }
    }
    $status = if ($covered) { 'Pass' } elseif ($category.name -in $baseline) { 'Fail' } else { 'Warning' }
    Result "Category:$($category.name)" $status "Enabled to expected destination: $covered"
}

