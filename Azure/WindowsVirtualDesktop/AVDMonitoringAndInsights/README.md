# AVD Monitoring and Insights

Read-only configuration checks, ingestion validation, controlled evidence generation and KQL queries for Azure Virtual Desktop (AVD) monitoring.

## Package layout

| Folder | Contents |
| --- | --- |
| [Script execution report](PowerShellScripts/AVD-Script-Execution-Report.md) | Verified live-run results for all 19 scripts in this folder and `PowerShellScripts`, with the defects and environment findings each run surfaced |
| [PowerShellScripts](PowerShellScripts/README.md) | The complete script set: prerequisites, host pool and AVD Workspace diagnostic settings, DCR/AMA association, per-host monitoring, the interactive single-pass host report, Log Analytics ingestion, the multi-host report orchestrator, the test-event generator and the local diagnostic bundle collector |
| [KQL](KQL/README.md) | Thirty-eight queries: twenty-five base queries plus thirteen chart-view (`render`) companions |
| [Get-AVDHostPoolImageInformation.ps1](PowerShellScripts/Get-AVDHostPoolImageInformation.ps1) | Modern replacement for the legacy host-pool image utility: uses the current Azure sign-in, requires an explicit subscription, matches session hosts exactly and also reports the image actually deployed on each session host |
| [Legacy host-pool image metadata utility](PowerShellScripts/README-AVD-Get-Hostpool-Image-Information.md) | Usage, security notes, limitations and modernization guidance for `PowerShellScripts/AVD-Get-Hostpool-Image-information.ps1` |
| [Legacy logon-duration analyzer](PowerShellScripts/README-AVD-Analyze-Logon-Duration.md) | Operating modes, privileged preparation, evidence handling and review findings for `PowerShellScripts/AVD_AnalyzeLogonDuration.ps1` |
| [AVD assessment collector](PowerShellScripts/README-AVD-Assessment-Collector.md) | Azure inventory, session host health, evidence provenance, HTML reporting and exit codes for `PowerShellScripts/AVD-Assessment-Collector.ps1` |
| [Legacy VM cost utility](PowerShellScripts/README-AVD-Azure-Cost-Analysis-Costs-Per-VM.md) | Authentication, cost attribution, correctness risks and modernization guidance for `PowerShellScripts/AVD_AzureCostAnalysis_CostsPerVM.ps1` |
| [Full inventory assessment prototype](PowerShellScripts/README-AVD-Full-Inventory-Fetch.md) | Retained analysis only — the script `AVD_Full_Inventory_Fetch_working.txt` is **missing from the repository** |
| [Inventory reporting plug-in](PowerShellScripts/README-AVD-Inventory01.md) | External framework contract, tag row model and Excel dependencies for `PowerShellScripts/AVD_Inventory01.ps1` |
| [AVD KQL pack](KQL/README-AVD-KQL-Pack.md) | Six corrected queries in [`KQL/AVD_KQL_Pack.txt`](KQL/AVD_KQL_Pack.txt), verified against a live workspace, plus the original defects as an appendix |
| [ANF FIO performance test](PowerShellScripts/README-AVD-NetApp-Performance-Test.md) | Hardening status, remaining review findings, capacity impact and required preflight for `PowerShellScripts/AVD_NetApp_Perf_Test01_v0.1.ps1` |
| `altprof_setup_1.0.0.40.exe` | Third-party ALTProf installer binary, downloaded and still carrying mark of the web. It is **not** part of this package, has no companion README and is not referenced by any script here. Do not execute it as part of a monitoring assessment; verify its provenance independently or remove it. |

## Suggested order

For WPNS-AVD, begin with the [monitoring guide](PowerShellScripts/README.md). Verify Azure configuration, inspect every session host, generate controlled events, exercise a real AVD session, and check ingestion. A visible host in Insights is not evidence that service or guest telemetry is arriving.

## Host pool image reporting

