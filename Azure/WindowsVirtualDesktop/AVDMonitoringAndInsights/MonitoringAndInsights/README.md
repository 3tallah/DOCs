# Monitoring and Insights

Read-only configuration checks and ingestion validation for Azure Virtual Desktop, plus a cost-optimized monitoring deployment script, controlled event generator and local diagnostic collector.

## Architecture

AVD Insights combines independent telemetry paths:

~~~text
Host pool + AVD Workspace -> diagnostic settings -> Log Analytics -> WVD* tables
Session host -> events/counters -> AMA + associated DCR -> Log Analytics -> Event/Perf
AMA -> Heartbeat
~~~

AVD Agent health is distinct from AMA health. Guest data and service diagnostics may use different Log Analytics workspaces; supply the appropriate destination and query each one. [Microsoft Learn](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights).

## Scripts

| File | Runs on | Purpose |
| --- | --- | --- |
| [Test-AVDMonitoringPrerequisites.ps1](Test-AVDMonitoringPrerequisites.ps1) | Admin workstation/Cloud Shell | Modules, Azure context and resource read access |
| [Test-AVDHostPoolDiagnosticSettings.ps1](Test-AVDHostPoolDiagnosticSettings.ps1) | Admin workstation/Cloud Shell | Host pool categories, settings, expected destination and per-category coverage |
| [Test-AVDWorkspaceDiagnosticSettings.ps1](Test-AVDWorkspaceDiagnosticSettings.ps1) | Admin workstation/Cloud Shell | AVD Workspace diagnostic coverage |
| [Test-AVDDCRAssociation.ps1](Test-AVDDCRAssociation.ps1) | Admin workstation/Cloud Shell | Every registered VM's AMA extension, identity selection and DCR routes |
| [Set-AVDCostOptimizedMonitoring.ps1](Set-AVDCostOptimizedMonitoring.ps1) | Admin workstation/Cloud Shell | Creates/updates one cost-optimized DCR and associates it with every registered session-host VM |
| [Test-AVDSessionHostMonitoring.ps1](Test-AVDSessionHostMonitoring.ps1) | Each session host, elevated | Services, registration flag, AMA cache/logs, event channels and 20 counters |
| [Test-AVDLogAnalyticsIngestion.ps1](Test-AVDLogAnalyticsIngestion.ps1) | Admin workstation/Cloud Shell | Table activity, expected AMA hosts and generated test events |
| [New-AVDMonitoringTestEvents.ps1](New-AVDMonitoringTestEvents.ps1) | Session host, elevated Windows PowerShell 5.1 | One Application Warning 9001 and Error 9002 |
| [Collect-AVDDiagnosticBundle.ps1](Collect-AVDDiagnosticBundle.ps1) | Session host, elevated Windows PowerShell 5.1 | Bounded local evidence and a manifest in a ZIP |
| [Validate-AVDSessionHostMonitoring-Interactive.ps1](Validate-AVDSessionHostMonitoring-Interactive.ps1) | Each session host, elevated | Interactive single-pass colored console report; also writes two labeled test events |
| [Invoke-AVDSessionHostReport.ps1](Invoke-AVDSessionHostReport.ps1) | Admin workstation/Cloud Shell | Fans the host validation out to every registered session host via Run Command and merges all reports into one summary + CSV |
| [Invoke-AVDMonitoringReportUpload.ps1](Invoke-AVDMonitoringReportUpload.ps1) | Injected into each session host (not run directly) | Runs the validation and PUTs the JSON report to a write-only blob SAS URL |

The scripts are directly in this folder, including the interactive single-pass host report `Validate-AVDSessionHostMonitoring-Interactive.ps1`. Shared queries live in [../KQL](../KQL/). The earlier PowerShell folder has been merged into this one; `LEGACY-PowerShell-README.md` is kept only for reference.

## Collect a report from every session host at once

`Invoke-AVDSessionHostReport.ps1` runs the per-host validation on all registered hosts
in parallel (PowerShell 7) or sequentially (5.1) using **Run Command**
(`RunPowerShellScript`, runs elevated as SYSTEM). Run Command caps inline output at
4 KB, so each host PUTs its full JSON report to an anonymous, write-only blob SAS URL;
the orchestrator then downloads and merges them. This is the multi-VM alternative to
running `Validate-AVDSessionHostMonitoring-Interactive.ps1` by hand, and is used instead of
Azure Machine Configuration (Guest Configuration), which is for continuous compliance
state rather than on-demand report collection.

