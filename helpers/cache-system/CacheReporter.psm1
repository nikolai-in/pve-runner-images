<#
.SYNOPSIS
    Generates comprehensive reports on cache coverage, composition, and statistics.

.DESCRIPTION
    This module provides functionality to:
    - Generate reports on cache coverage and missing items
    - Show cache composition and statistics
    - Compare cache state with source lists
    - Export reports in various formats

.EXAMPLE
    Import-Module .\CacheReporter.psm1
    New-CacheReport -SourceListPath ".\cache-sources.json" -CacheDirectory ".\cache" -OutputPath ".\cache-report.json"
#>

using namespace System.Collections.Generic

# Import required modules
$ErrorActionPreference = 'Stop'

function New-CacheReport {
    <#
    .SYNOPSIS
        Generates a comprehensive cache report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceListPath,
        
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Json', 'Html', 'Text')]
        [string]$Format = 'Json'
    )
    
    if (-not (Test-Path $SourceListPath)) {
        throw "Source list file not found: $SourceListPath"
    }
    
    Write-Host "Generating cache report..." -ForegroundColor Green
    
    # Load source list
    $sourceList = Get-Content $SourceListPath -Raw | ConvertFrom-Json
    
    # Analyze cache
    $cacheAnalysis = Get-CacheAnalysis -SourceList $sourceList -CacheDirectory $CacheDirectory
    
    # Build report
    $report = @{
        metadata = @{
            generatedAt = (Get-Date).ToUniversalTime().ToString('o')
            cacheDirectory = $CacheDirectory
            sourceListPath = $SourceListPath
        }
        summary = $cacheAnalysis.Summary
        cachedItems = $cacheAnalysis.CachedItems
        missingItems = $cacheAnalysis.MissingItems
    }
    
    # Output report
    if ($OutputPath) {
        switch ($Format) {
            'Json' {
                $report | ConvertTo-Json -Depth 10 | Set-Content $OutputPath
                Write-Host "✓ JSON report saved to: $OutputPath" -ForegroundColor Green
            }
            'Html' {
                $htmlReport = ConvertTo-HtmlReport -Report $report
                $htmlReport | Set-Content $OutputPath
                Write-Host "✓ HTML report saved to: $OutputPath" -ForegroundColor Green
            }
            'Text' {
                $textReport = ConvertTo-TextReport -Report $report
                $textReport | Set-Content $OutputPath
                Write-Host "✓ Text report saved to: $OutputPath" -ForegroundColor Green
            }
        }
    }
    
    # Display summary
    Show-CacheReportSummary -Report $report
    
    return $report
}

function Get-CacheAnalysis {
    <#
    .SYNOPSIS
        Analyzes cache state against source list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceList,
        
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory
    )
    
    $cachedItems = [List[object]]::new()
    $missingItems = [List[object]]::new()
    $totalCacheSize = 0
    
    foreach ($source in $SourceList.sources) {
        $fileName = Get-CacheFileName -Source $source
        $filePath = Join-Path $CacheDirectory $fileName
        
        if (Test-Path $filePath) {
            $fileInfo = Get-Item $filePath
            $fileHash = $null
            
            # Calculate hash if we have the expected hash for comparison
            if ($source.sha256) {
                try {
                    $fileHash = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash
                }
                catch {
                    Write-Warning "Failed to calculate hash for: $filePath"
                }
            }
            
            $cachedItems.Add(@{
                name = $source.name
                version = $source.version
                platform = $source.platform
                arch = $source.arch
                filePath = $filePath
                fileSize = $fileInfo.Length
                sha256 = $fileHash
                downloadedAt = $fileInfo.CreationTime.ToUniversalTime().ToString('o')
                isValidChecksum = if ($source.sha256 -and $fileHash) { $fileHash -eq $source.sha256 } else { $null }
            })
            
            $totalCacheSize += $fileInfo.Length
        }
        else {
            $missingItems.Add(@{
                name = $source.name
                version = $source.version
                platform = $source.platform
                arch = $source.arch
                downloadUrl = $source.downloadUrl
                reason = "File not found in cache"
            })
        }
    }
    
    $totalSources = $SourceList.sources.Count
    $cachedCount = $cachedItems.Count
    $missingCount = $missingItems.Count
    $coveragePercentage = if ($totalSources -gt 0) { [math]::Round(($cachedCount / $totalSources) * 100, 2) } else { 0 }
    
    return @{
        Summary = @{
            totalSources = $totalSources
            cachedSources = $cachedCount
            missingSources = $missingCount
            coveragePercentage = $coveragePercentage
            totalCacheSize = $totalCacheSize
        }
        CachedItems = $cachedItems.ToArray()
        MissingItems = $missingItems.ToArray()
    }
}

