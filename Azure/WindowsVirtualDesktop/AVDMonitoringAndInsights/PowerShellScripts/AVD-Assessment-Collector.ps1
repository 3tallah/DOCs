<#
.SYNOPSIS
    Collects Azure Virtual Desktop inventory, session host health and local host evidence,
    then writes CSV artifacts, a JSON manifest, a text summary and an HTML report.

.DESCRIPTION
    The collector runs two independent scopes:

      Azure  - host pools, session hosts, per-host health checks, application groups,
               workspaces and scaling plans, read through the Az.DesktopVirtualization module.
      Local  - AVD agent and FSLogix registry state, related services, Application/System
               event logs and FSLogix logs from the machine the script runs on.

    Every artifact is recorded in a manifest with an explicit collection status, row count and
    SHA256 hash, so an empty file is never confused with a failed query. Findings such as stale
    session host heartbeats or failed health checks are raised separately from collection errors.

    The script never reports success when a required step failed. It exits non-zero if any
    required artifact could not be collected.

.PARAMETER SubscriptionId
    Subscription to assess. If omitted the current Az context subscription is used.
    The script does not switch context unless this differs from the active context.

.PARAMETER ResourceGroup
    Restricts Azure collection to one resource group. Honored by every Azure query.

.PARAMETER HostPoolName
    Restricts Azure collection to a single host pool. Requires -ResourceGroup.

.PARAMETER WorkspaceName
    Restricts workspace collection to a single AVD workspace.

.PARAMETER OutputPath
    Root directory for output. A timestamped run folder is created beneath it so runs never
    overwrite or mix with each other. Defaults to .\AVD_Assessment_Output.

.PARAMETER Scope
    All (default), Azure or Local. Use Local on a session host with no Azure access, or
    Azure from an admin workstation where local evidence would describe the wrong machine.

.PARAMETER EventLogDays
    Days of Application/System event log history to export. Default 7.

.PARAMETER HeartbeatThresholdHours
    A session host whose LastHeartBeat is older than this raises a finding. Default 24.

.PARAMETER DeviceCode
    Use device code authentication when a sign-in is required. Use this on servers and in
    remote sessions where an interactive browser cannot open.

.PARAMETER IncludeSecurityLog
    Also export the Security event log. Requires elevation.

.PARAMETER NoHtmlReport
    Skip HTML report generation and write only CSV, JSON and text output.

.EXAMPLE
    .\AVD-Assessment-Collector.ps1 -OutputPath 'C:\Temp\AVD' -Scope Azure

    Collects Azure inventory only, using the existing Az context.

.EXAMPLE
    .\AVD-Assessment-Collector.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -ResourceGroup 'WPNS-AVD' -HostPoolName 'WPNS-AVD' -OutputPath 'C:\Temp\AVD'

    Collects a single host pool plus local evidence and writes an HTML report.

.NOTES
    Exit codes: 0 = all required artifacts collected. 1 = one or more required artifacts failed.
    Findings do not change the exit code; review the report.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $SubscriptionId,
    [Parameter(Mandatory = $false)] [string] $ResourceGroup,
    [Parameter(Mandatory = $false)] [string] $HostPoolName,
    [Parameter(Mandatory = $false)] [string] $WorkspaceName,
    [Parameter(Mandatory = $false)] [string] $OutputPath = (Join-Path -Path (Get-Location).Path -ChildPath 'AVD_Assessment_Output'),
    [Parameter(Mandatory = $false)] [ValidateSet('All', 'Azure', 'Local')] [string] $Scope = 'All',
    [Parameter(Mandatory = $false)] [ValidateRange(1, 90)] [int] $EventLogDays = 7,
    [Parameter(Mandatory = $false)] [ValidateRange(1, 8760)] [int] $HeartbeatThresholdHours = 24,
    [Parameter(Mandatory = $false)] [switch] $DeviceCode,
    [Parameter(Mandatory = $false)] [switch] $IncludeSecurityLog,
    [Parameter(Mandatory = $false)] [switch] $NoHtmlReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($HostPoolName -and -not $ResourceGroup) {
    throw "-HostPoolName requires -ResourceGroup. A host pool name is not unique across resource groups."
}

#region Run context -----------------------------------------------------------

$StartedUtc = (Get-Date).ToUniversalTime()
$RunId      = [guid]::NewGuid()
$RunRoot    = Join-Path $OutputPath ('AVD-Assessment-{0}-{1}' -f $env:COMPUTERNAME, $StartedUtc.ToString('yyyyMMdd-HHmmss'))
New-Item -Path $RunRoot -ItemType Directory -Force | Out-Null

$Artifacts = New-Object System.Collections.Generic.List[object]
$Findings  = New-Object System.Collections.Generic.List[object]
$Errors    = New-Object System.Collections.Generic.List[object]

$IsElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Info  { param([string] $Message) Write-Host "[INFO ] $Message" -ForegroundColor Cyan }
function Write-Ok    { param([string] $Message) Write-Host "[ OK  ] $Message" -ForegroundColor Green }
function Write-Warn  { param([string] $Message) Write-Host "[WARN ] $Message" -ForegroundColor Yellow }
function Write-Fail  { param([string] $Message) Write-Host "[FAIL ] $Message" -ForegroundColor Red }

function Add-Finding {
    param(
        [ValidateSet('Critical', 'Warning', 'Info')] [string] $Severity,
        [string] $Area,
        [string] $Title,
        [string] $Detail,
        [string] $Recommendation = ''
    )
    $Findings.Add([pscustomobject]@{
        Severity       = $Severity
        Area           = $Area
        Title          = $Title
        Detail         = $Detail
        Recommendation = $Recommendation
    })
}

function Add-CollectionError {
    param([string] $Step, [System.Management.Automation.ErrorRecord] $ErrorRecord)
    $Errors.Add([pscustomobject]@{
        TimeUtc   = (Get-Date).ToUniversalTime().ToString('o')
        Step      = $Step
        Message   = $ErrorRecord.Exception.Message
        Category  = $ErrorRecord.CategoryInfo.Category
        Position  = $ErrorRecord.InvocationInfo.PositionMessage
        StackTrace= $ErrorRecord.ScriptStackTrace
    })
}