Operator requirements: read on the host pool and VMs,
`Microsoft.Compute/virtualMachines/runCommand/action` on each VM (Virtual Machine
Contributor or higher), and blob SAS create + read on the reports container
(Storage Blob Data Contributor).

~~~powershell
$hpId = '/subscriptions/<sub>/resourceGroups/rg-avd/providers/Microsoft.DesktopVirtualization/hostPools/WPNS-AVD'
.\Invoke-AVDSessionHostReport.ps1 -HostPoolResourceId $hpId `
    -StorageAccountName stavdreports -StorageResourceGroupName rg-avd -ContainerName reports
~~~

Add `-CollectOnly` to re-download the last run's reports without re-running the hosts.
Output lands in `.\AVDReports\<timestamp>-<host>.json` plus a merged
`AVDMonitoring-<timestamp>.csv`, with a worst-status-per-host summary table.

## Prerequisites

Use PowerShell 5.1 or 7 for Azure-side validation, with Az.Accounts. The automated ingestion checker also requires Az.OperationalInsights. Sign in manually; scripts neither authenticate interactively nor change your selected context.

~~~powershell
Install-Module Az.Accounts, Az.OperationalInsights -Scope CurrentUser
Connect-AzAccount -Tenant '<tenant-id>'
Set-AzContext -Subscription '<subscription-id>'
~~~

The operator needs resource read access across the host pool, AVD Workspace, VMs, extensions, diagnostic settings/categories, DCR associations, DCRs and Log Analytics workspace. Reader at the relevant scopes is a straightforward option. Log queries also need data access such as Log Analytics Reader. The prerequisite resource GET checks do not certify all child-resource or query permissions.

`Set-AVDCostOptimizedMonitoring.ps1` is different from the validation scripts: it needs write access to create or update the selected DCR and to create/update DCR associations on every session-host VM. Use a least-privilege role that permits these operations at the DCR resource-group and VM scopes. It does not remove existing DCRs or associations. `-WhatIf` still reads the workspace and session-host inventory, but skips the DCR and association PUT operations.

Run local checks elevated on the target Windows session host. The event generator and collector require Windows PowerShell 5.1. The local monitoring script accepts localized -CounterPaths and custom -EventLogNames.

ARM IDs and workspace GUIDs are different:

- Diagnostic, prerequisite and DCR scripts take full ARM IDs.
- Test-AVDLogAnalyticsIngestion takes the Log Analytics workspace GUID (customerId).
- ExpectedVMResourceId takes VM ARM IDs, not the internal VM GUID or session-host registration ID.

## Configure cost-optimized monitoring

Run this script after signing in when you want a single, deliberately lower-volume DCR for the registered session hosts. It reads the Log Analytics workspace location and creates or updates the DCR in the workspace's subscription and resource group by default. Use `-DCRResourceGroupName` to place the DCR in another resource group in the same subscription. The DCR location follows the workspace location.

~~~powershell
.\Set-AVDCostOptimizedMonitoring.ps1 `
    -HostPoolResourceId $hpId `
    -LogAnalyticsWorkspaceResourceId $lawId `
    -DCRName 'DCR-AVD-CostOptimized' `
    -WhatIf

.\Set-AVDCostOptimizedMonitoring.ps1 `
    -HostPoolResourceId $hpId `
    -LogAnalyticsWorkspaceResourceId $lawId
~~~

The default DCR name is `DCR-AVD-CostOptimized`; rerunning the script updates that DCR and uses the fixed association name `AVD-CostOptimized`. It discovers every registered session host, resolves its VM resource ID, checks the VM identity and AMA extension, and then reports the association result. A missing or invalid VM resource ID is reported for that host without stopping the remaining hosts. A shutdown host can be associated successfully, but ingestion begins when the VM runs.

The generated DCR contains:

- 14 performance counters sampled every 60 seconds, including aggregate physical-disk latency and per-session AVD density counters.
- Six Windows Event XPath queries for System, Application, RDP/AVD session-manager channels and FSLogix Apps channels.
- Critical, Error and Warning events only; informational session lifecycle data should come from AVD platform diagnostics such as `WVDConnections`.
- `Microsoft-Perf` and `Microsoft-Event` routes to the selected Log Analytics workspace with `transformKql = source` and no duplicate Metrics destination.

This profile deliberately excludes per-process User Input Delay, RemoteFX Network counters when AVD network telemetry is enabled, and per-disk physical counters to reduce cardinality and ingestion volume. Validate the resulting DCR and routes with [Test-AVDDCRAssociation.ps1](Test-AVDDCRAssociation.ps1), then verify actual ingestion with [Test-AVDLogAnalyticsIngestion.ps1](Test-AVDLogAnalyticsIngestion.ps1).

## 1. Check Azure configuration

From this folder, replace the placeholders. The example uses one resource group and one Log Analytics workspace; change the IDs for resources in other scopes.

~~~powershell
$subscriptionId = '<subscription-id>'
$baseId = "/subscriptions/$subscriptionId/resourceGroups/wpns-avd"
$hpId = "$baseId/providers/Microsoft.DesktopVirtualization/hostPools/WPNS-AVD"
$wsId = "$baseId/providers/Microsoft.DesktopVirtualization/workspaces/<AVD-workspace-name>"
$lawId = "$baseId/providers/Microsoft.OperationalInsights/workspaces/LAW-WPNS-AVD"

.\Test-AVDMonitoringPrerequisites.ps1 -HostPoolResourceId $hpId -AVDWorkspaceResourceId $wsId -LogAnalyticsWorkspaceResourceId $lawId
.\Test-AVDHostPoolDiagnosticSettings.ps1 -HostPoolResourceId $hpId -LogAnalyticsWorkspaceResourceId $lawId
.\Test-AVDWorkspaceDiagnosticSettings.ps1 -AVDWorkspaceResourceId $wsId -LogAnalyticsWorkspaceResourceId $lawId
.\Test-AVDDCRAssociation.ps1 -HostPoolResourceId $hpId -LogAnalyticsWorkspaceResourceId $lawId
~~~

Diagnostic coverage is combined across settings targeting the expected workspace. Settings pointing elsewhere do not satisfy it. allLogs is preferred for full category coverage; its absence warns even if explicit categories cover the baseline. New/optional category gaps warn. Available baseline gaps fail.

`Test-AVDHostPoolDiagnosticSettings.ps1` validates the AVD platform diagnostic path only. It lists the categories advertised by the host pool, lists every diagnostic setting and its enabled logs, checks whether a setting targets the expected Log Analytics workspace, and emits one result for every available category. A category passes when it is covered at the expected destination by `allLogs`, an explicit category, or a matching category group. An uncovered advertised baseline category fails; an uncovered non-baseline category warns. This does not validate AMA, DCR associations, Windows events or performance counters; use `Test-AVDDCRAssociation.ps1` for that guest telemetry path.

The DCR check uses each registered host's VM resourceId and follows inventory pagination. An endpoint-only (DCE) association does not satisfy a DCR requirement. It checks AMA identity selection against system-assigned or attached user-assigned identity configuration.

Event and Perf need sources and routes to the expected destination. Sources may be split across DCRs. Review emitted XPath expressions, counter lists, intervals, provisioning state and transforms: a route Pass does not prove complete baseline coverage or ingestion. A route only to InsightsMetrics does not satisfy Perf.

## 2. Inspect hosts and generate events

### Inspect the local host

Run the read-only host check first:

~~~powershell
.\Test-AVDSessionHostMonitoring.ps1 | Format-Table -Wrap
~~~

### Generate controlled validation events

`New-AVDMonitoringTestEvents.ps1` creates two deliberately fake entries in the local Windows **Application** event log. It is an end-to-end pipeline test, not a test of real AVD user activity.

The script:

1. Requires elevated **Windows PowerShell 5.1** on the target session host.
2. Creates the `AVD-Monitoring-Validation` event source in the Application log when it does not already exist.
3. Refuses to continue if that source belongs to a different event log.
4. Writes two entries with the same unique `RunId`, host name and UTC timestamp:
    - Event ID `9001` at `Warning` level
    - Event ID `9002` at `Error` level

Preview the operation before writing:

~~~powershell
.\New-AVDMonitoringTestEvents.ps1 -WhatIf
~~~

Write the events and capture the returned objects:

~~~powershell
$testEvents = .\New-AVDMonitoringTestEvents.ps1
$testEvents | Format-List
~~~

Save the returned `RunId`, computer name and UTC timestamps. Use the same `RunId` when querying the `Event` table. Existing alert rules may fire for the Warning or Error entry, so decide in advance whether test alerts should be suppressed or expected.

The script changes only the local Application log and event-source registration. It does not create AVD service-side telemetry, user connections, network data or graphics data. It does not create a DCR or configure Log Analytics. `-WhatIf` performs the source check but skips event-source creation and event writes.

For AMA to collect these entries, the DCR must include the Application log with an XPath that matches the event levels, for example:

~~~text
Application!*[System[(Level=1 or Level=2 or Level=3)]]
~~~

Application Warning/Error collection must include this provider, route to Microsoft-Event and survive transforms. Cache existence, extension provisioning success or a running process alone cannot prove ingestion.

The local monitoring script checks four core event channels. Microsoft's fuller Insights baseline also includes FSLogix Admin and Operational; the collector captures these when present, and AVD-FSLogixEvents.kql inspects their ingestion. No FSLogix configuration is changed.

Counter paths are English. Missing session-dependent counters on an idle host warn. Use localized counter names where appropriate. [Counter/event baseline](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights-costs).

## 3. Exercise a real user session

Launch the assigned desktop, actively use it for five minutes, disconnect without signing out, reconnect, use it briefly and sign out. Record UTC times and the user name. Local synthetic events cannot generate genuine WVDConnections or network/graphics records.

Some tables are activity-dependent. An empty errors table can be normal. Network/graphics telemetry also depends on the session/client and enabled categories.

## 4. Verify ingestion

On the admin workstation:

~~~powershell
$workspaceGuid = '<Log-Analytics-workspace-GUID>'
$vmIds = @(
    "$baseId/providers/Microsoft.Compute/virtualMachines/WPNS-AVD-0"
    "$baseId/providers/Microsoft.Compute/virtualMachines/<second-vm>"
)
.\Test-AVDLogAnalyticsIngestion.ps1 -LogAnalyticsWorkspaceResourceId $lawId -ExpectedVMResourceId $vmIds
.\Test-AVDLogAnalyticsIngestion.ps1 -LogAnalyticsWorkspaceResourceId $lawId -RunId '<RunId-from-test-host>' -TestComputer 'WPNS-AVD-0'
~~~

Populate the inventory with every actual VM ID. Without it, never-reporting hosts cannot be detected and the checker falls back to hosts observed in Heartbeat. A stopped or deallocated host is expected to have no recent heartbeat; compare the warning with the VM's actual power state before treating it as an AMA failure. Recheck after allowing ingestion time.

The checker reports table activity, an Event source inventory (`Computer`, `EventLog`, `Source`, and `EventID`), AMA heartbeats and optional RunId-specific test events. Event rows confirm that some event data arrived, but do not prove the expected DCR XPath or source; review the source inventory and DCR association separately. `Event` present with `Perf` absent is consistent with an Event-only DCR and should be treated as a missing `Microsoft-Perf` source/route until the DCR check proves otherwise.

The event check evaluates both IDs separately per computer, avoiding a false success from one event on each of two hosts. Missing data warns; a query/access error is reported as Error. Warnings from fuzzy table resolution should be reviewed rather than treated as complete evidence.

## Shared queries

Run each entire file in the appropriate workspace's Logs pane. Adjust Lookback and the filters at the top.

| Query | Evidence |
| --- | --- |
| [AVD-AllTables.kql](../KQL/AVD-AllTables.kql) | Table activity, including explicit zero-data rows |
| [AVD-Connections.kql](../KQL/AVD-Connections.kql) | Lifecycle rows and auto-reconnect predecessor IDs |
| [AVD-ConnectionFailures.kql](../KQL/AVD-ConnectionFailures.kql) | Connection-related errors with observed connection states |
| [AVD-AgentHealth.kql](../KQL/AVD-AgentHealth.kql) | Latest AVD agent report per host |
| [AVD-NetworkData.kql](../KQL/AVD-NetworkData.kql) | RTT in ms, bandwidth in KB/s and connection enrichment |
| [AVD-GraphicsData.kql](../KQL/AVD-GraphicsData.kql) | Preview frame/delay telemetry |
| [AVD-RDPShortpath.kql](../KQL/AVD-RDPShortpath.kql) | Observed transport, including reported TURN |
| [AVD-SessionHostPerformance.kql](../KQL/AVD-SessionHostPerformance.kql) | Per-host/counter/instance activity and values |
| [AVD-FSLogixEvents.kql](../KQL/AVD-FSLogixEvents.kql) | Collected FSLogix channels/providers |
| [AVD-ClientVersions.kql](../KQL/AVD-ClientVersions.kql) | Client-version observations counted per connection ID |

Empty typed inputs and fuzzy unions support tables that do not yet exist; they do not mask execution/access errors. The overall inventory covers the workspace, not only WPNS-AVD. Connection errors can occur after sign-in; inspect their messages and timeline before calling them failed sign-ins. PredecessorConnectionId identifies auto-reconnects, not every manual reconnect.

## Collect a support bundle

~~~powershell
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD -WhatIf
.\Collect-AVDDiagnosticBundle.ps1 -OutputDirectory C:\Temp\AVD -StorageHost '<account>.file.core.windows.net' -RunEndpointTool
~~~

The ZIP name includes computer, UTC timestamp and a random suffix to avoid collisions. The evidence directory remains alongside it. Read manifest.json first.

It collects OS/components/services, an allowlisted registration/configuration subset, dsregcmd, ticket metadata, FSLogix/AMA log tails, event extracts, local monitoring results, network configuration/routes/DNS and time status. Log and event limits are configurable. It excludes registration tokens, protected extension settings, full registry exports and raw DCR cache content. Logs still contain potentially identifying operational data; review before sharing. The collector does not upload anything.

| Optional input | What it does |
| --- | --- |
| -StorageHost | DNS and TCP 445 probe; not SMB authentication |
| -SharePath | Read-access test in the invoking identity; no write test or profile mount |
| -RunEndpointTool | Runs the installed Microsoft WVDAgentUrlTool with a timeout |
| -StunServer / -TurnServer / -UdpPort | Sends a UDP STUN Binding probe to a supplied endpoint |

No endpoint is guessed or downloaded. A Binding response proves only that this transaction reached a responding endpoint. It does not validate TURN authentication/allocation, peer-to-peer connectivity or actual AVD transport. Confirm real transport in Windows App and the transport query.

dsregcmd/klist in an elevated collector describe that invoking context. Validate the affected user's PRT and cloud Kerberos separately from their unelevated session. Existing SMB sessions also reflect context. DCR cache metadata needs the Azure-side DCR checker for authoritative configuration.

Native processes are bounded by CommandTimeoutSeconds; UDP receive/TCP connect probes use five seconds. DNS, CIM, event and filesystem reads can still be slower on an unhealthy machine. Failed components are recorded and collection continues.

## Interpret results

Test scripts emit Resource, Check, Status and Details:

- Pass: the specific observation met the check.
- Fail: inspected configuration did not meet a requirement.
- Warning: incomplete, absent or uncertain evidence requiring review.
- Error: inspection/query failed.
- Info: context rather than a health verdict.

The bundle uses Collected/NoData/Error/NotRun and other evidence statuses in its manifest. Collected never means healthy. No script exits a job with failure merely because a result object says Fail; automation should explicitly check Fail/Error rows. Capture objects before formatting if exporting.

## References

- [AMA identity requirements](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-requirements)
- [AMA Windows troubleshooting](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-vm)
- [Query cmdlet](https://learn.microsoft.com/en-us/powershell/module/az.operationalinsights/invoke-azoperationalinsightsquery)
- [AVD Agent URL Tool](https://learn.microsoft.com/en-us/azure/virtual-desktop/check-access-validate-required-fqdn-endpoint)
- [dsregcmd and user context](https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-device-dsregcmd)
- [RDP Shortpath](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath)
- [Connection schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/wvdconnections)
- [Network schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/wvdconnectionnetworkdata)
- [Graphics schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/wvdconnectiongraphicsdatapreview)