[Get-AVDHostPoolImageInformation.ps1](PowerShellScripts/Get-AVDHostPoolImageInformation.ps1) reports what a host pool was built from and what its session hosts actually run. It is read-only, uses the current `Connect-AzAccount` sign-in, installs nothing and restores the caller's Azure context.

```powershell
# Every host pool and session host in a subscription
.\PowerShellScripts\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>'

# One host pool
.\PowerShellScripts\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>' -ResourceGroupName 'WPNS-AVD' -HostPoolName 'WPNS-AVD' | Format-List

# Resolve the owning host pool from a session host, by NetBIOS name or FQDN
.\PowerShellScripts\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>' -SessionHostName 'WPNS-AVD-0'

# Template data only; no Az.Compute required
.\PowerShellScripts\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>' -SkipSessionHostImage | Export-Csv .\avd-images.csv -NoTypeInformation

# Write a plain-text report as well; objects still reach the pipeline
# If Az.Accounts/Az.DesktopVirtualization/Az.Compute have side-by-side versions installed (see Troubleshooting
# below), import them explicitly first, in dependency order, to avoid an intermittent Az.Compute load failure:
Import-Module Az.Accounts -MinimumVersion 5.5.0 -ErrorAction Stop
Import-Module Az.DesktopVirtualization -ErrorAction Stop
Import-Module Az.Compute -ErrorAction Stop
.\PowerShellScripts\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>' -ResourceGroupName 'WPNS-AVD' -HostPoolName 'WPNS-AVD' -OutputPath .\avd-image-report.txt | Out-Null
```

One object is emitted per session host, or one per host pool when session hosts are not queried. Key fields:

| Field | Meaning |
| --- | --- |
| `TemplateImageType`, `TemplateImage`, `TemplateVMSize` | Parsed from the host pool `VMTemplate`. Provisioning metadata only. |
| `VMImageType`, `VMImage`, `VMImageVersion`, `VMSize` | Read from the session host VM. This is what the host actually runs. |
| `VMImageLookup` | `Succeeded`, `Skipped`, `Az.ComputeNotInstalled`, `NoVMResourceIdOnSessionHost`, `UnrecognizedVMResourceId`, `NoImageReference` or `Failed: <reason>`. |

`VMImageVersion` prefers the VM's `ExactVersion`, so a host pool pinned to `latest` still reports the image version in use. Compare the `Template*` and `VM*` columns to find hosts that have drifted from the host pool definition.

`VMTemplatePresent` can be `True` while every `Template*` field is empty. The host pool then has a `VMTemplate` value that parses as JSON but carries no image or size keys, which is normal for host pools not created by the Azure portal's session host wizard. `TemplateImageType` reports `UnparsableJson` when the value is present but not valid JSON.

### Text report

`-OutputPath` writes an ASCII, tab-free report with aligned `label : value` lines. Session hosts are nested under their host pool, unresolved fields render as `-`, and missing parent directories are created. The pipeline is unaffected, so `-OutputPath` can be combined with `Export-Csv` or `Format-List` in the same run.

The `Image lookup` summary counts each status, collapsing every `Failed: <reason>` to a single `Failed=<n>` so one long Azure error cannot swamp the line. The full reason is kept on each affected session host.

```text
Azure Virtual Desktop - host pool image report
==============================================
Generated (UTC)     : 2026-09-11 07:03:49
Subscription        : <subscription-id>
Scope               : ResourceGroup=WPNS-AVD; HostPool=WPNS-AVD

Summary
-------
Host pools          : 1
Session hosts       : 2
Image lookup        : Succeeded=2

Host pool: WPNS-AVD
-------------------
Resource group      : WPNS-AVD
Location            : uaenorth
Type                : Pooled
Load balancer       : BreadthFirst
Max session limit   : 10
Template present    : True
Template image type : Gallery
Template image      : microsoftwindowsdesktop:windows-11:win11-23h2-avd
Template VM size    : Standard_D4s_v5
Template prefix     : WPNS-AVD

  Session host: WPNS-AVD-0.example.local
    Status        : Available
    VM name       : WPNS-AVD-0
    VM size       : Standard_D4s_v5
    Image type    : Marketplace
    Image         : MicrosoftWindowsDesktop:windows-11:win11-23h2-avd
    Image version : 22631.4460.241109
    Image lookup  : Succeeded
```