# Records one output file with an explicit status so an empty file is never mistaken for a
# failed query. Header-only files are written for genuinely empty result sets.
function Register-Artifact {
    param(
        [string] $Name,
        [string] $Path,
        [ValidateSet('Collected', 'NoData', 'Skipped', 'Error', 'NotRun')] [string] $Status,
        [int] $Rows = 0,
        [string] $Message = ''
    )
    $length = $null
    $hash   = $null
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $item = Get-Item -LiteralPath $Path
        if (-not $item.PSIsContainer) {
            $length = $item.Length
            $hash   = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
    }
    $Artifacts.Add([pscustomobject]@{
        Artifact = $Name
        Status   = $Status
        Rows     = $Rows
        Bytes    = $length
        Sha256   = $hash
        File     = if ($Path) { Split-Path -Leaf $Path } else { '' }
        Message  = $Message
    })
}

# Always writes a CSV with the given header, even when there are no rows, so that
# "no scaling plans exist" is visibly different from "the query failed".
function Export-Artifact {
    param(
        [string] $Name,
        [string] $FileName,
        # Typed as [object] rather than [object[]]: in Windows PowerShell 5.1, wrapping a
        # generic List in @() fails to bind to an [object[]] parameter. Normalized below.
        [AllowNull()] [object] $Rows,
        [string[]] $Header,
        [string] $Message = ''
    )
    $path = Join-Path $RunRoot $FileName

    # Normalized with an explicit loop rather than @($Rows): in this Windows PowerShell 5.1
    # build, wrapping a System.Collections.Generic.List[object] in @() throws
    # "Argument types do not match". A foreach enumerates arrays, lists and scalars safely.
    $items = New-Object System.Collections.ArrayList
    if ($null -ne $Rows) {
        foreach ($row in $Rows) { [void]$items.Add($row) }
    }

    if ($items.Count -gt 0) {
        $items | Select-Object -Property $Header | Export-Csv -NoTypeInformation -Path $path -Encoding UTF8
        Register-Artifact -Name $Name -Path $path -Status 'Collected' -Rows $items.Count -Message $Message
        Write-Ok ("{0}: {1} row(s)" -f $Name, $items.Count)
    }
    else {
        (($Header | ForEach-Object { '"' + $_ + '"' }) -join ',') | Set-Content -LiteralPath $path -Encoding UTF8
        Register-Artifact -Name $Name -Path $path -Status 'NoData' -Rows 0 -Message $Message
        Write-Warn ("{0}: no records returned (header-only file written)" -f $Name)
    }
}

function Get-SafeValue {
    param([object] $InputObject, [string] $Property)
    if ($null -eq $InputObject) { return $null }
    if (-not $InputObject.PSObject.Properties.Match($Property).Count) { return $null }
    return $InputObject.$Property
}

#endregion

#region Azure collection ------------------------------------------------------

$azureAttempted = $false
$azureContext   = $null

if ($Scope -in @('All', 'Azure')) {
    $azureAttempted = $true
    Write-Info 'Starting Azure collection.'

    try {
        Import-Module Az.Accounts -ErrorAction Stop
        Import-Module Az.DesktopVirtualization -ErrorAction Stop
    }
    catch {
        Add-CollectionError -Step 'Import Az modules' -ErrorRecord $_
        Add-Finding -Severity 'Critical' -Area 'Azure' -Title 'Az modules unavailable' `
            -Detail $_.Exception.Message `
            -Recommendation 'Install Az.Accounts and Az.DesktopVirtualization, then re-run.'
        Write-Fail "Az modules could not be loaded: $($_.Exception.Message)"
    }

    if ($Errors.Count -eq 0) {
        try {
            $azureContext = Get-AzContext -ErrorAction SilentlyContinue

            if (-not $azureContext) {
                Write-Info 'No Azure context found. Signing in.'
                $connectArgs = @{ ErrorAction = 'Stop' }
                if ($SubscriptionId) { $connectArgs['Subscription'] = $SubscriptionId }
                if ($DeviceCode)     { $connectArgs['UseDeviceAuthentication'] = $true }
                Connect-AzAccount @connectArgs | Out-Null
                $azureContext = Get-AzContext -ErrorAction Stop
            }
            elseif ($SubscriptionId -and $azureContext.Subscription.Id -ne $SubscriptionId) {
                Write-Info "Switching context to subscription $SubscriptionId."
                Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
                $azureContext = Get-AzContext -ErrorAction Stop
            }

            if (-not $azureContext) { throw 'No Azure context is available after authentication.' }
            Write-Ok ("Azure context: {0} / {1}" -f $azureContext.Account.Id, $azureContext.Subscription.Id)
        }
        catch {
            Add-CollectionError -Step 'Azure authentication' -ErrorRecord $_
            Add-Finding -Severity 'Critical' -Area 'Azure' -Title 'Azure authentication failed' `
                -Detail $_.Exception.Message `
                -Recommendation 'Run Connect-AzAccount (add -DeviceCode in a remote session), then re-run the collector.'
            Write-Fail "Azure authentication failed: $($_.Exception.Message)"
            $azureContext = $null
        }
    }
}

