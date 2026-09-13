# Azure NetApp Files FIO Performance Test

> **Still unvalidated against real storage:** `PowerShellScripts/AVD_NetApp_Perf_Test01_v0.1.ps1` stresses an Azure NetApp Files SMB path. The two blockers that previously stopped it from running at all are now fixed (see below), but the script has **never been executed end to end** and remains a destructive workload. Revalidate it in an isolated test environment before any storage workload.

## Purpose

The script is designed to run five FIO workloads against a mapped SMB folder used to represent an AVD/FSLogix workload:

- 8 KiB random read.
- 8 KiB random write.
- 8 KiB random 70/30 read/write.
- 1 MiB sequential read.
- 1 MiB sequential write.

It intends to aggregate IOPS, throughput and latency into CSV and HTML reports.

## Intended Requirements

- Windows test VM sized to drive the target throughput.
- Windows FIO executable, default `C:\FIO\fio.exe`.
- Dedicated, empty test folder on the target Azure NetApp Files SMB volume.
- Enough volume quota and client capacity for all job files.
- A maintenance window with no production FSLogix users on the tested path.
- Permission to create, overwrite and delete large files in the test folder.

Never target a profile-container root, user folder or any path containing production data.

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `TargetPath` | Required | Dedicated SMB test folder. |
| `FioPath` | `C:\FIO\fio.exe` | Windows FIO executable. |
| `DurationSec` | 600 | Runtime for each of five workloads. |
| `FileSize` | `4G` | File size per FIO job. |
| `NumJobs` | Maximum of 4 or logical processors / 4 | Parallel jobs for random workloads. |
| `IoDepth` | 128 | Queue depth for random workloads. |
| `OutputDir` | `ANF-FIO-Results` beside the script | JSON, text, CSV and HTML report folder. |

Sequential workloads use `max(4, logical processors / 8)` jobs and queue depth 64.

## Capacity and Runtime

Potential retained test data is approximately:

$$
\text{FileSize} \times (3 \times \text{NumJobs} + 2 \times \text{SequentialJobs})
$$

With 4 GiB files and four jobs in all workloads, this is approximately 80 GiB. Five 600-second workloads require at least 50 minutes plus setup and report time. FIO behavior and file reuse can vary by version, so measure actual allocated space during a controlled pilot.

The script still has no free-space/quota preflight check. It does now clean up its FIO data files
(`Remove-FioTestFile`, ShouldProcess-guarded), but calculate required capacity before starting
rather than relying on cleanup after the fact.

## Resolved Blockers

Both defects that prevented the script from running at all have been fixed.

1. **Parse errors (fixed).** The file is BOM-less UTF-8 and line 206 contained an en dash
   (U+2013) inside a double-quoted string. Windows PowerShell 5.1 decodes BOM-less `.ps1`
   as Windows-1252, where the dash's third byte `0x93` becomes `"` (U+201C) — a character
   PowerShell accepts as a string delimiter. The string terminated early, producing four
   cascading errors (`Unexpected token 'FIO'`, `The '<' operator is reserved for future use`
   at line 206, an unterminated string at line 211 and a missing `}` at line 68).
   The dash was replaced with an ASCII hyphen; the file is now pure ASCII, so it decodes
   identically under any encoding. Verified: **0 parser errors**.
2. **Identical stdout/stderr redirection (fixed).** `Start-Process` refuses the command
   outright with `"RedirectStandardOutput" and "RedirectStandardError" are same`, so every
   FIO invocation failed before FIO started. Standard error now goes to a separate
   `<workload>.err.txt` file.

A third latent issue was fixed at the same time: the argument array was assigned to
`$args`, which shadows the automatic variable inside a function. It is now `$fioArgs`.

The script parses, its process invocation is well-formed and it has been `-WhatIf` dry-run
verified, but a real FIO workload has **never** been executed — it is a destructive disk
benchmark and requires a dedicated target.

## Intended Output

After repair, the script is designed to write:

- One `<workload>.json` FIO result per workload.
- One text process-output log per workload.
- `ANF-FIO-Summary.csv`.
- `ANF-FIO-Report.html`.

## Additional Review Findings

Resolved since the original review (verified in-tree on 2026-09-11):

- `SupportsShouldProcess` with `ConfirmImpact='High'` is now set on the script and on `Invoke-FioTest`, so `-WhatIf`/`-Confirm` protect the destructive workload (L18, L83, L117).
- `DurationSec`, `NumJobs` and `IoDepth` now carry `ValidateRange` bounds (L29, L37, L41).
- A nonzero FIO exit now warns **and skips that workload** instead of trying to parse its output (L123-L126).
- `ConvertFrom-Json` runs with `-ErrorAction Stop` against text that is read and checked first (L177).
- `Remove-FioTestFile` cleans up the FIO data files and reports the space freed, under its own `ShouldProcess` guard (L133-L150).
- The `clat` unit assumption is fixed: `clat_ns` is preferred, and the legacy `clat` field is scaled from microseconds by 1000 (L210-L226). Per-job latency values are also reset between jobs so a job without `clat` data no longer inherits the previous job's numbers (L205).

Still open:

- `FileSize` has no bounds validation.
- Mean latency averages per-job means without weighting by I/O count; missing job latency values bias the result downward.
- P99 recognizes only the key `99.000000` and silently reports zero when another FIO version uses a different shape.
- P99 is the maximum per-job percentile, while IOPS and bandwidth are summed; these aggregation semantics must be documented when comparing results.
- No free-space or volume-quota preflight check.
- No live FIO or Azure NetApp Files test has been run. `-WhatIf` dry-run verification is the only execution evidence to date.

## Required Preflight After Repair

1. Confirm zero parser errors and test the process invocation with a one-second, small-file workload.
2. Record VM size, NIC limits, ANF service level, pool size, volume quota, QoS mode, SMB settings and test time.
3. Calculate required capacity and verify available quota before starting.
4. Use a unique empty target folder and separate report folder.
5. Monitor client CPU/network and ANF throughput/IOPS during the run.
6. Stop on any nonzero FIO exit or malformed JSON.
7. Review results, then explicitly remove only the dedicated test folder after approval.

## References

- [Azure NetApp Files testing methodology](https://learn.microsoft.com/azure/azure-netapp-files/testing-methodology)
- [Azure NetApp Files benchmark recommendations](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-performance-metrics-volumes)
- [Azure NetApp Files SMB performance](https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-smb-performance)
- [FIO documentation](https://fio.readthedocs.io/en/latest/fio_doc.html)