function Get-CacheFileName {
    <#
    .SYNOPSIS
        Generates cache file name (shared with CacheDownloader).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source
    )
    
    # Create a structured path: platform/arch/name/version/filename
    $platform = $Source.platform -replace '[^\w]', '_'
    $arch = $Source.arch -replace '[^\w]', '_'
    $name = $Source.name -replace '[^\w]', '_'
    $version = $Source.version -replace '[^\w\.]', '_'
    
    # Extract filename from URL
    $uri = [Uri]$Source.downloadUrl
    $originalFileName = [System.IO.Path]::GetFileName($uri.LocalPath)
    
    if ([string]::IsNullOrEmpty($originalFileName)) {
        # Generate filename if not available from URL
        $extension = if ($Source.downloadUrl -match '\.(zip|tar\.gz|tar\.bz2|exe|msi|dmg|pkg)(\?|$)') { $Matches[1] } else { 'bin' }
        $originalFileName = "$name-$version.$extension"
    }
    
    return Join-Path $platform (Join-Path $arch (Join-Path $name (Join-Path $version $originalFileName)))
}

function Show-CacheReportSummary {
    <#
    .SYNOPSIS
        Displays a formatted summary of the cache report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Report
    )
    
    Write-Host ""
    Write-Host "Cache Report Summary" -ForegroundColor Green
    Write-Host "===================" -ForegroundColor Green
    Write-Host "Generated: $($Report.metadata.generatedAt)" -ForegroundColor Gray
    Write-Host "Cache Directory: $($Report.metadata.cacheDirectory)" -ForegroundColor Gray
    Write-Host ""
    
    $summary = $Report.summary
    Write-Host "Coverage Statistics:" -ForegroundColor Yellow
    Write-Host "  Total Sources: $($summary.totalSources)" -ForegroundColor White
    Write-Host "  Cached: $($summary.cachedSources)" -ForegroundColor Green
    Write-Host "  Missing: $($summary.missingSources)" -ForegroundColor Red
    Write-Host "  Coverage: $($summary.coveragePercentage)%" -ForegroundColor $(if ($summary.coveragePercentage -ge 90) { 'Green' } elseif ($summary.coveragePercentage -ge 70) { 'Yellow' } else { 'Red' })
    Write-Host "  Total Size: $(Format-FileSize -Bytes $summary.totalCacheSize)" -ForegroundColor Cyan
    
    if ($summary.missingSources -gt 0) {
        Write-Host ""
        Write-Host "Missing Items (Top 10):" -ForegroundColor Red
        $Report.missingItems | Select-Object -First 10 | ForEach-Object {
            Write-Host "  $($_.name) $($_.version) ($($_.platform)/$($_.arch))" -ForegroundColor Red
        }
        
        if ($Report.missingItems.Count -gt 10) {
            Write-Host "  ... and $($Report.missingItems.Count - 10) more" -ForegroundColor Red
        }
    }
    
    # Platform/Architecture breakdown
    Write-Host ""
    Write-Host "Platform Breakdown:" -ForegroundColor Yellow
    $platformStats = $Report.cachedItems | Group-Object platform | Sort-Object Name
    foreach ($platform in $platformStats) {
        $archStats = $platform.Group | Group-Object arch | Sort-Object Name
        Write-Host "  $($platform.Name): $($platform.Count) items" -ForegroundColor White
        foreach ($arch in $archStats) {
            Write-Host "    $($arch.Name): $($arch.Count) items" -ForegroundColor Gray
        }
    }
    
    Write-Host ""
}

