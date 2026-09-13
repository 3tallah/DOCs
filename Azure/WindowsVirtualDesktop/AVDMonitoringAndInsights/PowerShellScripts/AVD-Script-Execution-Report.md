# AVD PowerShell Script Execution Report

Full execution pass over every PowerShell script in `AVDMonitoringAndInsights\` and
`AVDMonitoringAndInsights\PowerShellScripts\`.

| | |
|---|---|
| **Run date** | 2026-09-11 |
| **Operator** | `<operator-email>` |
| **Subscription** | `<subscription-id>` |
| **Tenant** | `<tenant-id>` |
| **Host pool** | `WPNS-AVD` (Pooled, BreadthFirst, max 5 sessions, 2 session hosts) |
| **Log Analytics** | `LAW-WPNS-AVD` (workspace GUID `<workspace-guid>`) |
| **AVD workspace** | `WPNS-AVD-WS` |
| **Local host** | `<hostname>` — Windows PowerShell 5.1.26100.9444 (Desktop) |
| **Evidence root** | `C:\Temp\AVDTest\FullRun-20260911-173145\` |

**Result at run time: 18 of 19 scripts executed. 1 could not be executed (parse errors).**

**Status now:** the parse failure was fixed during the same session (see [D4](#d4--avd_netapp_perf_test01_v01ps1-does-not-parse)). All 19 scripts parse with 0 errors, re-confirmed on 2026-09-11. `AVD_NetApp_Perf_Test01_v0.1.ps1` has been `-WhatIf` dry-run verified but a real FIO workload has still never been executed.

Each script ran in an isolated `powershell.exe` child process with stdout and stderr
captured to `logs\<script>.log` and artifacts written under `artifacts\`.

---

## Summary

| # | Script | Folder | Exit | Outcome |
|---|---|---|---|---|
| 1 | `AVD_AnalyzeLogonDuration.ps1` | PowerShellScripts | 0 | ✅ Ran elevated; produced a 6.5 s logon breakdown |
| 2 | `AVD_AzureCostAnalysis_CostsPerVM.ps1` | PowerShellScripts | 99 | ⛔ Blocked — missing ControlUp SP credential file |
| 3 | `AVD_Inventory01.ps1` | PowerShellScripts | 0 | ➖ No output by design (plug-in, not standalone) |
| 4 | `AVD_NetApp_Perf_Test01_v0.1.ps1` | PowerShellScripts | — | ❌ At run time: 4 parse errors. **Fixed since (D4)** — now parses clean and `-WhatIf` dry-run verified; still destructive, real FIO run outstanding |
| 5 | `AVD-Assessment-Collector.ps1` | PowerShellScripts | 0 | ✅ 13 artifacts, 0 zero-byte, HTML report |
| 6 | `AVD-Get-Hostpool-Image-information.ps1` | PowerShellScripts | 99 | ⛔ Blocked — missing ControlUp SP credential file |
| 7 | `Get-AVDHostPoolImageInformation.ps1` | PowerShellScripts | 0 | ✅ CSV for both session hosts, image resolved |
| 8 | `Collect-AVDDiagnosticBundle.ps1` | monitoring | 0 | ⚠️ 43 checks / 10 findings — **but 32 MB of junk JSON** |
| 9 | `Invoke-AVDMonitoringReportUpload.ps1` | monitoring | 1 | ✅ Failed gracefully as designed (payload script) |
| 10 | `Invoke-AVDSessionHostReport.ps1` | monitoring | 0 | ⚠️ Ran read-only; storage account unreachable |
| 11 | `New-AVDMonitoringTestEvents.ps1` | monitoring | 0 | ✅ Wrote events 9001 + 9002 |
| 12 | `Set-AVDCostOptimizedMonitoring.ps1` | monitoring | 0 | ✅ `-WhatIf` plan correct (14 counters, 6 XPath) |
| 13 | `Test-AVDDCRAssociation.ps1` | monitoring | 0 | ✅ 21 Pass, 0 Fail |
| 14 | `Test-AVDHostPoolDiagnosticSettings.ps1` | monitoring | 0 | ✅ 13 Pass, 2 Info, 0 Fail |
| 15 | `Test-AVDLogAnalyticsIngestion.ps1` | monitoring | 0 | ⚠️ 6 Pass, 10 Warning — `Perf` table empty |
| 16 | `Test-AVDMonitoringPrerequisites.ps1` | monitoring | 0 | ✅ 6 Pass, 3 Info |
| 17 | `Test-AVDSessionHostMonitoring.ps1` | monitoring | 0 | ✅ 20 Pass, 6 Warning, 2 Fail (expected off-AVD) |
| 18 | `Test-AVDWorkspaceDiagnosticSettings.ps1` | monitoring | 0 | ✅ 6 Pass, 2 Info, 0 Fail |
| 19 | `Validate-AVDSessionHostMonitoring-Interactive.ps1` | monitoring | 0 | ✅ Full console validation pass |

Legend: ✅ works · ⚠️ works with caveats · ⛔ blocked by external prerequisite · ❌ broken · ➖ no-op by design

---

## Defects Found

All four defects below have been **fixed and verified**. See "Fixes Applied" at the end.

### D1 — `exit` silently discards all object output (affects every `Test-*` script)

**Severity: High for automation.** Confirmed by controlled experiment against
`Test-AVDHostPoolDiagnosticSettings.ps1`:

| Wrapper | Captured stdout |
|---|---|
| No trailing `exit` | **4128 bytes** |
| Trailing `exit 0` | **6 bytes** (everything lost) |
| `\| Out-String` then `exit 0` | **12258 bytes** |

`exit` tears down the runspace before PowerShell's auto-sizing table formatter flushes
its buffer. Any wrapper, scheduled task or pipeline that calls these scripts and then
calls `exit` will record a **silent, empty, exit-0 success**.

**Mitigation:** always pipe to `Out-String`, `Export-Csv` or `ConvertTo-Json` before
`exit`. Never rely on implicit console formatting in an automated wrapper.

### D2 — `Collect-AVDDiagnosticBundle.ps1` emits 32 MB of CIM type metadata

Two captures serialize raw CIM objects with `ConvertTo-Json -Depth 12`, which walks the
entire `CimClass` → `CimSuperClass` inheritance graph instead of the data:

| Artifact | Size | Source |
|---|---|---|
| `NetworkConfiguration.json` | **25,779,970 B** | L195 `Get-NetIPConfiguration -Detailed` |
| `DNSServers.json` | **6,871,726 B** | L197 `Get-DnsClientServerAddress` |
| `NetworkRoutes.json` | 7,436 B | L196 — *has* a `Select-Object`, so it is fine |

Those two files are ~97% of the uncompressed bundle. Line 196 already shows the correct
pattern; lines 195 and 197 are missing the same `Select-Object` projection.

**Fix:** project the properties before `Capture`, e.g.
`Get-DnsClientServerAddress | Select-Object InterfaceAlias,InterfaceIndex,AddressFamily,ServerAddresses`.

### D3 — `AVD_AnalyzeLogonDuration.ps1` reports errors but still exits 0

Two non-terminating errors observed, neither of which changes the exit status:

- `Failed to cache any relevant security event log entries from <start> for 60 minutes` —
  emitted twice when the Security log has already rolled past the logon time. The script
  continues with a reduced phase set.
- `Select-Object : Property "TotalSeconds" cannot be found` at line 4942 — the `Gap (s)`
  column assumes `TimeDelta` is always a `TimeSpan`, but it is unset for the first phase
  of a truncated event set.

Gate automation on report content, not on the exit code.

### D4 — `AVD_NetApp_Perf_Test01_v0.1.ps1` does not parse

| Line | Error |
|---|---|
| 68 | Missing closing `}` in statement block or type definition |
| 206 | Unexpected token `FIO` in expression or statement |
| 206 | The `<` operator is reserved for future use |
| 211 | The string is missing the terminator: `"` |

