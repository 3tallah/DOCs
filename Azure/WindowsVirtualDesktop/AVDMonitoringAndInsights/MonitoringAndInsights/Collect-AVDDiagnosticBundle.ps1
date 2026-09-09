#requires -Version 5.1
#requires -PSEdition Desktop
#requires -RunAsAdministrator
<#
.SYNOPSIS
Collects bounded, local AVD troubleshooting evidence into a uniquely named ZIP.
.DESCRIPTION
Run in elevated Windows PowerShell 5.1 on the affected host. Writes only to
OutputDirectory; never uploads, changes policy, restarts services, purges tickets,
or mounts a profile disk. Logs can contain user names, addresses and file paths.
PRT/tickets reflect the invoking security context, not every signed-in user.
Optional UDP probes verify STUN Binding responses, not TURN relay allocation.
.EXAMPLE
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD -WhatIf
.EXAMPLE
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD -StorageHost 'account.file.core.windows.net'
.EXAMPLE
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD -SharePath '\\account.file.core.windows.net\profiles' -RunEndpointTool
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
param(
 [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
 [ValidateRange(1,168)][int]$LookbackHours=24,
 [ValidateRange(1,5000)][int]$MaxEventsPerLog=200,
 [ValidateRange(1,100)][int]$MaxFilesPerComponent=10,
 [ValidateRange(1,5000)][int]$TailLines=500,
 [ValidateRange(1,300)][int]$CommandTimeoutSeconds=30,
 [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$StorageHost,
 [ValidatePattern('^\\\\[^\\]+\\[^\\]+')][string]$SharePath,
 [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$StunServer,
 [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$TurnServer,
 [ValidateRange(1,65535)][int]$UdpPort=3478,
 [switch]$RunEndpointTool
)
$ErrorActionPreference='Stop'
$outputPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if ($outputPath.StartsWith('\\')) { throw 'Use a local output directory. The collector does not write diagnostic bundles to network shares.' }
$name="AVD-Diagnostics-$env:COMPUTERNAME-$([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$bundle=Join-Path $outputPath $name
$zip="$bundle.zip"
if (-not $PSCmdlet.ShouldProcess($zip,'Collect local diagnostics and create ZIP (no upload)')) { return }
New-Item -ItemType Directory -Path $bundle -ErrorAction Stop | Out-Null
$manifest=New-Object 'System.Collections.Generic.List[object]'
function Record([string]$Name,[string]$Status,[string]$Details,[string]$File='') {
    $manifest.Add([pscustomobject]@{Check=$Name;Status=$Status;Details=$Details;File=$File})
}
function Capture([string]$Name,[scriptblock]$Action) {
    try {
        $data=@(& $Action)
        $file="$Name.json"
        ConvertTo-Json -InputObject $data -Depth 12 | Set-Content -LiteralPath (Join-Path $bundle $file) -Encoding UTF8
        Record $Name $(if ($data.Count) { 'Collected' } else { 'NoData' }) "$($data.Count) item(s); collection success is not a health verdict." $file
    } catch { Record $Name 'Error' $_.Exception.Message }
}
function Native([string]$Name,[string]$Executable,[string]$Arguments,[string]$WorkingDirectory='') {
    $process=New-Object System.Diagnostics.Process
    try {
        $process.StartInfo=New-Object System.Diagnostics.ProcessStartInfo
        $process.StartInfo.FileName=$Executable
        $process.StartInfo.Arguments=$Arguments
        $process.StartInfo.UseShellExecute=$false
        $process.StartInfo.CreateNoWindow=$true
        $process.StartInfo.RedirectStandardOutput=$true
        $process.StartInfo.RedirectStandardError=$true
        if ($WorkingDirectory) { $process.StartInfo.WorkingDirectory=$WorkingDirectory }
        $null=$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($CommandTimeoutSeconds*1000)) {
            $process.Kill()
            $null=$process.WaitForExit(5000)
            Record $Name 'Timeout' "Exceeded $CommandTimeoutSeconds seconds; child process stopped."
            return
        }
        $file="$Name.txt"
        @($stdout.GetAwaiter().GetResult(),$stderr.GetAwaiter().GetResult()) |
            Set-Content -LiteralPath (Join-Path $bundle $file) -Encoding UTF8
        Record $Name $(if ($process.ExitCode -eq 0) { 'Collected' } else { 'Error' }) "ExitCode=$($process.ExitCode); review output." $file
    } catch { Record $Name 'Error' $_.Exception.Message }
    finally { $process.Dispose() }
}
function RegistryValues([string]$Path,[string[]]$Names) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item=Get-ItemProperty -LiteralPath $Path
    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -in $Names) { [pscustomobject]@{Path=$Path;Name=$property.Name;Value=$property.Value} }
    }
}
function LogTails([string]$Component,[string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { Record $Component 'NotPresent' $Path; return }
    try {
        $files=@(Get-ChildItem -LiteralPath $Path -Recurse -File |
            Where-Object { $_.Extension -in @('.log','.txt') -and $_.LastWriteTime -gt (Get-Date).AddHours(-$LookbackHours) } |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $MaxFilesPerComponent)
        foreach ($file in $files) {
            $out="$Component-$([guid]::NewGuid().ToString('N').Substring(0,8))-$($file.Name).txt"
            try {
                Get-Content -LiteralPath $file.FullName -Tail $TailLines |
                    Set-Content -LiteralPath (Join-Path $bundle $out) -Encoding UTF8
                Record $Component 'Collected' "Tail of $($file.FullName); at most $TailLines lines." $out
            } catch { Record $Component 'Error' "$($file.FullName): $($_.Exception.Message)" }
        }
        if (-not $files.Count) { Record $Component 'NoData' "No recent .log/.txt files in $Path" }
    } catch { Record $Component 'Error' $_.Exception.Message }
}
function UdpBindingProbe([string]$Server,[string]$Label) {
    $client=New-Object System.Net.Sockets.UdpClient
    $random=[System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $client.Client.ReceiveTimeout=5000
        $client.Connect($Server,$UdpPort)
        $transaction=New-Object byte[] 12
        $random.GetBytes($transaction)
        [byte[]]$request=@(0,1,0,0,33,18,164,66)+$transaction
        $null=$client.Send($request,$request.Length)
        $remote=New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any,0)
        [byte[]]$reply=$client.Receive([ref]$remote)
        $matchesRequest=$reply.Length -ge 20
        if ($matchesRequest) {
            for ($i=4; $i -lt 20; $i++) { if ($reply[$i] -ne $request[$i]) { $matchesRequest=$false } }
        }
        if (-not $matchesRequest) { throw 'Received packet did not match the STUN transaction.' }
        $type=([int]$reply[0]*256)+$reply[1]
        Record $Label $(if ($type -eq 257) { 'BindingResponse' } else { 'ResponseNeedsReview' }) "$Server : $UdpPort; response type=$type. UDP/STUN evidence only; does not prove peer connectivity or TURN allocation."
    } catch { Record $Label 'Inconclusive' "$Server : $UdpPort; $($_.Exception.Message). Timeout may mean filtering, DNS failure or unsupported Binding." }
    finally { $random.Dispose(); $client.Dispose() }
}
Capture 'Machine-OS' {
    Get-CimInstance Win32_OperatingSystem | Select-Object CSName,Caption,Version,BuildNumber,OSArchitecture,LastBootUpTime,LocalDateTime,FreePhysicalMemory
    Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,PartOfDomain,Manufacturer,Model,TotalPhysicalMemory
}
Capture 'InvokingContext' {
    [pscustomobject]@{Identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;UTC=[datetime]::UtcNow.ToString('o')}
}
Capture 'InstalledComponents' {
    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -match 'Remote Desktop|FSLogix|Azure Monitor' } |
        Select-Object DisplayName,DisplayVersion,Publisher,InstallLocation
}
Capture 'Services' {
    Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'RDAgent|TermService|frxsvc|frxccds|AzureMonitor|MonAgent' } |
        Select-Object Name,DisplayName,State,StartMode,ProcessId
}
Capture 'RDAgentRegistration' { RegistryValues 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' @('IsRegistered','AgentVersion','BrokerResourceId') }
Record 'RegistryScope' 'Info' 'Only allowlisted registry values are collected. Registration tokens, protected extension settings and complete registry exports are excluded.'
Native 'Dsregcmd-Status' "$env:SystemRoot\System32\dsregcmd.exe" '/status'
Native 'Kerberos-TicketMetadata' "$env:SystemRoot\System32\klist.exe" ''
Native 'CloudKerberos-Status' "$env:SystemRoot\System32\klist.exe" 'cloud_debug'
Record 'PRT-UserContext' 'NeedsUserContext' 'dsregcmd/klist describe the invoking elevated context. In the affected user session, run dsregcmd /status and klist cloud_debug without elevation to validate that user.'
Capture 'FSLogixConfiguration' {
    RegistryValues 'HKLM:\SOFTWARE\FSLogix\Profiles' @('Enabled','VHDLocations','VolumeType','SizeInMBs','IsDynamic','DeleteLocalProfileWhenVHDShouldApply','PreventLoginWithFailure','PreventLoginWithTempProfile','RedirXMLSourceFolder','AccessNetworkAsComputerObject')
    RegistryValues 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC' @('Enabled','VHDLocations','VolumeType','SizeInMBs')
    RegistryValues 'HKLM:\SOFTWARE\FSLogix\Logging' @('LoggingEnabled','LogDir','LogFileKeepingPeriod')
}
$fsLogPath=Join-Path $env:ProgramData 'FSLogix\Logs'
try {
    if (Test-Path 'HKLM:\SOFTWARE\FSLogix\Logging') {
        $configured=(Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Logging').LogDir
        if ($configured) { $fsLogPath=[Environment]::ExpandEnvironmentVariables($configured) }
    }
    if ($fsLogPath.StartsWith('\\')) { Record 'FSLogixLogs' 'NotRun' "Configured logs are on a share ($fsLogPath); retrieve separately in the authorized context." }
    else { LogTails 'FSLogixLogs' $fsLogPath }
} catch { Record 'FSLogixLogs' 'Error' $_.Exception.Message }
Capture 'SMBConnections' { Get-SmbConnection | Select-Object ServerName,ShareName,UserName,Dialect,NumOpens,Encrypted }
Record 'SMBAuthentication' 'Info' 'SMB connections and ticket metadata are context-specific evidence; no password, storage key or new drive mapping is requested.'
if ($SharePath) {
    $escaped=$SharePath.Replace("'","''")
    $shareCode="if (Test-Path -LiteralPath '$escaped' -ErrorAction Stop) { Write-Output 'Share readable in invoking context' } else { throw 'Share unavailable in invoking context' }"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($shareCode))
    Native 'ShareAccess' "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -NonInteractive -EncodedCommand $encoded"
    if (-not $StorageHost) { $StorageHost=($SharePath -split '\\')[2] }
} else { Record 'ShareAccess' 'NotRun' 'Supply -SharePath to test read access in the invoking identity; this does not validate the affected user or profile write permissions.' }
if ($StorageHost) {
    Capture 'StorageDNS' { Resolve-DnsName -Name $StorageHost -DnsOnly }
    Capture 'StorageTCP445' {
        $tcp=New-Object System.Net.Sockets.TcpClient
        try {
            $connect=$tcp.ConnectAsync($StorageHost,445)
            if (-not $connect.Wait(5000)) { throw 'TCP 445 connection timed out.' }
            $connect.GetAwaiter().GetResult()
            [pscustomobject]@{Server=$StorageHost;Port=445;Connected=$tcp.Connected;Note='Transport only, not SMB authentication'}
        } finally { $tcp.Dispose() }
    }
} else { Record 'AzureFilesConnectivity' 'NotRun' 'Supply -StorageHost or -SharePath for DNS/TCP 445 checks.' }
Capture 'NetworkConfiguration' { Get-NetIPConfiguration -Detailed }
Capture 'NetworkRoutes' { Get-NetRoute | Select-Object DestinationPrefix,NextHop,InterfaceIndex,RouteMetric,AddressFamily }
Capture 'DNSServers' { Get-DnsClientServerAddress }
Native 'TimeSynchronization' "$env:SystemRoot\System32\w32tm.exe" '/query /status'
Native 'SessionListeners' "$env:SystemRoot\System32\qwinsta.exe" ''
if ($RunEndpointTool) {
    try {
        $tool=Get-ChildItem -Path "$env:ProgramFiles\Microsoft RDInfra\RDAgent_*\WVDAgentUrlTool.exe" -File |
            Sort-Object { [version]$_.VersionInfo.FileVersion } -Descending | Select-Object -First 1
        if (-not $tool) { throw 'Installed WVDAgentUrlTool.exe not found.' }
        if (-not (Test-Path -LiteralPath (Join-Path $tool.DirectoryName 'WVDAgentUrlTool.config'))) { throw 'Agent URL tool configuration missing.' }
        Native 'AVDRequiredEndpoints' $tool.FullName '' $tool.DirectoryName
    } catch { Record 'AVDRequiredEndpoints' 'Error' $_.Exception.Message }
} else { Record 'AVDRequiredEndpoints' 'NotRun' 'Use -RunEndpointTool to invoke the installed Microsoft Agent URL Tool. Its output does not cover every wildcard endpoint.' }
if ($StunServer) { UdpBindingProbe $StunServer 'STUNConnectivity' }
else { Record 'STUNConnectivity' 'NotRun' 'Supply -StunServer from your approved/current endpoint list to send a UDP Binding probe.' }
if ($TurnServer) { UdpBindingProbe $TurnServer 'TURNEndpointBinding' }
else { Record 'TURNEndpointBinding' 'NotRun' 'Supply -TurnServer to probe UDP Binding reachability; this is not a relay allocation test.' }
Record 'TURNAllocation' 'NotTested' 'Confirm an actual relayed connection in Windows App and AVD-RDPShortpath.kql. A Binding response cannot prove TURN allocation or end-to-end media transport.'
Capture 'RDPPolicyEvidence' {
    RegistryValues 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' @('fClientDisableUDP','fServerEnableUDP','SelectTransport','fEnableUdpPort')
    RegistryValues 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' @('fUseUdpPortRedirector','UdpPortNumber')
}
Capture 'AMAProcess' { Get-Process | Where-Object ProcessName -eq 'MonAgentCore' | Select-Object ProcessName,Id,StartTime }
Capture 'AMADCRCacheMetadata' {
    Get-ChildItem -Path 'C:\WindowsAzure\Resources\AMADataStore.*\mcs\mcsconfig.latest.xml' -File |
        Select-Object FullName,Length,LastWriteTimeUtc
}
Record 'DCRConfiguration' 'NeedsAzureCheck' 'Cache metadata is collected; run Test-AVDDCRAssociation.ps1 for authoritative DCR sources/routes/identity. Raw cache contents are not copied.'
LogTails 'AMAExtensionLogs' 'C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent'
$channels=@('Application','System','Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin',
 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational',
 'Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational',
 'Microsoft-FSLogix-Apps/Admin','Microsoft-FSLogix-Apps/Operational')
Capture 'EventChannelInventory' {
    foreach ($channel in $channels) {
        try { Get-WinEvent -ListLog $channel | Select-Object LogName,IsEnabled,RecordCount,LastWriteTime }
        catch { [pscustomobject]@{LogName=$channel;Error=$_.Exception.Message} }
    }
}
foreach ($channel in $channels) {
    $safeName=$channel -replace '[^a-zA-Z0-9-]','_'
    Capture "Events-$safeName" {
        $filter=@{LogName=$channel;StartTime=(Get-Date).AddHours(-$LookbackHours)}
        if ($channel -in @('Application','System')) { $filter.Level=@(1,2,3) }
        try {
            Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEventsPerLog |
                Select-Object TimeCreated,LogName,ProviderName,Id,LevelDisplayName,Message
        } catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
    }
}
Capture 'AVDAgentEvents' {
    try {
        Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddHours(-$LookbackHours);ProviderName=@('WVD-Agent','WVD-Agent-Updater','RDAgentBootLoader')} -MaxEvents $MaxEventsPerLog |
            Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message
    } catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
}
Capture 'LocalMonitoringChecks' {
    & (Join-Path $PSScriptRoot 'Test-AVDSessionHostMonitoring.ps1') -LookbackHours $LookbackHours
}
@"
AVD diagnostic evidence from $env:COMPUTERNAME, UTC $([datetime]::UtcNow.ToString('o')).
Read manifest.json first. Collected means evidence was saved, not that the component is healthy.
Missing, partial, timed-out and skipped checks are explicit. Logs are bounded text/JSON extracts, not full EVTX.
User names, IP addresses, tenant/device IDs, host names and paths may be present.
No upload was performed. Review contents before sharing through your approved support channel.
Registration tokens and complete registry/cache exports are intentionally excluded.
PRT, Kerberos and SMB results reflect the invoking identity, not all signed-in users.
STUN Binding does not validate TURN allocation or prove the transport of an actual AVD session.
The unpacked evidence folder is retained beside this ZIP for review. Delete it manually when no longer needed.
"@ | Set-Content -LiteralPath (Join-Path $bundle 'README.txt') -Encoding UTF8
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Encoding UTF8
Compress-Archive -LiteralPath $bundle -DestinationPath $zip -ErrorAction Stop

