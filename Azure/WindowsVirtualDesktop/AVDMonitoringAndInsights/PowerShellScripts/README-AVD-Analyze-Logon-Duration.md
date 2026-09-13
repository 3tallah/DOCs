# AVD Logon Duration Analyzer

> **Legacy privileged utility:** `AVD_AnalyzeLogonDuration.ps1` is a large ControlUp-oriented Windows logon diagnostics script. It reads local security and operational telemetry, can make persistent audit and event-log changes, and can export sensitive evidence. Review the operating modes and safety notes before use.

## Purpose

The script reconstructs a user's most recent local logon and reports the duration, start time, end time, and gap between detected phases. It can enrich the Windows timeline with data from Citrix, VMware, FSLogix, App Volumes, Ivanti Environment Manager, Group Policy, WMI filters, printers, scheduled tasks, AppX, and related providers when those products and logs are available.

Despite its AVD filename, the script does not query the Azure Virtual Desktop control plane. It analyzes a Windows session host or an evidence package collected from one.

## Operating Modes

| Mode | Trigger | Privilege | Behavior |
| --- | --- | --- | --- |
| Online analysis | `-DomainUser` | Administrator required | Reads the current machine's session, registry, services, LSA data, WMI and event logs, then writes a text report. |
| Machine preparation | `-PrepMachine <MB>` in the Online parameter set | Administrator required | Changes audit policy, command-line process logging, event-log enablement, retention and maximum sizes, then exits. |
| Evidence capture | `-CreateOfflineAnalysisPackage <folder>` | Administrator required | Exports event logs and supporting files into a folder, then continues analysis and writes package metadata. |
| Offline analysis | `-OfflineAnalysis <folder>` | No explicit administrator check | Loads a prior evidence package, but some code paths still query or copy data from the analysis machine. |

## Requirements

- Windows session host or Windows analysis workstation.
- Windows PowerShell 5.1 is the practical minimum. The file declares PowerShell 3, but it calls `Get-TimeZone`, which is documented for Windows PowerShell 5.1, and uses newer collection methods extensively.
- Administrator rights for Online, machine-preparation and evidence-capture modes.
- Access to the required local event logs and registry paths.
- Enough free space for copied event logs and vendor logs.
- An interactive host that supports `RawUI.BufferSize`; non-interactive hosts may reject console-buffer resizing.
- Relevant product providers and logs for optional Citrix, VMware, FSLogix, App Volumes or Ivanti measurements.

The script does not install PowerShell modules. It relies on Windows PowerShell, .NET types, native Windows commands and locally installed product providers.

## Parameters

| Parameter | Mode | Notes |
| --- | --- | --- |
| `DomainUser` | Online, capture | Use `DOMAIN\username`. Mandatory for Online and required in practice for package capture. |
| `SessionID` | Online, capture | Recommended when a user has multiple sessions. The script attempts local discovery when omitted. |
| `SessionName` | Online, capture | Usually similar to `RDP-Tcp#2`; also contributes to the default report filename. |
| `CUDesktopLoadTime` | Online, capture | Optional ControlUp shell-duration value. Both dot and comma decimal separators are handled. |
| `ClientName` | Online, capture | Optional endpoint/client name used by some phase calculations. |
| `SaveOutputTo` | Online only | Text report path. Its parent directory must exist when a custom path is supplied. |
| `PrepMachine` | Online only | Positive integer interpreted as the requested event-log size in MB. This invokes persistent machine changes. |
| `CreateOfflineAnalysisPackage` | Capture | Destination folder for exported evidence. Although typed as `FileInfo`, it is used as a directory. |
| `OfflineAnalysis` | Offline | Folder containing a previously captured package. Although typed as `FileInfo`, it is used as a directory. |

## Usage

Run from an elevated Windows PowerShell 5.1 session for Online, preparation and capture modes.

The script hard-fails early with `This script must be run with administrative privilege` when the session is not elevated, so start the shell with **Run as administrator** before any of the commands below. The file was downloaded and originally carried a `Zone.Identifier` stream, which `RemoteSigned` rejects as `is not digitally signed`; that stream has been cleared in-tree as of 2026-09-11, so no `Unblock-File` step is needed unless you re-download the script.