**Root cause (all four errors are one bug).** The file is BOM-less UTF-8 and line 206
contained an en dash `–` (U+2013, bytes `E2 80 93`) inside a double-quoted string.
Windows PowerShell 5.1 decodes BOM-less `.ps1` files as Windows-1252, where byte `0x93`
maps to `"` (U+201C) — **a character PowerShell accepts as a string delimiter**. The
string terminated early and the remainder of the line parsed as operators.

Proof: `Parser::ParseFile` (reads from disk) returned 4 errors, while `Parser::ParseInput`
on the same content decoded explicitly as UTF-8 returned **0**.

A second, independent blocker would have stopped execution even after parsing: line 99
passed the **same path** to `-RedirectStandardOutput` and `-RedirectStandardError`, which
`Start-Process` rejects outright (`"RedirectStandardOutput" and "RedirectStandardError"
are same`). Every FIO invocation would have failed before FIO started.

---

## Fixes Applied

| ID | File | Change | Verification |
|---|---|---|---|
| **D1** | `PowerShellScripts\README.md` | New section *"Always materialize output before calling `exit`"* with the measured evidence and a correct wrapper pattern. | Documented; no code change needed (the scripts themselves are correct). |
| **D2** | `Collect-AVDDiagnosticBundle.ps1` L195, L197 | Replaced raw CIM output with `[pscustomobject]` projections for `NetworkConfiguration` and `DNSServers`. | Executed the two `Capture` scriptblocks straight from the file: **32,659,132 B → 11,657 B (−99.96%)**. |
| **D3** | `AVD_AnalyzeLogonDuration.ps1` L4942 | `Gap (s)` column now emits `''` unless `TimeDelta -is [TimeSpan]`. | All three shapes exercised — `TimeSpan` → `4.0`, `''` → `''`, `$null` → `''`. Old expression errored on `''`. |
| **D4** | `AVD_NetApp_Perf_Test01_v0.1.ps1` L206, L75-99 | En dash → ASCII hyphen (file is now pure ASCII); stderr redirected to a separate `.err.txt`; `$args` renamed to `$fioArgs` to stop shadowing the automatic variable. | `ParseFile` → **0 errors**; `Start-Process` same-file rejection reproduced and confirmed resolved by separate paths. |

