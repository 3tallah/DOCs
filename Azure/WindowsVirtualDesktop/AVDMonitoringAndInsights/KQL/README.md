# AVD Monitoring and Insights — KQL Queries

KQL queries for the Log Analytics workspace used by Azure Virtual Desktop (AVD) monitoring. They verify that telemetry is actually arriving, and then inspect connections, errors, agent health, network/graphics data, transport, client versions and guest-OS (Event/Perf) data.

These queries support the [monitoring and insights guide](../README.md). The PowerShell validation scripts live in the [PowerShell folder](../PowerShell/).

## Contents

| Query | Source table(s) | What it answers |
| --- | --- | --- |
| [AVD-AllTables.kql](AVD-AllTables.kql) | All 14 expected tables | Is each AVD/AMA table receiving data in the window? |
| [AVD-AllTelemetryTables.kql](AVD-AllTelemetryTables.kql) | Same as AVD-AllTables | Alternate filename of the same ingestion check |
| [AVD-Heartbeat.kql](AVD-Heartbeat.kql) | `Heartbeat` | Which session hosts have a recent Azure Monitor Agent heartbeat? |
| [AVD-AgentHealth.kql](AVD-AgentHealth.kql) | `WVDAgentHealthStatus` | Latest AVD agent status, version and health-check result per host |
| [AVD-AgentHealthChart.kql](AVD-AgentHealthChart.kql) | `WVDAgentHealthStatus` | Chart view: hosts per reported status over time (`render timechart`) |
| [AVD-Connections.kql](AVD-Connections.kql) | `WVDConnections` | Connection lifecycle rows (states, auto-reconnects, transport) in time order |
| [AVD-ConnectionFailures.kql](AVD-ConnectionFailures.kql) | `WVDErrors` + `WVDConnections` | Connection-related errors, enriched with user/host/states |
| [AVD-Errors.kql](AVD-Errors.kql) | `WVDErrors` | All service-generated diagnostic errors |
| [AVD-ClientVersions.kql](AVD-ClientVersions.kql) | `WVDConnections` | Which client types/OS/versions are connecting |
| [AVD-NetworkData.kql](AVD-NetworkData.kql) | `WVDConnectionNetworkData` + `WVDConnections` | Estimated RTT and bandwidth per connection |
| [AVD-GraphicsData.kql](AVD-GraphicsData.kql) | `WVDConnectionGraphicsDataPreview` | Frame delays and skipped-frame percentages per connection |
| [AVD-RDPShortpath.kql](AVD-RDPShortpath.kql) | `WVDConnections` | Observed transport type (Shortpath / TURN / WebSocket) per connection |
| [AVD-SessionHostEvents.kql](AVD-SessionHostEvents.kql) | `Event` | Host Windows events; also verifies the generated validation events by `RunId` |
| [AVD-PerformanceCounters.kql](AVD-PerformanceCounters.kql) | `Perf` | Per-counter ingestion stats and values (avg/min/max) |
| [AVD-SessionHostPerformance.kql](AVD-SessionHostPerformance.kql) | Same as AVD-PerformanceCounters | Alternate filename of the same Perf summary |
| [AVD-FSLogixEvents.kql](AVD-FSLogixEvents.kql) | `Event` | FSLogix profile events from the Admin/Operational channels |