if ($azureContext) {

    $hostPools = @()
    try {
        if ($HostPoolName)      { $hostPools = @(Get-AzWvdHostPool -ResourceGroupName $ResourceGroup -Name $HostPoolName -ErrorAction Stop) }
        elseif ($ResourceGroup) { $hostPools = @(Get-AzWvdHostPool -ResourceGroupName $ResourceGroup -ErrorAction Stop) }
        else                    { $hostPools = @(Get-AzWvdHostPool -ErrorAction Stop) }

        $poolRows = foreach ($pool in $hostPools) {
            [pscustomobject]@{
                Name                  = $pool.Name
                ResourceGroup         = ($pool.Id -split '/')[4]
                Location              = $pool.Location
                HostPoolType          = $pool.HostPoolType
                LoadBalancerType      = $pool.LoadBalancerType
                PreferredAppGroupType = $pool.PreferredAppGroupType
                MaxSessionLimit       = $pool.MaxSessionLimit
                StartVMOnConnect      = Get-SafeValue $pool 'StartVMOnConnect'
                ValidationEnvironment = Get-SafeValue $pool 'ValidationEnvironment'
                CustomRdpProperty     = Get-SafeValue $pool 'CustomRdpProperty'
                ResourceId            = $pool.Id
            }
        }
        Export-Artifact -Name 'Host pools' -FileName 'HostPools.csv' -Rows $poolRows -Header @(
            'Name','ResourceGroup','Location','HostPoolType','LoadBalancerType','PreferredAppGroupType',
            'MaxSessionLimit','StartVMOnConnect','ValidationEnvironment','CustomRdpProperty','ResourceId')
    }
    catch {
        Add-CollectionError -Step 'Get-AzWvdHostPool' -ErrorRecord $_
        Register-Artifact -Name 'Host pools' -Path $null -Status 'Error' -Message $_.Exception.Message
        Add-Finding -Severity 'Critical' -Area 'Azure' -Title 'Host pool enumeration failed' `
            -Detail $_.Exception.Message -Recommendation 'Verify RBAC and the resource group name, then re-run.'
        Write-Fail "Host pool enumeration failed: $($_.Exception.Message)"
    }

    # Session hosts and health checks, per pool.
    $allSessionHostRows = New-Object System.Collections.Generic.List[object]
    $allHealthCheckRows = New-Object System.Collections.Generic.List[object]
    $nowUtc = (Get-Date).ToUniversalTime()

    foreach ($pool in $hostPools) {
        $poolRg = ($pool.Id -split '/')[4]
        try {
            $sessionHosts = @(Get-AzWvdSessionHost -ResourceGroupName $poolRg -HostPoolName $pool.Name -ErrorAction Stop)
        }
        catch {
            Add-CollectionError -Step ("Get-AzWvdSessionHost [{0}]" -f $pool.Name) -ErrorRecord $_
            Add-Finding -Severity 'Critical' -Area 'Session hosts' -Title ("Session host enumeration failed for {0}" -f $pool.Name) `
                -Detail $_.Exception.Message -Recommendation 'Verify RBAC on the host pool, then re-run.'
            Write-Fail ("Session hosts for {0}: {1}" -f $pool.Name, $_.Exception.Message)
            continue
        }

        foreach ($sessionHost in $sessionHosts) {
            # Name arrives as "<pool>/<host>"; split so the host name is usable on its own.
            $shortName = ($sessionHost.Name -split '/')[-1]
            $heartbeat = Get-SafeValue $sessionHost 'LastHeartBeat'
            $ageHours  = $null
            if ($heartbeat) {
                $ageHours = [math]::Round(($nowUtc - ([datetime]$heartbeat).ToUniversalTime()).TotalHours, 1)
            }

            $healthResults = @(Get-SafeValue $sessionHost 'HealthCheckResult')
            $failedChecks  = @($healthResults | Where-Object { $_ -and $_.HealthCheckResult -ne 'HealthCheckSucceeded' })

            $allSessionHostRows.Add([pscustomobject]@{
                HostPool            = $pool.Name
                ResourceGroup       = $poolRg
                SessionHost         = $shortName
                Status              = $sessionHost.Status
                AllowNewSession     = $sessionHost.AllowNewSession
                Sessions            = Get-SafeValue $sessionHost 'Session'
                AssignedUser        = Get-SafeValue $sessionHost 'AssignedUser'
                AgentVersion        = Get-SafeValue $sessionHost 'AgentVersion'
                SxSStackVersion     = Get-SafeValue $sessionHost 'SxSStackVersion'
                OSVersion           = Get-SafeValue $sessionHost 'OSVersion'
                UpdateState         = Get-SafeValue $sessionHost 'UpdateState'
                UpdateErrorMessage  = Get-SafeValue $sessionHost 'UpdateErrorMessage'
                LastHeartBeatUtc    = if ($heartbeat) { ([datetime]$heartbeat).ToUniversalTime().ToString('o') } else { $null }
                HeartbeatAgeHours   = $ageHours
                HeartbeatStale      = if ($null -ne $ageHours) { $ageHours -gt $HeartbeatThresholdHours } else { $true }
                HealthChecksTotal   = $healthResults.Count
                HealthChecksFailed  = $failedChecks.Count
                VirtualMachineId    = Get-SafeValue $sessionHost 'VirtualMachineId'
                ResourceId          = $sessionHost.Id
            })

            foreach ($check in $healthResults) {
                if (-not $check) { continue }
                $allHealthCheckRows.Add([pscustomobject]@{
                    HostPool        = $pool.Name
                    SessionHost     = $shortName
                    HealthCheckName = $check.HealthCheckName
                    Result          = $check.HealthCheckResult
                    ErrorCode       = $check.AdditionalFailureDetailErrorCode
                    LastCheckedUtc  = $check.AdditionalFailureDetailLastHealthCheckDateTime
                    Message         = $check.AdditionalFailureDetailMessage
                })
            }

            # Findings raised from the collected data.
            if ($null -ne $ageHours -and $ageHours -gt $HeartbeatThresholdHours) {
                $severity = 'Warning'
                $advice   = 'Confirm whether the host is intentionally deallocated.'
                if ($sessionHost.Status -eq 'Available' -and $sessionHost.AllowNewSession) {
                    # Accepting brokered connections while the agent is silent is user-impacting.
                    $severity = 'Critical'
                    $advice   = 'The host is accepting new sessions but its agent is not reporting. Restart RDAgentBootLoader or drain the host.'
                }
                Add-Finding -Severity $severity -Area 'Session hosts' `
                    -Title ("Stale agent heartbeat: {0}" -f $shortName) `
                    -Detail ("Status '{0}', AllowNewSession '{1}', last heartbeat {2} h ago (threshold {3} h)." -f `
                             $sessionHost.Status, $sessionHost.AllowNewSession, $ageHours, $HeartbeatThresholdHours) `
                    -Recommendation $advice
            }

            foreach ($failed in $failedChecks) {
                Add-Finding -Severity 'Critical' -Area 'Session hosts' `
                    -Title ("Health check failed: {0} on {1}" -f $failed.HealthCheckName, $shortName) `
                    -Detail ("Result '{0}', error code {1}. {2}" -f $failed.HealthCheckResult, $failed.AdditionalFailureDetailErrorCode, $failed.AdditionalFailureDetailMessage) `
                    -Recommendation 'Resolve the failing check before assigning users to this host.'
            }

            if ((Get-SafeValue $sessionHost 'UpdateState') -eq 'Failed') {
                Add-Finding -Severity 'Warning' -Area 'Session hosts' `
                    -Title ("Agent update failed: {0}" -f $shortName) `
                    -Detail (Get-SafeValue $sessionHost 'UpdateErrorMessage') `
                    -Recommendation 'Review the AVD agent update state on the host.'
            }
        }
    }

    Export-Artifact -Name 'Session hosts' -FileName 'SessionHosts.csv' -Rows $allSessionHostRows -Header @(
        'HostPool','ResourceGroup','SessionHost','Status','AllowNewSession','Sessions','AssignedUser',
        'AgentVersion','SxSStackVersion','OSVersion','UpdateState','UpdateErrorMessage',
        'LastHeartBeatUtc','HeartbeatAgeHours','HeartbeatStale','HealthChecksTotal','HealthChecksFailed',
        'VirtualMachineId','ResourceId')

    Export-Artifact -Name 'Session host health checks' -FileName 'SessionHostHealthChecks.csv' -Rows $allHealthCheckRows -Header @(
        'HostPool','SessionHost','HealthCheckName','Result','ErrorCode','LastCheckedUtc','Message')

    # Agent version drift is a common cause of inconsistent behaviour across a pool.
    $agentVersions = @($allSessionHostRows | Where-Object { $_.AgentVersion } | Select-Object -ExpandProperty AgentVersion -Unique)
    if ($agentVersions.Count -gt 1) {
        Add-Finding -Severity 'Warning' -Area 'Session hosts' -Title 'AVD agent version drift' `
            -Detail ("Multiple agent versions in scope: {0}." -f ($agentVersions -join ', ')) `
            -Recommendation 'Align agent versions so all hosts behave consistently.'
    }

    # Application groups.
    try {
        if ($ResourceGroup) { $appGroups = @(Get-AzWvdApplicationGroup -ResourceGroupName $ResourceGroup -ErrorAction Stop) }
        else                { $appGroups = @(Get-AzWvdApplicationGroup -ErrorAction Stop) }

        $appGroupRows = foreach ($ag in $appGroups) {
            [pscustomobject]@{
                Name                 = $ag.Name
                ResourceGroup        = ($ag.Id -split '/')[4]
                Location             = $ag.Location
                ApplicationGroupType = $ag.ApplicationGroupType
                HostPoolArmPath      = Get-SafeValue $ag 'HostPoolArmPath'
                FriendlyName         = Get-SafeValue $ag 'FriendlyName'
                Description          = Get-SafeValue $ag 'Description'
                ResourceId           = $ag.Id
            }
        }
        Export-Artifact -Name 'Application groups' -FileName 'ApplicationGroups.csv' -Rows $appGroupRows -Header @(
            'Name','ResourceGroup','Location','ApplicationGroupType','HostPoolArmPath','FriendlyName','Description','ResourceId')
    }
    catch {
        Add-CollectionError -Step 'Get-AzWvdApplicationGroup' -ErrorRecord $_
        Register-Artifact -Name 'Application groups' -Path $null -Status 'Error' -Message $_.Exception.Message
        Write-Fail "Application groups: $($_.Exception.Message)"
    }

    # Workspaces. List-valued properties are flattened so the CSV holds data, not type names.
    try {
        if ($WorkspaceName -and $ResourceGroup) { $workspaces = @(Get-AzWvdWorkspace -ResourceGroupName $ResourceGroup -Name $WorkspaceName -ErrorAction Stop) }
        elseif ($ResourceGroup)                 { $workspaces = @(Get-AzWvdWorkspace -ResourceGroupName $ResourceGroup -ErrorAction Stop) }
        else                                    { $workspaces = @(Get-AzWvdWorkspace -ErrorAction Stop) }

        $workspaceRows = foreach ($ws in $workspaces) {
            $appRefs = @(Get-SafeValue $ws 'ApplicationGroupReference')
            [pscustomobject]@{
                Name                      = $ws.Name
                ResourceGroup             = ($ws.Id -split '/')[4]
                Location                  = $ws.Location
                FriendlyName              = Get-SafeValue $ws 'FriendlyName'
                Description               = Get-SafeValue $ws 'Description'
                PublicNetworkAccess       = Get-SafeValue $ws 'PublicNetworkAccess'
                ApplicationGroupCount     = $appRefs.Count
                ApplicationGroupReference = ($appRefs -join ';')
                ResourceId                = $ws.Id
            }
        }
        Export-Artifact -Name 'Workspaces' -FileName 'Workspaces.csv' -Rows $workspaceRows -Header @(
            'Name','ResourceGroup','Location','FriendlyName','Description','PublicNetworkAccess',
            'ApplicationGroupCount','ApplicationGroupReference','ResourceId')
    }
    catch {
        Add-CollectionError -Step 'Get-AzWvdWorkspace' -ErrorRecord $_
        Register-Artifact -Name 'Workspaces' -Path $null -Status 'Error' -Message $_.Exception.Message
        Write-Fail "Workspaces: $($_.Exception.Message)"
    }

    # Scaling plans.
    try {
        if ($ResourceGroup) { $scalingPlans = @(Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroup -ErrorAction Stop) }
        else                { $scalingPlans = @(Get-AzWvdScalingPlan -ErrorAction Stop) }

        $scalingRows = foreach ($sp in $scalingPlans) {
            $refs = @(Get-SafeValue $sp 'HostPoolReference')
            [pscustomobject]@{
                Name              = $sp.Name
                ResourceGroup     = ($sp.Id -split '/')[4]
                Location          = $sp.Location
                HostPoolType      = Get-SafeValue $sp 'HostPoolType'
                TimeZone          = Get-SafeValue $sp 'TimeZone'
                ScheduleCount     = @(Get-SafeValue $sp 'Schedule').Count
                HostPoolCount     = $refs.Count
                HostPoolReference = (($refs | ForEach-Object { Get-SafeValue $_ 'HostPoolArmPath' }) -join ';')
                ResourceId        = $sp.Id
            }
        }
        Export-Artifact -Name 'Scaling plans' -FileName 'ScalingPlans.csv' -Rows $scalingRows -Header @(
            'Name','ResourceGroup','Location','HostPoolType','TimeZone','ScheduleCount','HostPoolCount','HostPoolReference','ResourceId') `
            -Message 'No scaling plan in scope. Confirm whether this is expected.'

        if ($null -eq $scalingRows -or @($scalingRows).Count -eq 0) {
            Add-Finding -Severity 'Info' -Area 'Cost' -Title 'No scaling plan found' `
                -Detail 'No AVD scaling plan exists in the collected scope.' `
                -Recommendation 'Consider a scaling plan to deallocate idle session hosts outside business hours.'
        }
    }
    catch {
        Add-CollectionError -Step 'Get-AzWvdScalingPlan' -ErrorRecord $_
        Register-Artifact -Name 'Scaling plans' -Path $null -Status 'Error' -Message $_.Exception.Message
        Write-Fail "Scaling plans: $($_.Exception.Message)"
    }
}
elseif ($azureAttempted) {
    foreach ($name in 'Host pools', 'Session hosts', 'Session host health checks', 'Application groups', 'Workspaces', 'Scaling plans') {
        Register-Artifact -Name $name -Path $null -Status 'NotRun' -Message 'Azure collection did not run because authentication failed.'
    }
}
else {
    foreach ($name in 'Host pools', 'Session hosts', 'Session host health checks', 'Application groups', 'Workspaces', 'Scaling plans') {
        Register-Artifact -Name $name -Path $null -Status 'Skipped' -Message "Scope is '$Scope'."
    }
}

#endregion

#region Local collection ------------------------------------------------------

if ($Scope -in @('All', 'Local')) {
    Write-Info "Starting local collection on $env:COMPUTERNAME."

    if (-not $IsElevated) {
        Add-Finding -Severity 'Info' -Area 'Local' -Title 'Collector is not elevated' `
            -Detail 'Some registry paths, event log channels and FSLogix logs may be unreadable without elevation.' `
            -Recommendation 'Re-run from an elevated session for complete local evidence.'
    }

    # Services.
    try {
        $wanted = 'RDAgent', 'RDAgentBootLoader', 'RdInfraAgent', 'WVDAgent', 'frxsvc', 'frxccds', 'frxdrv'
        $svc = @(Get-Service -ErrorAction SilentlyContinue |
                 Where-Object { $wanted -contains $_.Name -or $_.DisplayName -like '*WebRTC*' -or $_.DisplayName -like '*FSLogix*' })
        $svcRows = foreach ($s in $svc) {
            [pscustomobject]@{
                Name        = $s.Name
                DisplayName = $s.DisplayName
                Status      = $s.Status
                StartType   = $s.StartType
            }
        }
        Export-Artifact -Name 'Local services' -FileName 'Services.csv' -Rows $svcRows -Header @('Name','DisplayName','Status','StartType') `
            -Message 'No AVD agent or FSLogix service found. Expected when not running on a session host.'

        foreach ($s in $svc) {
            if ($s.Name -in @('RDAgentBootLoader', 'frxsvc') -and $s.Status -ne 'Running') {
                Add-Finding -Severity 'Critical' -Area 'Local' -Title ("Service not running: {0}" -f $s.Name) `
                    -Detail ("Status '{0}', start type '{1}'." -f $s.Status, $s.StartType) `
                    -Recommendation 'Start the service and investigate why it stopped.'
            }
        }
    }
    catch {
        Add-CollectionError -Step 'Get-Service' -ErrorRecord $_
        Register-Artifact -Name 'Local services' -Path $null -Status 'Error' -Message $_.Exception.Message
    }

    # Registry evidence.
    $registryTargets = @(
        @{ Name = 'RDInfraAgent registry'; Key = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent';  File = 'RDInfraAgent_Reg.txt' }
        @{ Name = 'FSLogix Profiles registry'; Key = 'HKLM:\SOFTWARE\FSLogix\Profiles';    File = 'FSLogix_Profiles_Reg.txt' }
        @{ Name = 'FSLogix Profiles policy';   Key = 'HKLM:\SOFTWARE\Policies\FSLogix\Profiles'; File = 'FSLogix_Profiles_Policy.txt' }
        @{ Name = 'FSLogix ODFC policy';       Key = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC';     File = 'FSLogix_ODFC_Reg.txt' }
    )
    foreach ($target in $registryTargets) {
        $path = Join-Path $RunRoot $target.File
        try {
            if (Test-Path -LiteralPath $target.Key) {
                Get-ItemProperty -LiteralPath $target.Key -ErrorAction Stop |
                    Format-List * | Out-String -Width 400 | Set-Content -LiteralPath $path -Encoding UTF8
                Register-Artifact -Name $target.Name -Path $path -Status 'Collected' -Rows 1
                Write-Ok $target.Name
            }
            else {
                Register-Artifact -Name $target.Name -Path $null -Status 'NoData' -Message "Registry key not present: $($target.Key)"
                Write-Warn ("{0}: key not present" -f $target.Name)
            }
        }
        catch {
            Add-CollectionError -Step $target.Name -ErrorRecord $_
            Register-Artifact -Name $target.Name -Path $null -Status 'Error' -Message $_.Exception.Message
        }
    }

    # Event logs. Native exit codes are checked so a missing EVTX cannot pass silently.
    $milliseconds = $EventLogDays * 86400000
    $logs = @('Application', 'System')
    if ($IncludeSecurityLog) {
        if ($IsElevated) { $logs += 'Security' }
        else {
            Register-Artifact -Name 'Security event log' -Path $null -Status 'Skipped' -Message 'Security log export requires elevation.'
            Add-Finding -Severity 'Warning' -Area 'Local' -Title 'Security log not exported' `
                -Detail '-IncludeSecurityLog was specified but the session is not elevated.' `
                -Recommendation 'Re-run elevated to export the Security log.'
        }
    }

    foreach ($log in $logs) {
        $evtxPath = Join-Path $RunRoot ("{0}.evtx" -f $log)
        $query    = "*[System[TimeCreated[timediff(@SystemTime) <= $milliseconds]]]"
        try {
            $stderr = & wevtutil.exe epl $log $evtxPath "/q:$query" /ow:true 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("wevtutil exited with code {0}: {1}" -f $LASTEXITCODE, ($stderr | Out-String).Trim())
            }
            Register-Artifact -Name ("{0} event log" -f $log) -Path $evtxPath -Status 'Collected' `
                -Message ("Last {0} day(s)." -f $EventLogDays)
            Write-Ok ("{0} event log exported" -f $log)
        }
        catch {
            Add-CollectionError -Step ("wevtutil epl {0}" -f $log) -ErrorRecord $_
            Register-Artifact -Name ("{0} event log" -f $log) -Path $null -Status 'Error' -Message $_.Exception.Message
            Add-Finding -Severity 'Warning' -Area 'Local' -Title ("{0} event log export failed" -f $log) `
                -Detail $_.Exception.Message -Recommendation 'Re-run elevated, or verify the log channel exists.'
            Write-Fail ("{0} event log: {1}" -f $log, $_.Exception.Message)
        }
    }

    # FSLogix logs.
    $frxLogRoot = Join-Path $env:ProgramData 'FSLogix\Logs'
    try {
        if (Test-Path -LiteralPath $frxLogRoot) {
            $dest = Join-Path $RunRoot 'FSLogix_Logs'
            New-Item -Path $dest -ItemType Directory -Force | Out-Null
            Copy-Item -Path (Join-Path $frxLogRoot '*') -Destination $dest -Recurse -Force -ErrorAction Stop
            $count = @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count
            Register-Artifact -Name 'FSLogix logs' -Path $dest -Status 'Collected' -Rows $count -Message "$count file(s) copied."
            Write-Ok "FSLogix logs: $count file(s)"
        }
        else {
            Register-Artifact -Name 'FSLogix logs' -Path $null -Status 'NoData' -Message "Path not present: $frxLogRoot"
            Write-Warn 'FSLogix logs: path not present'
        }
    }
    catch {
        Add-CollectionError -Step 'Copy FSLogix logs' -ErrorRecord $_
        Register-Artifact -Name 'FSLogix logs' -Path $null -Status 'Error' -Message $_.Exception.Message
    }
}
else {
    foreach ($name in 'Local services', 'RDInfraAgent registry', 'Application event log', 'System event log', 'FSLogix logs') {
        Register-Artifact -Name $name -Path $null -Status 'Skipped' -Message "Scope is '$Scope'."
    }
}

#endregion

#region Reporting -------------------------------------------------------------

$CompletedUtc = (Get-Date).ToUniversalTime()

$errorArtifacts = @($Artifacts | Where-Object { $_.Status -eq 'Error' })
$notRun         = @($Artifacts | Where-Object { $_.Status -eq 'NotRun' })
$criticalCount  = @($Findings | Where-Object { $_.Severity -eq 'Critical' }).Count
$warningCount   = @($Findings | Where-Object { $_.Severity -eq 'Warning' }).Count
$infoCount      = @($Findings | Where-Object { $_.Severity -eq 'Info' }).Count

$collectionSucceeded = ($errorArtifacts.Count -eq 0 -and $notRun.Count -eq 0)

# Errors file is always written when there is anything to report.
if ($Errors.Count -gt 0) {
    $errPath = Join-Path $RunRoot 'Errors.txt'
    $Errors | Format-List * | Out-String -Width 400 | Set-Content -LiteralPath $errPath -Encoding UTF8
    Register-Artifact -Name 'Collection errors' -Path $errPath -Status 'Collected' -Rows $Errors.Count
}

$findingsPath = Join-Path $RunRoot 'Findings.csv'
if ($Findings.Count -gt 0) {
    $Findings | Select-Object Severity, Area, Title, Detail, Recommendation |
        Export-Csv -NoTypeInformation -Path $findingsPath -Encoding UTF8
}
else {
    '"Severity","Area","Title","Detail","Recommendation"' | Set-Content -LiteralPath $findingsPath -Encoding UTF8
}

$manifest = [ordered]@{
    RunId                   = $RunId.ToString()
    SchemaVersion           = '2.0'
    StartedUtc              = $StartedUtc.ToString('o')
    CompletedUtc            = $CompletedUtc.ToString('o')
    DurationSeconds         = [math]::Round(($CompletedUtc - $StartedUtc).TotalSeconds, 1)
    CollectorComputer       = $env:COMPUTERNAME
    CollectorUser           = "$env:USERDOMAIN\$env:USERNAME"
    Elevated                = $IsElevated
    PowerShellVersion       = $PSVersionTable.PSVersion.ToString()
    Scope                   = $Scope
    Parameters              = [ordered]@{
        SubscriptionId          = $SubscriptionId
        ResourceGroup           = $ResourceGroup
        HostPoolName            = $HostPoolName
        WorkspaceName           = $WorkspaceName
        EventLogDays            = $EventLogDays
        HeartbeatThresholdHours = $HeartbeatThresholdHours
    }
    AzureContext            = if ($azureContext) {
        [ordered]@{
            Account        = $azureContext.Account.Id
            SubscriptionId = $azureContext.Subscription.Id
            TenantId       = $azureContext.Tenant.Id
            Environment    = $azureContext.Environment.Name
        }
    } else { $null }
    CollectionSucceeded     = $collectionSucceeded
    ArtifactsWithErrors     = $errorArtifacts.Count
    ArtifactsNotRun         = $notRun.Count
    FindingsCritical        = $criticalCount
    FindingsWarning         = $warningCount
    FindingsInfo            = $infoCount
    Artifacts               = $Artifacts.ToArray()
    Findings                = $Findings.ToArray()
}
$manifestPath = Join-Path $RunRoot 'manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

# Text summary.
$summary = New-Object System.Text.StringBuilder
[void]$summary.AppendLine('AVD Assessment Collector - Summary')
[void]$summary.AppendLine('==================================')
[void]$summary.AppendLine(("Run ID          : {0}" -f $RunId))
[void]$summary.AppendLine(("Started (UTC)   : {0}" -f $StartedUtc.ToString('u')))
[void]$summary.AppendLine(("Completed (UTC) : {0}" -f $CompletedUtc.ToString('u')))
[void]$summary.AppendLine(("Collector       : {0}\{1} on {2} (elevated: {3})" -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $IsElevated))
[void]$summary.AppendLine(("Scope           : {0}" -f $Scope))
if ($azureContext) {
    [void]$summary.AppendLine(("Subscription    : {0}" -f $azureContext.Subscription.Id))
    [void]$summary.AppendLine(("Account         : {0}" -f $azureContext.Account.Id))
}
[void]$summary.AppendLine('')
[void]$summary.AppendLine(("Collection succeeded : {0}" -f $collectionSucceeded))
[void]$summary.AppendLine(("Artifacts in error   : {0}" -f $errorArtifacts.Count))
[void]$summary.AppendLine(("Artifacts not run    : {0}" -f $notRun.Count))
[void]$summary.AppendLine(("Findings             : {0} critical, {1} warning, {2} info" -f $criticalCount, $warningCount, $infoCount))
[void]$summary.AppendLine('')
[void]$summary.AppendLine('Artifacts')
[void]$summary.AppendLine('---------')
[void]$summary.AppendLine(($Artifacts | Format-Table Artifact, Status, Rows, Bytes, File -AutoSize | Out-String -Width 200).TrimEnd())
if ($Findings.Count -gt 0) {
    [void]$summary.AppendLine('')
    [void]$summary.AppendLine('Findings')
    [void]$summary.AppendLine('--------')
    foreach ($f in ($Findings | Sort-Object @{ E = { switch ($_.Severity) { 'Critical' { 0 } 'Warning' { 1 } default { 2 } } } })) {
        [void]$summary.AppendLine(("[{0}] {1} - {2}" -f $f.Severity.ToUpper(), $f.Area, $f.Title))
        [void]$summary.AppendLine(("    {0}" -f $f.Detail))
        if ($f.Recommendation) { [void]$summary.AppendLine(("    -> {0}" -f $f.Recommendation)) }
    }
}
$summaryPath = Join-Path $RunRoot 'Summary.txt'
$summary.ToString() | Set-Content -LiteralPath $summaryPath -Encoding UTF8

#endregion

#region HTML report -----------------------------------------------------------

function ConvertTo-HtmlText {
    param([object] $Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string] $Value)
}

