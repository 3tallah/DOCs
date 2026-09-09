# AVD Monitoring and Insights — PowerShell Scripts

PowerShell scripts that validate the Azure-side and guest-side configuration needed for Azure Virtual Desktop (AVD) monitoring with Azure Monitor and AVD Insights. Four scripts are **read-only** diagnostics; one generates two **controlled, labeled test events** for end-to-end ingestion validation. A sixth script is an **interactive single-pass console report** combining the common host checks for manual runs.

These scripts support the [monitoring and insights guide](../README.md). Companion KQL queries for verifying ingestion live in the [KQL folder](../KQL/).

## Contents

| Script | Where it runs | Type |
| --- | --- | --- |
| [Test-AVDHostPoolDiagnosticSettings.ps1](Test-AVDHostPoolDiagnosticSettings.ps1) | Azure (any machine signed in to Azure) | Read-only validation |
| [Test-AVDWorkspaceDiagnosticSettings.ps1](Test-AVDWorkspaceDiagnosticSettings.ps1) | Azure (any machine signed in to Azure) | Read-only validation |
| [Test-AVDDCRAssociation.ps1](Test-AVDDCRAssociation.ps1) | Azure (any machine signed in to Azure) | Read-only validation |
| [Test-AVDSessionHostMonitoring.ps1](Test-AVDSessionHostMonitoring.ps1) | Locally on each session host (elevated) | Read-only validation |
| [Validate-AVDSessionHostMonitoring-Interactive.ps1](Validate-AVDSessionHostMonitoring-Interactive.ps1) | Locally on a session host (elevated) | Interactive console report; writes two labeled test events |
| [New-AVDMonitoringTestEvents.ps1](New-AVDMonitoringTestEvents.ps1) | Locally on a chosen session host (elevated Windows PowerShell 5.1) | Writes two test events |

## Prerequisites

- **Azure scripts** (`Test-AVDHostPoolDiagnosticSettings`, `Test-AVDWorkspaceDiagnosticSettings`, `Test-AVDDCRAssociation`): Windows PowerShell 5.1+, the `Az.Accounts` module installed, and an active `Connect-AzAccount` session with read access to the subscription. All Azure calls go through `Invoke-AzRestMethod` (ARM REST, read-only GETs).
- **Host scripts** (`Test-AVDSessionHostMonitoring`, `New-AVDMonitoringTestEvents`): run elevated (as Administrator) on the session host. `New-AVDMonitoringTestEvents` additionally requires Windows PowerShell 5.1 Desktop edition.
- Scripts do **not** install modules automatically or change execution policy.

## Common output format

All scripts emit one object per check with the columns `Resource`, `Check`, `Status`, `Details`. Status values:

| Status | Meaning |
| --- | --- |
| `Pass` | Check succeeded |
| `Fail` | Expected configuration missing or unhealthy |
| `Warning` | Not necessarily broken, but review recommended (e.g. custom transform may filter records, category not advertised) |
| `Error` | The check itself could not run (permission, API, missing artifact) |
| `Info` | Inventory/evidence output for review |

---

## Test-AVDHostPoolDiagnosticSettings.ps1

Read-only validation of an AVD **host pool**'s diagnostic settings: which log categories exist, which settings target the expected Log Analytics workspace, and whether the baseline AVD categories are enabled to that destination.

- **Parameters**

  | Parameter | Mandatory | Notes |
  | --- | --- | --- |
  | `HostPoolResourceId` | Yes | Full ARM resource ID of the host pool (validated against the `Microsoft.DesktopVirtualization/hostPools` pattern) |
  | `LogAnalyticsWorkspaceResourceId` | Yes | Full ARM resource ID of the expected workspace (`Microsoft.OperationalInsights/workspaces`) |

- **What it checks**
  - Lists the log categories the resource advertises (`diagnosticSettingsCategories`).
  - Confirms at least one diagnostic setting targets the expected workspace (`ExpectedDestination`).
  - Reports every diagnostic setting and its enabled log categories/groups.
  - Detects the `allLogs` category group (covers current and future categories).
  - Verifies baseline categories (`Checkpoint`, `Error`, `Management`, `Connection`, `HostRegistration`, `AgentHealthStatus`) are enabled to the expected destination; warns if a baseline category is not advertised by the resource.

- **Example**

  ```powershell
  .\Test-AVDHostPoolDiagnosticSettings.ps1 -HostPoolResourceId $id -LogAnalyticsWorkspaceResourceId $lawId
  ```

## Test-AVDWorkspaceDiagnosticSettings.ps1

Same validation as the host pool script, but for an AVD **workspace**. The baseline categories for a workspace are `Checkpoint`, `Error`, `Management`, `Feed`.

- **Parameters**

  | Parameter | Mandatory | Notes |
  | --- | --- | --- |
  | `AVDWorkspaceResourceId` | Yes | Full ARM resource ID of the AVD workspace (`Microsoft.DesktopVirtualization/workspaces`) |
  | `LogAnalyticsWorkspaceResourceId` | Yes | Full ARM resource ID of the expected workspace |

- **Example**

  ```powershell
  .\Test-AVDWorkspaceDiagnosticSettings.ps1 -AVDWorkspaceResourceId $id -LogAnalyticsWorkspaceResourceId $lawId
  ```

## Test-AVDDCRAssociation.ps1

Checks, for every session host registered to a host pool, that the Azure Monitor Agent (AMA), its VM identity configuration, and Data Collection Rules (DCRs) can support Windows Event (`Microsoft-Event`) and Performance (`Microsoft-Perf`) collection to the expected workspace. Read-only.

