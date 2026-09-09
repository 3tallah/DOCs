#requires -Version 5.1
#requires -Modules Az.Accounts, Az.OperationalInsights
<#
.SYNOPSIS
Queries table activity, expected AMA heartbeats and optional validation-event ingestion.
.DESCRIPTION
Accepts the workspace by full ARM resource ID and resolves its GUID internally.
Uses a workspace GUID internally, not its ARM ID. No Azure resources are modified.
Missing/quiet tables warn. Expected VM IDs expose hosts that never sent heartbeats.
Custom query errors are reported separately from absent data.
.EXAMPLE
.\Test-AVDLogAnalyticsIngestion.ps1 -LogAnalyticsWorkspaceResourceId $lawId -ExpectedVMResourceId $vmIds
.EXAMPLE
.\Test-AVDLogAnalyticsIngestion.ps1 -LogAnalyticsWorkspaceResourceId $lawId -RunId $runId -TestComputer 'WPNS-AVD-0'
#>
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+/?$')][string]$LogAnalyticsWorkspaceResourceId,
 [ValidateRange(1,168)][int]$LookbackHours=48,
 [ValidateRange(1,1440)][int]$StaleAfterMinutes=15,
 [ValidatePattern('(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/virtualMachines/[^/]+/?$')][string[]]$ExpectedVMResourceId=@(),
 [guid]$RunId=[guid]::Empty,
 [ValidatePattern('^[a-zA-Z0-9._-]+$')][string]$TestComputer,
 [ValidateRange(1,600)][int]$QueryTimeoutSeconds=60
)
$ErrorActionPreference='Stop'
if (-not (Get-AzContext)) { throw 'Run Connect-AzAccount first.' }

$workspaceArmId = $LogAnalyticsWorkspaceResourceId.Trim().TrimEnd('/')
$rgMatch = [regex]::Match($workspaceArmId, '(?i)/resourceGroups/([^/]+)/providers/')
$wsMatch = [regex]::Match($workspaceArmId, '(?i)/workspaces/([^/]+)$')
$rgName = $rgMatch.Groups[1].Value
$wsName = $wsMatch.Groups[1].Value

$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $rgName -Name $wsName -ErrorAction Stop
$WorkspaceId = $ws.CustomerId

function Result([string]$Resource,[string]$Check,[string]$Status,[string]$Details) {
    [pscustomobject]@{ Resource=$Resource; Check=$Check; Status=$Status; Details=$Details }
}
function Query([string]$Text) {
    $response=Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId.ToString() -Query $Text -Wait $QueryTimeoutSeconds -ErrorAction Stop
    if ($response.Error) { throw ($response.Error | ConvertTo-Json -Depth 6 -Compress) }
    @($response.Results) | Where-Object { $null -ne $_ }
}
$tables=@('WVDConnections','WVDCheckpoints','WVDErrors','WVDFeeds','WVDManagement',
 'WVDHostRegistrations','WVDAgentHealthStatus','WVDConnectionNetworkData',
 'WVDConnectionGraphicsDataPreview','WVDSessionHostManagement','WVDMultiLinkAdd',
 'Event','Perf','Heartbeat')
$queryText=@"
union isfuzzy=true (datatable(TimeGenerated:datetime, Type:string)[]), $($tables -join ',')
| where TimeGenerated > ago($($LookbackHours)h)
| summarize Records=count(), LastRecord=max(TimeGenerated) by Type
"@
try {
    $records=@(Query $queryText)
    foreach ($table in $tables) {
        $row=$records | Where-Object Type -eq $table | Select-Object -First 1
        $status = if ($row -and $row.Records -gt 0) { 'Pass' } else { 'Warning' }
        $details = if ($row) { "Records=$($row.Records); LastRecord=$($row.LastRecord)" } else { "No visible rows in $LookbackHours hours or table absent. Activity-dependent tables can be quiet." }
        if ($table -eq 'Perf' -and $status -eq 'Warning') {
            $details += ' No Perf data usually means the DCR has no Microsoft-Perf source/route, or the host has not produced a matching counter sample.'
        }
        if ($table -eq 'Event' -and $status -eq 'Pass') {
            $details += ' Event rows confirm some event ingestion; use -RunId or the Event source query to identify their source and validate the expected XPath.'
        }
        Result $WorkspaceId.ToString() "Table:$table" $status $details
    }
} catch { Result $WorkspaceId.ToString() 'TableQuery' 'Error' $_.Exception.Message }

