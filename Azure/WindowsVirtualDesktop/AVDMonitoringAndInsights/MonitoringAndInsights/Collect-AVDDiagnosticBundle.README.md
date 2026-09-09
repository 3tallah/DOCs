# Collect-AVDDiagnosticBundle

Read-only, single-host evidence collector for Azure Virtual Desktop (AVD) session
hosts. It gathers bounded diagnostic data into a uniquely named folder and ZIP, and
generates an interactive HTML report that **flags likely issues with triage guidance**
— without uploading anything or changing system state.

> **Script:** [Collect-AVDDiagnosticBundle.ps1](Collect-AVDDiagnosticBundle.ps1)
> **Runs on:** the affected session host, elevated **Windows PowerShell 5.1** (Desktop edition).

---

## What it is for

Use it when you need a complete, sanitized snapshot of one host for:

- **Microsoft support tickets** — the bundle a support engineer asks for (services,
  registration, FSLogix, AMA logs, endpoint reachability, RDP transport), pre-bounded.
- **Troubleshooting** — logon failures, FSLogix/profile problems, Azure Files / SMB
  connectivity, RDP Shortpath / UDP issues, and AMA / DCR monitoring-ingestion gaps.
- **Before / after evidence** — capture a baseline, make a change, capture again, diff.
- **Audit artifact** — a time-stamped, manifest-inventoried record of host config and
  observed state at a point in time.

## What it collects (by category)

| Category | Checks |
| --- | --- |
| **System** | OS build/version/boot, computer + domain, invoking identity/session, installed AVD/FSLogix/AMA components, key service states (RDAgent, TermService, frxsvc, MonAgent), local disk free space |
| **AVD Agent** | Registration flag (`IsRegistered`, version, broker resource — **never** the token), optional WVDAgentUrlTool required-endpoint run |
| **Identity** | `dsregcmd /status`, `klist`, `klist cloud_debug` (PRT / Kerberos / cloud Kerberos, invoking context only) |
| **FSLogix** | Profile/ODFC/Logging registry (allowlisted values), FSLogix log tails |
| **Storage** | Active SMB connections, optional share read test, Azure Files DNS + TCP 445 probe |
| **Network** | IP configuration, routes, DNS servers, time sync, optional STUN/TURN UDP Binding probes |
| **Session** | RDP/SxS listeners (`qwinsta`), RDP/UDP transport policy registry |
| **Monitoring** | AMA process (`MonAgentCore`), DCR cache **metadata** (not contents), AMA extension log tails |
| **Events** | Channel inventory (enabled/record counts) + recent Critical/Error/Warning events from Application, System, Terminal-Services, RdpCoreCDV, and FSLogix channels; AVD agent events |

## Safety and privacy

- **Read-only.** Does not install agents, change DCRs or policy, restart services,
  purge tickets, or mount profile disks.
- **No upload.** Everything stays local in the output folder + ZIP.
- **Deliberately excluded:** registration tokens, protected extension settings, full
  registry exports, and raw DCR cache contents.
- **`-WhatIf` supported** — previews the action and writes nothing.
- ⚠️ Output **can contain** user names, IP addresses, tenant/device IDs, host names,
  and file paths. Review `README.txt` (written into the bundle) before sharing.
- PRT / Kerberos / SMB results reflect the **invoking (elevated) context only**, not
  every signed-in user. Validate an affected user's PRT from *their* unelevated session.
- STUN/UDP Binding probes prove a packet reached a responding endpoint — they **do
  not** prove TURN relay allocation or the transport of a real AVD session.

## Parameters