- **Parameters**

  | Parameter | Mandatory | Notes |
  | --- | --- | --- |
  | `HostPoolResourceId` | Yes | Host pool whose registered session hosts are inspected |
  | `LogAnalyticsWorkspaceResourceId` | Yes | Workspace the DCR destinations are matched against |

- **What it checks, per session host**
  - Resolves the session host's VM resource ID and reports a failure for a missing or unsupported ID. VMs in other resource groups are supported.
  - AVD agent status, version, and last heartbeat.
  - VM managed identity presence. If the AMA extension explicitly selects a user-assigned identity, verifies that the selected resource ID, client ID, or object ID matches an identity attached to the VM. If no identity is explicitly selected, verifies that a system-assigned identity is available.
  - `AzureMonitorWindowsAgent` extension present and `Succeeded`, including its automatic-upgrade setting.
  - DCR associations exist (DCE-only associations do not count).
  - For each associated DCR: provisioning state, Windows Event XPath queries, performance counter specifiers and sampling interval, data flows, and destination match to the expected workspace.
  - `ExpectedWorkspaceRoute:Microsoft-Event` / `ExpectedWorkspaceRoute:Microsoft-Perf` — Pass means a matching data source and data flow to the expected destination exist. A route is marked `Error` when a DCR cannot be read and `Fail` when it is readable but no matching route exists.
  - Reports matching routes with their `transformKql` value and warns when a custom transform other than `source` may filter records.
  - Reports an empty session-host inventory as `SessionHostInventory:Fail`; ARM/API and unreadable-resource failures are reported as `Error` results.

- **Example**

  ```powershell
  .\Test-AVDDCRAssociation.ps1 -HostPoolResourceId $hpId -LogAnalyticsWorkspaceResourceId $lawId
  ```

- **Note** — a Pass on routing proves configuration exists, not that data is arriving. Verify ingestion separately with the KQL queries and the test-event generator below.

## Test-AVDSessionHostMonitoring.ps1

Read-only **local** health checks for the AVD agent and Azure Monitor Agent on a session host. Run it on each host. It does not install agents, change DCRs, restart services, or generate events.

- **Parameters**

  | Parameter | Default | Notes |
  | --- | --- | --- |
  | `LookbackHours` | `24` | Window (1–168 hours) for recent-event checks |
  | `CounterPaths` | 20 AVD-relevant counters | CPU, memory, logical/physical disk, Terminal Services sessions, user input delay, RemoteFX network |
  | `EventLogNames` | Application, System, TerminalServices RemoteConnectionManager/Admin, LocalSessionManager/Operational | Event logs checked for enablement and recent activity |

- **What it checks**
  - `RDAgentBootLoader` and `TermService` services are running.
  - AVD registration flag (`IsRegistered`) — reads only the flag, never the registration token.
  - Installed AVD agent/boot loader/infrastructure package versions.
  - Session listeners (`qwinsta`).
  - AMA process (`MonAgentCore`) is running.
  - AMA downloaded DCR config cache exists and when it was last updated (existence does not prove correct DCR content or successful ingestion).
  - Most recent AMA extension log files.
  - Each event log is enabled and has recent records (an idle/healthy host can legitimately be quiet).
  - Recent AVD agent events from `WVD-Agent`, `WVD-Agent-Updater`, `RDAgentBootLoader` providers.
  - Samples each configured performance counter (session counters may need an active session; use localized paths on non-English Windows).

- **Example**

  ```powershell
  .\Test-AVDSessionHostMonitoring.ps1 | Format-Table -Wrap
  ```

## New-AVDMonitoringTestEvents.ps1

Creates two controlled Application log events for **end-to-end ingestion validation**. Run it in elevated Windows PowerShell 5.1 on the chosen session host. This is the only script that writes anything.

- **Behavior**
  - Creates the `AVD-Monitoring-Validation` event source in the Application log if absent, and refuses to run if the source is already registered to a different log.
  - Writes one **Warning (Event ID 9001)** and one **Error (Event ID 9002)**, each tagged with a `RunId` GUID, host name and UTC timestamp so they can be traced precisely in Log Analytics.
  - These events can trigger existing alert rules — check whether test alerts should be expected or suppressed.
  - Supports `-WhatIf`. Does not create AVD service-side telemetry (connections, etc.).

- **Parameters**

  | Parameter | Mandatory | Notes |
  | --- | --- | --- |
  | `RunId` | No | GUID label for correlation; auto-generated when omitted |

- **Examples**

  ```powershell
  .\New-AVDMonitoringTestEvents.ps1 -WhatIf   # preview
  .\New-AVDMonitoringTestEvents.ps1           # write events
  ```

---

## Suggested validation order

1. **Azure control plane** — run `Test-AVDHostPoolDiagnosticSettings.ps1` and `Test-AVDWorkspaceDiagnosticSettings.ps1` to confirm diagnostic settings, categories and destination workspace.
2. **Per-host pipeline** — run `Test-AVDDCRAssociation.ps1` to verify the AMA extension and DCR event/perf routes for every registered session host.
3. **Guest OS** — run `Test-AVDSessionHostMonitoring.ps1` on each session host to verify agent services, registration, AMA process and local logging.
4. **End-to-end** — run `New-AVDMonitoringTestEvents.ps1` on a chosen host, then confirm the two events arrive in Log Analytics using the queries in [`../KQL/`](../KQL/) (search by the returned `RunId`).

## Notes and limitations

- All Azure-side scripts are read-only GETs; the only state change in this folder is the two labeled test events (and their event source).
- A visible host in AVD Insights is not evidence that service or guest telemetry is arriving — that is why ingestion is verified explicitly in step 4.
- These scripts have been checked with PowerShell parsing and simulated responses; validate on a test host before production use. See the parent [README](../README.md) for validation status and references.


