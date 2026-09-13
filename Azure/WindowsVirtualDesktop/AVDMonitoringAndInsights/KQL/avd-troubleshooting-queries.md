# Azure Virtual Desktop Troubleshooting Queries

## KQL Queries

## 1. AVD Available Bandwidth Percentiles, 10-Minute Trend

```kusto
// AVD Available Bandwidth Percentiles, 10-Minute Trend
// Shows P90, P50, and P10 estimated available bandwidth in 10-minute intervals.
// Use P50 for the typical connection experience and P10 to identify low-bandwidth periods.

WVDConnectionNetworkData
| summarize
    BWP90 = percentile(EstAvailableBandwidthKBps, 90),
    BWP50 = percentile(EstAvailableBandwidthKBps, 50),
    BWP10 = percentile(EstAvailableBandwidthKBps, 10)
    by bin(TimeGenerated, 10m)
| render timechart with (
    title="AVD Available Bandwidth Percentiles",
    ytitle="Available Bandwidth (KBps)"
)
```

## 2. AVD RTT by Session Host, P95 Above 150 ms

```kusto
// AVD RTT by Session Host, P95 Above 150 ms
// Calculates Avg and P95 estimated round-trip time for each discovered session host.
// Returns only hosts where P95 RTT is above 150 ms.
// Use this to quickly identify session hosts associated with poor network latency.

let Lookback = 24h;

let Connections =
    WVDConnections
    | where TimeGenerated > ago(Lookback)
    | summarize arg_max(TimeGenerated, SessionHostName, _ResourceId) by CorrelationId
    | project
        CorrelationId,
        SessionHostName,
        HostPoolResourceId = _ResourceId;

WVDConnectionNetworkData
| where TimeGenerated > ago(Lookback)
| join kind=inner Connections on CorrelationId
| extend HostPool = tostring(split(HostPoolResourceId, "/")[-1])
| summarize
    AvgRTT = round(avg(EstRoundTripTimeInMs), 1),
    P95RTT = round(percentile(EstRoundTripTimeInMs, 95), 1),
    Samples = count()
    by HostPool, SessionHostName
| where P95RTT > 150
| order by P95RTT desc
```

## 3. AVD Network Latency, RTT Summary for the Last 7 Days

```kusto
// AVD Network Latency, RTT Summary for the Last 7 Days
// Measures estimated round-trip latency across AVD connections.
// Shows Average, P50, and P95 RTT in milliseconds.
// Use P50 to understand the typical user experience.
// Use P95 to identify intermittent latency or poor-performing connection paths.

WVDConnectionNetworkData
| where TimeGenerated > ago(7d)
| summarize
    AvgRTT = round(avg(EstRoundTripTimeInMs), 1),
    P50RTT = round(percentile(EstRoundTripTimeInMs, 50), 1),
    P95RTT = round(percentile(EstRoundTripTimeInMs, 95), 1)
| render columnchart with (
    kind=unstacked
)
```

## 4. AVD Logon Duration by Host Pool, Seconds

```kusto
// AVD Logon Duration by Host Pool, Seconds
// Measures Started → Connected connection establishment time.
// Shows connection count plus Avg, P50, P95, and Max logon duration.
// Use P95 and Max to identify slow host pools and extreme outliers.
// Note: This measures AVD connection establishment, not full Windows desktop-ready time.

let Lookback = 7d;

WVDConnections
| where TimeGenerated > ago(Lookback)
| where State == "Started"
| project
    CorrelationId,
    StartTime = TimeGenerated,
    _ResourceId
| join kind=inner (
    WVDConnections
    | where TimeGenerated > ago(Lookback)
    | where State == "Connected"
    | project
        CorrelationId,
        ConnectedTime = TimeGenerated
) on CorrelationId
| extend LogonDurationSec =
    datetime_diff("millisecond", ConnectedTime, StartTime) / 1000.0
| where LogonDurationSec >= 0
| parse _ResourceId with
    "/subscriptions/" Subscription
    "/resourcegroups/" ResourceGroup
    "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
| summarize
    Connections = count(),
    AvgLogonSec = round(avg(LogonDurationSec), 1),
    P50LogonSec = round(percentile(LogonDurationSec, 50), 1),
    P95LogonSec = round(percentile(LogonDurationSec, 95), 1),
    MaxLogonSec = round(max(LogonDurationSec), 1)
    by ResourceGroup, HostPool
| order by P95LogonSec desc
| project
    HostPool,
    Connections,
    AvgLogonSec,
    P50LogonSec,
    P95LogonSec,
    MaxLogonSec
| render columnchart with (
    kind=unstacked,
    xcolumn=HostPool,
    ycolumns=AvgLogonSec, P50LogonSec, P95LogonSec, MaxLogonSec,
    title="AVD Logon Duration by Host Pool",
    xtitle="Host Pool",
    ytitle="Logon Duration (Seconds)"
)
```

