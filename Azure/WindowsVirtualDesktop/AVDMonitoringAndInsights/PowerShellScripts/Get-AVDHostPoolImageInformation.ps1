#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Az.Accounts'; ModuleVersion = '2.12.0' }, @{ ModuleName = 'Az.DesktopVirtualization'; ModuleVersion = '4.0.0' }

<#
.SYNOPSIS
    Reports Azure Virtual Desktop host pool VM template metadata and, optionally, the image actually deployed on each session host.

.DESCRIPTION
    Modern replacement for 'AVD-Get-Hostpool-Image-information.ps1'.

    Differences from the legacy script:
      - Uses the current Azure PowerShell sign-in context instead of a stored ControlUp service principal secret.
      - Requires an explicit SubscriptionId instead of taking the first subscription returned.
      - Matches session hosts exactly (NetBIOS or FQDN) and fails on zero or multiple matches.
      - Never installs modules and never changes machine state.
      - Restores the caller's Azure context, even on failure.
      - Reports the real image reference from the session host VM, because the host pool VMTemplate is
        provisioning metadata and is not evidence of what a running session host uses today.

    Read-only: issues only Get-* calls.

.PARAMETER SubscriptionId
    Subscription that contains the host pool.

.PARAMETER ResourceGroupName
    Optional resource group scope. Narrows the search and reduces the number of calls.

.PARAMETER HostPoolName
    Optional exact host pool name. When omitted, every host pool in scope is reported.

.PARAMETER SessionHostName
    Session host to locate, as NetBIOS name or FQDN. The owning host pool is resolved from it.

.PARAMETER SkipSessionHostImage
    Skip the Azure Compute lookup and report host pool template data only. Removes the Az.Compute requirement.

.PARAMETER OutputPath
    Optional file path for a plain-text report. The report groups session hosts under their host pool and uses
    aligned label/value lines. Objects are still written to the pipeline, so -OutputPath can be combined with
    Export-Csv or Format-List. Missing parent directories are created.

.EXAMPLE
    .\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>' -ResourceGroupName 'WPNS-AVD' -HostPoolName 'WPNS-AVD' | Format-List

.EXAMPLE
    .\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>' -SessionHostName 'WPNS-AVD-0'

.EXAMPLE
    .\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>' -SkipSessionHostImage |
        Export-Csv -Path 'C:\Temp\avd-images.csv' -NoTypeInformation

.EXAMPLE
    .\Get-AVDHostPoolImageInformation.ps1 -SubscriptionId '<subscription-id>' -OutputPath 'C:\Temp\avd-image-report.txt' | Out-Null

.NOTES
    Requires read access to the host pools and, unless -SkipSessionHostImage is used, to the session host virtual machines.
    'Desktop Virtualization Reader' plus 'Reader' on the VM scope is sufficient.
#>

[CmdletBinding(DefaultParameterSetName = 'HostPool')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(ParameterSetName = 'HostPool')]
    [ValidateNotNullOrEmpty()]
    [string] $HostPoolName,

    [Parameter(Mandatory, ParameterSetName = 'SessionHost')]
    [ValidateNotNullOrEmpty()]
    [string] $SessionHostName,

    [Parameter()]
    [switch] $SkipSessionHostImage,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

function Get-HostPoolTemplateSummary {
    param([string] $VMTemplate)

    $summary = [ordered]@{
        VMTemplatePresent    = $false
        TemplateImageType    = $null
        TemplateImage        = $null
        TemplateVMSize       = $null
        TemplateNamePrefix   = $null
        VMTemplate           = $null
    }

    if ([string]::IsNullOrWhiteSpace($VMTemplate)) {
        return $summary
    }

    $summary.VMTemplatePresent = $true

    try {
        $parsed = $VMTemplate | ConvertFrom-Json
    }
    catch {
        $summary.TemplateImageType = 'UnparsableJson'
        return $summary
    }

    $summary.VMTemplate = $parsed
    $properties = $parsed.PSObject.Properties.Name

    if ($properties -contains 'imageType') { $summary.TemplateImageType = $parsed.imageType }
    if ($properties -contains 'namePrefix') { $summary.TemplateNamePrefix = $parsed.namePrefix }

    if ($properties -contains 'vmSize' -and $parsed.vmSize) {
        if ($parsed.vmSize.PSObject.Properties.Name -contains 'id') {
            $summary.TemplateVMSize = $parsed.vmSize.id
        }
        else {
            $summary.TemplateVMSize = [string]$parsed.vmSize
        }
    }

    if ($properties -contains 'customImageId' -and $parsed.customImageId) {
        $summary.TemplateImage = $parsed.customImageId
    }
    elseif ($properties -contains 'imageUri' -and $parsed.imageUri) {
        $summary.TemplateImage = $parsed.imageUri
    }
    elseif ($properties -contains 'galleryImagePublisher' -and $parsed.galleryImagePublisher) {
        $summary.TemplateImage = '{0}:{1}:{2}' -f $parsed.galleryImagePublisher, $parsed.galleryImageOffer, $parsed.galleryImageSKU
    }

    return $summary
}

function Get-SessionHostImageSummary {
    param([string] $VMResourceId)

    $summary = [ordered]@{
        VMName          = $null
        VMSize          = $null
        VMImageType     = $null
        VMImage         = $null
        VMImageVersion  = $null
        VMImageLookup   = 'Skipped'
    }

    if ([string]::IsNullOrWhiteSpace($VMResourceId)) {
        $summary.VMImageLookup = 'NoVMResourceIdOnSessionHost'
        return $summary
    }

    $segments = $VMResourceId.Trim('/') -split '/'
    if ($segments.Count -lt 8) {
        $summary.VMImageLookup = 'UnrecognizedVMResourceId'
        return $summary
    }

    $vmResourceGroup = $segments[3]
    $vmName = $segments[-1]
    $summary.VMName = $vmName

    try {
        $vm = Get-AzVM -ResourceGroupName $vmResourceGroup -Name $vmName
    }
    catch {
        $summary.VMImageLookup = 'Failed: {0}' -f $_.Exception.Message
        return $summary
    }

    $summary.VMSize = $vm.HardwareProfile.VmSize
    $image = $vm.StorageProfile.ImageReference

    if (-not $image) {
        $summary.VMImageLookup = 'NoImageReference'
        return $summary
    }

    if ($image.Id) {
        if ($image.Id -like '*/galleries/*') { $summary.VMImageType = 'Gallery' } else { $summary.VMImageType = 'ManagedImage' }
        $summary.VMImage = $image.Id
    }
    elseif ($image.Publisher) {
        $summary.VMImageType = 'Marketplace'
        $summary.VMImage = '{0}:{1}:{2}' -f $image.Publisher, $image.Offer, $image.Sku
    }

    if ($image.ExactVersion) { $summary.VMImageVersion = $image.ExactVersion } else { $summary.VMImageVersion = $image.Version }
    $summary.VMImageLookup = 'Succeeded'

    return $summary
}

function Test-SessionHostNameMatch {
    param(
        [string] $CandidateName,
        [string] $RequestedName
    )

    # Session host names arrive as '<hostPool>/<fqdn>'.
    $leaf = ($CandidateName -split '/')[-1]
    return ($leaf -ieq $RequestedName) -or (($leaf -split '\.')[0] -ieq $RequestedName)
}

function Format-ReportField {
    param(
        [string] $Label,
        $Value,
        [int] $Indent = 0,
        [int] $Width = 19
    )

    $text = if ($null -eq $Value) { '-' } else { [string]$Value }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '-' }

    '{0}{1} : {2}' -f (' ' * $Indent), $Label.PadRight($Width), $text
}

function New-HostPoolImageReport {
    param(
        [psobject[]] $Record,
        [string] $Scope
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $title = 'Azure Virtual Desktop - host pool image report'

    $lines.Add($title)
    $lines.Add('=' * $title.Length)
    $lines.Add((Format-ReportField -Label 'Generated (UTC)' -Value ([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))))
    $lines.Add((Format-ReportField -Label 'Subscription' -Value $Record[0].SubscriptionId))
    $lines.Add((Format-ReportField -Label 'Scope' -Value $Scope))
    $lines.Add('')

    $reportedHosts = @($Record | Where-Object { $_.SessionHostName })
    # 'Failed: <reason>' is collapsed so one long message cannot swamp the summary line; the reason stays on each session host.
    $lookupSummary = @(
        $reportedHosts |
            Group-Object -Property { if ($_.VMImageLookup -like 'Failed:*') { 'Failed' } else { $_.VMImageLookup } } |
            Sort-Object Name |
            ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
    ) -join '; '

    $lines.Add('Summary')
    $lines.Add('-------')
    $lines.Add((Format-ReportField -Label 'Host pools' -Value @($Record.HostPoolId | Sort-Object -Unique).Count))
    $lines.Add((Format-ReportField -Label 'Session hosts' -Value $reportedHosts.Count))
    $lines.Add((Format-ReportField -Label 'Image lookup' -Value $lookupSummary))
    $lines.Add('')

    $ordered = $Record | Sort-Object -Property HostPoolName, SessionHostName

    foreach ($group in ($ordered | Group-Object -Property HostPoolId)) {
        $pool = $group.Group[0]
        $heading = 'Host pool: {0}' -f $pool.HostPoolName

        $lines.Add($heading)
        $lines.Add('-' * $heading.Length)
        $lines.Add((Format-ReportField -Label 'Resource group' -Value $pool.ResourceGroupName))
        $lines.Add((Format-ReportField -Label 'Location' -Value $pool.Location))
        $lines.Add((Format-ReportField -Label 'Type' -Value $pool.HostPoolType))
        $lines.Add((Format-ReportField -Label 'Load balancer' -Value $pool.LoadBalancerType))
        $lines.Add((Format-ReportField -Label 'Max session limit' -Value $pool.MaxSessionLimit))
        $lines.Add((Format-ReportField -Label 'Template present' -Value $pool.VMTemplatePresent))
        $lines.Add((Format-ReportField -Label 'Template image type' -Value $pool.TemplateImageType))
        $lines.Add((Format-ReportField -Label 'Template image' -Value $pool.TemplateImage))
        $lines.Add((Format-ReportField -Label 'Template VM size' -Value $pool.TemplateVMSize))
        $lines.Add((Format-ReportField -Label 'Template prefix' -Value $pool.TemplateNamePrefix))
        $lines.Add('')

        $poolHosts = @($group.Group | Where-Object { $_.SessionHostName })
        if (-not $poolHosts.Count) {
            $lines.Add((Format-ReportField -Label 'Session hosts' -Value 'not queried' -Indent 2 -Width 17))
            $lines.Add('')
            continue
        }

        foreach ($item in $poolHosts) {
            $lines.Add(('  Session host: {0}' -f $item.SessionHostName))
            $lines.Add((Format-ReportField -Label 'Status' -Value $item.SessionHostStatus -Indent 4 -Width 13))
            $lines.Add((Format-ReportField -Label 'VM name' -Value $item.VMName -Indent 4 -Width 13))
            $lines.Add((Format-ReportField -Label 'VM size' -Value $item.VMSize -Indent 4 -Width 13))
            $lines.Add((Format-ReportField -Label 'Image type' -Value $item.VMImageType -Indent 4 -Width 13))
            $lines.Add((Format-ReportField -Label 'Image' -Value $item.VMImage -Indent 4 -Width 13))
            $lines.Add((Format-ReportField -Label 'Image version' -Value $item.VMImageVersion -Indent 4 -Width 13))
            $lines.Add((Format-ReportField -Label 'Image lookup' -Value $item.VMImageLookup -Indent 4 -Width 13))
            $lines.Add('')
        }
    }

    $lines.Add('Notes')
    $lines.Add('-----')
    $lines.Add('Template values describe how the host pool provisions new session hosts.')
    $lines.Add('VM values are read from the session host virtual machine and describe what it runs today.')
    $lines.Add('A difference between the two means the session host has drifted from the host pool definition.')

    return $lines.ToArray()
}

$originalContext = Get-AzContext
if (-not $originalContext -or -not $originalContext.Account) {
    throw "No Azure PowerShell sign-in was found. Run 'Connect-AzAccount' in this session, then run this script again."
}

$resolveSessionHostImage = -not $SkipSessionHostImage
if ($resolveSessionHostImage -and -not (Get-Module -ListAvailable -Name 'Az.Compute')) {
    Write-Warning 'Az.Compute is not installed, so session host image details are unavailable. Reporting host pool template data only.'
    $resolveSessionHostImage = $false
    $azComputeMissing = $true
}

$contextChanged = $false

try {
    if ($originalContext.Subscription.Id -ne $SubscriptionId) {
        Write-Verbose "Switching Azure context to subscription $SubscriptionId."
        $null = Set-AzContext -SubscriptionId $SubscriptionId
        $contextChanged = $true
    }

    $hostPoolParameters = @{ SubscriptionId = $SubscriptionId }
    if ($ResourceGroupName) { $hostPoolParameters['ResourceGroupName'] = $ResourceGroupName }
    if ($PSCmdlet.ParameterSetName -eq 'HostPool' -and $HostPoolName -and $ResourceGroupName) {
        $hostPoolParameters['Name'] = $HostPoolName
    }

    $hostPools = @(Get-AzWvdHostPool @hostPoolParameters)

    if ($PSCmdlet.ParameterSetName -eq 'HostPool' -and $HostPoolName -and -not $ResourceGroupName) {
        $hostPools = @($hostPools | Where-Object { $_.Name -ieq $HostPoolName })
    }

    if (-not $hostPools) {
        throw "No host pool was found in subscription $SubscriptionId for the requested scope."
    }

    $targets = New-Object System.Collections.Generic.List[psobject]

    foreach ($pool in $hostPools) {
        # Host pool IDs are /subscriptions/<id>/resourceGroups/<rg>/providers/...
        $poolResourceGroup = ($pool.Id -split '/')[4]
        $sessionHosts = @()

        if ($PSCmdlet.ParameterSetName -eq 'SessionHost' -or $resolveSessionHostImage) {
            $sessionHosts = @(Get-AzWvdSessionHost -SubscriptionId $SubscriptionId -ResourceGroupName $poolResourceGroup -HostPoolName $pool.Name)
        }

        if ($PSCmdlet.ParameterSetName -eq 'SessionHost') {
            $sessionHosts = @($sessionHosts | Where-Object { Test-SessionHostNameMatch -CandidateName $_.Name -RequestedName $SessionHostName })
            if (-not $sessionHosts) { continue }
        }

        if ($sessionHosts) {
            foreach ($sessionHost in $sessionHosts) {
                $targets.Add([pscustomobject]@{ HostPool = $pool; ResourceGroupName = $poolResourceGroup; SessionHost = $sessionHost })
            }
        }
        else {
            $targets.Add([pscustomobject]@{ HostPool = $pool; ResourceGroupName = $poolResourceGroup; SessionHost = $null })
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'SessionHost') {
        if ($targets.Count -eq 0) {
            throw "Session host '$SessionHostName' was not found in subscription $SubscriptionId for the requested scope."
        }
        if ($targets.Count -gt 1) {
            $matchedHosts = ($targets | ForEach-Object { '{0}/{1}' -f $_.HostPool.Name, ($_.SessionHost.Name -split '/')[-1] }) -join ', '
            throw "Session host '$SessionHostName' matched $($targets.Count) session hosts ($matchedHosts). Specify -ResourceGroupName or use the FQDN."
        }
    }

    $records = New-Object System.Collections.Generic.List[psobject]

    foreach ($target in $targets) {
        $pool = $target.HostPool
        $template = Get-HostPoolTemplateSummary -VMTemplate $pool.VMTemplate

        # Deliberately not named $sessionHostName: PowerShell variables are case-insensitive and would hit the parameter's validation attribute.
        $resolvedHostName = $null
        $resolvedHostStatus = $null
        $vmResourceId = $null

        if ($target.SessionHost) {
            $resolvedHostName = ($target.SessionHost.Name -split '/')[-1]
            $resolvedHostStatus = $target.SessionHost.Status
            $vmResourceId = $target.SessionHost.ResourceId
        }

        if ($resolveSessionHostImage) {
            $image = Get-SessionHostImageSummary -VMResourceId $vmResourceId
        }
        else {
            $image = Get-SessionHostImageSummary -VMResourceId $null
            if ($azComputeMissing) { $image.VMImageLookup = 'Az.ComputeNotInstalled' } else { $image.VMImageLookup = 'Skipped' }
        }

        $records.Add([pscustomobject]@{
            SubscriptionId     = $SubscriptionId
            ResourceGroupName  = $target.ResourceGroupName
            HostPoolName       = $pool.Name
            HostPoolType       = $pool.HostPoolType
            Location           = $pool.Location
            LoadBalancerType   = $pool.LoadBalancerType
            MaxSessionLimit    = $pool.MaxSessionLimit
            SessionHostName    = $resolvedHostName
            SessionHostStatus  = $resolvedHostStatus
            VMTemplatePresent  = $template.VMTemplatePresent
            TemplateImageType  = $template.TemplateImageType
            TemplateImage      = $template.TemplateImage
            TemplateVMSize     = $template.TemplateVMSize
            TemplateNamePrefix = $template.TemplateNamePrefix
            VMName             = $image.VMName
            VMSize             = $image.VMSize
            VMImageType        = $image.VMImageType
            VMImage            = $image.VMImage
            VMImageVersion     = $image.VMImageVersion
            VMImageLookup      = $image.VMImageLookup
            VMResourceId       = $vmResourceId
            HostPoolId         = $pool.Id
            VMTemplate         = $template.VMTemplate
        })
    }

    $records

    if ($OutputPath) {
        $reportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        $reportDirectory = Split-Path -Path $reportPath -Parent
        if ($reportDirectory -and -not (Test-Path -LiteralPath $reportDirectory)) {
            $null = New-Item -ItemType Directory -Path $reportDirectory -Force
        }

        $scopeParts = New-Object System.Collections.Generic.List[string]
        if ($ResourceGroupName) { $scopeParts.Add("ResourceGroup=$ResourceGroupName") }
        if ($PSCmdlet.ParameterSetName -eq 'SessionHost') {
            $scopeParts.Add("SessionHost=$SessionHostName")
        }
        elseif ($HostPoolName) {
            $scopeParts.Add("HostPool=$HostPoolName")
        }
        if (-not $scopeParts.Count) { $scopeParts.Add('Whole subscription') }

        $report = New-HostPoolImageReport -Record $records.ToArray() -Scope ($scopeParts -join '; ')
        Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8
        Write-Host "Report written to $reportPath"
    }
}
finally {
    if ($contextChanged) {
        Write-Verbose 'Restoring the original Azure context.'
        $null = Set-AzContext -Context $originalContext -ErrorAction SilentlyContinue
    }
}
