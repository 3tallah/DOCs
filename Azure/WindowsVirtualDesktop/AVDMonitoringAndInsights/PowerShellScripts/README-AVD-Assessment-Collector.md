# AVD Assessment Collector

`AVD-Assessment-Collector.ps1` (v2.0) collects Azure Virtual Desktop inventory, session host health and local host evidence, then writes CSV artifacts, a JSON manifest, a text summary and a self-contained HTML report.

The collector is designed so that **an empty result is never mistaken for a failed query**, and so that a run which could not collect its evidence **fails loudly and exits non-zero**.

## Purpose

Two independent scopes are collected:

| Scope | Contents |
| --- | --- |
| `Azure` | Host pools, session hosts, per-host health checks, application groups, workspaces, scaling plans |
| `Local` | AVD agent and FSLogix registry state, related services, Application/System event logs, FSLogix logs |

The Azure resources and the local computer are **not** correlated. Running from an administrator workstation collects that workstation's local evidence, not evidence from the session hosts discovered in Azure. The manifest records which machine produced the local evidence so the distinction is auditable. Use `-Scope Azure` from a workstation and `-Scope Local` on a session host when that separation matters.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- `Az.Accounts` and `Az.DesktopVirtualization` for Azure collection.
- An existing Azure sign-in, or credentials to complete one. The collector **reuses the current `Az` context** and only calls `Connect-AzAccount` when no context exists.
- `Desktop Virtualization Reader` or equivalent read access at the intended scope.
- Local permissions to read services, HKLM registry paths and event logs. An elevated session collects more; the run is not blocked without it.
- Disk space for EVTX exports (roughly 2 MB per log for seven days on a workstation).

The script does not install modules and does not change any Azure or local configuration.

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `SubscriptionId` | current context | Switches context only if it differs from the active subscription. |
| `ResourceGroup` | all | Restricts every Azure query to one resource group. |
| `HostPoolName` | all | Restricts collection to a single host pool. Requires `-ResourceGroup`. |
| `WorkspaceName` | all | Restricts workspace collection to one AVD workspace. |
| `OutputPath` | `.\AVD_Assessment_Output` | Root folder. A timestamped run folder is created beneath it. |
| `Scope` | `All` | `All`, `Azure` or `Local`. |
| `EventLogDays` | `7` | Days of Application/System history to export (1–90). |
| `HeartbeatThresholdHours` | `24` | Session host heartbeat age that raises a finding (1–8760). |
| `DeviceCode` | off | Use device code sign-in. Required in remote sessions with no browser. |
| `IncludeSecurityLog` | off | Also export the Security log. Requires elevation. |
| `NoHtmlReport` | off | Write only CSV, JSON and text output. |

Every parameter listed is implemented. `-HostPoolName` without `-ResourceGroup` is rejected up front, because a host pool name is not unique across resource groups.

## Usage

The script is unsigned and may carry a `Zone.Identifier` stream from download, which `RemoteSigned` rejects with `is not digitally signed`. The in-tree copy was verified stream-free on 2026-09-11, but if you obtain it another way, review the contents and unblock it once:

```powershell
Unblock-File -LiteralPath '.\PowerShellScripts\AVD-Assessment-Collector.ps1'
```

### Full collection for one host pool

```powershell
Connect-AzAccount

& '.\PowerShellScripts\AVD-Assessment-Collector.ps1' `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -ResourceGroup 'WPNS-AVD' `
    -HostPoolName 'WPNS-AVD' `
    -OutputPath 'C:\Temp\AVD-Assessment'
```

### Azure inventory only, from an admin workstation

```powershell
& '.\PowerShellScripts\AVD-Assessment-Collector.ps1' -Scope Azure -OutputPath 'C:\Temp\AVD-Assessment'
```

### Local evidence only, on a session host

Run elevated for complete registry, event log and FSLogix coverage:

```powershell
& '.\PowerShellScripts\AVD-Assessment-Collector.ps1' -Scope Local -EventLogDays 3 -IncludeSecurityLog `
    -OutputPath 'C:\Temp\AVD-Assessment'
```

### Unattended use