## 5. AVD Agent Health Status, Latest Report per Session Host

```kusto
// AVD Agent Health Status, Latest Report per Session Host
// Shows the most recent AVD agent health record within the selected lookback period.
// Includes agent status, version, last heartbeat, report age, and health check results.
// Note: This is AVD agent telemetry, not Azure Monitor Agent (AMA) Heartbeat.
// Hosts with no recent agent report will not appear here, compare against Azure host pool inventory to identify missing hosts.

let Lookback = 48h;
let HostPoolResourceId = "";

union isfuzzy=true
    (datatable(
        TimeGenerated:datetime,
        _ResourceId:string,
        SessionHostName:string,
        Status:string,
        AgentVersion:string,
        LastHeartBeat:datetime,
        SessionHostHealthCheckResult:dynamic
    )[]),
    WVDAgentHealthStatus
| where TimeGenerated > ago(Lookback)
| where isempty(HostPoolResourceId) or _ResourceId =~ HostPoolResourceId
| summarize arg_max(TimeGenerated, *) by _ResourceId, SessionHostName
| project
    TimeGenerated,
    SessionHostName,
    Status,
    AgentVersion,
    LastHeartBeat,
    ReportAge = now() - TimeGenerated,
    SessionHostHealthCheckResult,
    _ResourceId
| order by SessionHostName asc
```

## 6. AMA Heartbeat Verification, Confirm Session Host Is Reporting

```kusto
// AMA Heartbeat Verification, Confirm Session Host Is Reporting
// Checks whether the selected AVD session host has sent Azure Monitor Agent heartbeat records in the last 24 hours.
// Returns the total heartbeat records, first observed heartbeat, and most recent heartbeat.
// Use this to validate AMA connectivity and Log Analytics ingestion.
// Note: This does not confirm AVD Agent health, use WVDAgentHealthStatus separately for that.

Heartbeat
| where TimeGenerated > ago(24h)
| where Computer contains "WPNS-AVD-0"
| summarize
    Records = count(),
    FirstSeen = min(TimeGenerated),
    LastSeen = max(TimeGenerated)
    by Computer, _ResourceId
```

## 7. AVD Memory Pressure, Available Memory by Session Host

```kusto
// AVD Memory Pressure, Available Memory by Session Host
// Tracks available memory for each discovered AVD session host over the selected lookback period.
// Shows both average and minimum available memory in 5-minute intervals.
// Use MinAvailableMB to identify memory pressure, spikes, or hosts approaching resource exhaustion.
// Note: This query relies on Perf counter ingestion and only shows hosts reporting the Memory\Available MBytes counter.

let Lookback = 24h;
let BinSize = 5m;

union isfuzzy=true
    (datatable(
        TimeGenerated:datetime,
        Computer:string,
        ObjectName:string,
        CounterName:string,
        CounterValue:real
    )[]),
    Perf
| where TimeGenerated > ago(Lookback)
| where ObjectName =~ "Memory"
| where CounterName =~ "Available MBytes"
| summarize
    AvgAvailableMB = avg(CounterValue),
    MinAvailableMB = min(CounterValue)
    by bin(TimeGenerated, BinSize), Computer
| order by TimeGenerated asc
| render timechart with (
    title="AVD Available Memory",
    ytitle="Available Memory (MB)"
)
```

## 8. Log Analytics Ingestion Volume by Table

