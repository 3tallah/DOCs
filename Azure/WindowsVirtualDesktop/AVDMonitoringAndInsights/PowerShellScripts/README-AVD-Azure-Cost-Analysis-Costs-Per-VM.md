# AVD Azure Costs Per VM

> **Legacy, non-production-ready utility:** `AVD_AzureCostAnalysis_CostsPerVM.ps1` queries current-month Cost Management data and attributes rows to one VM and its disks. It contains correctness failures around scope, empty results and resource matching; validate all results independently.

## Purpose

The script authenticates with a stored service-principal secret, lists accessible subscriptions and virtual machines, queries subscription-level actual and forecast Cost Management endpoints, and prints actual cost rows associated with a selected VM.

It does not query AVD host pools. The AVD relationship is only that ControlUp can supply a session-host VM name.

## Requirements

- Windows PowerShell 5.1 and .NET Framework 4.7.2 or later.
- Network access to Microsoft Entra, Azure Resource Manager and Cost Management endpoints.
- A credential file at `%ProgramData%\ControlUp\ScriptSupport\<WindowsUserName>_AZ_Cred.xml` containing `tenantID` and `spCreds`.
- Read access to subscription and VM metadata plus cost data. Prefer `Reader` and `Cost Management Reader` at the narrowest practical scope; subscription-level `Contributor` is excessive for this report.
- Cost visibility enabled for the applicable billing agreement and subscription.

The script uses a client secret and the legacy Microsoft Entra OAuth v1 token endpoint. New automation should prefer managed identity or certificate authentication.

## Parameter

`vmName` is optional. If omitted, every VM is returned and the script silently analyzes the first after issuing a warning. Always provide the exact VM name.

## Usage

```powershell
& '.\PowerShellScripts\AVD_AzureCostAnalysis_CostsPerVM.ps1' `
    -vmName 'avd-sh-01' `
    -Verbose
```

Use only when the service principal can access one intended subscription and the VM/resource names are unique within that subscription. Multiple subscriptions are not supported safely by the current workflow.

## Output

The console output includes actual current-month cost rows grouped by resource, service, tier and meter, followed by:

- Total actual cost attributed to the selected VM and its managed disks.
- Percentage of total actual subscription cost.

The script calls the forecast endpoint and calculates `totalForecastCosts`, but never displays or returns that value. No files are written; there is no `-OutputPath` parameter.

To keep a copy of a run, redirect the pipeline output to a file, or transcript the whole console session to also capture `Write-Host`/`Write-Verbose` lines that plain redirection would miss:

```powershell
# Pipeline output only (the cost rows written to the success stream)
& '.\PowerShellScripts\AVD_AzureCostAnalysis_CostsPerVM.ps1' -vmName 'avd-sh-01' |
    Out-File -FilePath 'C:\Temp\avd-cost-avd-sh-01.txt' -Encoding utf8

# Everything shown on screen, including Write-Host/Write-Verbose lines
Start-Transcript -Path 'C:\Temp\avd-cost-avd-sh-01.txt'
& '.\PowerShellScripts\AVD_AzureCostAnalysis_CostsPerVM.ps1' -vmName 'avd-sh-01' -Verbose
Stop-Transcript
```

## Cost Interpretation

Attribution is name-based. The script compares only the last segment of each Cost Management `ResourceId` with the VM and disk names. Identically named resources in different resource groups can therefore be included in the same result.

Actual charges can also include resources not discovered from the VM storage profile, such as snapshots, network resources, backup, monitoring, shared storage, reservation allocation or marketplace charges. Treat the output as a partial name-based view, not authoritative VM total cost.

## Review Findings

- All accessible subscriptions are returned, but the script has no subscription parameter or cardinality check. Multiple subscriptions can cause a failure or unintended scope.
- Empty `vmName` values select the first VM in the subscription; multiple matches also select index zero.
- If no VM is found, `whereBlock` is never created but is used unconditionally.
- Resource attribution uses terminal resource names rather than full resource IDs, allowing cross-resource-group name collisions.
- The calculated `Percentage` property references undefined `totalCosts`. The separately printed percentage uses `totalActualCosts`, but the dataset property is invalid.
- Empty cost results are indexed at `[0]` for currency and can fail.
- Forecast data is fetched and totaled but not exposed, adding an API call without a usable result.
- The request uses the old `2019-11-01` Cost Management API. Current Microsoft examples use `2025-03-01`; the request body and dimensions must be retested before migration.
- Response continuation is not handled, and HTTP 429 retry headers/backoff are not implemented.
- The service-principal secret is converted to plaintext for the OAuth request and remains in process memory.
- **Verified by execution:** the script was invoked as `-vmName 'WPNS-AVD-0'` and failed immediately at `Get-Content` for the ControlUp credential file, confirming that the credential store is a hard prerequisite and that the script cannot run standalone from an existing `Connect-AzAccount` session. No output file is produced when this occurs.
- The script originally carried a `Zone.Identifier` stream; under `RemoteSigned` the first run failed with `is not digitally signed` until `Unblock-File` was used. The stream was cleared in-tree on 2026-09-11, so this no longer blocks execution unless the file is re-downloaded.

## Recommended Modernization

1. Require explicit `SubscriptionId`, `ResourceGroupName` and exact `VMName` parameters.
2. Use managed identity or certificate authentication and current Azure PowerShell authentication patterns.
3. Query a current Cost Management API version and handle pagination, 204 responses, throttling and error bodies.
4. Filter with complete resource IDs, then disclose which related costs are and are not attributed.
5. Remove the unused forecast call or return forecast data with clear actual/forecast labels.
6. Return structured objects and include query scope, period, currency and API version in the output.
7. Validate totals against Azure Cost Analysis before operational use.

## References

- [Cost Management Query API](https://learn.microsoft.com/rest/api/cost-management/query/usage)
- [Cost Management Forecast API](https://learn.microsoft.com/rest/api/cost-management/forecast/usage)
- [Cost Management scopes and roles](https://learn.microsoft.com/azure/cost-management-billing/costs/understand-work-scopes)
- [Secure non-interactive Azure PowerShell authentication](https://learn.microsoft.com/powershell/azure/authenticate-noninteractive)