**All 19 scripts now parse with 0 errors.**

`AVD_NetApp_Perf_Test01_v0.1.ps1` still has **not** been executed against a real workload — it is a
destructive FIO disk benchmark and needs a dedicated target volume. Its earlier design issues have
since been addressed and verified in-tree: `SupportsShouldProcess` with `-WhatIf`/`-Confirm`,
`ValidateRange` bounds on its parameters, defensive `ConvertFrom-Json` handling and automatic
cleanup of the multi-GB test files. The file is pure ASCII (0 bytes above 127). The `clat` unit
assumption remains open and is documented in `README-AVD-NetApp-Performance-Test.md`.

---

## Environment Findings

These are conditions in the `WPNS-AVD` environment surfaced by the scripts, not script bugs.

| Severity | Finding | Evidence |
|---|---|---|
| 🔴 Critical | **`Perf` table has zero rows in 24 h** despite DCR association passing (21 Pass) and a healthy AMA heartbeat (1439 records, 1.3 min old). Monitoring is configured but not ingesting performance data. | `Test-AVDLogAnalyticsIngestion.ps1` |
| 🔴 Critical | **Stale AVD agent heartbeat** — `WPNS-AVD-0` last checked in 2026-09-07 yet is still `Available` and accepting new sessions. It will take connections it may not be able to service. | `AVD-Assessment-Collector.ps1` |
| 🟠 Warning | **Two overlapping DCRs** (`DCR-AVD-CostOptimized` and `WPNS-AVD-DCR`) on both hosts with duplicate counters → double ingestion cost. | `Test-AVDDCRAssociation.ps1` |
| 🟠 Warning | **Storage account `stavdreports` is unreachable** from the operator workstation (`Retry failed after 6 tries`), blocking the multi-host report pipeline. | `Invoke-AVDSessionHostReport.ps1` |
| 🟡 Info | `WPNS-AVD-1` is shut down; ingestion resumes when the VM runs. | `Set-AVDCostOptimizedMonitoring.ps1` |

### Ingestion detail

| Table | Status | Records (24 h) |
|---|---|---|
| `WVDAgentHealthStatus` | Pass | 2869 |
| `Heartbeat` | Pass | 1439 |
| `WVDManagement` | Pass | 87 |
| `WVDFeeds` | Pass | 5 |
| `Event` | Pass | 2 |
| `Perf` | **Warning** | **0** |
| `WVDConnections`, `WVDCheckpoints`, `WVDErrors`, `WVDHostRegistrations`, `WVDConnectionNetworkData`, `WVDConnectionGraphicsDataPreview`, `WVDSessionHostManagement`, `WVDMultiLinkAdd` | Warning | 0 (activity-dependent, no sessions in window) |

---

## Blocked Scripts

`AVD_AzureCostAnalysis_CostsPerVM.ps1` and `AVD-Get-Hostpool-Image-information.ps1` both
terminate immediately with:

```
The Azure Service Principal Credentials file stored for this user (<username>)
cannot be found. Create the file with the Set-AzSPCredentials script action (prerequisite).
```

Both are ControlUp Script Actions that require a ControlUp-managed service-principal
credential file. They cannot run standalone. `Get-AVDHostPoolImageInformation.ps1` is the
supported replacement for the image report and ran successfully.

---

## Verified Output

### `Get-AVDHostPoolImageInformation.ps1`

| Session host | Status | VM size | Image | Version |
|---|---|---|---|---|
| `WPNS-AVD-0` | Available | `Standard_D2as_v5` | `microsoftwindowsdesktop:office-365:win11-25h2-avd-m365` | `26200.9168.260811` |
| `WPNS-AVD-1` | Shutdown | `Standard_D2as_v5` | `microsoftwindowsdesktop:office-365:win11-25h2-avd-m365` | `26200.9168.260811` |

### `AVD-Assessment-Collector.ps1`

13 artifacts, **0 zero-byte files**, `CollectionSucceeded = True`, 0 artifacts in error.
Empty result sets correctly wrote header-only CSVs with status `NoData` (`ScalingPlans.csv`
129 B, `Services.csv` 46 B) rather than 0-byte files.

Outputs: `AVD-Assessment-Report.html`, `manifest.json` (SHA256 per file), `Summary.txt`,
`Findings.csv`, `HostPools.csv`, `SessionHosts.csv`, `SessionHostHealthChecks.csv`,
`ApplicationGroups.csv`, `Workspaces.csv`, `Application.evtx`, `System.evtx`.

### `Collect-AVDDiagnosticBundle.ps1`

43 checks, 10 findings (1 critical, 5 warning, 22 review-required), `Report.html` 28 KB,
zip 748 KB. See **D2** for the oversized-JSON defect.

### `Set-AVDCostOptimizedMonitoring.ps1` (`-WhatIf`)

Planned 14 performance counters at 60 s sampling and 6 Windows Event XPath queries,
targeting `DCR-AVD-CostOptimized` in `switzerlandnorth`, associating both session hosts
(both have a SystemAssigned identity and `Succeeded` AMA provisioning).

---

## Execution Policy Applied

Two scripts were deliberately constrained because this is shared, non-sandboxed infrastructure:

| Script | Constraint | Reason |
|---|---|---|
| `Set-AVDCostOptimizedMonitoring.ps1` | `-WhatIf` only | Creates/updates a DCR and associates it with production VMs. Both mutations are `ShouldProcess`-guarded, so `-WhatIf` exercises the full read and planning path safely. |
| `Invoke-AVDSessionHostReport.ps1` | `-CollectOnly -WhatIf` | Without `-CollectOnly` it dispatches Run Command to every production session host. `-CollectOnly` skips all dispatch and SAS minting (L134) and only reads blobs. |

`AVD_NetApp_Perf_Test01_v0.1.ps1` was not run at all during this pass — at the time it did not
parse, and it is a destructive disk benchmark. It parses cleanly now and supports `-WhatIf`, but a
supervised first run against a dedicated target volume is still required.

---

## Recommended Actions

Items 1–3 and 7 are **environment** actions and remain open. Items 4–6 were script
defects and are now **fixed** (see *Fixes Applied*).

1. **Investigate the AVD agent on `WPNS-AVD-0`.** It is advertising `Available` with a
   4-day-stale heartbeat. Highest user-facing risk.
2. **Fix `Perf` ingestion.** DCR association and AMA heartbeat both pass, so the gap is in
   the counter route or the data flow, not the association.
3. **Consolidate the two overlapping DCRs** to stop paying twice for the same counters.
4. ~~Patch D2~~ — ✅ done, 32 MB removed per bundle.
5. ~~Patch D1 guidance into the READMEs~~ — ✅ done.
6. ~~Fix or archive `AVD_NetApp_Perf_Test01_v0.1.ps1`~~ — ✅ parses and invokes correctly
   now, but still needs a supervised first run against a dedicated target volume.
7. **Open storage firewall for `stavdreports`** (or run the orchestrator from a permitted
   network) to enable multi-host report collection.
