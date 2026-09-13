# AVD Full Inventory Assessment Prototype

> **⚠️ The script this README documents is not present in the repository.** `AVD_Full_Inventory_Fetch_working.txt` cannot be found anywhere under `DOCs/`. This README is retained only because the defect analysis below remains valid and should be applied if the file is ever restored. There is currently nothing to run, and nothing to fix in-tree.

> **Currently non-functional — it cannot produce output:** `AVD_Full_Inventory_Fetch_working.txt` aborts with `Cannot overwrite variable Host because it is read-only or constant.` as soon as it processes a host pool that actually contains session hosts, and it writes **no CSV files at all**. See [Blocking defect](#blocking-defect-cannot-overwrite-variable-host) before use.

> **Prototype with synthetic results:** Even after that defect is fixed, its connection, FSLogix and security "advanced insights" contain hardcoded or inferred values. Do not use the Advanced Insights CSV for security, compliance, user-experience or audit decisions.

## Blocking defect: `Cannot overwrite variable Host`

Line 1135 uses `$host` as a `foreach` loop variable:

```powershell
foreach ($host in $hostsInPool) {
```

`$Host` is a PowerShell **automatic, read-only variable** (the host UI object), so the assignment throws a terminating `SessionStateUnauthorizedAccessException`. The failure occurs inside the `Generating Host Pool Summary Report` stage, which runs **before** any CSV is exported, so a run that discovers real data ends with zero output files.

The defect is masked when discovery returns nothing: with no session hosts the loop body never executes, the script completes normally and prints `No data collected. No file will be created.` A "clean" run against an empty or inaccessible subscription is therefore not evidence that the script works.

Fix by renaming the loop variable (and its three uses in the loop body) to something that is not automatic, for example:

```powershell
foreach ($poolHost in $hostsInPool) {
    if ($poolHost.SessionsPerVCPU -gt 0) {
        $avgSessionsPerVCPU += $poolHost.SessionsPerVCPU
    }
    $sessionDensityStatuses += $poolHost.SessionDensityStatus
}
```

Re-test afterwards against a host pool that has at least one session host, and confirm all three CSVs exist and have more than a header row.

## Purpose

The PowerShell content discovers AVD workspaces, host pools and session hosts, maps hosts to Azure VMs, gathers configuration and Azure Monitor metrics, applies sizing heuristics, and writes detailed and host-pool CSV reports.

The file has a `.txt` extension. Review it and save an approved copy with a `.ps1` extension before execution; normal PowerShell script invocation and execution-policy handling are designed for `.ps1` files.

## Requirements

- PowerShell with `Az.Accounts`, `Az.DesktopVirtualization`, `Az.Compute`, `Az.Monitor` and `Az.Resources`.
- An existing Azure context in the intended subscription; the script does not sign in or select a subscription.
- `Reader`, `Desktop Virtualization Reader` and `Monitoring Reader`, or equivalent read permissions.
- Azure Monitor metrics available for each VM.
- A writable parent directory for the chosen output prefix.

The script reads Azure resources and writes local CSV files. It does not modify Azure resources.

## Parameters

| Parameter | Behavior |
| --- | --- |
| `OutputPath` | Filename prefix, default `./AVD-Complete-Assessment`. |
| `MetricDays` | Metric lookback, default 30 days. |
| `TimeGrainMinutes` | Requested metric interval, default 60 minutes. |
| `LogAnalyticsWorkspaceId` | Declared but unused. |
| `LogAnalyticsResourceGroup` | Declared but unused. |
| `IncludePeakAnalysis` | Declared but unused. |
| `IncludeHostPoolSummary` | Declared but ignored; the summary is always generated. |
| `IncludeAdvancedInsights` | Controls generation of the synthetic/inferred advanced-insights rows; default is enabled. |

For inventory-only evaluation, explicitly pass `-IncludeAdvancedInsights:$false`.

## Example

After creating an approved `.ps1` copy:

```powershell
Connect-AzAccount
Set-AzContext -SubscriptionId '00000000-0000-0000-0000-000000000000'

& '.\AVD_Full_Inventory_Fetch_working.ps1' `
    -OutputPath 'C:\Temp\AVD-Assessment' `
    -MetricDays 14 `
    -TimeGrainMinutes 60 `
    -IncludeAdvancedInsights:$false
```

Copying the downloaded `.txt` to `.ps1` **preserves the `Zone.Identifier` stream**, so the new `.ps1` is still rejected under `RemoteSigned` with `is not digitally signed`. Review the contents, then unblock the copy before the first run:

```powershell
Copy-Item '.\AVD_Full_Inventory_Fetch_working.txt' '.\AVD_Full_Inventory_Fetch_working.ps1'
Unblock-File -LiteralPath '.\AVD_Full_Inventory_Fetch_working.ps1'
```

Verify the output afterwards, because the completion banner is not evidence that files exist:

```powershell
Get-ChildItem 'C:\Temp\AVD-Assessment*' | Select-Object Name, Length
```

## Output Files

- `<OutputPath>-SessionHosts.csv`: AVD, VM, storage, current sessions and Azure Monitor metrics.
- `<OutputPath>-HostPoolSummary.csv`: Current-snapshot aggregation and heuristic sizing suggestions.
- `<OutputPath>-AdvancedInsights.csv`: Synthetic/inferred connection, FSLogix, security and hygiene fields. Do not treat these as observed measurements.

The final console message lists all three files even when a switch or failure prevented one from being created. Verify file existence and row counts.

## Data Provenance

| Data | Provenance |
| --- | --- |
| AVD resource configuration/session counts | Azure Resource Manager at execution time |
| VM configuration and power state | Azure Compute at execution time |
| CPU, memory, disk and network fields | Azure Monitor queries, with zero used as the fallback on failure/no data |
| Connection latency/reconnect/disconnection fields | Hardcoded constants, identical for every host |
| FSLogix version, health, errors and profile score | Hardcoded constants, identical for every host |
| Defender/security score | Inferred from the presence of Windows OS configuration, not Defender telemetry |
| Cost and scaling recommendations | Local heuristics; no Azure price, Cost Management or historical session query is used |

## Review Findings

- `Get-ConnectionQualityMetrics` and `Get-FSLogixHealthStatus` return fabricated values that are exported without a provenance marker.
- `Get-SecurityComplianceStatus` equates Windows configuration with Defender enabled and assigns a fixed score of 85; this is not a security assessment.
- `vmDetail` is not reset for each host. If a VM lookup fails, advanced-insight code can reuse the preceding host's VM details.
- VMs are matched by short name across the subscription and the first match is used, so duplicate names across resource groups can map a host incorrectly.
- Metric failures return zero. Missing CPU/memory data can therefore classify a host as underutilized and generate downsizing advice.
- Every metric request asks for `Average`, while disk/network totals are later read from the `Total` property; those totals can remain zero because that aggregation was not requested.
- `UptimePercent` is metric sample count divided by `MetricDays * 24`. It is not VM availability and becomes mathematically wrong when `TimeGrainMinutes` is not 60.
- `PeakConcurrentSessions` is the maximum current session count among hosts, not a historical concurrency peak.
- Suggested off-peak hosts are an arbitrary 30 percent of the current-session calculation; configured off-peak hours are never queried.
- `IncludePeakAnalysis`, `IncludeHostPoolSummary` and both Log Analytics parameters do not control any implementation.
- Per-VM metric calls are sequential and have no 429 retry/backoff, creating throttling risk at scale.
- **Verified by execution against live Azure (host pool `WPNS-AVD`, 2 session hosts, `-MetricDays 7 -IncludeAdvancedInsights:$false`):** discovery, VM mapping and Azure Monitor metric collection all succeeded (`Metrics collected successfully` for both hosts), but the run then aborted at `Generating Host Pool Summary Report` with `Cannot overwrite variable Host because it is read-only or constant.` and produced **zero** CSV files. See [Blocking defect](#blocking-defect-cannot-overwrite-variable-host).
- Each session host also emits `Error getting VM size info: A parameter cannot be found that matches parameter name 'Location'`. The VM size lookup is calling a cmdlet with a `-Location` parameter that the installed Az.Compute version does not accept, so size/sizing fields degrade before the summary stage is even reached.
- A first run in the same session failed earlier with `Get-AzWvdWorkspace/Get-AzWvdHostPool/Get-AzVM : An error occurred while sending the request` (transient `HttpRequestException`). The script has no retry, reported `No AVD Workspaces found in this subscription`, and still printed the full success banner and the three output paths. A transient network fault is therefore indistinguishable from an empty subscription in the console output.

## Safe Use

Use the prototype only for exploratory inventory after independently checking sample rows. Disable advanced insights. Do not present zero-valued metrics as measured zero without checking metric availability, and do not execute rightsizing, reservation or scaling changes from these recommendations alone.

## Recommended Modernization

1. Rename the `foreach ($host ...)` loop variable at line 1135 so the script can reach its export stage at all, then re-test against a populated host pool.
2. Rename the executable source to `.ps1` and add comment-based help and version metadata.
3. Remove all placeholder values or mark every field with `DataSource` and `CollectionStatus`.
4. Reset all per-host variables, including `vmDetail`, before lookup.
5. Map VMs by full resource ID and pass subscription/resource-group context to every query.
6. Request correct metric aggregations and represent unavailable data as null, not zero.
7. Derive availability, peak sessions, connection quality and FSLogix health from supported telemetry.
8. Honor every switch or remove it, and add throttling/backoff plus output validation.
9. Fail with a non-zero exit code, and suppress the success banner and the output-file list, when discovery errors occur or no file is written.

## References

- [Azure Monitor supported metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/metrics-index)
- [Azure Virtual Desktop Insights](https://learn.microsoft.com/azure/virtual-desktop/insights)
- [Azure Virtual Desktop RBAC roles](https://learn.microsoft.com/azure/virtual-desktop/rbac)
- [Maintained KQL pack](../KQL/README.md)