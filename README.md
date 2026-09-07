# DOCs

Documentation, scripts and configuration references created for self-learning and knowledge sharing. This repository covers Microsoft Azure, Exchange, Microsoft 365, Enterprise Mobility + Security (EMS), Intune, Citrix, VMware and related technologies.

## Explore the repository

- [Azure Firewall](Azure/Azure%20Firewall/)
- [Azure Sentinel](Azure/Azure%20Sentinel/)
- [Azure Virtual Desktop (AVD)](Azure/WindowsVirtualDesktop/README.md)
- [Intune Compliance and Configuration Policies](M365/Intune/IntuneComplianceAndConfigurationPolicies/)

## Azure Virtual Desktop Operations, Configuration and Troubleshooting Toolkit

PowerShell diagnostics, KQL queries and configuration references for Azure Virtual Desktop (AVD). The historical GitHub path, Azure/WindowsVirtualDesktop, is retained so existing links continue to work.

### Start here

| Area | Contents |
| --- | --- |
| [Monitoring and Insights](Azure/WindowsVirtualDesktop/AVDMonitoringAndInsights/README.md) | Prerequisites, diagnostics, AMA, managed identities, DCR routes, ingestion tests and a local support bundle |
| [KQL queries](Azure/WindowsVirtualDesktop/AVDMonitoringAndInsights/KQL/) | Connections, connection-related errors, agent health, network/graphics telemetry, transport, performance, FSLogix events and client versions, plus a chart-view (`render`) companion for every query |

For WPNS-AVD, begin with the monitoring guide. Verify Azure configuration, inspect every session host, generate controlled events, exercise a real AVD session, and check ingestion. A visible host in Insights is not evidence that service or guest telemetry is arriving.

The new scripts do not install modules automatically or change execution policy. Test scripts are read-only. The event generator writes two labeled test events; the bundle collector writes local evidence files and can run explicitly requested connectivity probes. Both support -WhatIf.

### Existing references

These paths remain available. Their presence does not mean the older configuration examples have been revalidated for current production use.

| Existing folder | Subject |
| --- | --- |
| [AVDRegistrySettings](Azure/WindowsVirtualDesktop/AVDRegistrySettings/) | Registry samples |
| [AzureFilesSMBAccessWithWindowsAD](Azure/WindowsVirtualDesktop/AzureFilesSMBAccessWithWindowsAD/) | Historical AD DS/Azure Files setup |
| [MicrosoftDefenderExclusionsForAVD](Azure/WindowsVirtualDesktop/MicrosoftDefenderExclusionsForAVD/) | Defender exclusion examples |
| [RDP-ShortPath](Azure/WindowsVirtualDesktop/RDP-ShortPath/) | Existing transport guidance |
| [WVDCustomURLRedirection](Azure/WindowsVirtualDesktop/WVDCustomURLRedirection/) | Historical URL redirection sample |
| [WVDVMControl](Azure/WindowsVirtualDesktop/WVDVMControl/) | Historical WVD VM-control sample |

### Modernization roadmap

The consolidated AVDMonitoringAndInsights package contains eight scripts under MonitoringAndInsights (five of them also kept under PowerShell for compatibility) and twenty-eight queries under KQL — fifteen base queries plus thirteen chart companions. The monitoring and KQL sections are the first implementation phase. The following areas are planned, not shipped as new modules:

- SessionHost: registration, agent, service and required-endpoint diagnostics.
- IdentityAndSSO: device join, user-context PRT, cloud Kerberos and AVD Entra SSO.
- FSLogixAndStorage: profile configuration, share access, DNS, Azure Files identity methods and redirections.
- NetworkingAndRDPShortpath: managed/direct and relayed UDP, current policy guidance and private DNS.
- SecurityAndHardening: deliberate Defender exclusions, validation and rollback.
- IntuneAndGPO: documented policy equivalents for the reviewed settings.
- Operations: sessions, drain mode, utilization and capacity.
- Troubleshooting: symptom-led runbooks with concrete evidence and recovery steps.
- RegistrySettings and Legacy: reviewed migration of existing samples with compatibility links.

Registry exports and legacy tools have not been moved or rewritten in this phase. Future migrations should document each setting and keep existing links usable.

### Validation status

The additions have been checked locally with PowerShell parsing and simulated dependency responses. They have not been executed against WPNS-AVD, its Log Analytics workspace or an actual session host. Run them first on a test host and review their per-check results.

### References

- [AVD Insights setup](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights)
- [Azure Monitor Agent requirements](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-requirements)
- [AVD required endpoint validation](https://learn.microsoft.com/en-us/azure/virtual-desktop/check-access-validate-required-fqdn-endpoint)
- [RDP Shortpath](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath)