$queryText=@"
union isfuzzy=true (datatable(TimeGenerated:datetime, Computer:string, EventLog:string, Source:string, EventID:int)[]), Event
| where TimeGenerated > ago($($LookbackHours)h)
| summarize Records=count(), LastRecord=max(TimeGenerated) by Computer, EventLog, Source, EventID
| order by LastRecord desc
| take 1000
"@
try {
    $eventSources=@(Query $queryText)
    if ($eventSources.Count) {
        foreach ($row in $eventSources) {
            Result $row.Computer 'EventSourceInventory' 'Info' "EventLog=$($row.EventLog); Source=$($row.Source); EventID=$($row.EventID); Records=$($row.Records); LastRecord=$($row.LastRecord)"
        }
    } else {
        Result $WorkspaceId.ToString() 'EventSourceInventory' 'Info' "No Event source rows visible in $LookbackHours hours."
    }
} catch { Result $WorkspaceId.ToString() 'EventSourceQuery' 'Error' $_.Exception.Message }

$queryText=@"
union isfuzzy=true (datatable(TimeGenerated:datetime, Computer:string, Category:string, _ResourceId:string)[]), Heartbeat
| where TimeGenerated > ago($($LookbackHours)h) and Category == "Azure Monitor Agent"
| extend VMResourceId=tolower(_ResourceId)
| summarize LastHeartbeat=max(TimeGenerated), Computer=take_any(Computer) by VMResourceId
"@
try {
    $beats=@(Query $queryText)
    $ids=@($ExpectedVMResourceId | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() } | Sort-Object -Unique)
    if (-not $ids.Count) {
        Result $WorkspaceId.ToString() 'ExpectedHostInventory' 'Warning' 'No expected VM IDs supplied: never-seen hosts cannot be detected.'
        $ids=@($beats.VMResourceId)
    }
    foreach ($id in $ids) {
        $beat=$beats | Where-Object VMResourceId -eq $id | Select-Object -First 1
        if (-not $beat) { Result $id 'AMAHeartbeat' 'Warning' 'No heartbeat in window. Check power state, identity, AMA and ingestion.'; continue }
        $last=[datetimeoffset]::Parse([string]$beat.LastHeartbeat,[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $age=[datetimeoffset]::UtcNow-$last
        Result $id 'AMAHeartbeat' $(if ($age.TotalMinutes -le $StaleAfterMinutes) { 'Pass' } else { 'Warning' }) "Computer=$($beat.Computer); LastHeartbeat=$last; AgeMinutes=$([math]::Round($age.TotalMinutes,1))"
    }
} catch { Result $WorkspaceId.ToString() 'HeartbeatQuery' 'Error' $_.Exception.Message }
if ($RunId -ne [guid]::Empty) {
    # RunId is typed as GUID and TestComputer has a restricted character set.
    $computerPredicate=if ($TestComputer) { "| where Computer =~ '$TestComputer' or tostring(split(Computer, '.')[0]) =~ '$TestComputer'" } else { '' }
    $queryText=@"
union isfuzzy=true (datatable(TimeGenerated:datetime, Computer:string, Source:string, EventID:int, RenderedDescription:string)[]), Event
| where TimeGenerated > ago($($LookbackHours)h)
| where Source == "AVD-Monitoring-Validation" and EventID in (9001,9002)
| where RenderedDescription contains "$RunId"
$computerPredicate
| summarize Records=count(), LastRecord=max(TimeGenerated) by Computer, EventID
"@
    try {
        $events=@(Query $queryText)
        $computers=@($events.Computer | Sort-Object -Unique)
        if (-not $computers.Count) { Result $WorkspaceId.ToString() 'TestEvents' 'Warning' "No events for RunId=$RunId; allow ingestion time and review Application XPath/transforms." }
        foreach ($computer in $computers) {
            foreach ($eventId in @(9001,9002)) {
                $event=$events | Where-Object { $_.Computer -eq $computer -and $_.EventID -eq $eventId }
                Result $computer "TestEvent:$eventId" $(if ($event) { 'Pass' } else { 'Warning' }) "RunId=$RunId; LastRecord=$($event.LastRecord)"
            }
        }
    } catch { Result $WorkspaceId.ToString() 'TestEventsQuery' 'Error' $_.Exception.Message }
}
