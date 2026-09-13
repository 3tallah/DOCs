# AVD Host Pool Image Information

> **Legacy utility:** `AVD-Get-Hostpool-Image-information.ps1` was written for the 2020 Windows Virtual Desktop ARM release and ControlUp Script Action environments. It parses successfully in Windows PowerShell, but it has not been modernized or validated against a live Azure Virtual Desktop environment. Review the limitations below before use.

> **Replacement available:** [Get-AVDHostPoolImageInformation.ps1](Get-AVDHostPoolImageInformation.ps1) implements the modernization steps listed at the end of this document. Prefer it for new work; this document remains the reference for the legacy script.

## Purpose

The script accepts a session host NetBIOS name, finds the Azure Virtual Desktop host pool containing that session host, and displays the host pool's `VMTemplate` JSON as a PowerShell object.

`VMTemplate` is host-pool template metadata for session host configuration. It is not a live inventory of the image installed on each session host, and it does not prove that existing virtual machines still match the template. Query the Azure Compute virtual machines directly when per-VM image state is required.

## Prerequisites

- Windows PowerShell 5.1 on Windows.
- .NET Framework 4.7.2 or later.
- A host that supports console `RawUI` buffer resizing, as expected by the ControlUp console integration.
- The `Az.Accounts` and `Az.DesktopVirtualization` PowerShell modules.
- Network access to PowerShell Gallery if either module or the required NuGet provider is missing.
- A Microsoft Entra service principal that can read the target AVD host pools and session hosts.
- A ControlUp credential file created on the same Windows machine and under the same Windows account that runs the script.

The script's comment says the service principal needs the subscription-level `Contributor` role. That is broader than its read operations require. Prefer `Desktop Virtualization Host Pool Reader`, or an equivalent custom role, at the narrowest practical resource-group or subscription scope. Confirm the assignment in your environment before removing an existing role.

## Credential File

The script reads:

```text
%ProgramData%\ControlUp\ScriptSupport\<WindowsUserName>_AZ_Cred.xml
```

The credential directory is `ControlUp\ScriptSupport` under `%ProgramData%`, and the file name ends in `_AZ_Cred.xml`.

The imported object must contain:

| Property | Value |
| --- | --- |
| `tenantID` | Microsoft Entra tenant ID |
| `spCreds` | `PSCredential` whose username is the application/client ID and whose password is the client secret |

The file is expected to be produced by the separate ControlUp `Set-AzSPCredentials` prerequisite. Although this script includes a `Set-AzSPStoredCredentials` helper, its main workflow never calls that helper.

On Windows, `Export-Clixml` protects a `PSCredential` so only the same user on the same computer can decrypt it. Restrict the file ACL, do not copy or commit the file, and rotate the service-principal credential according to your security policy. For new automation, prefer a managed identity when the execution host supports one, or certificate-based service-principal authentication when it does not.

## Important Side Effect

The script automatically installs a missing NuGet provider and missing PowerShell modules. Depending on elevation, it uses `AllUsers` or `CurrentUser`, then calls `Install-Module` with `-Force` and `-AllowClobber`.

Review and install approved module versions before running the script in a controlled environment. The script does not pin module versions or prompt before installation.

## Usage

Run the script from Windows PowerShell 5.1 under the Windows account that owns the credential file, from the folder that contains it:

```powershell
& '.\PowerShellScripts\AVD-Get-Hostpool-Image-information.ps1' `
    -SessionHostName 'avd-sh-01' `
    -Verbose
```

`SessionHostName` is matched as a prefix. Supply the complete, unique NetBIOS name to reduce the chance of matching more than one session host.

The script has no `-OutputPath` parameter; it was written as a ControlUp Script Action, so it prints directly to the host instead of returning a report object. Only part of that output is redirectable:

- `"Image information for HostPool '<name>': "` and the blank lines around it are written with `Write-Host`, which goes straight to the console and is **not** captured by redirection, `Out-File`, or a variable assignment.
- The parsed `VMTemplate` object (`$item.VMTemplate | ConvertFrom-Json`) is written to the success/pipeline stream, so it *is* redirectable.

To capture a file, redirect the pipeline output and accept that the `Write-Host` headers will still only appear on screen, not in the file. Paste this as a single line — some PowerShell console hosts echo the `>>` continuation prompt back as literal text when a multi-line piped command is pasted, which then fails with `The term '>>' is not recognized`:

```powershell
& '.\PowerShellScripts\AVD-Get-Hostpool-Image-information.ps1' -SessionHostName 'avd-sh-01' | Format-List | Out-File -FilePath '.\avd-hostpool-image-legacy-report.txt' -Encoding utf8
```

To capture everything, including the `Write-Host` headers, transcript the whole run instead:

```powershell
Start-Transcript -Path '.\avd-hostpool-image-legacy-report.txt'
& '.\PowerShellScripts\AVD-Get-Hostpool-Image-information.ps1' -SessionHostName 'avd-sh-01'
Stop-Transcript
```

For a defined, file-based report use [Get-AVDHostPoolImageInformation.ps1](Get-AVDHostPoolImageInformation.ps1)'s `-OutputPath` parameter instead; see the [top-level README](../README.md#host-pool-image-reporting).

### Execution policy and mark of the web

This file was downloaded, so it originally carried a `Zone.Identifier` alternate data stream. Under the common `RemoteSigned` execution policy that makes it a remote script, and PowerShell refuses it with `is not digitally signed`. The effective policy is not the problem; the stream is. **As of 2026-09-11 the stream has been cleared in-tree, so the script is no longer blocked.** If you re-download it, check and clear the stream again after reviewing the contents:

```powershell
Get-Item -LiteralPath '.\PowerShellScripts\AVD-Get-Hostpool-Image-information.ps1' -Stream Zone.Identifier
Unblock-File -LiteralPath '.\PowerShellScripts\AVD-Get-Hostpool-Image-information.ps1'
```

No PowerShell file in this folder currently carries the stream. Only `../KQL/AVD_KQL_Pack.txt` and the unrelated `altprof_setup_1.0.0.40.exe` binary still do.

## Workflow

1. Resize the PowerShell host buffer for ControlUp output.
2. Install missing prerequisites and import `Az.Accounts` and `Az.DesktopVirtualization`.
3. Verify that .NET Framework 4.7.2 or later is installed.
4. Import the stored service-principal credential.
5. Connect to Azure and retrieve accessible subscriptions.
6. Enumerate host pools and session hosts to locate the supplied host name.
7. Retrieve the matching host pool and convert its `VMTemplate` JSON to a PowerShell object.
8. Disconnect the Azure account if execution reaches the end of the script.

The output starts with:

```text
Image information for HostPool '<host-pool-name>':
```

The properties that follow depend on the JSON stored in that host pool's `VMTemplate` value. If the value is empty, the script writes `No image information found`.

## Known Limitations

- The script has no explicit subscription parameter. Subscription selection is ambiguous when the service principal can access multiple subscriptions because it calls `Get-AzSubscription` without requiring or selecting one subscription.
- Session hosts are matched by prefix, so zero or multiple matches can cause null or array handling failures later in the workflow.
- `Exit` is used inside helper functions and catch blocks. Early failures can terminate the hosting process and skip `Disconnect-AzAccount`.
- Automatic module installation changes the machine and does not pin or verify module versions.
- The client-secret authentication model requires local secret storage and rotation.
- Console buffer resizing can fail in non-interactive hosts that do not implement `RawUI.BufferSize`.
- The file contains unused management helpers, including functions with duplicate positional parameter metadata. It should not be dot-sourced as a general-purpose module.
- Several names and help examples still use the retired Windows Virtual Desktop terminology, and the examples do not match the script-level parameter interface.
- Only PowerShell syntax parsing has been performed locally. The script has not been validated against live Azure; authentication, RBAC, host discovery, and output remain untested against a live tenant.

## Recommended Modernization

Before production use:

1. Require an explicit `SubscriptionId` and select or pass that subscription consistently.
2. Use exact session-host matching and fail clearly on zero or multiple results.
3. Remove automatic dependency installation; document and validate supported module versions instead.
4. Replace the stored client secret with managed identity or certificate authentication where possible.
5. Keep connection cleanup in a `try`/`finally` block.
6. Remove unrelated write-oriented helper functions and query only the host-pool fields needed for this report.
7. Query Azure Compute resources when the requirement is the actual image reference of each virtual machine.

## Troubleshooting

### `Get-AzVM` reports `Az.Compute ... could not be loaded`

[Get-AVDHostPoolImageInformation.ps1](Get-AVDHostPoolImageInformation.ps1) only checks that `Az.Compute` is *installed* (`Get-Module -ListAvailable`); it does not import the module itself, relying instead on Windows PowerShell's command auto-loading when `Get-AzVM` is first called. In a fresh PowerShell process this auto-load can intermittently fail with:

```text
The 'Get-AzVM' command was found in the module 'Az.Compute', but the module could not be loaded.
For more information, run 'Import-Module Az.Compute'.
```

The confirmed root cause is **multiple versions of the same Az module installed side by side** (for example `Az.Accounts` 5.3.0 and 5.5.3 both present under `C:\Program Files\WindowsPowerShell\Modules`). PowerShell's module auto-loader can resolve `Az.Compute`'s dependency on `Az.Accounts` to a different, already-loaded version than the one `Az.Compute` needs, and the load fails without a clear version-mismatch message. Confirm with:

```powershell
Get-Module -ListAvailable Az.Accounts, Az.Compute, Az.DesktopVirtualization |
    Select-Object Name, Version | Sort-Object Name, Version
```

More than one `Version` per module `Name` confirms the conflict. A related, more explicit failure mode from the same root cause is `Az.DesktopVirtualization` refusing to load with:

```text
This module requires Az.Accounts version 5.5.0. An earlier version of Az.Accounts is imported in the current
PowerShell session. Please open a new session before importing this module.
```

This happens when an older `Az.Accounts` (for example 5.3.0) gets auto-loaded first — commonly because it is a dependency of another already-imported module — before the newer `Az.DesktopVirtualization`/`Az.Compute` versions that require `Az.Accounts >= 5.5.0` are imported.

Remediation, in order:

1. Re-run the script in a brand-new PowerShell session. Auto-loading is session-scoped, so a clean session sometimes resolves the correct versions on its own.
2. If it still fails, import the modules explicitly, newest-required-version first, before running the script, which also surfaces the real underlying error if one exists:

   ```powershell
   Import-Module Az.Accounts -MinimumVersion 5.5.0 -Verbose -ErrorAction Stop
   Import-Module Az.DesktopVirtualization -Verbose -ErrorAction Stop
   Import-Module Az.Compute -Verbose -ErrorAction Stop
   ```

3. Remove the conflict permanently by uninstalling the older side-by-side versions once no other script depends on them:

   ```powershell
   Get-Module -ListAvailable Az.Accounts, Az.Compute, Az.DesktopVirtualization |
       Sort-Object Name, Version | Format-Table Name, Version

   Uninstall-Module -Name Az.Accounts -RequiredVersion 5.3.0
   Uninstall-Module -Name Az.DesktopVirtualization -RequiredVersion 5.4.1
   ```

4. As a fallback that avoids the Azure Compute dependency entirely, rerun with `-SkipSessionHostImage` to get host-pool template data only.

## References

- [Get-AzWvdHostPool](https://learn.microsoft.com/powershell/module/az.desktopvirtualization/get-azwvdhostpool)
- [Azure Virtual Desktop built-in RBAC roles](https://learn.microsoft.com/azure/virtual-desktop/rbac)
- [Non-interactive Azure PowerShell authentication](https://learn.microsoft.com/powershell/azure/authenticate-noninteractive)
- [Securing service principals in Microsoft Entra ID](https://learn.microsoft.com/entra/architecture/service-accounts-principal)
- [Export-Clixml credential encryption](https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/export-clixml)