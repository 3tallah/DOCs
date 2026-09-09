#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Interactive AVD session host monitoring validation with colored console output.
.DESCRIPTION
Single-pass console validation script intended for manual runs on an AVD session host.
Covers AVD services, registration, RDP/SxS listener, Azure Monitor Agent, DCR config
cache, extension logs, required event logs (including FSLogix), recent agent events,
performance counters, and writes two labeled test events to the Application log.

For pipeline use, prefer the structured scripts in the MonitoringAndInsights folder:
  - Test-AVDSessionHostMonitoring.ps1  (read-only, object output; also includes
    Terminal Services, User Input Delay and RemoteFX counters)
  - New-AVDMonitoringTestEvent.ps1     (test events with -WhatIf support)
  - Export-AVDMonitoringDiagnostics.ps1 (local evidence bundle)

This script writes two labeled test events (source AVD-Monitoring-Validation,
IDs 9001 warning / 9002 error) and creates the event source if missing. It does not
install agents, change DCRs or restart services.
.EXAMPLE
.\Validate-AVDSessionHostMonitoring-Interactive.ps1
#>

$ErrorActionPreference = "SilentlyContinue"

try {

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host " AVD SESSION HOST MONITORING VALIDATION"
Write-Host " Host: $env:COMPUTERNAME"
Write-Host " Time: $(Get-Date)"
Write-Host "=============================================" -ForegroundColor Cyan


# ------------------------------------------------------------
# 1. AVD Agent / Services
# ------------------------------------------------------------

Write-Host "`n[1] AVD SERVICES" -ForegroundColor Yellow

$services = @(
    "RDAgentBootLoader",
    "TermService",
    "frxsvc"
)

foreach ($service in $services) {

    $s = Get-Service $service -ErrorAction SilentlyContinue

    if ($s) {
        Write-Host "$service : $($s.Status)" `
            -ForegroundColor $(if ($s.Status -eq "Running") {"Green"} else {"Red"})
    }
    else {
        Write-Host "$service : NOT INSTALLED" -ForegroundColor DarkYellow
    }
}


# ------------------------------------------------------------
# 2. AVD Registration
# ------------------------------------------------------------

Write-Host "`n[2] AVD REGISTRATION" -ForegroundColor Yellow

$avdReg = Get-ItemProperty `
    "HKLM:\SOFTWARE\Microsoft\RDInfraAgent" `
    -ErrorAction SilentlyContinue

if ($avdReg) {

    Write-Host "IsRegistered : $($avdReg.IsRegistered)"

    if ($avdReg.IsRegistered -eq 1) {
        Write-Host "AVD Agent registration: PASS" -ForegroundColor Green
    }
    else {
        Write-Host "AVD Agent registration: FAIL" -ForegroundColor Red
    }
}
else {
    Write-Host "RDInfraAgent registry key not found" -ForegroundColor Red
}


# ------------------------------------------------------------
# 3. AVD SxS Listener
# ------------------------------------------------------------

Write-Host "`n[3] AVD RDP / SxS LISTENER" -ForegroundColor Yellow

qwinsta


# ------------------------------------------------------------
# 4. Azure Monitor Agent
# ------------------------------------------------------------

Write-Host "`n[4] AZURE MONITOR AGENT" -ForegroundColor Yellow

$ama = Get-Process MonAgentCore -ErrorAction SilentlyContinue

if ($ama) {
    Write-Host "MonAgentCore.exe : RUNNING" -ForegroundColor Green
}
else {
    Write-Host "MonAgentCore.exe : NOT RUNNING" -ForegroundColor Red
}


# ------------------------------------------------------------
# 5. AMA DCR Configuration Downloaded
# ------------------------------------------------------------

Write-Host "`n[5] DCR CONFIGURATION ON VM" -ForegroundColor Yellow

$amaConfig = Get-ChildItem `
    "C:\WindowsAzure\Resources\AMADataStore.*\mcs\mcsconfig.latest.xml" `
    -ErrorAction SilentlyContinue

if ($amaConfig) {

    foreach ($file in $amaConfig) {
        Write-Host "DCR configuration found:" -ForegroundColor Green
        Write-Host $file.FullName
        Write-Host "LastWriteTime : $($file.LastWriteTime)"
    }
}
else {
    Write-Host "mcsconfig.latest.xml NOT FOUND" -ForegroundColor Red
    Write-Host "Possible missing DCR association or AMA configuration download failure."
}


# ------------------------------------------------------------
# 6. AMA Extension Logs
# ------------------------------------------------------------

Write-Host "`n[6] AMA EXTENSION LOGS" -ForegroundColor Yellow

$amaLogPath =
"C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent"

if (Test-Path $amaLogPath) {

    Write-Host "AMA extension log path exists: PASS" -ForegroundColor Green

    Get-ChildItem $amaLogPath -Recurse -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 5 FullName, LastWriteTime
}
else {
    Write-Host "AMA extension logs NOT FOUND" -ForegroundColor Red
}


# ------------------------------------------------------------
# 7. Required Windows Event Logs
# ------------------------------------------------------------

Write-Host "`n[7] REQUIRED AVD INSIGHTS EVENT LOGS" -ForegroundColor Yellow

$requiredLogs = @(
    "Application",
    "System",
    "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin",
    "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational",
    "Microsoft-FSLogix-Apps/Operational",
    "Microsoft-FSLogix-Apps/Admin"
)

foreach ($log in $requiredLogs) {

    $logInfo = Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue

    if ($logInfo) {

        $events = Get-WinEvent `
            -FilterHashtable @{
                LogName   = $log
                StartTime = (Get-Date).AddHours(-24)
            } `
            -ErrorAction SilentlyContinue

        Write-Host "[PASS] $log | Last 24h events: $($events.Count)" `
            -ForegroundColor Green
    }
    else {
        Write-Host "[MISSING] $log" -ForegroundColor Red
    }
}


# ------------------------------------------------------------
# 8. Important local AVD Agent Events
# ------------------------------------------------------------

Write-Host "`n[8] RECENT AVD AGENT EVENTS" -ForegroundColor Yellow

Get-WinEvent `
    -FilterHashtable @{
        LogName   = "Application"
        StartTime = (Get-Date).AddHours(-24)
    } `
    -ErrorAction SilentlyContinue |
Where-Object {
    $_.ProviderName -match
    "WVD-Agent|WVD-Agent-Updater|RDAgentBootLoader|MsiInstaller"
} |
Select-Object -First 20 `
    TimeCreated,
    Id,
    LevelDisplayName,
    ProviderName,
    Message |
Format-Table -Wrap


# ------------------------------------------------------------
# 9. Validate important performance counters locally
# ------------------------------------------------------------

Write-Host "`n[9] PERFORMANCE COUNTERS" -ForegroundColor Yellow

$counters = @(
    '\Processor Information(_Total)\% Processor Time',
    '\Memory\Available MBytes',
    '\Memory\% Committed Bytes In Use',
    '\Memory\Pages/sec',
    '\LogicalDisk(C:)\% Free Space',
    '\LogicalDisk(C:)\Avg. Disk Queue Length',
    '\LogicalDisk(C:)\Avg. Disk sec/Transfer',
    '\PhysicalDisk(*)\Avg. Disk Queue Length',
    '\PhysicalDisk(*)\Avg. Disk sec/Read',
    '\PhysicalDisk(*)\Avg. Disk sec/Write'
)

foreach ($counter in $counters) {

    try {

        $result = Get-Counter $counter -MaxSamples 1 -ErrorAction Stop

        Write-Host "[PASS] $counter" -ForegroundColor Green
    }
    catch {

        Write-Host "[NOT AVAILABLE] $counter" -ForegroundColor DarkYellow
    }
}


# ------------------------------------------------------------
# 10. Generate harmless test events
# ------------------------------------------------------------

Write-Host "`n[10] GENERATING LOG ANALYTICS TEST EVENTS" `
    -ForegroundColor Yellow

$source = "AVD-Monitoring-Validation"

if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {

    New-EventLog `
        -LogName Application `
        -Source $source
}

Write-EventLog `
    -LogName Application `
    -Source $source `
    -EventId 9001 `
    -EntryType Warning `
    -Message "AVD monitoring validation WARNING from $env:COMPUTERNAME at $(Get-Date -Format o)"

Write-EventLog `
    -LogName Application `
    -Source $source `
    -EventId 9002 `
    -EntryType Error `
    -Message "AVD monitoring validation ERROR from $env:COMPUTERNAME at $(Get-Date -Format o)"

Write-Host "Test Event IDs 9001 and 9002 generated successfully." `
    -ForegroundColor Green


Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host " VALIDATION COMPLETE"
Write-Host "=============================================" -ForegroundColor Cyan

}
finally {
    # Do not leak SilentlyContinue into the caller's session.
    $ErrorActionPreference = 'Continue'
}