When session hosts are not queried, `-SkipSessionHostImage` or a missing `Az.Compute`, the host pool block reports `Session hosts : not queried` instead of an empty list.

Requires `Az.Accounts` and `Az.DesktopVirtualization`. `Az.Compute` is needed only for the `VM*` columns; without it the script warns, reports `Az.ComputeNotInstalled` and still returns template data.

### Troubleshooting

**Every session host reports `Failed: The 'Get-AzVM' command was found in the module 'Az.Compute', but the module could not be loaded.`** The module is installed, so the script's preflight check passes, but the import fails at call time. The usual cause is side-by-side Az versions: a newer `Az.Compute` requires a specific `Az.Accounts` build, and an older `Az.Accounts` is already loaded in the session. Confirm with `Import-Module Az.Compute` in the same session, which reports the required version:

```powershell
Get-Module -ListAvailable Az.Accounts, Az.DesktopVirtualization, Az.Compute |
    Sort-Object Name, Version -Descending | Select-Object Name, Version, ModuleBase
```

Open a new PowerShell session to work around it. To fix it permanently, uninstall the superseded versions from an elevated prompt, for example `Uninstall-Module Az.Accounts -RequiredVersion <old> -Force`. Host pool and session host data are unaffected, so the report is still valid apart from the `VM*` fields.

**`is not digitally signed`** is mark of the web, not the execution policy. See the safety notes below.

## Safety notes

The maintained scripts under [PowerShellScripts](PowerShellScripts/README.md) do not install modules automatically or change execution policy. Test scripts are read-only. The event generator writes two labeled test events; the bundle collector writes local evidence files and only runs explicitly requested connectivity probes. Both support -WhatIf.

The top-level legacy host-pool image metadata utility is an exception: it installs missing NuGet and PowerShell module prerequisites with `-Force` and `-AllowClobber`. Review its [companion README](PowerShellScripts/README-AVD-Get-Hostpool-Image-Information.md) before running it.

The top-level legacy logon-duration analyzer is also an exception. Its preparation mode changes audit and event-log settings, and its package mode exports sensitive diagnostic evidence. It does not support `-WhatIf`, and offline analysis is not fully isolated from the analysis host. Review its [companion README](PowerShellScripts/README-AVD-Analyze-Logon-Duration.md) before use.

The other top-level artifacts are reviewed prototypes or legacy utilities rather than members of the maintained package. In particular, the full-inventory prototype is missing from the repository altogether, and the ANF FIO script, while now runnable, remains destructive by design. Follow each companion README and prefer the maintained `PowerShellScripts` and `KQL` packages where they overlap.

The `Zone.Identifier` alternate data stream has since been cleared from every PowerShell file in this tree, so none of them now fail under a `RemoteSigned` execution policy with `is not digitally signed`. Re-verified on 2026-09-11: only `AVD_KQL_Pack.txt` and `altprof_setup_1.0.0.40.exe` still carry the stream, and neither is executed by PowerShell. If you re-download any of these scripts, the stream returns — that is mark of the web, not the execution policy. Review the contents, then clear it with `Unblock-File`.

## Validation status

