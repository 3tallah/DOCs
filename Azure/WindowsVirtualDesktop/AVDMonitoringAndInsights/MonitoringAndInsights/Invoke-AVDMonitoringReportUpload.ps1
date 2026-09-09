#requires -Version 5.1
<#
.SYNOPSIS
Appended to the on-host validation: uploads the JSON report to blob via SAS URL.
.DESCRIPTION
Runs on the session host. Executes Test-AVDSessionHostMonitoring.ps1, converts the
result objects to JSON, and PUTs the blob to the provided pre-authenticated SAS URL
with x-ms-blob-type: BlockBlob. No storage key or credential is stored on the host;
the SAS grants write-only access to one blob for a limited time.

Not run directly by the operator. Invoke-AVDSessionHostReport.ps1 injects this
script (plus the validation body) into each VM through Run Command.

.PARAMETER ReportSasUrl
Pre-authenticated write SAS URL for the destination blob (single object).

.PARAMETER ScriptBody
Not a parameter; this script dot-sources the validation logic passed in $ValidationScript.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReportSasUrl
)

$ErrorActionPreference = 'Stop'
try {
    # $ValidationScript is a scriptblock injected by the orchestrator before this runs.
    if ($ValidationScript -isnot [scriptblock]) { $ValidationScript = [scriptblock]::Create([string]$ValidationScript) }
    $results = & $ValidationScript
    $payload = [pscustomobject]@{
        Host        = $env:COMPUTERNAME
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Results     = @($results)
    }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $request = [System.Net.HttpWebRequest]::Create($ReportSasUrl)
    $request.Method = 'PUT'
    $request.ContentType = 'application/json'
    $request.Headers.Add('x-ms-blob-type', 'BlockBlob')
    $request.ContentLength = $bytes.Length
    $stream = $request.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $response = $request.GetResponse()
    $response.Close()

    Write-Output "UPLOAD_OK host=$env:COMPUTERNAME status=$([int]$response.StatusCode) bytes=$($bytes.Length)"
} catch {
    Write-Output "UPLOAD_FAIL host=$env:COMPUTERNAME error=$($_.Exception.Message)"
    exit 1
}