function ConvertTo-HtmlReport {
    <#
    .SYNOPSIS
        Converts cache report to HTML format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Report
    )
    
    $summary = $Report.summary
    $coverageColor = if ($summary.coveragePercentage -ge 90) { 'green' } elseif ($summary.coveragePercentage -ge 70) { 'orange' } else { 'red' }
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Cache Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .summary { background: #f5f5f5; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .metric { display: inline-block; margin-right: 20px; }
        .metric-value { font-weight: bold; font-size: 1.2em; }
        .coverage { color: $coverageColor; }
        table { border-collapse: collapse; width: 100%; margin-top: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        .cached { background-color: #d4edda; }
        .missing { background-color: #f8d7da; }
        .progress-bar { width: 100%; background-color: #f0f0f0; border-radius: 5px; overflow: hidden; }
        .progress { height: 20px; background-color: $coverageColor; text-align: center; line-height: 20px; color: white; }
    </style>
</head>
<body>
    <h1>Cache Report</h1>
    <p><strong>Generated:</strong> $($Report.metadata.generatedAt)</p>
    <p><strong>Cache Directory:</strong> $($Report.metadata.cacheDirectory)</p>
    
    <div class="summary">
        <h2>Summary</h2>
        <div class="metric">
            <div>Total Sources</div>
            <div class="metric-value">$($summary.totalSources)</div>
        </div>
        <div class="metric">
            <div>Cached</div>
            <div class="metric-value">$($summary.cachedSources)</div>
        </div>
        <div class="metric">
            <div>Missing</div>
            <div class="metric-value">$($summary.missingSources)</div>
        </div>
        <div class="metric">
            <div>Coverage</div>
            <div class="metric-value coverage">$($summary.coveragePercentage)%</div>
        </div>
        <div class="metric">
            <div>Total Size</div>
            <div class="metric-value">$(Format-FileSize -Bytes $summary.totalCacheSize)</div>
        </div>
        
        <div class="progress-bar">
            <div class="progress" style="width: $($summary.coveragePercentage)%">$($summary.coveragePercentage)%</div>
        </div>
    </div>
    
    <h2>Cached Items ($($Report.cachedItems.Count))</h2>
    <table>
        <tr>
            <th>Name</th>
            <th>Version</th>
            <th>Platform</th>
            <th>Architecture</th>
            <th>Size</th>
            <th>Downloaded</th>
        </tr>
"@
    
    foreach ($item in $Report.cachedItems) {
        $html += @"
        <tr class="cached">
            <td>$($item.name)</td>
            <td>$($item.version)</td>
            <td>$($item.platform)</td>
            <td>$($item.arch)</td>
            <td>$(Format-FileSize -Bytes $item.fileSize)</td>
            <td>$($item.downloadedAt)</td>
        </tr>
"@
    }
    
    $html += @"
    </table>
    
    <h2>Missing Items ($($Report.missingItems.Count))</h2>
    <table>
        <tr>
            <th>Name</th>
            <th>Version</th>
            <th>Platform</th>
            <th>Architecture</th>
            <th>Reason</th>
        </tr>
"@
    
    foreach ($item in $Report.missingItems) {
        $html += @"
        <tr class="missing">
            <td>$($item.name)</td>
            <td>$($item.version)</td>
            <td>$($item.platform)</td>
            <td>$($item.arch)</td>
            <td>$($item.reason)</td>
        </tr>
"@
    }
    
    $html += @"
    </table>
</body>
</html>
"@
    
    return $html
}

function ConvertTo-TextReport {
    <#
    .SYNOPSIS
        Converts cache report to plain text format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Report
    )
    
    $text = @"
CACHE REPORT
============

Generated: $($Report.metadata.generatedAt)
Cache Directory: $($Report.metadata.cacheDirectory)
Source List: $($Report.metadata.sourceListPath)

SUMMARY
-------
Total Sources: $($Report.summary.totalSources)
Cached Sources: $($Report.summary.cachedSources)
Missing Sources: $($Report.summary.missingSources)
Coverage: $($Report.summary.coveragePercentage)%
Total Cache Size: $(Format-FileSize -Bytes $Report.summary.totalCacheSize)

CACHED ITEMS ($($Report.cachedItems.Count))
============
"@
    
    foreach ($item in $Report.cachedItems) {
        $text += "`n$($item.name) $($item.version) ($($item.platform)/$($item.arch)) - $(Format-FileSize -Bytes $item.fileSize)"
    }
    
    if ($Report.missingItems.Count -gt 0) {
        $text += @"

MISSING ITEMS ($($Report.missingItems.Count))
=============
"@
        
        foreach ($item in $Report.missingItems) {
            $text += "`n$($item.name) $($item.version) ($($item.platform)/$($item.arch)) - $($item.reason)"
        }
    }
    
    return $text
}

function Format-FileSize {
    <#
    .SYNOPSIS
        Formats file size in human-readable format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )
    
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    $size = [double]$Bytes
    
    while ($size -ge 1024 -and $index -lt ($units.Length - 1)) {
        $size /= 1024
        $index++
    }
    
    return "{0:N2} {1}" -f $size, $units[$index]
}

function Compare-CacheReports {
    <#
    .SYNOPSIS
        Compares two cache reports to show changes over time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OldReportPath,
        
        [Parameter(Mandatory = $true)]
        [string]$NewReportPath,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )
    
    $oldReport = Get-Content $OldReportPath -Raw | ConvertFrom-Json
    $newReport = Get-Content $NewReportPath -Raw | ConvertFrom-Json
    
    $comparison = @{
        metadata = @{
            generatedAt = (Get-Date).ToUniversalTime().ToString('o')
            oldReport = $OldReportPath
            newReport = $NewReportPath
        }
        changes = @{
            totalSources = $newReport.summary.totalSources - $oldReport.summary.totalSources
            cachedSources = $newReport.summary.cachedSources - $oldReport.summary.cachedSources
            missingSources = $newReport.summary.missingSources - $oldReport.summary.missingSources
            coverageChange = $newReport.summary.coveragePercentage - $oldReport.summary.coveragePercentage
            sizeChange = $newReport.summary.totalCacheSize - $oldReport.summary.totalCacheSize
        }
        newItems = @()
        removedItems = @()
    }
    
    # Find new and removed items
    $oldItems = $oldReport.cachedItems | ForEach-Object { "$($_.name)-$($_.version)-$($_.platform)-$($_.arch)" }
    $newItems = $newReport.cachedItems | ForEach-Object { "$($_.name)-$($_.version)-$($_.platform)-$($_.arch)" }
    
    $comparison.newItems = $newReport.cachedItems | Where-Object {
        $key = "$($_.name)-$($_.version)-$($_.platform)-$($_.arch)"
        $key -notin $oldItems
    }
    
    $comparison.removedItems = $oldReport.cachedItems | Where-Object {
        $key = "$($_.name)-$($_.version)-$($_.platform)-$($_.arch)"
        $key -notin $newItems
    }
    
    if ($OutputPath) {
        $comparison | ConvertTo-Json -Depth 10 | Set-Content $OutputPath
        Write-Host "✓ Comparison report saved to: $OutputPath" -ForegroundColor Green
    }
    
    # Display summary
    Write-Host "Cache Comparison Summary:" -ForegroundColor Green
    Write-Host "  Sources: $($comparison.changes.totalSources) ($(if ($comparison.changes.totalSources -ge 0) { '+' })$($comparison.changes.totalSources))"
    Write-Host "  Cached: $($comparison.changes.cachedSources) ($(if ($comparison.changes.cachedSources -ge 0) { '+' })$($comparison.changes.cachedSources))"
    Write-Host "  Coverage: $(if ($comparison.changes.coverageChange -ge 0) { '+' })$($comparison.changes.coverageChange)%"
    Write-Host "  Size: $(if ($comparison.changes.sizeChange -ge 0) { '+' })$(Format-FileSize -Bytes [math]::Abs($comparison.changes.sizeChange))"
    Write-Host "  New Items: $($comparison.newItems.Count)"
    Write-Host "  Removed Items: $($comparison.removedItems.Count)"
    
    return $comparison
}

# Export functions
Export-ModuleMember -Function @(
    'New-CacheReport',
    'Get-CacheAnalysis',
    'Show-CacheReportSummary',
    'Compare-CacheReports',
    'ConvertTo-HtmlReport',
    'ConvertTo-TextReport'
)