The collector returns a result object and sets a process exit code, so it can gate a pipeline:

```powershell
$result = & '.\PowerShellScripts\AVD-Assessment-Collector.ps1' -Scope Azure -OutputPath 'C:\Temp\AVD-Assessment'

if ($LASTEXITCODE -ne 0) {
    throw "AVD collection incomplete: $($result.ArtifactsInError) artifact(s) in error."
}
if ($result.Critical -gt 0) {
    Write-Warning "$($result.Critical) critical finding(s). See $($result.Report)"
}
```

In a remote session with no browser, add `-DeviceCode` so sign-in can complete.

## Output

Each run creates its own folder, so runs never overwrite or mix with one another:

```
<OutputPath>\AVD-Assessment-<COMPUTERNAME>-<yyyyMMdd-HHmmss>\
```

| Artifact | Contents |
| --- | --- |
| `AVD-Assessment-Report.html` | Self-contained report: findings, session host table, artifact inventory |
| `manifest.json` | Machine-readable run record: parameters, context, per-artifact status, SHA256 hashes, findings |
| `Summary.txt` | Plain-text equivalent of the report |
| `Findings.csv` | Severity, area, title, detail, recommendation |
| `HostPools.csv` | Host pool configuration including RDP properties and session limits |
| `SessionHosts.csv` | One row per session host across all collected pools |
| `SessionHostHealthChecks.csv` | One row per individual AVD health check result |
| `ApplicationGroups.csv` | Application groups and their host pool association |
| `Workspaces.csv` | Workspaces with application group references flattened to a delimited string |
| `ScalingPlans.csv` | Scaling plans with schedule and host pool counts |
| `Services.csv` | Local AVD agent, WebRTC and FSLogix services |
| `RDInfraAgent_Reg.txt`, `FSLogix_*.txt` | Local registry evidence, when the keys exist |
| `Application.evtx`, `System.evtx`, `Security.evtx` | Local event logs for the requested window |
| `FSLogix_Logs\` | Copy of local FSLogix logs, when present |
| `Errors.txt` | Written whenever any step raised an exception |

Session hosts are exported to a **single** `SessionHosts.csv` with a `HostPool` column, rather than one file per pool, so the data can be filtered and compared directly.

### Artifact status

Every artifact is recorded in `manifest.json` and both reports with an explicit status:

| Status | Meaning |
| --- | --- |
| `Collected` | The query succeeded and returned data. **Never means the configuration is healthy.** |
| `NoData` | The query succeeded and returned nothing. A header-only CSV is written so this is visibly different from a failure. |
| `Skipped` | Not applicable to the selected `-Scope`, or missing a prerequisite such as elevation. |
| `Error` | The query failed. The exception is in `Errors.txt`. |
| `NotRun` | A prerequisite step failed, so this was never attempted. |

`Error` and `NotRun` both mean evidence is missing, and both cause a non-zero exit code.

### Findings

Findings are derived from the collected data and are reported separately from collection errors:

| Finding | Severity |
| --- | --- |
| Session host heartbeat older than `-HeartbeatThresholdHours` while `Available` and accepting sessions | Critical |
| Session host heartbeat stale in any other state | Warning |
| Any AVD health check not equal to `HealthCheckSucceeded` | Critical |
| `RDAgentBootLoader` or `frxsvc` present but not running | Critical |
| AVD agent version drift across hosts in scope | Warning |
| Agent update state `Failed` | Warning |
| No scaling plan in scope | Info |
| Collector not elevated | Info |

Findings do **not** change the exit code. A run can succeed completely and still report critical findings; that is the normal result of a healthy collection against an unhealthy environment.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every required artifact was collected. |
| `1` | One or more artifacts are `Error` or `NotRun`. |

## Verified behavior

Executed against subscription `beccc7a6-…`, host pool `WPNS-AVD`, on 2026-09-11.

**Successful run** — 13 artifacts, zero 0-byte files, exit code `0`:

```
[ OK  ] Azure context: ... / beccc7a6-...
[ OK  ] Host pools: 1 row(s)
[ OK  ] Session hosts: 2 row(s)
[ OK  ] Session host health checks: 7 row(s)
[ OK  ] Application groups: 1 row(s)
[ OK  ] Workspaces: 1 row(s)
[WARN ] Scaling plans: no records returned (header-only file written)
...
Findings      : 1 critical, 1 warning, 2 info
[ OK  ] All required artifacts were collected.
```

The two stale hosts were correctly separated by severity: `WPNS-AVD-0` was `Critical` because it was `Available` and accepting sessions with a 100.6-hour-old heartbeat, while `WPNS-AVD-1` was only `Warning` because it was `Shutdown`.

**Failure run** — `-ResourceGroup 'RG-DOES-NOT-EXIST-9821'` produced four `Error` artifacts, wrote `Errors.txt`, reported `CollectionSucceeded: False` and exited `1`.

Validate any run:

```powershell
Get-ChildItem $result.OutputPath -File | Select-Object Name, Length | Sort-Object Length
(Get-Content $result.Manifest -Raw | ConvertFrom-Json).Artifacts |
    Where-Object Status -in 'Error','NotRun'