#region HTML Report
$collected = @($manifest | Where-Object { $_.Status -eq 'Collected' }).Count
$noData = @($manifest | Where-Object { $_.Status -eq 'NoData' }).Count
$notRun = @($manifest | Where-Object { $_.Status -in @('NotRun','NotPresent','NeedsUserContext','NeedsAzureCheck','NotTested','Info') }).Count
$errored = @($manifest | Where-Object { $_.Status -in @('Error','Timeout','Inconclusive') }).Count

$categoryMap = @{
    'Machine-OS'='System';'InvokingContext'='System';'InstalledComponents'='System';'Services'='System'
    'RDAgentRegistration'='AVD Agent';'RegistryScope'='AVD Agent'
    'Dsregcmd-Status'='Identity';'Kerberos-TicketMetadata'='Identity';'CloudKerberos-Status'='Identity';'PRT-UserContext'='Identity'
    'FSLogixConfiguration'='FSLogix';'FSLogixLogs'='FSLogix'
    'SMBConnections'='Storage';'SMBAuthentication'='Storage';'ShareAccess'='Storage'
    'StorageDNS'='Storage';'StorageTCP445'='Storage';'AzureFilesConnectivity'='Storage'
    'NetworkConfiguration'='Network';'NetworkRoutes'='Network';'DNSServers'='Network'
    'TimeSynchronization'='Network';'SessionListeners'='Session'
    'AVDRequiredEndpoints'='AVD Agent';'STUNConnectivity'='Network';'TURNEndpointBinding'='Network';'TURNAllocation'='Network'
    'RDPPolicyEvidence'='Session';'AMAProcess'='Monitoring';'AMADCRCacheMetadata'='Monitoring';'DCRConfiguration'='Monitoring'
    'AMAExtensionLogs'='Monitoring';'EventChannelInventory'='Events';'AVDAgentEvents'='Events';'LocalMonitoringChecks'='Monitoring'
}