```kusto
// Log Analytics Ingestion Volume by Table, Chart View
// Shows which tables are consuming the most Log Analytics ingestion capacity.
// Helps identify high-volume tables and potential opportunities to optimize DCRs and monitoring cost.
// Results are displayed directly as a bar chart in GB.

Usage
| summarize
    VolumeGB = round(sum(Quantity) / 1.E3, 3)
    by Table = DataType
| sort by VolumeGB desc
| render barchart with (
    title="Log Analytics Ingestion Volume by Table",
    ytitle="Volume (GB)"
)
```

## 9. AVD Transport Verification, TCP vs RDP Shortpath

```kusto
// AVD Transport Verification
// Shows whether each connected AVD session is using TCP, Private Shortpath, STUN, or TURN.
// Use this before and after a reconnect to verify that RDP Shortpath was successfully negotiated.

WVDConnections
| where TimeGenerated > ago(30m)
| where State == "Connected"
| extend UdpUse = toint(UdpUse)
| extend Transport = case(
    UdpUse == 1, "UDP - Shortpath Private",
    UdpUse == 2, "UDP - Shortpath STUN",
    UdpUse == 4, "UDP - Shortpath TURN",
    "TCP"
)
| project
    TimeGenerated,
    UserName,
    SessionHostName,
    Transport,
    UdpUse,
    CorrelationId
| order by TimeGenerated desc
```

## 10. TCP vs RDP Shortpath RTT Comparison

```kusto
// TCP vs RDP Shortpath RTT Comparison
// Correlates AVD connection transport with RTT measurements.
// Compares Avg, P50, and P95 latency between TCP and UDP Shortpath sessions.
// Use this to demonstrate the network impact of RDP Shortpath.

let Connections =
    WVDConnections
    | where TimeGenerated > ago(1h)
    | where State == "Connected"
    | extend UdpUse = toint(UdpUse)
    | extend Transport = case(
        UdpUse == 1, "UDP Shortpath Private",
        UdpUse == 2, "UDP Shortpath STUN",
        UdpUse == 4, "UDP Shortpath TURN",
        "TCP"
    )
    | project CorrelationId, Transport;

WVDConnectionNetworkData
| where TimeGenerated > ago(1h)
| join kind=inner Connections on CorrelationId
| summarize
    AvgRTT = round(avg(EstRoundTripTimeInMs), 1),
    P50RTT = round(percentile(EstRoundTripTimeInMs, 50), 1),
    P95RTT = round(percentile(EstRoundTripTimeInMs, 95), 1),
    Samples = count()
    by Transport
| order by P95RTT desc
| render columnchart with (
    kind=unstacked,
    xcolumn=Transport,
    ycolumns=AvgRTT, P50RTT, P95RTT,
    title="TCP vs RDP Shortpath RTT",
    xtitle="Transport",
    ytitle="RTT (ms)"
)
```

## PowerShell Checks

## 11. Check Session Host RDP Transport Policy

```powershell
# Check Session Host RDP Transport Policy
# SelectTransport = 1 means TCP only.
# SelectTransport = 2 means UDP or TCP.
# A missing value means the default behavior applies.

Get-ItemProperty `
"HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" `
-Name SelectTransport `
-ErrorAction SilentlyContinue
```

## 12. Check Client UDP Policy

```powershell
# Check Client UDP Policy
# fClientDisableUDP = 1 disables UDP.
# 0 or a missing value means UDP is allowed.

Get-ItemProperty `
"HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client" `
-Name fClientDisableUDP `
-ErrorAction SilentlyContinue
```

## 13. Verify RDP Shortpath UDP 3390 Listener

```powershell
# Verify RDP Shortpath UDP Listener
# Confirms that the Session Host is listening on UDP port 3390.
# This check applies to managed/private network Shortpath scenarios.

Get-NetUDPEndpoint |
Where-Object LocalPort -eq 3390
```

## 14. Check RDP and Shortpath Firewall Rules

```powershell
# Check RDP / Shortpath Firewall Rules
# Displays Remote Desktop and Shortpath-related firewall rules.
# Use this to confirm that the required UDP path is not blocked by Windows Firewall.

Get-NetFirewallRule |
Where-Object DisplayName -Match "Shortpath|Remote Desktop" |
Select-Object DisplayName, Enabled, Direction, Action
```