| Parameter | Type | Default | Notes |
| --- | --- | --- | --- |
| `OutputDirectory` | string | *(required)* | Local path only — network shares are rejected |
| `LookbackHours` | int (1–168) | `24` | How far back events/logs are gathered |
| `MaxEventsPerLog` | int (1–5000) | `200` | Cap per event channel |
| `MaxFilesPerComponent` | int (1–100) | `10` | Cap on log-tail files per component |
| `TailLines` | int (1–5000) | `500` | Lines kept per log file |
| `CommandTimeoutSeconds` | int (1–300) | `30` | Timeout for native tool invocations |
| `StorageHost` | string | — | Enables Azure Files DNS + TCP 445 probe |
| `SharePath` | string (`\\server\share`) | — | Tests read access in the invoking identity |
| `StunServer` | string | — | Sends a STUN UDP Binding probe |
| `TurnServer` | string | — | Sends a TURN-endpoint UDP Binding probe |
| `UdpPort` | int (1–65535) | `3478` | Port for STUN/TURN probes |
| `RunEndpointTool` | switch | off | Runs the installed Microsoft WVDAgentUrlTool |
| `-WhatIf` | switch | off | Preview only |

## How to run

```powershell
# Preview (writes nothing)
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD -WhatIf

# Basic run
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD

# With storage + endpoint evidence
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD `
    -StorageHost 'mystorageacct.file.core.windows.net' `
    -SharePath  '\\mystorageacct.file.core.windows.net\profiles' `
    -RunEndpointTool

# Longer lookback, deeper logs, longer tool timeout
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD `
    -LookbackHours 72 -MaxEventsPerLog 1000 -TailLines 2000 -CommandTimeoutSeconds 60
```

## Output layout

```
AVD-Diagnostics-<HOST>-<yyyymmdd-hhmmss>-<id>\
├── Report.html      ← interactive report — open this first
├── findings.json    ← flagged issues: severity, evidence, likely cause, next steps
├── manifest.json    ← machine-readable index: every check, status, details, file
├── README.txt       ← plain-language caveat summary (read/share with the bundle)
├── Machine-OS.json, Services.json, FSLogixConfiguration.json, ...
└── *.txt / *.json   ← one bounded file per evidence source
AVD-Diagnostics-<HOST>-<yyyymmdd-hhmmss>-<id>.zip   ← the packaged bundle
```

The script also returns an object:

```powershell
$result = .\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD
$result | Format-List   # ZipPath, EvidenceDirectory, ReportPath, Checks, Findings, CriticalFindings, WarningFindings, ReviewRequired
```

## Consuming the output

**1. `Report.html` (triage).** Opens with **Flagged issues** — expandable,
severity-coded finding cards (Critical / Warning / Info) each showing observed
evidence, likely meaning, suggested next steps, and links to the evidence file and
Microsoft Learn reference. Severity filter buttons and the text search work across
findings and the evidence table. Below it, the **Evidence inventory** table lists
every check with status badges and category filters.

**2. `findings.json` (scripted triage).** The same findings, machine-readable:

```powershell
$f = Get-Content '...\findings.json' -Raw | ConvertFrom-Json
$f | Where-Object Severity -in 'Critical','Warning' |
     Select-Object Id, Severity, Category, Title | Format-Table -Wrap
# Fields: Id, Severity, Category, Title, Evidence[], Interpretation, NextSteps[], File, Reference
```

**3. `manifest.json` (scripted).** Find every problem row:

```powershell
$m = Get-Content '...\manifest.json' -Raw | ConvertFrom-Json
$m | Where-Object Status -in 'Error','Timeout','Inconclusive' |
     Select-Object Check, Status, Details | Format-Table -Wrap
```

**4. Individual evidence files.** Drill into the specific `.json` / `.txt` for the
failing component.

**5. `README.txt`.** Read before forwarding — it states exactly what is (and is
deliberately *not*) in the bundle.

## Flagged issues (findings)

After collection, a **read-only analysis pass** inspects the already-collected
evidence (no extra system reads beyond a disk-space check) and emits findings to
`findings.json` and the Report.html **Flagged issues** section. A `Findings` row is
added to `manifest.json` (category *Analysis*); if an analyzer itself fails, an
`Analysis-<name>` row appears instead.

