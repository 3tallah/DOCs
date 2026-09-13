# AVD KQL Pack

> **Corrected and verified.** [`AVD_KQL_Pack.txt`](AVD_KQL_Pack.txt) was a draft in which all six queries failed: the headings used SQL comment syntax and several tables and columns did not exist. It has been rewritten against the current Azure Monitor AVD schema. All six queries were executed against Log Analytics workspace `LAW-WPNS-AVD` on 2026-09-11 and every one returned rows. The original defects are kept in [Appendix: original queries and their defects](#appendix-original-queries-and-their-defects).

## Queries


| # | Query                                                                   | Primary tables                               |
| - | ----------------------------------------------------------------------- | -------------------------------------------- |
| 1 | Connection attempts, failures and failure rate by session host and user | `WVDConnections`, `WVDErrors`                |
| 2 | Network round-trip time and transport by session host                   | `WVDConnectionNetworkData`, `WVDConnections` |
| 3 | Session lifecycle, including reconnects                                 | `WVDConnections`                             |
| 4 | Agent version and last report per session host                          | `WVDAgentHealthStatus`                       |
| 5 | Logon duration distribution                                             | `WVDConnections`                             |
| 6 | Session host CPU and memory                                             | `Perf`                                       |

Each query is self-contained and declares its own `let Lookback = 7d;`, so cost and runtime do not depend on the portal time picker. Run one query at a time; a blank line is not a reliable batch separator in every client.

## Usage

Open the workspace in **Logs**, set the mode selector to **KQL**, paste a single query and run it. Adjust `Lookback` at the top of the query rather than relying on the time-range control.

Comments use `//`. Do not reintroduce `--`: in supported Kusto editors a leading `--` signals T-SQL and the query fails to parse before any table is evaluated.

## Verification

Executed against `LAW-WPNS-AVD` on 2026-09-11 with a 7-day lookback, reading each query straight from the file:


| Query                                   | Result | Rows |
| --------------------------------------- | ------ | ---- |
| 1 Connection attempts and failure rate  | Pass   | 15   |
| 2 Network round-trip time and transport | Pass   | 21   |
| 3 Session lifecycle                     | Pass   | 43   |
| 4 Agent version and last report         | Pass   | 2    |
| 5 Logon duration distribution           | Pass   | 14   |
| 6 Session host CPU and memory           | Pass   | 1153 |

Row counts reflect one host pool with light activity and are not a correctness target in another environment. A 24-hour lookback returned zero rows for queries 1, 2, 3 and 5 in the same workspace, because the most recent connection telemetry was two days old. Zero rows usually means no activity in the window, not a broken query; confirm with the table census below.

## Required Data

Service-side AVD diagnostics populate these tables, and only these. There is no `WVDEvents`; it is not a real table name and no diagnostic setting creates one.

| Table | Emitted by |
| --- | --- |
| `WVDConnections` | Host pool, application group, workspace |
| `WVDCheckpoints` | Host pool, application group, workspace |
| `WVDErrors` | Host pool, application group, workspace |
| `WVDManagement` | Host pool, application group, workspace |
| `WVDFeeds` | Workspace |
| `WVDConnectionNetworkData` | Host pool |
| `WVDConnectionGraphicsDataPreview` | Host pool |
| `WVDHostRegistrations` | Host pool |
| `WVDAgentHealthStatus` | Host pool |
| `WVDSessionHostManagement` | Host pool |
| `WVDMultiLinkAdd` | Host pool |

Guest operating-system performance comes from `Perf` via Azure Monitor Agent, not from any AVD diagnostic table. Configure host-pool diagnostic settings and guest collection before querying.

Confirm what is actually flowing, and how recent it is, before trusting any result:

```kusto
union withsource=TableName isfuzzy=true
    WVDConnections,
    WVDCheckpoints,
    WVDErrors,
    WVDAgentHealthStatus,
    WVDConnectionNetworkData,
    WVDManagement,
    Perf
| where TimeGenerated > ago(30d)
| summarize Rows = count(), LastRecord = max(TimeGenerated) by TableName
| order by TableName asc
```

## Appendix: original queries and their defects

> **Do not run the queries in this appendix.** Every one of them fails. They are kept only as a record of what was corrected. The queries you want are in [`AVD_KQL_Pack.txt`](AVD_KQL_Pack.txt), listed under [Queries](#queries).

Kept as a record of what was corrected, and because the same mistakes recur in AVD query samples found online.

### Critical syntax issue

KQL line comments use `//`, not `--`. In supported Kusto editors a leading `--` indicates T-SQL input, so each original heading stopped the query parsing before any table was evaluated.

All six headings in the original file began with `--`. Confirmed in the Azure Monitor Logs query editor in KQL mode, pasting the original query 1 returned:

```text
A syntax error has been identified in the query. Query could not be parsed at '-' on line [1,2]
Token: -
Line: 1
Position: 2
```

Because it failed at the comment character, the remaining defects in that query stayed hidden until the heading was fixed.

The blocks below are the original queries, with their `--` headings shown as `//` because a KQL-aware formatter rewrites `--` inside code fences in this file. They are tagged as plain text because none of them ran. Line numbers refer to the original file, not the current one.

### Connections and failures

Original lines 1-5:

```text
// Connections, failures, and failure rate by host/user
WVDConnections
| summarize Attempts=count(), Failures=sumif(1, State=="Failed"), FailureRate=100.0*sumif(1, State=="Failed")/count()
  by SessionHostName, UserName, TransportProtocol, ClientOS, ClientVersion, bin(TimeGenerated, 1h)
| order by FailureRate desc
```

`WVDConnections` is a current table, but its transport column is `TransportType`, not `TransportProtocol`. Connection lifecycle rows commonly use states such as `Started`, `Connected` and `Completed`; current Microsoft error examples join `WVDErrors` by `CorrelationId` rather than counting `State == "Failed"`.

This query has three independent defects, and each one hides the next. Confirmed in the Azure Monitor Logs query editor:

1. The `--` heading stops it parsing: `Query could not be parsed at '-' on line [1,2]`.
2. With the heading corrected, the column fails to resolve: `'summarize' operator: Failed to resolve scalar expression named 'TransportProtocol'`.
3. Renaming that column to `TransportType` makes the query run, but `State == "Failed"` matches nothing, so every row returns `Failures = 0` and `FailureRate = 0`. That is the dangerous case: a clean result set that is silently wrong. The workspace holds only `Completed`, `Started` and `Connected`.

Now query 1 in the pack, which counts one attempt per `CorrelationId` and derives failures from `WVDErrors`. See also [AVD-Connections.kql](AVD-Connections.kql) and [AVD-ConnectionFailures.kql](AVD-ConnectionFailures.kql).

### Network RTT

Original lines 7-11:

```text
// Network RTT & transport
WVDEvents
| where EventName == "NetworkData"
| summarize avg_RTT_ms=avg(RoundTripTimeMs), anyTransport=any(TransportProtocol) by SessionHostName, bin(TimeGenerated, 1h)
| order by avg_RTT_ms desc
```

Current network samples are in `WVDConnectionNetworkData`, with `EstRoundTripTimeInMs` and `EstAvailableBandwidthKBps`. Network rows are correlated to `WVDConnections` through `CorrelationId`; they do not directly contain host, user or transport columns.

Confirmed in the Azure Monitor Logs query editor. With the heading corrected to `//` so the query parses, it fails at the table name:

```text
'where' operator: Failed to resolve table or column expression named 'WVDEvents'
```

The same table error applies to the disconnect/reconnect and host utilization queries.

Now query 2 in the pack. What changed:


| Concern                  | Original                           | Corrected                                                                 |
| ------------------------ | ---------------------------------- | ------------------------------------------------------------------------- |
| Table                    | `WVDEvents`, which does not exist  | `WVDConnectionNetworkData`                                                |
| RTT column               | `RoundTripTimeMs`                  | `EstRoundTripTimeInMs`                                                    |
| Host, user and transport | Assumed present on the network row | Joined from`WVDConnections` on `CorrelationId`                            |
| Row multiplication       | Not considered                     | `arg_max` collapses to one connection row per correlation before the join |
| Lookback                 | Portal time picker only            | `let Lookback = 7d;`                                                      |

See also [AVD-NetworkData.kql](AVD-NetworkData.kql), which adds an empty-table guard and a host pool filter, and [AVD-RDPShortpath.kql](AVD-RDPShortpath.kql).

### Disconnect and reconnect

Original lines 13-17:

```text
// Disconnect/Reconnect patterns
WVDEvents
| where EventName in ("Disconnected","Reconnected","Logoff")
| summarize Events=count() by UserName, SessionHostName, EventName, bin(TimeGenerated, 1h)
| order by Events desc
```

The documented schema does not include `WVDEvents` or the proposed `EventName` values. `WVDConnections.PredecessorConnectionId` identifies automatic reconnect relationships; broader disconnect analysis requires a documented lifecycle/error correlation.

Now query 3 in the pack, which reports lifecycle `State` and flags auto-reconnects. See also [AVD-Connections.kql](AVD-Connections.kql) and [AVD-Errors.kql](AVD-Errors.kql).

### Agent versions

Original lines 19-22:

```text
// Agent versions & last seen
WVDCheckpoints
| summarize LastSeen=max(TimeGenerated) by SessionHostName, AgentVersion, SxSStackVersion
| order by LastSeen asc
```

`WVDCheckpoints` contains checkpoint `Name`, `Source`, `Parameters` and `CorrelationId`; it does not expose `SessionHostName`, `AgentVersion` or `SxSStackVersion`. Use `WVDAgentHealthStatus` for current agent-health/version fields.

Confirmed in the workspace:

```text
'summarize' operator: Failed to resolve scalar expression named 'SessionHostName'
```

KQL stops at the first unresolved name, so correcting `SessionHostName` alone would only surface `AgentVersion` next. All three are absent. Read from the workspace with `getschema`:

| Table | Columns |
| --- | --- |
| `WVDCheckpoints` | `ActivityType`, `CorrelationId`, `Name`, `Parameters`, `Source`, `SourceSystem`, `TenantId`, `TimeGenerated`, `Type`, `UserName`, `_ResourceId` |
| `WVDAgentHealthStatus` | `ActiveSessions`, `AgentVersion`, `AllowNewSessions`, `EndpointState`, `InactiveSessions`, `LastHeartBeat`, `LastUpgradeTimeStamp`, `OSVersion`, `OperationName`, `SessionHostHealthCheckResult`, `SessionHostName`, `SessionHostResourceId`, `SourceSystem`, `Status`, `StatusTimeStamp`, `SxSStackVersion`, `TenantId`, `TimeGenerated`, `Type`, `UpgradeErrorMsg`, `UpgradeState`, `_ResourceId` |

Now query 4 in the pack. See also [AVD-AgentHealth.kql](AVD-AgentHealth.kql).

### Logon duration

Original lines 24-29:

```text
// Logon duration distribution
WVDConnections
| where State == 'Connected'
| summarize avgLogonDuration_ms=avg(LogonDurationMs), p95LogonDuration_ms=percentile(LogonDurationMs,95)
  by SessionHostName, bin(TimeGenerated, 1h)
| order by p95LogonDuration_ms desc
```

`WVDConnections` has no `LogonDurationMs` column. Microsoft calculates logon time by joining `Started` and `Connected` rows on `CorrelationId`, optionally joining a `LoadBalancedNewConnection` checkpoint to classify session creation.

Confirmed in the workspace:

```text
'summarize' operator: Failed to resolve scalar expression named 'LogonDurationMs'
```

`WVDConnections | getschema` returns no duration column of any kind:

`AadTenantId`, `ClientIPAddress`, `ClientOS`, `ClientSideIPAddress`, `ClientType`, `ClientVersion`, `ConnectionType`, `CorrelationId`, `GatewayRegion`, `IsClientPrivateLink`, `IsSessionHostPrivateLink`, `PredecessorConnectionId`, `ResourceAlias`, `SessionHostAgentVersion`, `SessionHostAzureVmId`, `SessionHostIPAddress`, `SessionHostJoinType`, `SessionHostName`, `SessionHostOSDescription`, `SessionHostOSVersion`, `SessionHostPoolType`, `SessionHostSessionId`, `SessionHostSxSStackVersion`, `SourceSystem`, `State`, `TenantId`, `TimeGenerated`, `TransportType`, `Type`, `UdpType`, `UdpUse`, `UserName`, `_ResourceId`

That listing also settles two other defects at once: there is no `TransportProtocol`, only `TransportType`.

Now query 5 in the pack, which computes the `Started` to `Connected` gap per `CorrelationId` and drops correlations missing either row rather than counting them as zero. Against this workspace it measured 18 logons on `WPNS-AVD-0`, averaging 10.6 s with a 30.6 s maximum. For per-session logon breakdowns on the host itself, see the [logon-duration analyzer](../PowerShellScripts/README-AVD-Analyze-Logon-Duration.md).

### Host utilization

Original lines 31-35:

```text
// Session host utilization
WVDEvents
| where EventName == 'SessionHostPerformanceData'
| summarize avgCPU=avg(TotalCpuUsage), avgMem=avg(TotalMemoryUsage) by SessionHostName, bin(TimeGenerated, 5m)
| order by avgCPU desc
```

The proposed `SessionHostPerformanceData`, `TotalCpuUsage` and `TotalMemoryUsage` fields are not part of a documented `WVDEvents` table. Use the `Perf` table with explicitly collected CPU, memory and session counters.

Now query 6 in the pack, which reads `Perf` and reports CPU and memory in one result. Note that `Perf.Computer` is the guest hostname and will not always match `SessionHostName`. See also [AVD-CPUByHost.kql](AVD-CPUByHost.kql), [AVD-MemoryByHost.kql](AVD-MemoryByHost.kql) and [AVD-SessionHostPerformance.kql](AVD-SessionHostPerformance.kql).

## Related Queries

The [KQL package](README.md) covers the same ground in more depth, with empty-table guards, optional host pool and user filters, and chart companions:

- [Connections](AVD-Connections.kql), [Connection failures](AVD-ConnectionFailures.kql)
- [Network data](AVD-NetworkData.kql), [RDP Shortpath](AVD-RDPShortpath.kql)
- [Agent health](AVD-AgentHealth.kql)
- [CPU by host](AVD-CPUByHost.kql), [Memory by host](AVD-MemoryByHost.kql)
- [Overall host health](AVD-OverallHostHealth.kql)

Use this pack for a quick six-query sweep; use the package when you need filtering, guards against missing tables, or rendered charts.

## Validation Workflow

Run the table census under [Required Data](#required-data) first, then inspect schemas with `<TableName> | getschema` and validate a small time-bounded sample.

The rewritten pack was validated by reading each query from `AVD_KQL_Pack.txt` and submitting it to the workspace query API, rather than by inspection. Results are in [Verification](#verification). The maintained [AVD-NetworkData.kql](AVD-NetworkData.kql) was run in the same workspace and also returned rows.

Every defect listed below has since been reproduced against the workspace, except `RoundTripTimeMs`, which stays masked because the `WVDEvents` table error fires first. Column claims were checked with `getschema` rather than taken from documentation.

## What Was Fixed


| Original defect                                                                                                                                                                                 | Correction                                                                                    |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Six`--` headings signalled T-SQL. **Confirmed:** parse error at line 1, position 2.                                                                                                             | All comments now use`//`.                                                                     |
| Query 1 used`TransportProtocol`, absent from `WVDConnections`. **Confirmed:** `'summarize' operator: Failed to resolve scalar expression named 'TransportProtocol'`.                            | Uses`TransportType`.                                                                          |
| Query 1 counted`State == "Failed"`, which matches nothing and silently returns zero failures. **Confirmed:** the only states present are `Completed` (20), `Started` (19) and `Connected` (18). | Failures derived by correlating`WVDErrors` on `CorrelationId`.                                |
| Queries 2, 3 and 6 used the nonexistent`WVDEvents`. **Confirmed:** `Failed to resolve table or column expression named 'WVDEvents'`.                                                            | `WVDConnectionNetworkData`, `WVDConnections` and `Perf` respectively.                         |
| Query 2 used`RoundTripTimeMs`.                                                                                                                                                                  | `EstRoundTripTimeInMs`, joined to `WVDConnections` on `CorrelationId` for host and transport. |
| Query 4 read agent columns from`WVDCheckpoints`, which does not expose them. **Confirmed:** `'summarize' operator: Failed to resolve scalar expression named 'SessionHostName'`.                                                                    | `WVDAgentHealthStatus`.                                                                       |
| Query 5 used`LogonDurationMs`, which does not exist. **Confirmed:** `'summarize' operator: Failed to resolve scalar expression named 'LogonDurationMs'`.                                                                                            | Computed from the`Started` to `Connected` gap per `CorrelationId`.                            |
| Query 1 counted lifecycle rows as attempts, inflating the count.                                                                                                                                | Collapses to one row per`CorrelationId` with `arg_max` first.                                 |
| No query declared a lookback.                                                                                                                                                                   | Every query sets`let Lookback = 7d;`.                                                         |

The `State` counts above came from the workspace, over a 30-day window, and are the direct evidence that a state-based failure filter cannot work.

## References

- [KQL comment syntax](https://learn.microsoft.com/kusto/query/comment)
- [WVDConnections schema](https://learn.microsoft.com/azure/azure-monitor/reference/tables/wvdconnections)
- [WVDCheckpoints schema](https://learn.microsoft.com/azure/azure-monitor/reference/tables/wvdcheckpoints)
- [WVDConnectionNetworkData schema](https://learn.microsoft.com/azure/azure-monitor/reference/tables/wvdconnectionnetworkdata)
- [Microsoft WVDConnections sample queries](https://learn.microsoft.com/azure/azure-monitor/reference/queries/wvdconnections)