$rows = ''
foreach ($m in $manifest) {
    $cat = if ($categoryMap.ContainsKey($m.Check)) { $categoryMap[$m.Check] } else {
        if ($m.Check -like 'Events-*') { 'Events' } else { 'Other' }
    }
    $badge = switch ($m.Status) {
        'Collected'   { '<span class="badge collected">Collected</span>' }
        'NoData'      { '<span class="badge nodata">No Data</span>' }
        'NotRun'      { '<span class="badge notrun">Not Run</span>' }
        'NotPresent'  { '<span class="badge notrun">Not Present</span>' }
        'Error'       { '<span class="badge error">Error</span>' }
        'Timeout'     { '<span class="badge error">Timeout</span>' }
        'Inconclusive'{ '<span class="badge error">Inconclusive</span>' }
        'Info'        { '<span class="badge info">Info</span>' }
        'NeedsUserContext' { '<span class="badge warn">Needs User Context</span>' }
        'NeedsAzureCheck'  { '<span class="badge warn">Needs Azure Check</span>' }
        'NotTested'   { '<span class="badge notrun">Not Tested</span>' }
        default       { "<span class='badge'>$($m.Status)</span>" }
    }
    $fileLink = if ($m.File) { "<a href='$($m.File)'>$($m.File)</a>" } else { '&mdash;' }
    $detailEsc = [System.Net.WebUtility]::HtmlEncode($m.Details)
    $rows += "<tr data-cat='$cat'><td>$($m.Check)</td><td>$cat</td><td>$badge</td><td class='detail'>$detailEsc</td><td class='file'>$fileLink</td></tr>`n"
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AVD Diagnostic Bundle - $env:COMPUTERNAME</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif; background:#0d1117; color:#c9d1d9; padding:24px; }
  h1 { font-size:1.6rem; margin-bottom:4px; color:#58a6ff; }
  .subtitle { color:#8b949e; font-size:0.85rem; margin-bottom:20px; }
  .cards { display:flex; gap:12px; margin-bottom:24px; flex-wrap:wrap; }
  .card { background:#161b22; border:1px solid #30363d; border-radius:8px; padding:16px 24px; min-width:140px; text-align:center; }
  .card .num { font-size:2rem; font-weight:700; }
  .card .label { font-size:0.75rem; color:#8b949e; text-transform:uppercase; letter-spacing:0.5px; margin-top:2px; }
  .card.collected .num { color:#3fb950; }
  .card.nodata .num { color:#8b949e; }
  .card.warn .num { color:#d29922; }
  .card.error .num { color:#f85149; }
  .card.total .num { color:#58a6ff; }
  .filters { margin-bottom:16px; display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
  .filters label { color:#8b949e; font-size:0.8rem; margin-right:4px; }
  .filters button { background:#21262d; border:1px solid #30363d; color:#c9d1d9; padding:5px 12px; border-radius:6px; cursor:pointer; font-size:0.8rem; }
  .filters button:hover, .filters button.active { background:#1f6feb; border-color:#1f6feb; color:#fff; }
  .search { background:#0d1117; border:1px solid #30363d; color:#c9d1d9; padding:5px 12px; border-radius:6px; font-size:0.8rem; width:220px; }
  table { width:100%; border-collapse:collapse; background:#161b22; border:1px solid #30363d; border-radius:8px; overflow:hidden; }
  th { background:#21262d; text-align:left; padding:10px 12px; font-size:0.75rem; color:#8b949e; text-transform:uppercase; letter-spacing:0.5px; border-bottom:1px solid #30363d; position:sticky; top:0; }
  td { padding:8px 12px; border-bottom:1px solid #21262d; font-size:0.85rem; vertical-align:top; }
  tr:hover { background:#1c2128; }
  td.detail { max-width:500px; word-break:break-word; color:#8b949e; }
  td.file a { color:#58a6ff; text-decoration:none; }
  td.file a:hover { text-decoration:underline; }
  .badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:0.72rem; font-weight:600; white-space:nowrap; }
  .badge.collected { background:#238636; color:#fff; }
  .badge.nodata { background:#30363d; color:#8b949e; }
  .badge.notrun { background:#30363d; color:#6e7681; }
  .badge.error { background:#da3633; color:#fff; }
  .badge.warn { background:#9e6a03; color:#fff; }
  .badge.info { background:#1f6feb; color:#fff; }
  .section-title { font-size:1.1rem; color:#c9d1d9; margin:20px 0 10px; font-weight:600; }
  .footer { margin-top:20px; font-size:0.75rem; color:#484f58; }
</style>
</head>
<body>
<h1>AVD Diagnostic Bundle Report</h1>
<p class="subtitle">$env:COMPUTERNAME &mdash; Generated $([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC &mdash; Lookback $LookbackHours hours</p>

<div class="cards">
  <div class="card total"><div class="num">$($manifest.Count)</div><div class="label">Total Checks</div></div>
  <div class="card collected"><div class="num">$collected</div><div class="label">Collected</div></div>
  <div class="card nodata"><div class="num">$noData</div><div class="label">No Data</div></div>
  <div class="card warn"><div class="num">$notRun</div><div class="label">Skipped / Info</div></div>
  <div class="card error"><div class="num">$errored</div><div class="label">Errors</div></div>
</div>

<div class="filters">
  <label>FILTER:</label>
  <button class="active" onclick="filterCat('all')">All</button>
  <button onclick="filterCat('System')">System</button>
  <button onclick="filterCat('AVD Agent')">AVD Agent</button>
  <button onclick="filterCat('Identity')">Identity</button>
  <button onclick="filterCat('FSLogix')">FSLogix</button>
  <button onclick="filterCat('Storage')">Storage</button>
  <button onclick="filterCat('Network')">Network</button>
  <button onclick="filterCat('Session')">Session</button>
  <button onclick="filterCat('Events')">Events</button>
  <button onclick="filterCat('Monitoring')">Monitoring</button>
  <input type="text" class="search" placeholder="Search checks..." oninput="searchTable(this.value)">
</div>

<table>
<thead><tr><th>Check</th><th>Category</th><th>Status</th><th>Details</th><th>File</th></tr></thead>
<tbody id="rows">$rows</tbody>
</table>

<p class="footer">Collected means evidence was saved, not that the component is healthy. Review contents before sharing through your approved support channel.</p>

<script>
function filterCat(cat) {
  document.querySelectorAll('.filters button').forEach(b => b.classList.remove('active'));
  event.target.classList.add('active');
  document.querySelectorAll('#rows tr').forEach(tr => {
    tr.style.display = (cat === 'all' || tr.dataset.cat === cat) ? '' : 'none';
  });
}
function searchTable(q) {
  var lower = q.toLowerCase();
  document.querySelectorAll('#rows tr').forEach(tr => {
    tr.style.display = tr.textContent.toLowerCase().includes(lower) ? '' : 'none';
  });
}
</script>
</body>
</html>
"@

$htmlPath = Join-Path $bundle 'Report.html'
$html | Set-Content -LiteralPath $htmlPath -Encoding UTF8
Record 'HTMLReport' 'Collected' "Interactive HTML report with filterable table and summary cards." 'Report.html'
#endregion

[pscustomobject]@{ZipPath=$zip;EvidenceDirectory=$bundle;ReportPath=$htmlPath;Checks=$manifest.Count;ReviewRequired=@($manifest | Where-Object Status -ne 'Collected').Count}