| Severity | Meaning |
| --- | --- |
| `Critical` | A condition that typically breaks connections, profile loads, or ingestion outright (e.g. stopped RDAgent/frxsvc, `IsRegistered=0`, TCP 445 to storage failed, AMA not detected) |
| `Warning` | Likely fault or risk needing review (e.g. `fClientDisableUDP=1`, FSLogix error events, no DCR cache, unsynchronized clock, low disk) |
| `Info` | Context, positive signal, or an untested dimension with pointers (e.g. STUN probe not run, no PRT in elevated context, DCR correctness needs Azure-side validation) |

What gets flagged, per failure domain:

- **Logon failures** — stopped/missing agent services, `IsRegistered=0`, agent error
  events (token/install), User Profile Service events 1500–1545, service-crash
  events, session activity counts, clock skew.
- **FSLogix** — `Enabled`/`VHDLocations` configuration problems, `frxsvc` state,
  `DeleteLocalProfileWhenVHDShouldApply` risk, temp-profile guards, FSLogix channel
  Error/Warning events.
- **Azure Files / SMB** — storage DNS failure, TCP 445 failure, share unreadable in
  the invoking context, no Kerberos `cifs` ticket, empty SMB connection list.
- **RDP Shortpath / UDP** — `fClientDisableUDP`, `SelectTransport=1`, UDP port
  redirector policy, missing `rdp-sxs`/`rdp-tcp` listeners, STUN Binding outcome,
  UDP mentions in RdpCoreCDV events.
- **AMA / ingestion** — AMA services/process absence, no DCR cache, error keywords
  in AMA extension log tails, `Test-AVDSessionHostMonitoring` Fail/Error rows, and a
  standing pointer to the Azure-side validators.

> **Heuristics, not verdicts.** Findings flag what the local evidence *suggests*.
> False positives are possible and false negatives certain (e.g. Security-log 4625
> auditing is not collected). Authoritative DCR/ingestion checks remain
> `Test-AVDDCRAssociation.ps1` / `Test-AVDLogAnalyticsIngestion.ps1`; user-scoped
> checks (PRT, share access, Kerberos) remain with the affected user's session.

## Interpreting statuses

| Status | Meaning |
| --- | --- |
| `Collected` | Evidence was saved — **not** a health verdict |
| `NoData` | Source existed but returned nothing in the window |
| `Error` / `Timeout` / `Inconclusive` | The check itself failed, timed out, or was ambiguous — review |
| `NotRun` / `NotPresent` | Skipped (missing input) or source absent |
| `Info` | Context note, not a measurement |
| `NeedsUserContext` | Must be validated from the affected user's session |
| `NeedsAzureCheck` | Requires an Azure-side check (e.g. `Test-AVDDCRAssociation.ps1`) for the authoritative answer |
| `NotTested` | Out of scope for a local probe (e.g. TURN allocation) |
| `BindingResponse` | A STUN/TURN Binding response was received (UDP reachability only) |
| `ResponseNeedsReview` | A UDP reply arrived but was not a clean Binding response — review |

> **Key rule:** `Collected` ≠ healthy. This script gathers *facts*; the health verdict
> comes from you, the KQL queries in [../KQL](../KQL/), or the Azure-side validators.
> For example, DCR cache metadata is marked `NeedsAzureCheck` on purpose — a local
> cache existing does not prove the DCR routes to the right workspace.

## Related scripts

- [Test-AVDSessionHostMonitoring.ps1](Test-AVDSessionHostMonitoring.ps1) — the read-only per-host checks this collector also runs (`LocalMonitoringChecks`).
- [Test-AVDDCRAssociation.ps1](Test-AVDDCRAssociation.ps1) — authoritative Azure-side DCR sources/routes/identity.
- [Test-AVDLogAnalyticsIngestion.ps1](Test-AVDLogAnalyticsIngestion.ps1) — proves data actually reached Log Analytics.
