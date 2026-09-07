#requires -Version 5.1
#requires -Modules Az.Accounts

<#
.SYNOPSIS
Creates a cost-optimized Azure Monitor DCR for Azure Virtual Desktop session hosts.

.DESCRIPTION
Creates or updates one DCR containing:
- Essential AVD performance counters
- AVD, Windows and FSLogix event logs
- Microsoft-Perf -> Log Analytics
- Microsoft-Event -> Log Analytics
- DCR association for every registered session host in the host pool

Cost optimizations:
- 60-second sampling for all performance counters
- No per-process User Input Delay counter
- No RemoteFX Network counters when WVDConnectionNetworkData is already enabled
- System/Application events limited to Critical, Error and Warning
- AVD/FSLogix event channels limited to Critical, Error and Warning
- No duplicated Metrics destination
- No custom transforms

The script does NOT remove any existing DCRs.

.EXAMPLE
.\Set-AVDCostOptimizedMonitoring.ps1 `
  -HostPoolResourceId "/subscriptions/.../hostPools/WPNS-AVD" `
  -LogAnalyticsWorkspaceResourceId "/subscriptions/.../workspaces/LAW-WPNS-AVD"

.EXAMPLE
.\Set-AVDCostOptimizedMonitoring.ps1 `
  -HostPoolResourceId $hpId `
  -LogAnalyticsWorkspaceResourceId $lawId `
  -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.DesktopVirtualization/hostPools/[^/]+/?$')]
    [string]$HostPoolResourceId,

    [Parameter(Mandatory)]
    [ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+/?$')]
    [string]$LogAnalyticsWorkspaceResourceId,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9\-_\.]+$')]
    [string]$DCRName = "DCR-AVD-CostOptimized",

    [Parameter()]
    [string]$DCRResourceGroupName
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

if (-not (Get-AzContext)) {
    throw "Sign in first using Connect-AzAccount."
}

$hpId  = $HostPoolResourceId.Trim().TrimEnd('/')
$lawId = $LogAnalyticsWorkspaceResourceId.Trim().TrimEnd('/')

# ---------------------------------------------------------------------------
# ARM helper functions
# ---------------------------------------------------------------------------

function Get-ArmJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $response = Invoke-AzRestMethod `
        -Path $Path `
        -Method GET `
        -ErrorAction Stop

    if ([int]$response.StatusCode -ge 400) {
        throw "ARM GET failed ($($response.StatusCode)): $Path`n$($response.Content)"
    }

    if ($response.Content) {
        return ($response.Content | ConvertFrom-Json)
    }
}

function Get-ArmList {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    do {
        $page = Get-ArmJson -Path $Path

        @($page.value) |
            Where-Object { $null -ne $_ }

        $Path = $page.nextLink

        if ($Path -match '^https://') {
            $Path = ([uri]$Path).PathAndQuery
        }

    } while ($Path)
}

function Set-ArmJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Body
    )

    $json = $Body | ConvertTo-Json -Depth 30

    $response = Invoke-AzRestMethod `
        -Path $Path `
        -Method PUT `
        -Payload $json `
        -ErrorAction Stop

    if ([int]$response.StatusCode -lt 200 -or
        [int]$response.StatusCode -ge 300) {

        throw "ARM PUT failed ($($response.StatusCode)): $Path`n$($response.Content)"
    }

    return $response
}

function Get-ResourceGroupFromId {
    param([string]$ResourceId)

    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)') {
        return $Matches[1]
    }

    throw "Unable to determine resource group from: $ResourceId"
}

function Get-SubscriptionFromId {
    param([string]$ResourceId)

    if ($ResourceId -match '(?i)^/subscriptions/([^/]+)') {
        return $Matches[1]
    }

    throw "Unable to determine subscription from: $ResourceId"
}

# ---------------------------------------------------------------------------
# Read Log Analytics workspace
# DCR location follows the destination workspace region.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Reading Log Analytics workspace..."

$workspace = Get-ArmJson `
    -Path "$($lawId)?api-version=2023-09-01"

$workspaceLocation = [string]$workspace.location

if ([string]::IsNullOrWhiteSpace($workspaceLocation)) {
    throw "Unable to determine Log Analytics workspace location."
}

$lawSubscriptionId = Get-SubscriptionFromId -ResourceId $lawId

if ([string]::IsNullOrWhiteSpace($DCRResourceGroupName)) {
    $DCRResourceGroupName = Get-ResourceGroupFromId -ResourceId $lawId
}

$dcrId = @(
    "/subscriptions/$lawSubscriptionId"
    "/resourceGroups/$DCRResourceGroupName"
    "/providers/Microsoft.Insights/dataCollectionRules/$DCRName"
) -join ""

Write-Host "Workspace : $lawId"
Write-Host "Region    : $workspaceLocation"
Write-Host "DCR       : $dcrId"

# ---------------------------------------------------------------------------
# Get AVD registered session hosts
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Discovering AVD session hosts..."

$sessionHosts = @(
    Get-ArmList `
        -Path "$($hpId)/sessionHosts?api-version=2024-04-03"
)

