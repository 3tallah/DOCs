# AVD Inventory Reporting Plug-in

> **Framework component:** `AVD_Inventory01.ps1` is not a standalone Azure inventory script. It expects resource data and helper commands from an external inventory/reporting orchestrator and can either transform that data or append an `AVD` worksheet to an Excel workbook.

## Purpose

The plug-in has two implicit modes:

- `Task = Processing`: join pre-collected AVD host pools, session hosts and VMs into flattened rows.
- Any other `Task` value: export `SmaResources.AVD` to Excel.

It makes no Azure API calls itself.

## External Contract

| Input | Expected value |
| --- | --- |
| `SCPath` | Reserved by the owning framework; unused here. |
| `Sub` | Subscription objects with `id` and `Name`. |
| `Intag` | Whether tag columns are included in Excel output. |
| `Resources` | Pre-collected resource objects for VMs, host pools and session-host child resources. |
| `Task` | Exact string `Processing` for transformation; every other value selects reporting. |
| `File` | Existing or writable Excel workbook path. |
| `SmaResources` | Object whose `AVD` property contains transformed rows. |
| `TableStyle` | ImportExcel table style name. |

The input resource shape is expected to expose ARM/Resource Graph-style fields such as `TYPE`, `ID`, `subscriptionId`, `RESOURCEGROUP`, `PROPERTIES`, `ZONES` and `tags`.

## Dependencies

Reporting mode requires the ImportExcel module commands `New-ConditionalText`, `New-ExcelStyle` and `Export-Excel`. The script neither checks nor imports the module.

## Illustrative Invocation

Processing mode, called by an orchestrator:

```powershell
$rows = & '.\PowerShellScripts\AVD_Inventory01.ps1' `
    -Sub $subscriptions `
    -Resources $resourceGraphRows `
    -Task 'Processing' `
    -Intag $true
```

Reporting mode:

```powershell
Import-Module ImportExcel
& '.\PowerShellScripts\AVD_Inventory01.ps1' `
    -Task 'Reporting' `
    -SmaResources $smaResources `
    -File 'C:\Temp\Azure-Inventory.xlsx' `
    -TableStyle 'Medium2' `
    -Intag $true
```

These examples show the contract only; the repository does not include the owning orchestrator that builds `resourceGraphRows` and `smaResources`.

## Output Model

Processing returns host-pool/session-host/VM records including subscription, resource group, pool settings, agent state, sessions, VM size, OS and disk type.

Tags use a normalized row model: a session host is repeated once per host-pool tag. When consuming row counts, use `Resource U`, group by resource ID, or otherwise deduplicate. Reporting mode can omit tag columns with `Intag = $false`, after which `Select-Object -Unique` may collapse otherwise identical tag-expanded rows.

Reporting writes an `AVD` worksheet and table to the path in `File`.

## Review Findings

- The script cannot run meaningfully without an external resource-collection and reporting framework.
- **Verified by execution:** invoking `.\PowerShellScripts\AVD_Inventory01.ps1 -Task 'Processing' -Sub @() -Resources @() -InTag $true` completes with exit code `0` and returns nothing. Every parameter is untyped `[Object]` with no validation or mandatory flag, so the script accepts any input and silently produces no output rather than reporting that it was given no resources. A clean run proves only that it parsed, never that an inventory was collected.
- Any `Task` typo selects reporting instead of rejecting an invalid mode.
- The calculated `Domain` removes the first dot-delimited segment and leaves a leading dot for an FQDN; names without dots produce an empty value.
- Missing VM matches silently produce rows with blank VM fields, so orphaned session hosts are not clearly identified.
- Multiple VM matches are not rejected and can expand scalar fields unexpectedly.
- Untagged pools use the string `0` as an iteration sentinel, which yields a row with empty tag properties rather than an explicit untagged state.
- The tag-expanded row model can inflate naive host/session counts.
- Session-host child IDs that do not contain `/sessionhosts/` are silently excluded.
- The Excel parent path, workbook writability and ImportExcel dependency are not validated or caught.
- Variable names such as `$1` and `$2` obscure ownership and make maintenance error-prone.
- PowerShell syntax parsing passed locally; no owning-framework or ImportExcel integration test was available.

## Recommended Modernization

1. Convert this file into an advanced function or module with typed, validated inputs.
2. Use a `ValidateSet` for explicit `Processing` and `Reporting` modes.
3. Return one host row with tags serialized as structured text, or formally document the normalized tag table as a separate output.
4. Parse resource IDs with validated ARM ID helpers and derive domains without a leading dot.
5. Add `CollectionStatus` and warnings for missing or ambiguous VM relationships.
6. Declare/import ImportExcel and validate the destination before writing.
7. Add fixture-based tests for tagged, untagged, orphaned and malformed resources.

## References

- [Azure Resource Graph overview](https://learn.microsoft.com/azure/governance/resource-graph/overview)
- [ImportExcel module](https://github.com/dfinke/ImportExcel)
- [Azure Virtual Desktop resource types](https://learn.microsoft.com/azure/templates/microsoft.desktopvirtualization/allversions)