
<# 
.SYNOPSIS
  Run Azure NetApp Files performance tests for AVD FSLogix profile shares using FIO (Windows).

.DESCRIPTION
  - Executes multiple FIO workloads against a mapped SMB drive (ANF volume).
  - Parses FIO JSON results and creates a CSV + HTML summary.
  - Defaults chosen per Microsoft ANF testing guidance:
      * Highly parallel workloads (numjobs) and deep queues (iodepth).
      * Disable client/server caching effects (--direct=1, --randrepeat=0).
  References:
    - ANF Testing Methodology (caching, parallelism, fio usage): https://learn.microsoft.com/azure/azure-netapp-files/testing-methodology
    - Benchmark test recommendations (VM sizing, VNet locality, Windows FIO availability): 
      https://learn.microsoft.com/azure/azure-netapp-files/azure-netapp-files-performance-metrics-volumes
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
  [Parameter(Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [string]$TargetPath,             # e.g. Z:\fio-test (folder on ANF SMB share)

  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [string]$FioPath = "C:\FIO\fio.exe", # path to fio.exe for Windows

  [Parameter(Mandatory=$false)]
  [ValidateRange(10, 86400)]
  [int]$DurationSec = 600,         # runtime per test (seconds)

  [Parameter(Mandatory=$false)]
  [ValidatePattern('^\d+[kKmMgGtT]?$')]
  [string]$FileSize = "4G",        # per-job file size; adjust up for larger runs

  [Parameter(Mandatory=$false)]
  [ValidateRange(1, 256)]
  [int]$NumJobs = [Math]::Max(4, [int]([Environment]::ProcessorCount / 4)), # parallel jobs

  [Parameter(Mandatory=$false)]
  [ValidateRange(1, 1024)]
  [int]$IoDepth = 128,             # queue depth for random; sequential will use 64

  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [string]$OutputDir = "$PSScriptRoot\ANF-FIO-Results",  # output for JSON/CSV/HTML

  # FIO writes multi-GB data files into -TargetPath. They are deleted after each
  # workload unless this switch is set, so a run cannot silently fill the volume.
  [Parameter(Mandatory=$false)]
  [switch]$KeepTestFiles
)

begin {
  $ErrorActionPreference = "Stop"

  if (-not (Test-Path $FioPath)) {
    throw "FIO not found at '$FioPath'. Download for Windows and set -FioPath. See: https://github.com/axboe/fio/releases"
  }

  if (-not (Test-Path $TargetPath)) {
    throw "TargetPath '$TargetPath' not found. Map your ANF SMB share and create a subfolder (e.g., Z:\fio-test)."
  }

  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
  Write-Host "Results directory: $OutputDir" -ForegroundColor Cyan

  # Define workloads
  $workloads = @(
    @{ Name="8k_rand_read";    rw="randread";  bs="8k"; rwmixread=$null;  iodepth=$IoDepth; numjobs=$NumJobs },
    @{ Name="8k_rand_write";   rw="randwrite"; bs="8k"; rwmixread=$null;  iodepth=$IoDepth; numjobs=$NumJobs },
    @{ Name="8k_randrw_70r30w";rw="randrw";    bs="8k"; rwmixread=70;     iodepth=$IoDepth; numjobs=$NumJobs },
    @{ Name="1M_seq_read";     rw="read";      bs="1M"; rwmixread=$null;  iodepth=64;       numjobs=[Math]::Max(4, [int]([Environment]::ProcessorCount / 8)) },
    @{ Name="1M_seq_write";    rw="write";     bs="1M"; rwmixread=$null;  iodepth=64;       numjobs=[Math]::Max(4, [int]([Environment]::ProcessorCount / 8)) }
  )

  $summary = New-Object System.Collections.Generic.List[pscustomobject]
}

process {

  function Invoke-FioTest {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
      [Parameter(Mandatory=$true)] [hashtable]$w
    )

    $jsonPath = Join-Path $OutputDir "$($w.Name).json"
    $stdPath  = Join-Path $OutputDir "$($w.Name).txt"
    $errPath  = Join-Path $OutputDir "$($w.Name).err.txt"

    # Build argument list (use tokens, not single string)
    $fioArgs = @(
      "--name=$($w.Name)",
      "--rw=$($w.rw)",
      "--direct=1",
      "--randrepeat=0",
      "--ioengine=windowsaio",
      "--bs=$($w.bs)",
      "--numjobs=$($w.numjobs)",
      "--iodepth=$($w.iodepth)",
      "--size=$FileSize",
      "--directory=$TargetPath",
      "--time_based=1",
      "--runtime=$DurationSec",
      "--group_reporting",
      "--output=$jsonPath",
      "--output-format=json"
    )
    if ($w.rwmixread) { $fioArgs += "--rwmixread=$($w.rwmixread)" }

    Write-Host ">>> Running $($w.Name) (rw=$($w.rw), bs=$($w.bs), nj=$($w.numjobs), qd=$($w.iodepth))..." -ForegroundColor Yellow

    # Destructive: FIO writes $FileSize x numjobs of data into $TargetPath and
    # saturates the volume for $DurationSec. Gate it so -WhatIf/-Confirm work.
    $target = "$TargetPath ($($w.numjobs) x $FileSize for ${DurationSec}s)"
    if (-not $PSCmdlet.ShouldProcess($target, "Run FIO workload '$($w.Name)'")) {
      return $null
    }

    # Start-Process rejects the same path for both redirects, so stderr gets its own file.
    $p = Start-Process -FilePath $FioPath -ArgumentList $fioArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdPath -RedirectStandardError $errPath
    if ($p.ExitCode -ne 0) {
      # Do not fall through to parsing: FIO writes no usable JSON on failure and
      # the resulting row would silently report 0 IOPS as if it were a measurement.
      Write-Warning "FIO exited with code $($p.ExitCode) for '$($w.Name)'. Skipping this workload. Check $stdPath and $errPath"
      return $null
    }

    return $jsonPath
  }

  function Remove-FioTestFile {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
      [Parameter(Mandatory=$true)][hashtable]$w
    )
    if ($KeepTestFiles) {
      Write-Verbose "KeepTestFiles set - leaving data files for '$($w.Name)' in $TargetPath"
      return
    }
    # FIO names its data files "<jobname>.<jobnum>.<filenum>" inside --directory.
    $pattern = Join-Path $TargetPath "$($w.Name).*"
    try {
      $files = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
      if ($files.Count -gt 0) {
        $freed = ($files | Measure-Object -Property Length -Sum).Sum
        if ($PSCmdlet.ShouldProcess("$($files.Count) FIO data file(s) in $TargetPath", "Delete")) {
          $files | Remove-Item -Force -ErrorAction Stop
          Write-Host "    Cleaned up $($files.Count) data file(s), freed $([math]::Round($freed / 1GB, 2)) GB" -ForegroundColor DarkGray
        }
      }
    }
    catch {
      Write-Warning "Could not clean up FIO data files matching '$pattern': $($_.Exception.Message)"
    }
  }

  function ConvertFrom-FioJson {
    param(
      [Parameter(Mandatory=$true)][string]$JsonFile,
      [Parameter(Mandatory=$true)][hashtable]$w
    )

    # FIO can exit 0 yet still produce an empty or truncated file (e.g. killed
    # mid-write). Parse defensively so one bad run cannot abort the whole suite.
    if (-not (Test-Path -LiteralPath $JsonFile)) {
      Write-Warning "FIO produced no JSON at '$JsonFile' for '$($w.Name)'. Skipping."
      return $null
    }
    $rawText = Get-Content -LiteralPath $JsonFile -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($rawText)) {
      Write-Warning "FIO JSON '$JsonFile' is empty for '$($w.Name)'. Skipping."
      return $null
    }
    try {
      $raw = $rawText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
      Write-Warning "FIO JSON '$JsonFile' is malformed for '$($w.Name)': $($_.Exception.Message). Skipping."
      return $null
    }
    if (-not $raw.jobs -or @($raw.jobs).Count -eq 0) {
      Write-Warning "FIO JSON '$JsonFile' contains no job results for '$($w.Name)'. Skipping."
      return $null
    }

    # Sum across jobs
    [double]$read_iops  = 0
    [double]$write_iops = 0
    [double]$read_bwB   = 0
    [double]$write_bwB  = 0
    [double]$read_lat_mean_ns  = 0
    [double]$write_lat_mean_ns = 0
    [double]$read_lat_p99_ns   = 0
    [double]$write_lat_p99_ns  = 0
    $jobsCount = [double]([Math]::Max(1, $raw.jobs.Count))

    foreach ($j in $raw.jobs) {
      $read_iops  += [double]$j.read.iops
      $write_iops += [double]$j.write.iops
      $read_bwB   += [double]$j.read.bw_bytes
      $write_bwB  += [double]$j.write.bw_bytes

      # Reset per job: without this, a job missing clat data would inherit the
      # previous job's latency values.
      $rMeanNs = $null; $wMeanNs = $null
      $rP99Ns  = $null; $wP99Ns  = $null

      # FIO >= 3.0 reports completion latency in nanoseconds as "clat_ns".
      # Older builds report "clat" in MICROseconds. The two were previously
      # treated identically, under-reporting legacy latency by 1000x, so scale
      # the legacy values up to nanoseconds here.
      $rScale = 1; $wScale = 1
      $rClat = $j.read.clat_ns
      if (-not $rClat) { $rClat = $j.read.clat; $rScale = 1000 }
      $wClat = $j.write.clat_ns
      if (-not $wClat) { $wClat = $j.write.clat; $wScale = 1000 }

      if ($rClat) {
        if ($rClat.mean) { $rMeanNs = [double]$rClat.mean * $rScale }
        if ($rClat.percentile.'99.000000') { $rP99Ns = [double]$rClat.percentile.'99.000000' * $rScale }
      }
      if ($wClat) {
        if ($wClat.mean) { $wMeanNs = [double]$wClat.mean * $wScale }
        if ($wClat.percentile.'99.000000') { $wP99Ns = [double]$wClat.percentile.'99.000000' * $wScale }
      }

      if ($rMeanNs) { $read_lat_mean_ns  += $rMeanNs }
      if ($wMeanNs) { $write_lat_mean_ns += $wMeanNs }
      if ($rP99Ns  -and $rP99Ns  -gt $read_lat_p99_ns)  { $read_lat_p99_ns  = $rP99Ns  } # take max
      if ($wP99Ns  -and $wP99Ns  -gt $write_lat_p99_ns) { $write_lat_p99_ns = $wP99Ns }  # take max
    }

    # Convert units
    $read_MBps  = $read_bwB  / 1MB
    $write_MBps = $write_bwB / 1MB
    $read_lat_ms_mean  = ($read_lat_mean_ns  / $jobsCount) / 1e6
    $write_lat_ms_mean = ($write_lat_mean_ns / $jobsCount) / 1e6
    $read_lat_ms_p99   = $read_lat_p99_ns  / 1e6
    $write_lat_ms_p99  = $write_lat_p99_ns / 1e6

    [pscustomobject]@{
      TestName          = $w.Name
      RW                = $w.rw
      BS                = $w.bs
      NumJobs           = $w.numjobs
      IoDepth           = $w.iodepth
      RWMixRead         = $(if ($w.rwmixread) { $w.rwmixread } else { "" })
      Read_IOPS         = [math]::Round($read_iops, 2)
      Write_IOPS        = [math]::Round($write_iops, 2)
      Read_MBps         = [math]::Round($read_MBps, 2)
      Write_MBps        = [math]::Round($write_MBps, 2)
      Read_Lat_Mean_ms  = [math]::Round($read_lat_ms_mean, 3)
      Write_Lat_Mean_ms = [math]::Round($write_lat_ms_mean, 3)
      Read_Lat_P99_ms   = [math]::Round($read_lat_ms_p99, 3)
      Write_Lat_P99_ms  = [math]::Round($write_lat_ms_p99, 3)
      JsonFile          = $JsonFile
    }
  }

  # Run all workloads. Any workload can be skipped (-WhatIf, FIO failure, bad
  # JSON), so every step is null-checked rather than assumed to produce a row.
  foreach ($w in $workloads) {
    $json = Invoke-FioTest -w $w
    if ($null -eq $json) { continue }
    try {
      $row = ConvertFrom-FioJson -JsonFile $json -w $w
      if ($null -ne $row) { $summary.Add($row) | Out-Null }
    }
    finally {
      Remove-FioTestFile -w $w
    }
  }

  if ($summary.Count -eq 0) {
    Write-Warning "No workload produced usable results - no CSV or HTML report was generated."
    return
  }

  # Save CSV
  $csv = Join-Path $OutputDir "ANF-FIO-Summary.csv"
  $summary | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
  Write-Host "CSV saved: $csv" -ForegroundColor Green

  # Save HTML
  $htmlPath = Join-Path $OutputDir "ANF-FIO-Report.html"
  $style = @"
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
    h1 { color: #2b5797; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ddd; padding: 6px 8px; }
    th { background: #f4f6fa; text-align: left; }
    tr:nth-child(even){background-color:#fbfbfb;}
    .note { font-size: 0.9em; color: #555; margin-top: 10px;}
  </style>
"@

  $htmlHeader = "<h1>Azure NetApp Files - FIO Summary</h1><div class='note'>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>"
  ($summary | Sort-Object TestName | ConvertTo-Html -Head $style -Title "ANF FIO Report" -PreContent $htmlHeader) | Out-File -FilePath $htmlPath -Encoding UTF8
  Write-Host "HTML report: $htmlPath" -ForegroundColor Green

} end {
  Write-Host "Done." -ForegroundColor Cyan
}