Every base query also has a `*Chart.kql` companion that renders the same data as a chart — see [Chart companions](#chart-companions).

## How to use

1. Open **Logs** (Log Analytics) in the target workspace in the Azure portal, or Log Analytics debug mode, and paste the query.
2. Edit the `let` variables at the top of each query before running:

   | Variable | Used by | Notes |
   | --- | --- | --- |
   | `Lookback` | All queries | Time window (`48h` typical; `7d` for client versions; `2h` for Perf) |
   | `HostPoolResourceId` | Most WVD queries | Optional full host pool ARM ID; empty = all host pools |
   | `ResourceId` | AVD-Errors | Optional host pool **or** AVD workspace ARM ID |
   | `ComputerFilter` | Event/Perf queries | Optional short name or FQDN; matches either |
   | `UserFilter` | AVD-Connections | Optional exact UPN |
   | `StaleAfter` | AVD-Heartbeat | Heartbeat age threshold (default `15m`) |
   | `ExpectedVMs` | AVD-Heartbeat | Paste every session host VM ARM ID to detect never-seen hosts |
   | `BinSize` | Chart companions | Bin width for time series (default `1h`; `5m` for the Perf chart) |
   | `ObjectFilter`, `CounterFilter`, `InstanceFilter` | AVD-PerformanceCountersChart | Select the single counter to chart |
   | `OnlyValidationEvents`, `RunId` | AVD-SessionHostEvents | Set `true` and paste the `RunId` from `New-AVDMonitoringTestEvents.ps1` |

3. Conventions shared by all queries:
   - Each starts with `union isfuzzy=true` against an empty `datatable`, so the query runs without failing when an optional table does not exist yet in the workspace. **Fuzzy-union warnings for absent tables are expected**; access or runtime errors still matter.
   - Chart companions (`*Chart.kql`) end with a `render` statement, which takes effect in the portal **chart view** (in the table view you still see the underlying rows). Because charts are built from rows, absent tables/hosts simply do not appear in them — use the table query for the full matrix.
   - Most queries cap output with `take 1000` newest rows — adjust as needed.
   - A zero/empty result means *no rows visible in that window*; it does not by itself prove collection is disabled or broken (see each query's header comments for the specific caveat).
   - If service-side (WVD\*) and guest-side (Event/Perf/Heartbeat) data go to **different workspaces**, run the query in both.

---

## Ingestion and host health

### AVD-AllTables.kql (alias: AVD-AllTelemetryTables.kql)

Compares a hard-coded list of 14 expected tables (`WVDConnections`, `WVDCheckpoints`, `WVDErrors`, `WVDFeeds`, `WVDManagement`, `WVDHostRegistrations`, `WVDAgentHealthStatus`, `WVDConnectionNetworkData`, `WVDConnectionGraphicsDataPreview`, `WVDSessionHostManagement`, `WVDMultiLinkAdd`, plus `Event`, `Perf`, `Heartbeat`) against rows actually visible in the window. Output per table: record count, last record time, and `Observation` = "Receiving data" or "No data in window / table absent". Zero means no rows in this time range, including tables not yet created. Start here when validating the monitoring pipeline.

### AVD-Heartbeat.kql

Latest Azure Monitor Agent heartbeat per VM (`Heartbeat` table, `Category == "Azure Monitor Agent"`). Classifies each host as `Recent`, `Stale` (older than `StaleAfter`, default 15 minutes) or `Missing in window`. Populate `ExpectedVMs` with every session host VM ARM ID to also detect hosts that have **never** reported; with an empty list only observed hosts are shown. A stale heartbeat may reflect a stopped/deallocated VM or ingestion delay — this is AMA heartbeat, not the AVD agent health report.

### AVD-AgentHealth.kql

Latest AVD agent report per session host from `WVDAgentHealthStatus`: `Status`, `AgentVersion`, `LastHeartBeat`, `ReportAge` and the `SessionHostHealthCheckResult` dynamic column. Note: missing hosts cannot be discovered from this table alone — compare against the Azure inventory (e.g. `Test-AVDDCRAssociation.ps1` output or the host pool session host list).

### AVD-AgentHealthChart.kql

Chart companion to `AVD-AgentHealth.kql`: counts distinct session hosts per reported `Status` per time bin (`BinSize`, default `1h` — narrow to `5m`/`15m` for short windows, widen to `6h`/`1d` for long ones) and renders a **timechart** (one line per status). A host reporting different statuses within one bin counts once in each; a gap in all series can simply mean hosts were stopped/deallocated. For a stacked column view, swap the final line for the commented `render columnchart with (kind=stacked, ...)` alternative included in the file header.

## Connections and errors

### AVD-Connections.kql

Connection lifecycle rows from `WVDConnections` in time order. A single connection can emit multiple rows (states over time). Adds `IsAutoReconnect` from `PredecessorConnectionId` — note this identifies *auto*-reconnects, not every manual reconnect; to validate a manual reconnect, correlate user, host and the recorded test times. Shows `TransportType` per row.

### AVD-ConnectionFailures.kql

Connection-related rows from `WVDErrors` (`ActivityType =~ "Connection"` or matching a known connection CorrelationId), joined with the latest user/host and the set of observed `State` values from `WVDConnections`. **An error row is not proof of a failed sign-in** — inspect `Message`, `CodeSymbolic`, `ServiceError` and the connection timeline before concluding.

### AVD-Errors.kql

All service-generated diagnostic errors from `WVDErrors` (these are AVD service diagnostics, **not** local Windows Event log errors). Optional `ResourceId` filters by host pool **or** AVD workspace. Zero rows can be normal and does not prove collection is enabled — pair with `AVD-AllTables.kql`.

### AVD-ClientVersions.kql

Distribution of connecting client types: takes the latest non-empty `ClientVersion` per `CorrelationId` from `WVDConnections`, then counts connections by `ClientType`, `ClientOS`, `ClientVersion` over 7 days. Describes observed connecting clients, not an installed-device software inventory.

## Network, graphics and transport

### AVD-NetworkData.kql

Per-connection network telemetry from `WVDConnectionNetworkData`: estimated round-trip time (`RTTms`) and available bandwidth (`BandwidthKBps` — kilobytes per second). Network rows carry no host/user/transport fields, so the query enriches each row from one `WVDConnections` row per `_ResourceId` + `CorrelationId` (to avoid multiplying samples). Only **active sessions** generate this telemetry — an idle host legitimately has no rows.

### AVD-GraphicsData.kql

Preview graphics telemetry from `WVDConnectionGraphicsDataPreview` per connection: end-to-end, encoding, decoding and rendering delays (ms) plus server/network/client skipped-frame percentages. Missing rows are not by themselves proof of failure — this preview data depends on eligible client/session activity and diagnostics.

### AVD-RDPShortpath.kql

The service-reported `TransportType` per connection from `WVDConnections`, with an `Interpretation` column: `Shortpath` = direct UDP (managed-network vs. STUN-assisted direct is **not** distinguished here), `TURN` = relayed UDP, `Websocket` = WebSocket transport. This is observed transport, not configuration or a standalone connectivity test.

## Guest OS telemetry (Event and Perf)

### AVD-SessionHostEvents.kql

Host Windows events collected by AMA into `Event`. With defaults it lists all collected events (filterable by `ComputerFilter`). For end-to-end validation, set `OnlyValidationEvents = true` and paste the `RunId` returned by [`New-AVDMonitoringTestEvents.ps1`](../PowerShell/New-AVDMonitoringTestEvents.ps1) — it matches `Source == "AVD-Monitoring-Validation"` and event IDs 9001/9002, proving the whole pipeline (host → AMA → DCR → workspace) works.

### AVD-PerformanceCounters.kql (alias: AVD-SessionHostPerformance.kql)

Summary of the `Perf` table over the window: `Records`, `LastSample`, `Average`, `Minimum` and `Maximum` per `_ResourceId` / `Computer` / `ObjectName` / `CounterName` / `InstanceName`. Each counter and instance stays on its own row — units differ and must not be averaged together. Compare the counter list and host coverage against the DCR configuration and expected inventory.

### AVD-FSLogixEvents.kql

FSLogix profile events from `Event`: rows where `EventLog` is `Microsoft-FSLogix-Apps/Admin` or `Microsoft-FSLogix-Apps/Operational`, or `Source` contains "FSLogix". Requires the DCR to collect those channels; empty results can mean no activity, excluded channels, or missing collection — pair with `AVD-AllTables.kql` and the DCR review.

---

## Chart companions

Each base query has an `*Chart.kql` companion that renders the same telemetry as a chart (mostly `render timechart`, one series per status/level/code/transport). They use the same `Lookback`/filter variables as their base query plus `BinSize` (default `1h`); averages per bin smooth outliers, so inspect the table query for detail. File headers note how to switch render type (e.g. stacked `columnchart`, `piechart`).

| Chart | Based on | What it shows |
| --- | --- | --- |
| [AVD-AllTablesChart.kql](AVD-AllTablesChart.kql) | AVD-AllTables | Records per table per bin; absent tables have no series |
| [AVD-HeartbeatChart.kql](AVD-HeartbeatChart.kql) | AVD-Heartbeat | Distinct hosts with an AMA heartbeat per bin |
| [AVD-AgentHealthChart.kql](AVD-AgentHealthChart.kql) | AVD-AgentHealth | Distinct hosts per agent `Status` per bin |
| [AVD-ConnectionsChart.kql](AVD-ConnectionsChart.kql) | AVD-Connections | Distinct connections with activity per bin |
| [AVD-ConnectionFailuresChart.kql](AVD-ConnectionFailuresChart.kql) | AVD-ConnectionFailures | Connection-related error rows per `CodeSymbolic` per bin |
| [AVD-ErrorsChart.kql](AVD-ErrorsChart.kql) | AVD-Errors | Service error rows per `CodeSymbolic` per bin |
| [AVD-ClientVersionsChart.kql](AVD-ClientVersionsChart.kql) | AVD-ClientVersions | Connections per client type/OS/version (columnchart) |
| [AVD-NetworkDataChart.kql](AVD-NetworkDataChart.kql) | AVD-NetworkData | Average estimated RTT (ms) per bin; bandwidth needs a separate chart (different units) |
| [AVD-GraphicsDataChart.kql](AVD-GraphicsDataChart.kql) | AVD-GraphicsData | Average end-to-end/encoding/decoding/rendering delays (ms) per bin; skipped-frame % separately |
| [AVD-RDPShortpathChart.kql](AVD-RDPShortpathChart.kql) | AVD-RDPShortpath | Distinct connections per `TransportType` per bin |
| [AVD-SessionHostEventsChart.kql](AVD-SessionHostEventsChart.kql) | AVD-SessionHostEvents | Event rows per level per bin |
| [AVD-PerformanceCountersChart.kql](AVD-PerformanceCountersChart.kql) | AVD-PerformanceCounters | One selected counter over time; one series per host/instance (defaults to total CPU %) |
| [AVD-FSLogixEventsChart.kql](AVD-FSLogixEventsChart.kql) | AVD-FSLogixEvents | FSLogix event rows per Event ID per bin |

---

## Suggested validation workflow

1. **Ingestion** — run `AVD-AllTables.kql` in the target workspace (repeat in the guest workspace if different) to see which tables are receiving data.
2. **Agent health** — `AVD-Heartbeat.kql` (AMA) and `AVD-AgentHealth.kql` (AVD agent) to confirm hosts are reporting.
3. **Exercise a session** — connect a real user session, then review `AVD-Connections.kql`, `AVD-ConnectionFailures.kql`, `AVD-NetworkData.kql`, `AVD-GraphicsData.kql` and `AVD-RDPShortpath.kql`.
4. **End-to-end test** — run `New-AVDMonitoringTestEvents.ps1` on a host, then use `AVD-SessionHostEvents.kql` with `OnlyValidationEvents = true` and the `RunId` to confirm guest event ingestion.

## Notes

- `AVD-AllTelemetryTables.kql` and `AVD-SessionHostPerformance.kql` are duplicate filenames kept for compatibility; they are byte-identical to `AVD-AllTables.kql` and `AVD-PerformanceCounters.kql`, so `AVD-AllTablesChart.kql` and `AVD-PerformanceCountersChart.kql` serve them as well.
- Queries are read-only; they do not modify the workspace.
- Table/column names reflect the AVD diagnostic tables at the time of writing; if Microsoft adds or renames tables, update the `Expected` datatable in `AVD-AllTables.kql` accordingly.
- See the parent [README](../README.md) for prerequisites and validation status.


