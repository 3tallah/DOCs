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
$evidence=@{}
function Record([string]$Name,[string]$Status,[string]$Details,[string]$File='') {
    $manifest.Add([pscustomobject]@{Check=$Name;Status=$Status;Details=$Details;File=$File})
}
function Capture([string]$Name,[scriptblock]$Action) {
    try {
        $data=@(& $Action)
        $evidence[$Name]=$data
        $file="$Name.json"
        ConvertTo-Json -InputObject $data -Depth 12 | Set-Content -LiteralPath (Join-Path $bundle $file) -Encoding UTF8
        Record $Name $(if ($data.Count) { 'Collected' } else { 'NoData' }) "$($data.Count) item(s)" $file
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
        $outText=$stdout.GetAwaiter().GetResult()
        $errText=$stderr.GetAwaiter().GetResult()
        $evidence[$Name]=($outText,$errText) -join "`r`n"
        @($outText,$errText) |
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
                $tail=@(Get-Content -LiteralPath $file.FullName -Tail $TailLines)
                $evidence["$Component|$($file.Name)"]=$tail
                $tail | Set-Content -LiteralPath (Join-Path $bundle $out) -Encoding UTF8
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
Capture 'Disks' {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
        Select-Object DeviceID,VolumeName,@{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},@{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}},@{n='FreePct';e={ if ($_.Size) { [math]::Round(100*$_.FreeSpace/$_.Size,1) } }}
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
    $agentEventProviders=@('WVD-Agent','WVD-Agent-Updater','RDAgentBootLoader')
    $agentEventRows=@()
    foreach ($provider in $agentEventProviders) {
        try {
            $agentEventRows += @(Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=(Get-Date).AddHours(-$LookbackHours);ProviderName=$provider} -MaxEvents $MaxEventsPerLog -ErrorAction Stop |
                Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message)
        } catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -like '*not an event provider*') {
                $agentEventRows += [pscustomobject]@{TimeCreated=$null;ProviderName=$provider;Id=0;LevelDisplayName='NoEvents';Message='No matching events in the lookback window, or the provider is absent on this host.'}
            } else { throw }
        }
    }
    $agentEventRows
}
$monitorCheckerPath=$null
$monitorCheckerRoot=''
if ($PSScriptRoot) { $monitorCheckerRoot=$PSScriptRoot }
elseif ($MyInvocation.MyCommand.Path) { $monitorCheckerRoot=Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($monitorCheckerRoot) { $monitorCheckerPath=Join-Path $monitorCheckerRoot 'Test-AVDSessionHostMonitoring.ps1' }
if ($monitorCheckerPath -and (Test-Path -LiteralPath $monitorCheckerPath)) {
    Capture 'LocalMonitoringChecks' { & $monitorCheckerPath -LookbackHours $LookbackHours }
} else {
    Record 'LocalMonitoringChecks' 'NotRun' 'Test-AVDSessionHostMonitoring.ps1 was not found beside the collector; copy it to the same folder to include its local monitoring checks.'
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
#region Findings
# Heuristic triage layer (read-only): analyzes the evidence already collected in memory
# and emits findings.json plus the "Flagged issues" section of the HTML report.
# Findings are triage hints for common AVD failure patterns, not health verdicts.
$findings=New-Object 'System.Collections.Generic.List[object]'
$findingSeq=0
function Add-Finding([string]$Severity,[string]$Category,[string]$Title,[object[]]$Evidence,[string]$Interpretation,[object[]]$NextSteps,[string]$File='',[string]$Reference='') {
    $script:findingSeq=$script:findingSeq+1
    $findings.Add([pscustomobject]@{
        Id=('F{0:d3}' -f $script:findingSeq)
        Severity=$Severity
        Category=$Category
        Title=$Title
        Evidence=@($Evidence | ForEach-Object { [string]$_ })
        Interpretation=$Interpretation
        NextSteps=@($NextSteps | ForEach-Object { [string]$_ })
        File=$File
        Reference=$Reference
    })
}
function TrimText([object]$Text,[int]$Max=140) {
    if ($null -eq $Text) { return '' }
    $t=((([string]$Text) -replace '\s+',' ')).Trim()
    if ($t.Length -gt $Max) { $t=$t.Substring(0,$Max).TrimEnd()+'...' }
    return $t
}
function Get-Status([string]$Check) {
    foreach ($row in $manifest) { if ($row.Check -eq $Check) { return $row.Status } }
    return $null
}
function Get-Val([string]$Key,[string]$PropName) {
    $rows=$evidence[$Key]
    if ($null -eq $rows) { return $null }
    foreach ($row in @($rows)) {
        if ($null -ne $row -and $row.PSObject.Properties['Name'] -and $row.Name -eq $PropName) { return $row.Value }
    }
    return $null
}
function Invoke-Analyzer([string]$Name,[scriptblock]$Body) {
    try { & $Body } catch { Record "Analysis-$Name" 'Error' $_.Exception.Message }
}
Invoke-Analyzer 'Agent' {
    $agentServiceNames=@('RDAgent','RDAgentBootLoader','TermService')
    foreach ($svc in @($evidence['Services'])) {
        if ($null -eq $svc -or $agentServiceNames -notcontains $svc.Name) { continue }
        if ($svc.State -ne 'Running' -and $svc.StartMode -eq 'Auto') {
            Add-Finding 'Critical' 'AVD Agent' "Service '$($svc.Name)' is $($svc.State) (StartMode=$($svc.StartMode))" @("Win32_Service: $($svc.Name) State=$($svc.State) StartMode=$($svc.StartMode)") 'A stopped AVD agent, bootloader, or Remote Desktop Services stack prevents broker heartbeats and new connections.' @('Start the service and watch whether it stays running; a service that stops again usually indicates a registration/token problem','Check AVDAgentEvents.json for INVALID_REGISTRATION_TOKEN or EXPIRED_MACHINE_TOKEN (event 3277)','Review the agent troubleshooting guide') 'Services.json' 'https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-agent'
        }
        if ($svc.State -eq 'Running' -and $svc.StartMode -ne 'Auto') {
            Add-Finding 'Warning' 'AVD Agent' "Service '$($svc.Name)' runs but StartMode=$($svc.StartMode)" @("Win32_Service: $($svc.Name) StartMode=$($svc.StartMode)") 'The service may not start after a reboot, causing intermittent availability loss.' @('Set the service startup type to Automatic') 'Services.json' ''
        }
    }
    $isRegistered=Get-Val 'RDAgentRegistration' 'IsRegistered'
    if ("$isRegistered" -eq '0') {
        Add-Finding 'Critical' 'AVD Agent' 'Host reports IsRegistered=0' @('HKLM:\SOFTWARE\Microsoft\RDInfraAgent IsRegistered=0') 'The host is not registered with the AVD broker; it will show as Unavailable or take no sessions in the host pool.' @('Generate a fresh registration key and reregister the host per the agent troubleshooting guide','After reregistration verify IsRegistered=1') 'RDAgentRegistration.json' 'https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-agent'
    }
    $agentVersion=Get-Val 'RDAgentRegistration' 'AgentVersion'
    if ("$agentVersion" -eq '') {
        Add-Finding 'Warning' 'AVD Agent' 'AgentVersion not populated' @('HKLM:\SOFTWARE\Microsoft\RDInfraAgent AgentVersion is empty or absent.') 'The agent may not have completed installation or registration.' @('Reinstall the latest AVD agent and bootloader') 'RDAgentRegistration.json' 'https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-agent'
    }
    $agentErrors=@($evidence['AVDAgentEvents'] | Where-Object { $null -ne $_ -and $_.PSObject.Properties['LevelDisplayName'] -and $_.LevelDisplayName -in @('Error','Warning') -and "$($_.LevelDisplayName)" -ne 'NoEvents' })
    if ($agentErrors.Count -gt 0) {
        $agentEvLines=@()
        foreach ($ev in ($agentErrors | Select-Object -First 3)) { $agentEvLines += "[$($ev.TimeCreated)] $($ev.ProviderName) ID=$($ev.Id): $(TrimText $ev.Message 90)" }
        Add-Finding 'Warning' 'AVD Agent' "$($agentErrors.Count) AVD agent Error/Warning event(s) in the last $LookbackHours hours" $agentEvLines 'Agent-side warnings or errors during the lookback window; correlate their timestamps with connection failures.' @('Open AVDAgentEvents.json and read the full messages for the event IDs listed','Follow the agent troubleshooting guide for the specific event IDs') 'AVDAgentEvents.json' ''
    }
    if ((Get-Status 'AVDRequiredEndpoints') -eq 'NotRun') {
        Add-Finding 'Info' 'AVD Agent' 'Required-endpoint probe not run' @('AVDRequiredEndpoints check skipped: -RunEndpointTool was not supplied') 'Without an endpoint check you cannot rule out blocked required URLs as a cause of agent or connection failures.' @('Re-run the collector with -RunEndpointTool to invoke the installed Microsoft Agent URL Tool','The Agent URL Tool output does not cover every wildcard endpoint') '' 'https://learn.microsoft.com/azure/virtual-desktop/safe-url-list'
    }
}
Invoke-Analyzer 'Identity' {
    $dsreg=[string]$evidence['Dsregcmd-Status']
    $entraJoined=($dsreg -match '(?im)^\s*AzureAdJoined\s*:\s*YES')
    $domainJoined=($dsreg -match '(?im)^\s*DomainJoined\s*:\s*YES')
    if ($dsreg -ne '' -and -not $entraJoined -and -not $domainJoined) {
        Add-Finding 'Critical' 'Identity' 'Host joined to neither AD DS nor Microsoft Entra ID' @('dsregcmd /status: AzureAdJoined=NO and DomainJoined=NO') 'AVD session hosts must be joined to AD DS or Microsoft Entra ID before the agent can register and accept host pool connections.' @('Validate the join in an elevated console with dsregcmd /status and nltest /dsgetdc:yourdomain','If a join is expected, check domain controller and Entra network reachability before rejoining') 'Dsregcmd-Status.txt' ''
    }
    if ($dsreg -match '(?im)^\s*AzureAdPrt\s*:\s*NO') {
        Add-Finding 'Info' 'Identity' 'No PRT in the invoking (elevated) context' @('dsregcmd /status: AzureAdPrt : NO') 'The collector runs elevated, and elevated contexts frequently have no Primary Refresh Token; this alone does not prove the affected user lacks one.' @('In the affected user session, run dsregcmd /status without elevation and confirm AzureAdPrt : YES','PRT and ticket evidence in this bundle always reflects the invoking identity, not every signed-in user') 'Dsregcmd-Status.txt' ''
    }
    if ($StorageHost) {
        $klist=[string]$evidence['Kerberos-TicketMetadata']
        if ($klist -ne '' -and $klist -notmatch '(?i)cifs/') {
            Add-Finding 'Info' 'Storage' "No Kerberos cifs ticket for $StorageHost in the invoking context" @('klist output contains no cifs/ service tickets') 'Azure Files Kerberos mounts need a cifs service ticket; its absence in this context hints at identity, Kerberos, or session-key configuration issues.' @('In the affected user session, run klist (and klist cloud_debug) without elevation to check for cifs tickets','Review CloudKerberos-Status.txt and your Azure Files identity configuration') 'Kerberos-TicketMetadata.txt' ''
        }
    }
}
Invoke-Analyzer 'FSLogix' {
    $frxsvc=$null
    foreach ($svc in @($evidence['Services'])) { if ($null -ne $svc -and $svc.Name -eq 'frxsvc') { $frxsvc=$svc } }
    if ($null -ne $frxsvc -and $frxsvc.State -ne 'Running') {
        Add-Finding 'Critical' 'FSLogix' "FSLogix service (frxsvc) is $($frxsvc.State)" @("Win32_Service: frxsvc State=$($frxsvc.State) StartMode=$($frxsvc.StartMode)") 'FSLogix profile loading fails when its service is not running; users get local or temporary profiles.' @('Start frxsvc and watch whether it stays running; investigate the tailed FSLogix logs in this bundle','Reinstall or repair FSLogix if the service keeps stopping') 'Services.json' 'https://learn.microsoft.com/azure/virtual-desktop/fslogix-troubleshoot'
    }
    $fxEnabled=Get-Val 'FSLogixConfiguration' 'Enabled'
    $fxVhdLocations=Get-Val 'FSLogixConfiguration' 'VHDLocations'
    if ("$fxEnabled" -eq '1' -and "$fxVhdLocations" -eq '') {
        Add-Finding 'Critical' 'FSLogix' 'FSLogix enabled but VHDLocations is empty' @('HKLM:\SOFTWARE\FSLogix\Profiles Enabled=1; VHDLocations is empty') 'With FSLogix enabled and no profile container location configured, profile containers cannot attach.' @('Set VHDLocations to your profile share (typically via GPO or Intune)','Confirm the host can resolve and reach the profile share') 'FSLogixConfiguration.json' 'https://learn.microsoft.com/azure/virtual-desktop/fslogix-troubleshoot'
    }
    $fxDeleteLocal=Get-Val 'FSLogixConfiguration' 'DeleteLocalProfileWhenVHDShouldApply'
    if ("$fxDeleteLocal" -eq '1') {
        Add-Finding 'Warning' 'FSLogix' 'DeleteLocalProfileWhenVHDShouldApply=1' @('HKLM:\SOFTWARE\FSLogix\Profiles DeleteLocalProfileWhenVHDShouldApply=1') 'This setting deletes the matching local profile when a profile VHD should apply - a known data-loss risk when containers are unreachable.' @('Confirm this setting is intentional; Microsoft documents using it only with a migration plan','Verify profile containers are reachable before users sign in') 'FSLogixConfiguration.json' ''
    }
    $fxPreventFail=Get-Val 'FSLogixConfiguration' 'PreventLoginWithFailure'
    $fxPreventTemp=Get-Val 'FSLogixConfiguration' 'PreventLoginWithTempProfile'
    if ("$fxEnabled" -eq '1' -and ("$fxPreventFail" -ne '1' -or "$fxPreventTemp" -ne '1')) {
        Add-Finding 'Info' 'FSLogix' 'Temporary-profile guards not enabled' @('PreventLoginWithFailure and/or PreventLoginWithTempProfile are not set to 1') 'Without these guards, users can sign in with temporary profiles when container attach fails, which hides the failure and risks data loss.' @('Consider enabling both guards so a failed profile attach blocks sign-in instead of creating a temporary profile') 'FSLogixConfiguration.json' ''
    }
    $fxEvents=@((@($evidence['Events-Microsoft-FSLogix-Apps_Admin']) + @($evidence['Events-Microsoft-FSLogix-Apps_Operational'])) | Where-Object { $null -ne $_ -and $_.PSObject.Properties['LevelDisplayName'] -and $_.LevelDisplayName -in @('Error','Warning') })
    if ($fxEvents.Count -gt 0) {
        $fxEvLines=@()
        foreach ($ev in ($fxEvents | Select-Object -First 3)) { $fxEvLines += "[$($ev.TimeCreated)] ID=$($ev.Id): $(TrimText $ev.Message 90)" }
        Add-Finding 'Warning' 'FSLogix' "$($fxEvents.Count) FSLogix Error/Warning event(s) in the last $LookbackHours hours" $fxEvLines 'FSLogix reported errors or warnings during the window; read them together with the tailed FSLogix logs.' @('Review Events-Microsoft-FSLogix-Apps_*.json and the FSLogixLogs-*.txt tails','Common patterns: container not found, VHD(X) attach failure, permissions on the profile share') '' 'https://learn.microsoft.com/azure/virtual-desktop/fslogix-troubleshoot'
    }
}
Invoke-Analyzer 'Storage' {
    $tcp445=@($evidence['StorageTCP445'] | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Connected'] })
    $tcp445Failed=($tcp445.Count -gt 0 -and -not ($tcp445 | Where-Object { $_.Connected })) -or ((Get-Status 'StorageTCP445') -eq 'Error')
    if ($tcp445Failed) {
        Add-Finding 'Critical' 'Storage' "TCP 445 to $StorageHost failed" @("TCP connect to ${StorageHost}:445 did not succeed (see the StorageTCP445 row)") 'Azure Files SMB traffic requires outbound TCP 445; a failed connect means profile containers on that storage account cannot mount.' @('Check NSG/firewall/on-premises egress allows TCP 445 to the storage account endpoint','Confirm the storage account firewall allows this host/subnet','Verify DNS resolution (StorageDNS.json)') 'StorageTCP445.json' ''
    }
    if ((Get-Status 'ShareAccess') -eq 'Error') {
        Add-Finding 'Warning' 'Storage' 'Share not readable in the invoking context' @('ShareAccess check returned an error; see ShareAccess.txt') 'The share could not be read from this elevated context - permissions, Kerberos, or connectivity are candidates.' @('Read ShareAccess.txt for the exact error','Re-run with -SharePath on the affected host; note this does not validate the affected user or profile write permissions') 'ShareAccess.txt' ''
    }
    $smb=@($evidence['SMBConnections'] | Where-Object { $null -ne $_ })
    if ($smb.Count -eq 0) {
        Add-Finding 'Info' 'Storage' 'No active SMB connections at collection time' @('Get-SmbConnection returned no rows') 'No SMB sessions existed while collecting; expected on an idle host, but notable if a user session with FSLogix was active.' @('If users with FSLogix profiles were signed in, an empty list suggests containers are not mounting') 'SMBConnections.json' ''
    }
}

Invoke-Analyzer 'Shortpath' {
    $fClientDisableUDP=Get-Val 'RDPPolicyEvidence' 'fClientDisableUDP'
    if ("$fClientDisableUDP" -eq '1') {
        Add-Finding 'Warning' 'Session' 'Client UDP disabled by policy (fClientDisableUDP=1)' @('Terminal Services policy: fClientDisableUDP=1') 'RDP over UDP (including Shortpath transport candidates) is disabled client-side by policy; connections fall back to TCP.' @('If UDP is intended, set fClientDisableUDP=0 or remove the policy','Review RDPPolicyEvidence.json for the other transport policy values') 'RDPPolicyEvidence.json' ''
    }
    $fUdpRedirector=Get-Val 'RDPPolicyEvidence' 'fUseUdpPortRedirector'
    $udpPortNumber=Get-Val 'RDPPolicyEvidence' 'UdpPortNumber'
    if ("$fUdpRedirector" -eq '1') {
        $portText=if ("$udpPortNumber" -ne '') { "$udpPortNumber" } else { 'not set' }
        Add-Finding 'Info' 'Session' "UDP port redirector enabled (UdpPortNumber=$portText)" @("WinStations policy: fUseUdpPortRedirector=1; UdpPortNumber=$portText") 'The UDP port redirector policy is active; it must match the intended client/transport configuration or UDP connections can fail.' @('Confirm the configured UdpPortNumber matches your design and firewall rules','See RDPPolicyEvidence.json for the raw policy values') 'RDPPolicyEvidence.json' ''
    }
    $qwinsta=[string]$evidence['SessionListeners']
    if ($qwinsta -ne '' -and $qwinsta -notmatch '(?i)rdp-sxs') {
        Add-Finding 'Warning' 'Session' 'AVD reverse-connect listener (rdp-sxs) missing' @('qwinsta output lists no rdp-sxs listener') 'The reverse-connect listener is how AVD brokered clients reach the host; without it, new connections typically fail.' @('Verify the AVD agent and bootloader are running and the host is registered (rdp-sxs appears when the agent registers)','Review SessionListeners.txt') 'SessionListeners.txt' ''
    }
    if ((Get-Status 'STUNConnectivity') -eq 'NotRun') {
        Add-Finding 'Info' 'Network' 'STUN/UDP probe not run' @('STUNConnectivity check skipped: -StunServer was not supplied') 'Without a UDP/STUN probe, direct UDP (Shortpath) reachability over public networks is unverified.' @('Re-run with -StunServer from your approved endpoint list to test UDP Binding reachability','A Binding response does not prove TURN allocation or end-to-end media transport') '' ''
    }
    $udpEvents=@($evidence['Events-Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV_Operational'] | Where-Object { $null -ne $_ -and "$($_.Message)" -match '(?i)udp' })
    if ($udpEvents.Count -gt 0) {
        Add-Finding 'Info' 'Session' "UDP referenced in $($udpEvents.Count) RDP core event(s)" @("RdpCoreCDV operational events mention UDP in the last $LookbackHours hours") 'UDP was at least referenced/negotiated in RDP core traffic during the window.' @('Review Events-Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV_Operational.json transport messages (connection quality and transport upgrade events)') 'Events-Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV_Operational.json' ''
    }
}
Invoke-Analyzer 'Monitoring' {
    $ama=@($evidence['AMAProcess'] | Where-Object { $null -ne $_ })
    if ($ama.Count -eq 0) {
        Add-Finding 'Critical' 'Monitoring' 'Azure Monitor Agent not detected' @('No MonAgentCore process found at collection time') 'Without Azure Monitor Agent the host sends no logs or metrics to Log Analytics; AVD insights and alerts go dark.' @('Install or repair the AzureMonitorWindowsAgent VM extension','Confirm the extension reports provisioning succeeded, then re-run the collector') 'AMAProcess.json' ''
    }
    $dcrCache=@($evidence['AMADCRCacheMetadata'] | Where-Object { $null -ne $_ })
    if ($dcrCache.Count -eq 0) {
        Add-Finding 'Warning' 'Monitoring' 'No AMA configuration (DCR) cache found' @('No AMADataStore mcsconfig cache metadata found') 'A missing DCR cache suggests the agent has not received or processed a Data Collection Rule association.' @('Verify a Data Collection Rule association exists for this host in Azure','Run Test-AVDDCRAssociation.ps1 for authoritative DCR sources/routes/identity') 'AMADCRCacheMetadata.json' ''
    }
    $amaErrFiles=0
    $amaErrLines=@()
    foreach ($evKey in @($evidence.Keys)) {
        if ("$evKey" -like 'AMAExtensionLogs|*') {
            $hits=@(@($evidence[$evKey]) | Where-Object { $null -ne $_ } | Select-String -Pattern '(?i)\berror\b|\bfail(ed|ure)?\b|403|exception')
            if ($hits.Count -gt 0) {
                $amaErrFiles=$amaErrFiles+1
                if ($amaErrLines.Count -lt 3) { foreach ($hit in @($hits | Select-Object -First 2)) { $amaErrLines += TrimText $hit.Line 120 } }
            }
        }
    }
    if ($amaErrFiles -gt 0) {
        Add-Finding 'Warning' 'Monitoring' "AMA extension logs contain error keywords in $amaErrFiles tailed file(s)" $amaErrLines 'Recent extension logs contain error-like keywords; this can be transient (startup noise) or a persistent ingestion/configuration failure.' @('Review the AMAExtensionLogs-*.txt tails in this bundle','Persistent 403/credential errors usually mean managed identity or DCR association problems - run Test-AVDDCRAssociation.ps1') '' ''
    }
    Add-Finding 'Info' 'Monitoring' 'DCR correctness requires Azure-side validation' @('Local evidence only covers agent presence, process, and cache metadata') 'Local checks cannot prove which DCRs should collect data; associations and destinations live in Azure.' @('Run Test-AVDDCRAssociation.ps1 (Azure side) for authoritative DCR sources/routes/identity','Confirm data actually arrives in AVD Insights / Log Analytics') '' ''
}
Invoke-Analyzer 'Session' {
    $systemEvents=@($evidence['Events-System'] | Where-Object { $null -ne $_ })
    $upsEvents=@($systemEvents | Where-Object { $_.PSObject.Properties['ProviderName'] -and $_.ProviderName -eq 'Microsoft-Windows-User Profile Service' -and $_.Id -ge 1500 -and $_.Id -le 1545 })
    if ($upsEvents.Count -gt 0) {
        $upsLines=@()
        foreach ($ev in ($upsEvents | Select-Object -First 3)) { $upsLines += "[$($ev.TimeCreated)] ID=$($ev.Id): $(TrimText $ev.Message 90)" }
        Add-Finding 'Warning' 'Session' "$($upsEvents.Count) User Profile Service event(s) (IDs 1500-1545) in the System log" $upsLines 'Classic profile-load failure events; with FSLogix they often correspond to container attach problems.' @('Correlate timestamps with the FSLogix findings and Events-Microsoft-FSLogix-Apps_*.json','IDs 1511/1519 indicate temporary or missing local profiles; read the full messages in Events-System.json') 'Events-System.json' ''
    }
    $svcFailEvents=@($systemEvents | Where-Object { $_.PSObject.Properties['ProviderName'] -and $_.ProviderName -eq 'Service Control Manager' -and $_.Id -ge 7000 -and $_.Id -le 7046 -and "$($_.Message)" -match '(?i)RDAgent|TermService|frxsvc|Remote Desktop' })
    if ($svcFailEvents.Count -gt 0) {
        $svcFailLines=@()
        foreach ($ev in ($svcFailEvents | Select-Object -First 3)) { $svcFailLines += "[$($ev.TimeCreated)] ID=$($ev.Id): $(TrimText $ev.Message 90)" }
        Add-Finding 'Warning' 'Session' "$($svcFailEvents.Count) service-failure event(s) affecting AVD components" $svcFailLines 'AVD-related services failed or crashed during the window; correlates with connection drops.' @('Cross-check Services.json and the AVD agent findings; recurring crashes usually need reinstall or configuration fixes') 'Events-System.json' ''
    }
    $lsmEvents=@($evidence['Events-Microsoft-Windows-TerminalServices-LocalSessionManager_Operational'] | Where-Object { $null -ne $_ })
    $logonCount=@($lsmEvents | Where-Object { $_.Id -in @(21,22) }).Count
    $disconnectCount=@($lsmEvents | Where-Object { $_.Id -in @(24,39,40) }).Count
    if (($logonCount + $disconnectCount) -gt 0) {
        Add-Finding 'Info' 'Session' "Session activity: $logonCount logon(s), $disconnectCount disconnect-type event(s) in the last $LookbackHours hours" @("LocalSessionManager events captured: $($lsmEvents.Count)") 'Context for logon-failure investigations; compare these timestamps with error events.' @('If logons fail before reaching the host, check AVD service-side connection diagnostics; OS logon failure auditing (Security 4625) is in the Security channel, which this bundle does not collect') 'Events-Microsoft-Windows-TerminalServices-LocalSessionManager_Operational.json' ''
    }
    $w32tm=[string]$evidence['TimeSynchronization']
    if ($w32tm -match '(?i)leap indicator:\s*(2|3)|not synchronized|free-running') {
        Add-Finding 'Warning' 'Network' 'Host clock not synchronized' @(TrimText $w32tm 160) 'Kerberos - and therefore SMB to Azure Files - breaks when clock skew exceeds roughly five minutes; broker heartbeats also degrade.' @('Fix the w32tm configuration and check VM guest time synchronization settings') 'TimeSynchronization.txt' ''
    }
    foreach ($disk in @($evidence['Disks'] | Where-Object { $null -ne $_ -and $_.PSObject.Properties['FreePct'] -and $null -ne $_.FreePct })) {
        if ([double]$disk.FreePct -lt 10) {
            Add-Finding 'Warning' 'System' "Low disk space on $($disk.DeviceID) ($($disk.FreePct)% free)" @("$($disk.DeviceID) FreeGB=$($disk.FreeGB) of SizeGB=$($disk.SizeGB)") 'Low disk breaks FSLogix VHD temp copies, updates, and profile writes.' @('Free space or expand the disk; review pagefile, dumps, and temp files') 'Disks.json' ''
        }
    }
    $companionFails=@($evidence['LocalMonitoringChecks'] | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Status'] -and "$($_.Status)" -in @('Fail','Error') })
    if ($companionFails.Count -gt 0) {
        $companionLines=@()
        foreach ($row in ($companionFails | Select-Object -First 3)) { $companionLines += "$($row.Check): $(TrimText $row.Details 90)" }
        Add-Finding 'Warning' 'Monitoring' "Test-AVDSessionHostMonitoring reported $($companionFails.Count) Fail/Error row(s)" $companionLines 'The companion read-only checker found failing local monitoring checks on this host.' @('Review LocalMonitoringChecks.json rows and follow the per-check guidance') 'LocalMonitoringChecks.json' ''
    }
}

if ($findings.Count -gt 0) {
    ConvertTo-Json -InputObject $findings.ToArray() -Depth 8 | Set-Content -LiteralPath (Join-Path $bundle 'findings.json') -Encoding UTF8
} else {
    '[]' | Set-Content -LiteralPath (Join-Path $bundle 'findings.json') -Encoding UTF8
}
$findingCritical=@($findings | Where-Object { $_.Severity -eq 'Critical' }).Count
$findingWarning=@($findings | Where-Object { $_.Severity -eq 'Warning' }).Count
$findingInfo=@($findings | Where-Object { $_.Severity -eq 'Info' }).Count
Record 'Findings' 'Collected' "$($findings.Count) flagged issue(s): $findingCritical critical, $findingWarning warning, $findingInfo info - see findings.json and the Flagged issues section of Report.html." 'findings.json'
#endregion
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Encoding UTF8
Compress-Archive -LiteralPath $bundle -DestinationPath $zip -ErrorAction Stop

#region HTML Report
$collected = @($manifest | Where-Object { $_.Status -eq 'Collected' }).Count
$noData = @($manifest | Where-Object { $_.Status -eq 'NoData' }).Count
$notRun = @($manifest | Where-Object { $_.Status -in @('NotRun','NotPresent','NeedsUserContext','NeedsAzureCheck','NotTested','Info') }).Count
$errored = @($manifest | Where-Object { $_.Status -in @('Error','Timeout','Inconclusive') }).Count
$findingCritical=@($findings | Where-Object { $_.Severity -eq 'Critical' }).Count
$findingWarning=@($findings | Where-Object { $_.Severity -eq 'Warning' }).Count
$findingInfo=@($findings | Where-Object { $_.Severity -eq 'Info' }).Count

$categoryMap = @{
    'Machine-OS'='System';'InvokingContext'='System';'InstalledComponents'='System';'Services'='System';'Disks'='System'
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
    'Findings'='Analysis';'HTMLReport'='Analysis'
}

$rows = ''
foreach ($m in $manifest) {
    $cat = if ($categoryMap.ContainsKey($m.Check)) { $categoryMap[$m.Check] } else {
        if ($m.Check -like 'Events-*') { 'Events' } elseif ($m.Check -like 'Analysis-*') { 'Analysis' } else { 'Other' }
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

$findingCards = ''
foreach ($f in $findings) {
    $sevClass = switch ($f.Severity) { 'Critical' { 'crit' } 'Warning' { 'warn' } default { 'info' } }
    $encTitle = [System.Net.WebUtility]::HtmlEncode($f.Title)
    $encCat = [System.Net.WebUtility]::HtmlEncode($f.Category)
    $encInterp = [System.Net.WebUtility]::HtmlEncode($f.Interpretation)
    $evItems = (@($f.Evidence) | ForEach-Object { '<li>' + [System.Net.WebUtility]::HtmlEncode([string]$_) + '</li>' }) -join ''
    $nsItems = (@($f.NextSteps) | ForEach-Object { '<li>' + [System.Net.WebUtility]::HtmlEncode([string]$_) + '</li>' }) -join ''
    $links = ''
    if ($f.File) { $links += "Evidence file: <a href='$([System.Net.WebUtility]::HtmlEncode($f.File))'>$([System.Net.WebUtility]::HtmlEncode($f.File))</a>" }
    if ($f.Reference) { $links += " &middot; Reference: <a href='$([System.Net.WebUtility]::HtmlEncode($f.Reference))' target='_blank' rel='noopener'>Microsoft Learn</a>" }
    $findingCards += "<details class='finding' data-sev='$sevClass' data-cat='$encCat'><summary><span class='badge $sevClass'>$($f.Severity)</span> <span class='ftitle'>$encTitle</span> <span class='fcat'>$encCat</span></summary><div class='fbody'><div class='fsec'>Observed evidence</div><ul class='flist'>$evItems</ul><div class='fsec'>Likely meaning</div><p class='finterp'>$encInterp</p><div class='fsec'>Suggested next steps</div><ol class='flist'>$nsItems</ol><div class='flinks'>$links</div></div></details>`n"
}
$findingsBlock = if ($findingCards) { $findingCards } else { "<div class='no-findings'>No issues flagged by the local heuristics. This is not a health verdict - review the evidence inventory below.</div>" }

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
  .card.info2 .num { color:#58a6ff; }
  .badge.crit { background:#b62324; color:#fff; }
  .finding { background:#161b22; border:1px solid #30363d; border-left:4px solid #6e7681; border-radius:8px; margin-bottom:8px; }
  .finding[data-sev="crit"] { border-left-color:#f85149; }
  .finding[data-sev="warn"] { border-left-color:#d29922; }
  .finding[data-sev="info"] { border-left-color:#1f6feb; }
  .finding summary { padding:12px 14px; cursor:pointer; display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
  .finding summary::before { content:'\25B8'; color:#8b949e; }
  .finding[open] summary::before { content:'\25BE'; }
  .finding summary::-webkit-details-marker { display:none; }
  .ftitle { color:#c9d1d9; font-size:0.9rem; font-weight:600; }
  .fcat { color:#8b949e; font-size:0.72rem; border:1px solid #30363d; padding:1px 8px; border-radius:10px; }
  .fbody { padding:0 16px 14px 16px; }
  .fsec { font-size:0.72rem; color:#8b949e; text-transform:uppercase; letter-spacing:0.5px; margin:10px 0 4px; }
  .flist { margin-left:20px; }
  .flist li { font-size:0.85rem; color:#c9d1d9; margin-bottom:4px; word-break:break-word; }
  .finterp { font-size:0.85rem; color:#c9d1d9; }
  .flinks { font-size:0.75rem; margin-top:10px; color:#8b949e; }
  .flinks a { color:#58a6ff; text-decoration:none; }
  .flinks a:hover { text-decoration:underline; }
  .no-findings { color:#8b949e; font-size:0.85rem; background:#161b22; border:1px dashed #30363d; padding:14px; border-radius:8px; }
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
  <div class="card error"><div class="num">$findingCritical</div><div class="label">Critical Flags</div></div>
  <div class="card warn"><div class="num">$findingWarning</div><div class="label">Warning Flags</div></div>
  <div class="card info2"><div class="num">$findingInfo</div><div class="label">Info Notes</div></div>
</div>

<div class="section-title">Flagged issues &mdash; triage findings (heuristics, not health verdicts)</div>
<div class="filters sevfilters">
  <label>SEVERITY:</label>
  <button class="active" onclick="filterSev('all')">All</button>
  <button onclick="filterSev('crit')">Critical</button>
  <button onclick="filterSev('warn')">Warning</button>
  <button onclick="filterSev('info')">Info</button>
</div>
<div id="findings">$findingsBlock</div>

<div class="section-title">Evidence inventory &mdash; every check</div>

<div class="filters">
  <label>CATEGORY:</label>
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
  <button onclick="filterCat('Analysis')">Analysis</button>
  <input type="text" class="search" placeholder="Search checks..." oninput="searchTable(this.value)">
</div>

<table>
<thead><tr><th>Check</th><th>Category</th><th>Status</th><th>Details</th><th>File</th></tr></thead>
<tbody id="rows">$rows</tbody>
</table>

<p class="footer">Collected means evidence was saved, not that the component is healthy. Flagged issues are local heuristics for triage &mdash; verify before acting on them. Review contents before sharing through your approved support channel.</p>

<script>
function filterCat(cat) {
  document.querySelectorAll('.filters button').forEach(b => b.classList.remove('active'));
  event.target.classList.add('active');
  document.querySelectorAll('#rows tr').forEach(tr => {
    tr.style.display = (cat === 'all' || tr.dataset.cat === cat) ? '' : 'none';
  });
}
function filterSev(sev) {
  document.querySelectorAll('.sevfilters button').forEach(b => b.classList.remove('active'));
  event.target.classList.add('active');
  document.querySelectorAll('#findings .finding').forEach(d => {
    d.style.display = (sev === 'all' || d.dataset.sev === sev) ? '' : 'none';
  });
}
function searchTable(q) {
  var lower = q.toLowerCase();
  document.querySelectorAll('#rows tr').forEach(tr => {
    tr.style.display = tr.textContent.toLowerCase().includes(lower) ? '' : 'none';
  });
  document.querySelectorAll('#findings .finding').forEach(d => {
    d.style.display = d.textContent.toLowerCase().includes(lower) ? '' : 'none';
  });
}
</script>
</body>
</html>
"@

$htmlPath = Join-Path $bundle 'Report.html'
$html | Set-Content -LiteralPath $htmlPath -Encoding UTF8
Record 'HTMLReport' 'Collected' "Interactive HTML report: flagged issues (triage findings) plus a filterable evidence inventory." 'Report.html'
#endregion

[pscustomobject]@{ZipPath=$zip;EvidenceDirectory=$bundle;ReportPath=$htmlPath;Checks=$manifest.Count;Findings=$findings.Count;CriticalFindings=$findingCritical;WarningFindings=$findingWarning;ReviewRequired=@($manifest | Where-Object Status -ne 'Collected').Count}