if (-not $sessionHosts.Count) {
    throw "No registered session hosts were found in the host pool."
}

Write-Host "Found $($sessionHosts.Count) registered session host(s)."

# ---------------------------------------------------------------------------
# Cost-optimized performance counters
#
# Deliberately excluded:
#   User Input Delay per Process(*)
#       High cardinality, one series per process.
#
#   RemoteFX Network(*)
#       WVDConnectionNetworkData already provides AVD RTT/bandwidth.
#
#   PhysicalDisk(*)
#       Avoid one series per physical disk.
#
# We retain _Total physical disk latency for infrastructure health.
# ---------------------------------------------------------------------------

$performanceCounters = @(
    # CPU
    '\Processor Information(_Total)\% Processor Time'

    # Memory
    '\Memory\Available MBytes'
    '\Memory\% Committed Bytes In Use'
    '\Memory\Pages/sec'

    # OS disk
    '\LogicalDisk(C:)\% Free Space'
    '\LogicalDisk(C:)\Avg. Disk Queue Length'
    '\LogicalDisk(C:)\Avg. Disk sec/Transfer'
    '\LogicalDisk(C:)\Current Disk Queue Length'

    # Aggregate physical disk latency
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read'
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write'

    # AVD session density
    '\Terminal Services(*)\Active Sessions'
    '\Terminal Services(*)\Inactive Sessions'
    '\Terminal Services(*)\Total Sessions'

    # User experience
    '\User Input Delay per Session(*)\Max Input Delay'
)

# ---------------------------------------------------------------------------
# Cost-optimized Windows Event Logs
#
# Levels:
#   1 = Critical
#   2 = Error
#   3 = Warning
#
# Informational session lifecycle is already available from AVD platform
# diagnostics such as WVDConnections.
# ---------------------------------------------------------------------------

$eventXPath = @(

    # Windows
    'System!*[System[(Level=1 or Level=2 or Level=3)]]'
    'Application!*[System[(Level=1 or Level=2 or Level=3)]]'

    # RDP / AVD session host
    'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(Level=1 or Level=2 or Level=3)]]'
    'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!*[System[(Level=1 or Level=2 or Level=3)]]'

    # FSLogix
    'Microsoft-FSLogix-Apps/Operational!*[System[(Level=1 or Level=2 or Level=3)]]'
    'Microsoft-FSLogix-Apps/Admin!*[System[(Level=1 or Level=2 or Level=3)]]'
)

# ---------------------------------------------------------------------------
# DCR definition
# ---------------------------------------------------------------------------

$dcrBody = @{
    location = $workspaceLocation

    tags = @{
        Workload       = "Azure Virtual Desktop"
        Monitoring     = "CostOptimized"
        ManagedBy      = "PowerShell"
        Sampling       = "60Seconds"
    }

    properties = @{

        dataSources = @{

            performanceCounters = @(
                @{
                    name                       = "AVD-Performance-60sec"
                    streams                    = @("Microsoft-Perf")
                    samplingFrequencyInSeconds = 60
                    counterSpecifiers          = $performanceCounters
                }
            )

            windowsEventLogs = @(
                @{
                    name         = "AVD-WindowsEvents"
                    streams      = @("Microsoft-Event")
                    xPathQueries = $eventXPath
                }
            )
        }

        destinations = @{
            logAnalytics = @(
                @{
                    name                = "LAW-AVD"
                    workspaceResourceId = $lawId
                }
            )
        }

        dataFlows = @(

            @{
                streams      = @("Microsoft-Perf")
                destinations = @("LAW-AVD")
                transformKql = "source"
                outputStream = "Microsoft-Perf"
            },

            @{
                streams      = @("Microsoft-Event")
                destinations = @("LAW-AVD")
                transformKql = "source"
                outputStream = "Microsoft-Event"
            }
        )
    }
}

# ---------------------------------------------------------------------------
# Create/update DCR
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Creating/updating DCR..."

if ($PSCmdlet.ShouldProcess(
    $dcrId,
    "Create or update cost-optimized AVD Data Collection Rule"
)) {

    Set-ArmJson `
        -Path "$($dcrId)?api-version=2023-03-11" `
        -Body $dcrBody | Out-Null

    Write-Host "DCR created/updated successfully."
}