if (-not $NoHtmlReport) {
    $statusClassMap = @{
        'Collected' = 'ok'; 'NoData' = 'warn'; 'Skipped' = 'muted'; 'Error' = 'bad'; 'NotRun' = 'bad'
    }
    $sevClassMap = @{ 'Critical' = 'bad'; 'Warning' = 'warn'; 'Info' = 'info' }

    $overallClass = 'ok'
    $overallText  = 'Collection complete'
    if (-not $collectionSucceeded) { $overallClass = 'bad'; $overallText = 'Collection incomplete' }
    elseif ($criticalCount -gt 0)  { $overallClass = 'bad'; $overallText = 'Collected with critical findings' }
    elseif ($warningCount -gt 0)   { $overallClass = 'warn'; $overallText = 'Collected with warnings' }

    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine(@'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>AVD Assessment Report</title>
<style>
  :root {
    --ink: #10151c; --muted: #5b6775; --line: #dfe4ea; --bg: #f4f6f8; --panel: #ffffff;
    --ok: #0f7b3f; --ok2: #0f7b3f; --warn: #a86400; --bad: #b3261e; --info: #1f5fa8;
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 32px; background: var(--bg); color: var(--ink);
         font-family: "Segoe UI", -apple-system, Roboto, Helvetica, Arial, sans-serif; line-height: 1.5; }
  .wrap { max-width: 1180px; margin: 0 auto; }
  header { border-bottom: 3px solid var(--ink); padding-bottom: 16px; margin-bottom: 24px; }
  h1 { margin: 0 0 4px; font-size: 26px; letter-spacing: -0.01em; }
  h2 { margin: 32px 0 12px; font-size: 18px; border-left: 4px solid var(--ink); padding-left: 10px; }
  .sub { color: var(--muted); font-size: 13px; }
  .banner { padding: 14px 18px; border-radius: 6px; font-weight: 600; margin-bottom: 24px; border-left: 6px solid; }
  .banner.ok   { background: #e8f5ec; border-color: var(--ok2); color: var(--ok2); }
  .banner.warn { background: #fdf3e2; border-color: var(--warn); color: var(--warn); }
  .banner.bad  { background: #fdeceb; border-color: var(--bad);  color: var(--bad); }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-bottom: 8px; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 14px 16px; }
  .card .n { font-size: 28px; font-weight: 700; line-height: 1.1; }
  .card .l { font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin-top: 4px; }
  table { width: 100%; border-collapse: collapse; background: var(--panel);
          border: 1px solid var(--line); border-radius: 6px; overflow: hidden; font-size: 13px; }
  th { background: #eef1f4; text-align: left; padding: 9px 12px; font-size: 11px;
       text-transform: uppercase; letter-spacing: .06em; color: var(--muted); border-bottom: 1px solid var(--line); }
  td { padding: 9px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  .tag { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 700; }
  .tag.ok { background: #e8f5ec; color: var(--ok2); }
  .tag.warn { background: #fdf3e2; color: var(--warn); }
  .tag.bad { background: #fdeceb; color: var(--bad); }
  .tag.info { background: #e9f0fa; color: var(--info); }
  .tag.muted { background: #eef1f4; color: var(--muted); }
  code, .mono { font-family: Consolas, "Cascadia Mono", monospace; font-size: 12px; }
  .rec { color: var(--muted); font-size: 12px; margin-top: 3px; }
  .empty { background: var(--panel); border: 1px dashed var(--line); border-radius: 6px;
           padding: 18px; color: var(--muted); font-size: 13px; }
  footer { margin-top: 36px; padding-top: 14px; border-top: 1px solid var(--line);
           color: var(--muted); font-size: 12px; }
</style>
</head>
<body><div class="wrap">
'@)

    [void]$html.AppendLine('<header>')
    [void]$html.AppendLine('<h1>Azure Virtual Desktop &mdash; Assessment Report</h1>')
    [void]$html.AppendLine(('<div class="sub">Run <span class="mono">{0}</span> &middot; collected {1} UTC by {2}\{3} on {4} &middot; scope {5}</div>' -f `
        (ConvertTo-HtmlText $RunId), (ConvertTo-HtmlText $CompletedUtc.ToString('u')),
        (ConvertTo-HtmlText $env:USERDOMAIN), (ConvertTo-HtmlText $env:USERNAME),
        (ConvertTo-HtmlText $env:COMPUTERNAME), (ConvertTo-HtmlText $Scope)))
    if ($azureContext) {
        [void]$html.AppendLine(('<div class="sub">Subscription <span class="mono">{0}</span> &middot; account {1}</div>' -f `
            (ConvertTo-HtmlText $azureContext.Subscription.Id), (ConvertTo-HtmlText $azureContext.Account.Id)))
    }
    [void]$html.AppendLine('</header>')

    [void]$html.AppendLine(('<div class="banner {0}">{1} &mdash; {2} critical, {3} warning, {4} informational finding(s).</div>' -f `
        $overallClass, (ConvertTo-HtmlText $overallText), $criticalCount, $warningCount, $infoCount))

    # Summary cards.
    $shTotal     = @($Artifacts | Where-Object { $_.Artifact -eq 'Session hosts' } | Select-Object -ExpandProperty Rows)
    $shTotalVal  = if ($shTotal) { $shTotal[0] } else { 0 }
    $poolRowsCnt = @($Artifacts | Where-Object { $_.Artifact -eq 'Host pools' } | Select-Object -ExpandProperty Rows)
    $poolVal     = if ($poolRowsCnt) { $poolRowsCnt[0] } else { 0 }

    [void]$html.AppendLine('<div class="cards">')
    [void]$html.AppendLine(('<div class="card"><div class="n">{0}</div><div class="l">Host pools</div></div>' -f $poolVal))
    [void]$html.AppendLine(('<div class="card"><div class="n">{0}</div><div class="l">Session hosts</div></div>' -f $shTotalVal))
    [void]$html.AppendLine(('<div class="card"><div class="n">{0}</div><div class="l">Critical</div></div>' -f $criticalCount))
    [void]$html.AppendLine(('<div class="card"><div class="n">{0}</div><div class="l">Warnings</div></div>' -f $warningCount))
    [void]$html.AppendLine(('<div class="card"><div class="n">{0}</div><div class="l">Artifacts in error</div></div>' -f $errorArtifacts.Count))
    [void]$html.AppendLine('</div>')

    # Findings.
    [void]$html.AppendLine('<h2>Findings</h2>')
    if ($Findings.Count -gt 0) {
        [void]$html.AppendLine('<table><thead><tr><th>Severity</th><th>Area</th><th>Finding</th></tr></thead><tbody>')
        $ordered = $Findings | Sort-Object @{ E = { switch ($_.Severity) { 'Critical' { 0 } 'Warning' { 1 } default { 2 } } } }, Area
        foreach ($f in $ordered) {
            $cls = $sevClassMap[$f.Severity]
            [void]$html.AppendLine(('<tr><td><span class="tag {0}">{1}</span></td><td>{2}</td><td><strong>{3}</strong><br />{4}{5}</td></tr>' -f `
                $cls, (ConvertTo-HtmlText $f.Severity), (ConvertTo-HtmlText $f.Area),
                (ConvertTo-HtmlText $f.Title), (ConvertTo-HtmlText $f.Detail),
                $(if ($f.Recommendation) { '<div class="rec">&rarr; ' + (ConvertTo-HtmlText $f.Recommendation) + '</div>' } else { '' })))
        }
        [void]$html.AppendLine('</tbody></table>')
    }
    else {
        [void]$html.AppendLine('<div class="empty">No findings were raised. This reflects only the checks this collector performs.</div>')
    }

    # Session hosts.
    [void]$html.AppendLine('<h2>Session hosts</h2>')
    if ($azureContext -and $allSessionHostRows.Count -gt 0) {
        [void]$html.AppendLine('<table><thead><tr><th>Host pool</th><th>Session host</th><th>Status</th><th>New sessions</th><th>Sessions</th><th>Agent</th><th>Heartbeat age (h)</th><th>Health</th></tr></thead><tbody>')
        foreach ($row in ($allSessionHostRows | Sort-Object HostPool, SessionHost)) {
            $hbClass = 'ok'
            if ($row.HeartbeatStale) { $hbClass = 'bad' }
            $healthClass = 'ok'
            $healthText  = ("{0}/{1} passed" -f ($row.HealthChecksTotal - $row.HealthChecksFailed), $row.HealthChecksTotal)
            if ($row.HealthChecksFailed -gt 0) { $healthClass = 'bad' }
            elseif ($row.HealthChecksTotal -eq 0) { $healthClass = 'muted'; $healthText = 'no data' }
            $statusClass = 'ok'
            if ($row.Status -ne 'Available') { $statusClass = 'warn' }

            [void]$html.AppendLine(('<tr><td>{0}</td><td class="mono">{1}</td><td><span class="tag {2}">{3}</span></td><td>{4}</td><td>{5}</td><td class="mono">{6}</td><td><span class="tag {7}">{8}</span></td><td><span class="tag {9}">{10}</span></td></tr>' -f `
                (ConvertTo-HtmlText $row.HostPool), (ConvertTo-HtmlText $row.SessionHost),
                $statusClass, (ConvertTo-HtmlText $row.Status),
                (ConvertTo-HtmlText $row.AllowNewSession), (ConvertTo-HtmlText $row.Sessions),
                (ConvertTo-HtmlText $row.AgentVersion),
                $hbClass, (ConvertTo-HtmlText $row.HeartbeatAgeHours),
                $healthClass, (ConvertTo-HtmlText $healthText)))
        }
        [void]$html.AppendLine('</tbody></table>')
    }
    else {
        [void]$html.AppendLine('<div class="empty">No session host data was collected in this run.</div>')
    }

    # Artifacts.
    [void]$html.AppendLine('<h2>Collected artifacts</h2>')
    [void]$html.AppendLine('<table><thead><tr><th>Artifact</th><th>Status</th><th>Rows</th><th>Bytes</th><th>File</th><th>Note</th></tr></thead><tbody>')
    foreach ($a in $Artifacts) {
        $cls = $statusClassMap[$a.Status]
        if (-not $cls) { $cls = 'muted' }
        [void]$html.AppendLine(('<tr><td>{0}</td><td><span class="tag {1}">{2}</span></td><td>{3}</td><td>{4}</td><td class="mono">{5}</td><td>{6}</td></tr>' -f `
            (ConvertTo-HtmlText $a.Artifact), $cls, (ConvertTo-HtmlText $a.Status),
            (ConvertTo-HtmlText $a.Rows), (ConvertTo-HtmlText $a.Bytes),
            (ConvertTo-HtmlText $a.File), (ConvertTo-HtmlText $a.Message)))
    }
    [void]$html.AppendLine('</tbody></table>')

    [void]$html.AppendLine('<h2>How to read this report</h2>')
    [void]$html.AppendLine('<div class="empty"><strong>Collected</strong> means a query returned data, never that the configuration is healthy. <strong>NoData</strong> means the query succeeded but returned nothing &mdash; a header-only CSV is written so it is distinguishable from a failure. <strong>Error</strong> and <strong>NotRun</strong> mean the evidence is missing and the run exits non-zero. Findings are derived only from the data in this run and are not a complete AVD health assessment.</div>')

    [void]$html.AppendLine(('<footer>AVD Assessment Collector v2.0 &middot; manifest.json holds the machine-readable form of this report, including SHA256 hashes for every file. Output may contain user names, host names and resource topology &mdash; handle as sensitive evidence.</footer>'))
    [void]$html.AppendLine('</div></body></html>')

    $reportPath = Join-Path $RunRoot 'AVD-Assessment-Report.html'
    $html.ToString() | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Register-Artifact -Name 'HTML report' -Path $reportPath -Status 'Collected'
}

#endregion

#region Exit ------------------------------------------------------------------

Write-Host ''
Write-Host ('Output folder : {0}' -f $RunRoot) -ForegroundColor White
Write-Host ('Findings      : {0} critical, {1} warning, {2} info' -f $criticalCount, $warningCount, $infoCount)

if ($collectionSucceeded) {
    Write-Ok 'All required artifacts were collected.'
}
else {
    Write-Fail ('Collection incomplete: {0} artifact(s) in error, {1} not run. See Errors.txt and manifest.json.' -f `
        $errorArtifacts.Count, $notRun.Count)
}

[pscustomobject]@{
    RunId               = $RunId
    OutputPath          = $RunRoot
    CollectionSucceeded = $collectionSucceeded
    ArtifactsInError    = $errorArtifacts.Count
    ArtifactsNotRun     = $notRun.Count
    Critical            = $criticalCount
    Warning             = $warningCount
    Info                = $infoCount
    Report              = if ($NoHtmlReport) { $null } else { Join-Path $RunRoot 'AVD-Assessment-Report.html' }
    Manifest            = $manifestPath
    Summary             = $summaryPath
}

if (-not $collectionSucceeded) { exit 1 }
exit 0

#endregion