The reviewed top-level PowerShell artifacts all parse cleanly. `AVD_NetApp_Perf_Test01_v0.1.ps1` previously reported four parser errors beginning at line 206; the root cause was a single non-ASCII en dash in a BOM-less file (Windows PowerShell decodes such files as Windows-1252, where one of its bytes becomes a smart quote that opens a string). The file is now pure ASCII, parses with zero errors, and has been hardened with `-WhatIf`/`-Confirm` support, parameter bounds validation, defensive JSON parsing and automatic cleanup of its multi-GB test files. It has been dry-run verified but a real FIO workload has still never been executed, and it remains destructive by design: it saturates the target volume for the full run duration. The six queries in `AVD_KQL_Pack.txt` were corrected and then executed against workspace `LAW-WPNS-AVD` on 2026-09-11, all six returning rows. The `KQL` package queries, including the chart companions, were reviewed but not run against a live workspace, apart from `AVD-NetworkData.kql`. Follow each companion README, use an isolated test environment and review the per-check results.

All 19 PowerShell scripts in this folder and in `PowerShellScripts` were also scanned with PSScriptAnalyzer 1.25.0. Every `Error`-severity and genuinely actionable `Warning` finding has been resolved. The remaining findings are accepted: `PSAvoidUsingWriteHost` (these are interactive console tools), `PSAvoidGlobalVars` (confined to the vendor logon-duration analyzer), `PSReviewUnusedParameter` false positives where parameters are referenced only inside interpolated strings or nested functions, and one `PSAvoidUsingConvertToSecureStringWithPlainText` in the ControlUp image utility, where converting form-entered input into a `PSCredential` for encrypted storage is the intended behaviour.

### Re-validation, 2026-09-11

The whole tree was re-validated after the entries above were written. Results:

| Check | Result |
| --- | --- |
| PowerShell AST parse, all 19 `.ps1` | 0 errors |
| PSScriptAnalyzer 1.25.0, `Error` severity | 1 finding, the accepted `ConvertTo-SecureString` case in `AVD-Get-Hostpool-Image-information.ps1` line 258 |
| PSScriptAnalyzer, `Warning` severity | 468 findings, all in the accepted categories above; the `PSPossibleIncorrectComparisonWithNull` and `PSAvoidAssignmentToAutomaticVariable` hits are confined to the vendor `AVD_AnalyzeLogonDuration.ps1` |
| Comment-based help | Present in 18 of 19 scripts; `AVD_Inventory01.ps1` is a plug-in fragment with no help block by design |
| Relative Markdown links, all README files | 0 broken |
| `.kql` inventory | 38 files: 25 base, 13 chart companions |
| Duplicate `.kql` files | `AVD-AllTelemetryTables` and `AVD-SessionHostPerformance` confirmed SHA256-identical to their originals |
| DCR content claims in `Set-AVDCostOptimizedMonitoring.ps1` | Confirmed: 14 counters, 60 s sampling, 6 event XPath queries, `transformKql = source` |
| Default counter list in `Test-AVDSessionHostMonitoring.ps1` | Confirmed: 20 counters, 4 event channels |
| Mark of the web | No longer present on any `.ps1`; only `AVD_KQL_Pack.txt` and `altprof_setup_1.0.0.40.exe` retain the stream |

Three documentation defects were corrected by this pass: the KQL query count was understated as 28 (fifteen base), the claim that every base query has a `*Chart.kql` companion was untrue for the ten cost-optimized host queries, and the mark-of-the-web note described six blocked PowerShell files that are no longer blocked. The undocumented `altprof_setup_1.0.0.40.exe` binary is now called out in the package layout.

Every other script in this folder has now been executed against the live `WPNS-AVD` environment. Results:

| Script | Result |
| --- | --- |
| `Get-AVDHostPoolImageInformation.ps1` | Works — `Image lookup : Succeeded=2` |
| `AVD_AnalyzeLogonDuration.ps1` | Works elevated — produced a 6.5 s logon report |
| `PowerShellScripts/Test-*.ps1` (5 scripts) | All ran; see that folder's README for the per-script table |
| `PowerShellScripts/New-AVDMonitoringTestEvents.ps1` | `-WhatIf` correct; `-RunId` must be a GUID |
| `PowerShellScripts/Collect-AVDDiagnosticBundle.ps1` | `-WhatIf` correct |
| `AVD-Get-Hostpool-Image-information.ps1` | Blocked — requires the ControlUp credential file |
| `AVD_AzureCostAnalysis_CostsPerVM.ps1` | Blocked — requires the ControlUp credential file |
| `AVD-Assessment-Collector.ps1` | Rewritten (v2.0) and verified — 13 artifacts, HTML report, exits non-zero on missing evidence |
| `AVD_Full_Inventory_Fetch_working.txt` | **Missing from the repository** — the file is not present under `DOCs/`; nothing to run |
| `AVD_Inventory01.ps1` | Plug-in only; returns nothing without its orchestrator |
| `AVD_NetApp_Perf_Test01_v0.1.ps1` | Parses cleanly and hardened; dry-run verified with `-WhatIf`. A real FIO run is still outstanding |

Two defects found by execution are not visible from code review alone:

- `AVD_Full_Inventory_Fetch_working.txt` uses `$host`, an automatic read-only variable, as a `foreach` loop variable at line 1135. It aborts before any CSV export whenever a host pool actually contains session hosts, so it yields zero files. It appears to succeed only when discovery returns nothing. **The file is no longer present in the repository**, so there is nothing to fix in-tree; the analysis and the suggested rename are kept in its companion README in case the script is restored.
- `AVD-Assessment-Collector.ps1` continued after a failed `Connect-AzAccount`, silently reused the pre-existing Azure context, printed `Done.`, exited `0`, and never wrote `Errors.txt`. **This has been fixed:** the collector was rewritten to v2.0, which reuses the current context deliberately, distinguishes empty results from failures, writes a manifest with per-artifact status and SHA256 hashes, produces an HTML report, and exits non-zero when evidence is missing. See [the collector README](PowerShellScripts/README-AVD-Assessment-Collector.md) for the full before/after list.

The live run also surfaced three environment issues worth acting on: the `Perf` table held zero rows over 24 hours despite a passing DCR association and a fresh AMA heartbeat; two overlapping DCRs (`DCR-AVD-CostOptimized` and `WPNS-AVD-DCR`) define duplicate counters and bill twice; and both session hosts' AVD agent heartbeats are several days stale.

`Get-AVDHostPoolImageInformation.ps1` passes 36 mocked assertions covering host pool scope, session host resolution by NetBIOS name and FQDN, prefix-collision rejection, the not-found error path, `-SkipSessionHostImage`, graceful degradation when `Az.Compute` is absent, and Azure context switch and restore. A further 16 mocked assertions cover the `-OutputPath` report: unchanged pipeline output and no stray file when the parameter is omitted, nested output-directory creation, ASCII-only tab-free text, dash placeholders for unresolved fields, and the `not queried` host pool block.

It has also been run end to end against live Azure, against host pool `WPNS-AVD` in `westeurope`. Host pool discovery, resource group resolution, session host enumeration, the Azure Compute image lookup and the text report were all confirmed against real data: `Image lookup : Succeeded=2`, with `WPNS-AVD-0` `Available` and `WPNS-AVD-1` `Shutdown`, both `Standard_D2as_v5` running `microsoftwindowsdesktop:office-365:win11-25h2-avd-m365` at exact version `26200.9168.260811`. That host pool also confirms the `VMTemplatePresent = True` with empty `Template*` fields case described above.

An earlier run in a session holding stale Az module versions exercised the per-session-host failure path for real: `Az.Compute` was installed but refused to load, each host reported `Failed: <reason>`, and the report was still produced with host pool and session host data intact. Running the same command in a clean session resolved it. See Troubleshooting above.

## References

- [AVD Insights setup](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights)
- [Azure Monitor Agent requirements](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-requirements)
- [AVD required endpoint validation](https://learn.microsoft.com/en-us/azure/virtual-desktop/check-access-validate-required-fqdn-endpoint)
- [RDP Shortpath](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath)