### Online analysis

```powershell
& '.\PowerShellScripts\AVD_AnalyzeLogonDuration.ps1' `
    -DomainUser 'CONTOSO\user1' `
    -SessionID 4 `
    -SessionName 'RDP-Tcp#4' `
    -SaveOutputTo 'C:\Temp\ALD\user1-session4.txt' `
    -Verbose
```

The target user must have a relevant local session. Specify `SessionID` when concurrent or disconnected sessions could make automatic discovery ambiguous.

### Prepare a test machine

```powershell
& '.\PowerShellScripts\AVD_AnalyzeLogonDuration.ps1' `
    -DomainUser 'CONTOSO\user1' `
    -PrepMachine 100 `
    -Verbose
```

`DomainUser` is required because `PrepMachine` belongs to the Online parameter set, even though preparation itself does not use the selected user's logon.

### Capture an evidence package

```powershell
& '.\PowerShellScripts\AVD_AnalyzeLogonDuration.ps1' `
    -DomainUser 'CONTOSO\user1' `
    -SessionID 4 `
    -SessionName 'RDP-Tcp#4' `
    -CreateOfflineAnalysisPackage 'C:\Temp\ALD-user1-session4' `
    -Verbose
```

### Analyze a captured package

```powershell
& '.\PowerShellScripts\AVD_AnalyzeLogonDuration.ps1' `
    -OfflineAnalysis 'C:\Temp\ALD-user1-session4' `
    -Verbose
