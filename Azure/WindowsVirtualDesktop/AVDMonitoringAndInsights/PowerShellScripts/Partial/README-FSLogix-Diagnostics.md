# FSLogix Diagnostics — Partial Scripts

Short, copy/paste PowerShell snippets for live FSLogix troubleshooting on an AVD session host. These are partial/demo scripts, not full standalone tools — each one reads local registry state or the current FSLogix Profile log and prints a focused view instead of the raw log.

## Requirements

- Run on a session host with the FSLogix agent installed.
- Registry snippets read `HKLM:\SOFTWARE\FSLogix\Profiles\Sessions\*`.
- Log snippets read the newest file in `C:\ProgramData\FSLogix\Logs\Profile\*.log`.
- No special modules; Windows PowerShell 5.1 is sufficient. Read-only, no admin rights required.

## 1. Active FSLogix Sessions

Lists every currently attached FSLogix profile session with its health status, temp-profile flag, first-logon flag, last profile load time, and the actual VHD(X) path in use. Best first command for a live demo — replaces the old `frxtray` view.

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles\Sessions\*" |
Select-Object `
    @{N='User';E={Split-Path $_.UserProfilePath -Leaf}},
    WindowsSessionID,
    @{N='Status';E={if ($_.Status -eq 0) {'Healthy'} else {"Error:$($_.Status)"}}},
    Reason,
    ErrorCode,
    WindowsTempProfile,
    FirstLogon,
    LastProfileLoadTimeMS,
    VHDOpenedFilePath |
Format-Table -AutoSize -Wrap
```

## 2. Key Events From the Latest Profile Log

Filters the newest Profile log down to session start, load/unload markers, VHD(X) attach/mount events, status/reason changes, and container free space — cutting out the noise so only the meaningful lifecycle lines remain.

```powershell
$Log = Get-ChildItem "C:\ProgramData\FSLogix\Logs\Profile\*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

Write-Host "`nFSLogix Profile Log: $($Log.FullName)`n"

Get-Content $Log.FullName |
Select-String -Pattern `
    "Begin Session: Logon",
    "LoadProfile:",
    "LoadProfile successful",
    "loadProfile time:",
    "VHD\(x\) attached:",
    "VHD\(x\) Mounted:",
    "Reason set to",
    "Status set to",
    "has .* MB left",
    "WindowsTempProfile",
    "FirstLogon"
```

## 3. Slowest FSLogix Operations

Parses every timed operation in the log (`... returning after N milliseconds`, plus `loadProfile`/`unloadProfile time`), keeps only entries at or above 100 ms, and sorts them descending — surfaces where load/unload time is actually being spent even on a "successful" sign-in.

```powershell
$Log = Get-ChildItem "C:\ProgramData\FSLogix\Logs\Profile\*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

Get-Content $Log.FullName |
ForEach-Object {

    if ($_ -match '(.+?) returning after (\d+) milliseconds') {
        [PSCustomObject]@{
            Operation = $Matches[1].Trim()
            TimeMS    = [int]$Matches[2]
        }
    }

    elseif ($_ -match '(loadProfile|unloadProfile) time:\s+(\d+) milliseconds') {
        [PSCustomObject]@{
            Operation = $Matches[1]
            TimeMS    = [int]$Matches[2]
        }
    }

} |
Where-Object TimeMS -ge 100 |
Sort-Object TimeMS -Descending |
Format-Table -AutoSize
```

## 4. Real Errors and Warnings

Scans the log for explicit `[ERROR]`/`[WARN]` markers plus common failure phrases (`failed`, `access denied`, `timed out`, `corrupt`, `locked by`) to separate genuine faults from normal — even if slow — profile activity.

```powershell
$Log = Get-ChildItem "C:\ProgramData\FSLogix\Logs\Profile\*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

Get-Content $Log.FullName |
Where-Object {
    $_ -match '\[(ERROR|WARN)(:|\])' -or
    $_ -match '(?i)\bfailed\b|access denied|timed out|corrupt|locked by'
}
```

## 5. New Profile Creation vs. Existing Profile

Highlights the "no existing VHD(X)" path — container-not-found, creation, attach, and load — so a first sign-in (which pays container creation/formatting/expansion cost) isn't mistaken for a slow returning-user sign-in.

```powershell
$Log = Get-ChildItem "C:\ProgramData\FSLogix\Logs\Profile\*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

Get-Content $Log.FullName |
Select-String -Pattern `
    "Profile VHD not found",
    "Creating new VHD",
    "Created vhd",
    "VHD\(x\) attached",
    "LoadProfile successful",
    "loadProfile time"
```

## Preferred Testing Sequence

Session state → container → timing → errors:

```powershell
# 1. What's attached right now?
Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles\Sessions\*" |
Select @{N='User';E={Split-Path $_.UserProfilePath -Leaf}},
WindowsSessionID,Status,WindowsTempProfile,
LastProfileLoadTimeMS,VHDOpenedFilePath |
Format-Table -AutoSize -Wrap
```

```powershell
# 2. Where is FSLogix spending time?
$Log = Get-ChildItem "C:\ProgramData\FSLogix\Logs\Profile\*.log" |
Sort LastWriteTime -Descending | Select -First 1

Get-Content $Log.FullName |
Select-String "LoadProfile successful|loadProfile time|VHD\(x\) attached|VHD\(x\) Mounted"
```

```powershell
# 3. Are there real errors?
Get-Content $Log.FullName |
Where-Object {
    $_ -match '\[(ERROR|WARN)(:|\])' -or
    $_ -match '(?i)\bfailed\b|access denied|timed out|corrupt|locked by'
}
```
