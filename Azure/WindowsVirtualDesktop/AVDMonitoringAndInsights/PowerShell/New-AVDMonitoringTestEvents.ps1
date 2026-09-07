#requires -Version 5.1
#requires -PSEdition Desktop
#requires -RunAsAdministrator
<#
.SYNOPSIS
Creates two controlled Application events for end-to-end ingestion validation.
.DESCRIPTION
Run in elevated Windows PowerShell 5.1 on the chosen session host.
Creates the AVD-Monitoring-Validation event source if absent and writes one
Warning (9001) and one Error (9002). These can trigger existing alert rules.
Supports -WhatIf. Does not create AVD service-side telemetry.
.EXAMPLE
.\New-AVDMonitoringTestEvents.ps1 -WhatIf
.EXAMPLE
.\New-AVDMonitoringTestEvents.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param([guid]$RunId = [guid]::NewGuid())
$ErrorActionPreference = 'Stop'
$source = 'AVD-Monitoring-Validation'
if ([System.Diagnostics.EventLog]::SourceExists($source)) {
    $logName = [System.Diagnostics.EventLog]::LogNameFromSourceName($source, '.')
    if ($logName -ne 'Application') { throw "Source $source belongs to $logName, not Application." }
}
if ($PSCmdlet.ShouldProcess("$env:COMPUTERNAME / Application", 'Create validation source if needed and write Warning 9001 and Error 9002')) {
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
        New-EventLog -LogName Application -Source $source
    }
    foreach ($item in @(@{Id=9001;Level='Warning'}, @{Id=9002;Level='Error'})) {
        $utc = [datetime]::UtcNow.ToString('o')
        $message = "AVD monitoring validation; RunId=$RunId; Host=$env:COMPUTERNAME; Level=$($item.Level); UTC=$utc"
        Write-EventLog -LogName Application -Source $source -EventId $item.Id -EntryType $item.Level -Message $message
        [pscustomobject]@{ Computer=$env:COMPUTERNAME; RunId=$RunId; EventID=$item.Id; Level=$item.Level; TimeUTC=$utc; Message=$message }
    }
}