```

## Changes from v1

The previous version had defects that silently produced misleading evidence. All are fixed:

| v1 defect | v2 behavior |
| --- | --- |
| `Connect-AzAccount` failed but the script printed `Done.` and exited `0`, silently reusing a stale context | The existing context is reused deliberately; a genuine authentication failure is a `Critical` finding, marks Azure artifacts `NotRun` and exits `1` |
| `Errors.txt` was never created despite exceptions | Written whenever any step raises, and registered as an artifact |
| `ScalingPlans.csv` and `Services.csv` were written as 0-byte files | Empty result sets get a header-only CSV and status `NoData` |
| `SessionHosts` selected `Sku` and `Sessions`, which do not exist on the object, so the columns were always blank | Correct property names, plus `AgentVersion`, `SxSStackVersion`, `OSVersion`, `UpdateState` and health check counts |
| `Workspaces.csv` serialized list properties as `System.Collections.Generic.List'1[System.String]` | List properties are flattened to a delimited string with a count column |
| `ResourceGroup`, `HostPoolName` and `WorkspaceId` were declared but ignored | All scope parameters are implemented and honored by every query |
| Output went to a fixed CWD-relative folder that runs reused and mixed | `-OutputPath` plus a per-run timestamped folder |
| `wevtutil` exit codes were unchecked, so missing EVTX passed silently | Exit code checked; failure becomes an `Error` artifact and a finding |
| EVTX export did not overwrite, so stale logs could persist | `/ow:true` is passed |
| No manifest; no way to distinguish empty from failed | `manifest.json` with per-artifact status, row counts and SHA256 hashes |
| Always exited `0` | Exits `1` when evidence is missing |

The v1 comment-based help promised JSON that was never produced. v2 writes `manifest.json`.

## Evidence Handling

Output may contain user names, assigned users, host names, resource topology, profile container paths and application events. Restrict access, encrypt transfers, apply a retention period and never commit a collection folder to source control.

Each run writes to its own timestamped folder, so evidence from separate runs cannot be conflated. `manifest.json` records a SHA256 hash for every file, which supports chain-of-custody verification.

## Known limitations

- Azure inventory and local evidence still describe different machines unless the collector runs on a session host. The manifest records which, but does not correlate them.
- Findings cover only the checks listed above. A clean report is not a complete AVD health assessment; pair it with the checks in `PowerShellScripts/`.
- Health check data is only as fresh as the AVD agent's last report. A host with a stale heartbeat may also have stale health results.
- The collector reads Azure Resource Manager only. It does not query Log Analytics, so it cannot confirm that telemetry is actually being ingested.

## References

- [Use Azure PowerShell with Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/cli-powershell)
- [Azure Virtual Desktop RBAC roles](https://learn.microsoft.com/azure/virtual-desktop/rbac)
- [Session host health checks](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-agent)
- [wevtutil command reference](https://learn.microsoft.com/windows-server/administration/windows-commands/wevtutil)
- [FSLogix logging and diagnostics](https://learn.microsoft.com/fslogix/troubleshooting-events-logs-diagnostics)
