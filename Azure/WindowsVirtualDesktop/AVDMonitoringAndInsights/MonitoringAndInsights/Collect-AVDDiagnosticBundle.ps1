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
    # RFC 5389 Binding request: type 0x0001, zero body length, magic cookie, 96-bit transaction ID.
    # Works only where the server permits Binding. It does NOT authenticate/allocate a TURN relay.
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
    # Run a potentially slow network filesystem call in an isolated, bounded process.
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
[pscustomobject]@{ZipPath=$zip;EvidenceDirectory=$bundle;Checks=$manifest.Count;ReviewRequired=@($manifest | Where-Object Status -ne 'Collected').Count}
