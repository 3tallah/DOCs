# AVD Monitoring and Insights

Read-only configuration checks, ingestion validation, controlled evidence generation and KQL queries for Azure Virtual Desktop (AVD) monitoring.

## Package layout

| Folder | Contents |
| --- | --- |
| [MonitoringAndInsights](MonitoringAndInsights/README.md) | The complete, current script set (eight): prerequisites, host pool and AVD Workspace diagnostic settings, DCR/AMA association, per-host monitoring, Log Analytics ingestion, the test-event generator and the local diagnostic bundle collector |
| [PowerShell](PowerShell/README.md) | Six scripts from the earlier layout, kept for compatibility, including the interactive single-pass host validation report; MonitoringAndInsights holds the authoritative versions |
| [KQL](KQL/README.md) | Twenty-eight queries: fifteen base queries plus thirteen chart-view (`render`) companions |

## Suggested order

For WPNS-AVD, begin with the [monitoring guide](MonitoringAndInsights/README.md). Verify Azure configuration, inspect every session host, generate controlled events, exercise a real AVD session, and check ingestion. A visible host in Insights is not evidence that service or guest telemetry is arriving.

## Safety notes

The scripts do not install modules automatically or change execution policy. Test scripts are read-only. The event generator writes two labeled test events; the bundle collector writes local evidence files and only runs explicitly requested connectivity probes. Both support -WhatIf.

## Validation status

The scripts have been checked locally with PowerShell parsing and simulated dependency responses; they have not been executed against WPNS-AVD, its Log Analytics workspace or an actual session host. The KQL queries, including the chart companions, were reviewed but not run against a live workspace. Run everything first on a test host and review the per-check results.

## References

- [AVD Insights setup](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights)
- [Azure Monitor Agent requirements](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-requirements)
- [AVD required endpoint validation](https://learn.microsoft.com/en-us/azure/virtual-desktop/check-access-validate-required-fqdn-endpoint)
- [RDP Shortpath](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath)