#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Read-only local AVD session host monitoring checks. Run on each Windows session host.
.DESCRIPTION
Checks services, registration flag, AMA process/config cache, logs and counters.
Does not install agents, change DCRs, restart services or generate test events.
Local cache existence does not prove correct DCR content or successful ingestion.
.EXAMPLE
.\Test-AVDSessionHostMonitoring.ps1 | Format-Table -Wrap
#>
[CmdletBinding()]
param(
    [ValidateRange(1,168)][int]$LookbackHours = 24,
    [string[]]$CounterPaths = @(
        '\Processor Information(_Total)\% Processor Time',
        '\Memory\Available MBytes',
        '\Memory\Page Faults/sec',
        '\Memory\Pages/sec',
        '\Memory\% Committed Bytes In Use',
        '\LogicalDisk(C:)\% Free Space',
        '\LogicalDisk(C:)\Avg. Disk Queue Length',
        '\LogicalDisk(C:)\Avg. Disk sec/Transfer',
        '\LogicalDisk(C:)\Current Disk Queue Length',
        '\PhysicalDisk(*)\Avg. Disk Queue Length',
        '\PhysicalDisk(*)\Avg. Disk sec/Read',
        '\PhysicalDisk(*)\Avg. Disk sec/Transfer',
        '\PhysicalDisk(*)\Avg. Disk sec/Write',
        '\Terminal Services\Active Sessions',
        '\Terminal Services\Inactive Sessions',
        '\Terminal Services\Total Sessions',
        '\User Input Delay per Process(*)\Max Input Delay',
        '\User Input Delay per Session(*)\Max Input Delay',
        '\RemoteFX Network(*)\Current TCP RTT',
        '\RemoteFX Network(*)\Current UDP Bandwidth'
    ),
    [string[]]$EventLogNames = @(
        'Application', 'System',
        'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin',
        'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
    )
)
$ErrorActionPreference = 'Stop'
function Result([string]$Check, [string]$Status, [string]$Details) {
    [pscustomobject]@{ Resource = $env:COMPUTERNAME; Check = $Check; Status = $Status; Details = $Details }
}
foreach ($name in @('RDAgentBootLoader','TermService')) {
    try {
        $service = Get-Service -Name $name -ErrorAction Stop
        Result "Service:$name" $(if ($service.Status -eq 'Running') { 'Pass' } else { 'Fail' }) ([string]$service.Status)
    } catch { Result "Service:$name" 'Error' $_.Exception.Message }
}
try {
    # Read only the registration flag, never the registration token.
    $registration = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -Name IsRegistered
    Result 'AVDRegistration' $(if ($registration -eq 1) { 'Pass' } else { 'Fail' }) "IsRegistered=$registration"
} catch { Result 'AVDRegistration' 'Error' $_.Exception.Message }
try {
    $packages = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -match 'Remote Desktop.*(Agent|Boot Loader|Infrastructure)' })
    Result 'AVDAgentPackages' 'Info' (($packages | ForEach-Object { "$($_.DisplayName): $($_.DisplayVersion)" }) -join '; ')
} catch { Result 'AVDAgentPackages' 'Error' $_.Exception.Message }
try {
    $listeners = & "$env:SystemRoot\System32\qwinsta.exe" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($listeners -join ' ') }
    Result 'SessionListeners' 'Info' ($listeners -join [Environment]::NewLine)
} catch { Result 'SessionListeners' 'Error' $_.Exception.Message }
try {
    $ama = @(Get-Process | Where-Object { $_.ProcessName -eq 'MonAgentCore' })
    Result 'AMAProcess' $(if ($ama.Count) { 'Pass' } else { 'Fail' }) "$($ama.Count) MonAgentCore process(es)."
} catch { Result 'AMAProcess' 'Error' $_.Exception.Message }
try {
    $cache = @(Get-ChildItem -Path 'C:\WindowsAzure\Resources\AMADataStore.*\mcs\mcsconfig.latest.xml' -File)
    Result 'AMADownloadedConfig' $(if ($cache.Count) { 'Pass' } else { 'Warning' }) (
        ($cache | ForEach-Object { "$($_.FullName); ModifiedUTC=$($_.LastWriteTimeUtc.ToString('o'))" }) -join '; ')
    Result 'DCRContentValidation' 'Info' 'Use Test-AVDDCRAssociation.ps1 to inspect authoritative DCR sources/routes. Cache location can vary by agent version.'
} catch { Result 'AMADownloadedConfig' 'Error' $_.Exception.Message }
try {
    $logPath = 'C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent'
    if (Test-Path -LiteralPath $logPath) {
        $logs = Get-ChildItem -LiteralPath $logPath -Recurse -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 5
        Result 'AMAExtensionLogs' 'Info' (($logs | ForEach-Object { "$($_.FullName); ModifiedUTC=$($_.LastWriteTimeUtc.ToString('o'))" }) -join '; ')
    } else { Result 'AMAExtensionLogs' 'Warning' "Directory not found: $logPath" }
} catch { Result 'AMAExtensionLogs' 'Error' $_.Exception.Message }
foreach ($name in $EventLogNames) {
    try {
        $log = Get-WinEvent -ListLog $name -ErrorAction Stop
        Result "EventLog:$name" $(if ($log.IsEnabled) { 'Pass' } else { 'Warning' }) "Enabled=$($log.IsEnabled); TotalRecords=$($log.RecordCount)"
    } catch { Result "EventLog:$name" 'Error' $_.Exception.Message; continue }
    try {
        $recent = Get-WinEvent -FilterHashtable @{ LogName=$name; StartTime=(Get-Date).AddHours(-$LookbackHours) } -MaxEvents 1 -ErrorAction Stop
        Result "RecentEvent:$name" 'Info' "Latest=$($recent.TimeCreated.ToUniversalTime().ToString('o')); ID=$($recent.Id)"
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { Result "RecentEvent:$name" 'Info' 'No recent events; an idle/healthy host can be quiet.' }
        else { Result "RecentEvent:$name" 'Error' $_.Exception.Message }
    }
}
try {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName='Application'; StartTime=(Get-Date).AddHours(-$LookbackHours)
        ProviderName=@('WVD-Agent','WVD-Agent-Updater','RDAgentBootLoader')
    } -MaxEvents 20 -ErrorAction Stop)
    foreach ($event in $events) {
        Result 'AVDAgentEvent' 'Info' "$($event.TimeCreated.ToUniversalTime().ToString('o')); $($event.ProviderName); ID=$($event.Id); $($event.LevelDisplayName); $($event.Message)"
    }
} catch {
    if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { Result 'AVDAgentEvents' 'Info' 'No matching recent agent events.' }
    else { Result 'AVDAgentEvents' 'Warning' $_.Exception.Message }
}
foreach ($counter in $CounterPaths) {
    try {
        $sample = Get-Counter -Counter $counter -MaxSamples 1 -ErrorAction Stop
        $valid = @($sample.CounterSamples | Where-Object { $_.Status -eq 0 })
        Result "Counter:$counter" $(if ($valid.Count) { 'Pass' } else { 'Warning' }) (
            ($sample.CounterSamples | ForEach-Object { "$($_.Path)=$($_.CookedValue); Status=$($_.Status)" }) -join '; ')
    } catch { Result "Counter:$counter" 'Warning' "$($_.Exception.Message) Session counters may need an active session; use localized paths on non-English Windows." }
}