```

The default Offline report filename is generated before identity details are loaded from `logon.json`, so it may contain blank user/session segments. `SaveOutputTo` is not available in the Offline parameter set.

## Report Contents

`SaveOutputTo` writes the report as **UTF-16LE**, not UTF-8 or ASCII. Tools that assume UTF-8 render it as text with a space between every character. Read it with an explicit encoding:

```powershell
Get-Content 'C:\Temp\ALD\user1-session4.txt' -Encoding Unicode
```

The text report can include:

- Overall logon start, end and duration.
- Windows phases such as profile, Group Policy, userinit, shell, network providers and App Readiness.
- Per-phase duration, timestamps and gaps.
- Citrix HDX, profile and client-startup data.
- VMware Horizon, DEM and App Volumes phases.
- FSLogix profile timing and failure information.
- Ivanti Environment Manager phases and warnings.
- Printer mapping, scheduled task, AppX and WMI-filter timing.
- Warnings for missing logs, events, providers, audit settings or ambiguous evidence.

Timings are reconstructed from available records and vendor telemetry. Missing, overwritten, disabled or overlapping events can produce incomplete or approximate results.

## Machine-Preparation Side Effects

`PrepMachine` has no `-WhatIf` support and does not save or restore prior settings. It can:

- Set the Security log to overwrite old events when full with retention and automatic backup disabled.
- Enable command-line data in process creation event 4688 by setting `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit\ProcessCreationIncludeCmdLine_Enabled` to `1`.
- Enable and resize multiple Windows operational logs.
- Enable successful Process Creation and Process Termination auditing through the local security policy API.
- Increase Security and operational log storage requirements and event volume.

Command-line process auditing stores process arguments in plain text in the Security event log. Microsoft warns that arguments can contain passwords or other private data. Confirm organizational policy, retention, SIEM ingestion and access controls before enabling it.

Use preparation only on an approved test or session host. Record the existing event-log and audit configuration first and define a rollback procedure outside this script.

## Evidence Package Security

The capture folder can contain Security and Application event logs, Group Policy and session logs, usernames, SIDs, process command lines, service inventory, profile paths, client details, GPO names, application information and vendor logs. Treat it as sensitive diagnostic evidence:

- Store it in an access-controlled folder.
- Encrypt it at rest and during transfer.
- Apply the shortest practical retention period.
- Review it before sending it to a third party.
- Never commit captured packages to source control.

## Review Findings and Known Limitations

- Offline mode is not fully offline. Ivanti code paths query live `Application` and `AppSense` logs, WMI fallback paths query the live WMI-Activity provider, and the workflow can copy the analysis machine's live `svservice.log` into the package.
- The declared PowerShell 3 minimum is inaccurate because the script uses `Get-TimeZone` and newer collection APIs. Use Windows PowerShell 5.1.
- Invalid `CUDesktopLoadTime` input writes an error and exits with status code `0`, so automation can misclassify failure as success.
- Preparation applies persistent system changes without `ShouldProcess`, `-WhatIf`, rollback or a saved baseline.
- Capture invokes `wevtutil export-log` repeatedly without checking each native exit code, so a partial package can continue through analysis.
- Asynchronous event-log jobs have no timeout. `EndInvoke()` can wait indefinitely when a provider or query stalls.
- The runspace pool is opened but never explicitly closed or disposed, which matters when the script runs repeatedly in a long-lived host.
- Live and offline paths share extensive global state. Dot-sourcing the file or invoking it repeatedly in one PowerShell host can retain or overwrite state.
- Session discovery depends on local WTS data and exact `DOMAIN\username` matching; multiple sessions require `SessionID`.
- The help example calls `Get-LogonDurationAnalysis` directly, but normal use is invoking the script file and its script-level parameters.
- Online mode has been run successfully on a local, non-AVD Windows console session (Windows PowerShell 5.1, elevated): the script parsed cleanly, produced a complete phase breakdown and wrote the `SaveOutputTo` report. It has **not** been run against an AVD session host, an RDP session or a real evidence package.
- When the Security log has already rolled past the logon time, the script writes the non-terminating error `Failed to cache any relevant security event log entries from <start> for 60 minutes. Oldest event is <oldest>` and then continues with a reduced phase set. The message is emitted twice (once formatted, once raw). Treat any report produced after this error as incomplete rather than as a clean result.
- A formatting defect surfaces as `Select-Object : Property "TotalSeconds" cannot be found` at line 4942. The `Gap (s)` column expression assumes `TimeDelta` is always a `TimeSpan`, but it is unset for the first phase in a truncated event set. The error is non-terminating and the table still renders with an empty gap cell.
- Neither of the two errors above changes the exit status: the run still ends with exit code `0` and `$LASTEXITCODE` unset. Gate automation on the presence of report content, not on the exit code.
- With `Process Creation` auditing set to `No Auditing`, the run still completes but degrades to warnings rather than failing. Observed warnings included `Auditing of "Process Creation" is not set to at least "Success" as required`, missing Group Policy event ID 5016 CSE-finish instances, missing network-provider and Pre-Shell (Userinit) start events, and absent AppX package load times on a non-first logon. Vendor phases for FSLogix and VMware DEM warn rather than fail when those products are not installed, which is the expected result on a non-AVD host.

For forensic or audit use, fix the offline/live data separation before relying on package results as evidence provenance.

## Recommended Modernization

1. Raise `#Requires` to Windows PowerShell 5.1 and validate all required native commands and providers at startup.
2. Split preparation, collection, online analysis and offline analysis into separate scripts or functions with explicit contracts.
3. Make offline analysis reject every live provider, registry and file-system fallback.
4. Add `SupportsShouldProcess`, a configuration backup and rollback for preparation changes.
5. Check every native command exit code and write a package manifest containing hashes, collection status and source-machine metadata.
6. Replace `exit 0` error paths with terminating errors and nonzero process exit codes.
7. Add runspace timeouts and dispose the pool in `finally`.
8. Minimize global variables and return structured objects before formatting or writing text.

## References

- [Get-WinEvent](https://learn.microsoft.com/powershell/module/microsoft.powershell.diagnostics/get-winevent)
- [Get-TimeZone for Windows PowerShell 5.1](https://learn.microsoft.com/powershell/module/microsoft.powershell.management/get-timezone?view=powershell-5.1)
- [wevtutil command reference](https://learn.microsoft.com/windows-server/administration/windows-commands/wevtutil)
- [Command-line process auditing](https://learn.microsoft.com/windows-server/identity/ad-ds/manage/component-updates/command-line-process-auditing)
- [Advanced Audit Policy Configuration](https://learn.microsoft.com/windows-server/identity/ad-ds/plan/security-best-practices/advanced-audit-policy-configuration)
- [Event 4688: A new process has been created](https://learn.microsoft.com/windows/security/threat-protection/auditing/event-4688)