# ---------------------------------------------------------------------------
# Associate DCR with every AVD session host
# ---------------------------------------------------------------------------

$associationName = "AVD-CostOptimized"

$results = @()

foreach ($sessionHost in $sessionHosts) {

    $sessionHostName = [string]$sessionHost.name
    $avdState        = [string]$sessionHost.properties.status
    $vmId            = [string]$sessionHost.properties.resourceId

    if ($vmId -notmatch '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/virtualMachines/[^/]+$') {

        $results += [pscustomobject]@{
            SessionHost = $sessionHostName
            AVDState    = $avdState
            AMA         = "Unknown"
            Identity    = "Unknown"
            Association = "Failed"
            Details     = "Invalid or missing VM resource ID: $vmId"
        }

        continue
    }

    $vmName = ($vmId -split '/')[-1]

    # -----------------------------------------------------------------------
    # Check managed identity
    # -----------------------------------------------------------------------

    $identityStatus = "Missing"

    try {
        $vm = Get-ArmJson `
            -Path "$($vmId)?api-version=2024-03-01"

        if ([string]$vm.identity.type -match 'SystemAssigned') {
            $identityStatus = "SystemAssigned"
        }
        elseif ($vm.identity.type) {
            $identityStatus = [string]$vm.identity.type
        }
    }
    catch {
        $identityStatus = "Unreadable"
    }

    # -----------------------------------------------------------------------
    # Check AMA
    # -----------------------------------------------------------------------

    $amaStatus = "Missing"

    try {
        $extensions = @(
            Get-ArmList `
                -Path "$($vmId)/extensions?api-version=2024-03-01"
        )

        $ama = @(
            $extensions |
            Where-Object {
                $_.properties.publisher -eq 'Microsoft.Azure.Monitor' -and
                $_.properties.type -eq 'AzureMonitorWindowsAgent'
            }
        )

        if (
            @(
                $ama |
                Where-Object {
                    $_.properties.provisioningState -eq 'Succeeded'
                }
            ).Count -gt 0
        ) {
            $amaStatus = "Succeeded"
        }
        elseif ($ama.Count) {
            $amaStatus = [string]$ama[0].properties.provisioningState
        }
    }
    catch {
        $amaStatus = "Unreadable"
    }

    # -----------------------------------------------------------------------
    # Create DCR association
    # -----------------------------------------------------------------------

    $associationPath =
        "$($vmId)/providers/Microsoft.Insights/dataCollectionRuleAssociations/" +
        "$($associationName)?api-version=2023-03-11"

    $associationBody = @{
        properties = @{
            dataCollectionRuleId = $dcrId
        }
    }

    $associationStatus = "WhatIf"
    $details = ""

    if ($PSCmdlet.ShouldProcess(
        $vmId,
        "Associate DCR $DCRName"
    )) {

        try {
            Set-ArmJson `
                -Path $associationPath `
                -Body $associationBody | Out-Null

            $associationStatus = "Succeeded"
        }
        catch {
            $associationStatus = "Failed"
            $details = $_.Exception.Message
        }
    }

    if ($amaStatus -ne "Succeeded") {
        $details += " AMA is not healthy."
    }

    if ($identityStatus -notmatch 'SystemAssigned') {
        $details += " Verify AMA managed identity configuration."
    }

    if ($avdState -eq "Shutdown") {
        $details += " Host is shutdown, ingestion starts when the VM runs."
    }

    $results += [pscustomobject]@{
        SessionHost = $vmName
        AVDState    = $avdState
        AMA         = $amaStatus
        Identity    = $identityStatus
        Association = $associationStatus
        Details     = $details.Trim()
    }
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Deployment summary"
Write-Host "=================="

$results |
    Format-Table `
        SessionHost,
        AVDState,
        AMA,
        Identity,
        Association,
        Details `
        -AutoSize

Write-Host ""
Write-Host "DCR: $dcrId"

Write-Host ""
Write-Host "Performance counters: $($performanceCounters.Count)"
Write-Host "Performance sampling : 60 seconds"
Write-Host "Windows Event XPath  : $($eventXPath.Count)"

Write-Host ""
Write-Host "Run Test-AVDDCRAssociation.ps1 again to validate:"
Write-Host ""
Write-Host "  DCRAssociations                        Pass"
Write-Host "  ExpectedWorkspaceRoute:Microsoft-Perf  Pass"
Write-Host "  ExpectedWorkspaceRoute:Microsoft-Event Pass"