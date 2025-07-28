<#
.SYNOPSIS
    Main orchestrator script for the cache system.

.DESCRIPTION
    This script provides a unified interface to all cache system operations:
    - Building source lists
    - Downloading tools
    - Generating reports
    - Running integrity checks

.EXAMPLE
    .\CacheManager.ps1 -Action BuildSources -UpstreamReportUrl "https://github.com/actions/runner-images/releases/download/win25/20250720.1/internal.windows-2025.json" -ToolsetPaths @(".\toolset-2022.json")

.EXAMPLE
    .\CacheManager.ps1 -Action Download -SourceListPath ".\cache-sources.json" -CacheDirectory ".\cache"

.EXAMPLE
    .\CacheManager.ps1 -Action Report -SourceListPath ".\cache-sources.json" -CacheDirectory ".\cache" -OutputPath ".\cache-report.html" -Format Html
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('BuildSources', 'UpdateSources', 'Download', 'Report', 'Integrity', 'Statistics', 'All')]
    [string]$Action,
    
    # Source List Builder parameters
    [Parameter(Mandatory = $false)]
    [string]$UpstreamReportUrl,
    
    [Parameter(Mandatory = $false)]
    [string[]]$ToolsetPaths,
    
    [Parameter(Mandatory = $false)]
    [string]$SourceListPath = "cache-sources.json",
    
    # Cache Downloader parameters
    [Parameter(Mandatory = $false)]
    [string]$CacheDirectory = "cache",
    
    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 3,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipExisting,
    
    [Parameter(Mandatory = $false)]
    [switch]$VerifyChecksums,
    
    # Cache Reporter parameters
    [Parameter(Mandatory = $false)]
    [string]$OutputPath,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('Json', 'Html', 'Text')]
    [string]$Format = 'Json',
    
    # Common parameters
    [Parameter(Mandatory = $false)]
    [string]$CachePath
)

# Set up error handling
$ErrorActionPreference = 'Stop'

# Import required modules
$ModulePath = $PSScriptRoot
Import-Module (Join-Path $ModulePath "CacheSourceListBuilder.psm1") -Force
Import-Module (Join-Path $ModulePath "CacheDownloader.psm1") -Force
Import-Module (Join-Path $ModulePath "CacheReporter.psm1") -Force

function Write-Banner {
    param([string]$Title)
    
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Green
    Write-Host " $Title" -ForegroundColor Green
    Write-Host "=" * 60 -ForegroundColor Green
    Write-Host ""
}

function Invoke-BuildSources {
    Write-Banner "Building Cache Source List"
    
    if (-not $UpstreamReportUrl) {
        throw "UpstreamReportUrl is required for BuildSources action"
    }
    
    if (-not $ToolsetPaths) {
        throw "ToolsetPaths is required for BuildSources action"
    }
    
    $result = New-CacheSourceList -UpstreamReportUrl $UpstreamReportUrl -ToolsetPaths $ToolsetPaths -OutputPath $SourceListPath -CachePath $CachePath
    
    Write-Host "✓ Source list created successfully: $SourceListPath" -ForegroundColor Green
    Write-Host "  Sources found: $($result.sources.Count)" -ForegroundColor Gray
    
    return $result
}

function Invoke-UpdateSources {
    Write-Banner "Updating Cache Source List"
    
    if (-not $UpstreamReportUrl) {
        throw "UpstreamReportUrl is required for UpdateSources action"
    }
    
    if (-not $ToolsetPaths) {
        throw "ToolsetPaths is required for UpdateSources action"
    }
    
    $result = Update-CacheSourceList -SourceListPath $SourceListPath -UpstreamReportUrl $UpstreamReportUrl -ToolsetPaths $ToolsetPaths -CachePath $CachePath
    
    Write-Host "✓ Source list updated successfully: $SourceListPath" -ForegroundColor Green
    Write-Host "  Sources found: $($result.sources.Count)" -ForegroundColor Gray
    
    return $result
}

function Invoke-Download {
    Write-Banner "Downloading Cache Tools"
    
    if (-not (Test-Path $SourceListPath)) {
        throw "Source list file not found: $SourceListPath. Run BuildSources first."
    }
    
    $params = @{
        SourceListPath = $SourceListPath
        CacheDirectory = $CacheDirectory
        MaxRetries = $MaxRetries
    }
    
    if ($SkipExisting) { $params.SkipExisting = $true }
    if ($VerifyChecksums) { $params.VerifyChecksums = $true }
    
    $result = Start-CacheDownload @params
    
    Write-Host "✓ Download completed" -ForegroundColor Green
    Write-Host "  Downloaded: $($result.Summary.Downloaded)" -ForegroundColor Green
    Write-Host "  Skipped: $($result.Summary.Skipped)" -ForegroundColor Yellow
    Write-Host "  Errors: $($result.Summary.Errors)" -ForegroundColor Red
    
    return $result
}

function Invoke-Report {
    Write-Banner "Generating Cache Report"
    
    if (-not (Test-Path $SourceListPath)) {
        throw "Source list file not found: $SourceListPath"
    }
    
    $result = New-CacheReport -SourceListPath $SourceListPath -CacheDirectory $CacheDirectory -OutputPath $OutputPath -Format $Format
    
    if ($OutputPath) {
        Write-Host "✓ Report saved to: $OutputPath" -ForegroundColor Green
    }
    
    return $result
}

function Invoke-Integrity {
    Write-Banner "Checking Cache Integrity"
    
    if (-not (Test-Path $SourceListPath)) {
        throw "Source list file not found: $SourceListPath"
    }
    
    $result = Test-CacheIntegrity -SourceListPath $SourceListPath -CacheDirectory $CacheDirectory
    
    Write-Host "✓ Integrity check completed" -ForegroundColor Green
    Write-Host "  Valid: $($result.Summary.Valid)" -ForegroundColor Green
    Write-Host "  Invalid: $($result.Summary.Invalid)" -ForegroundColor Red
    Write-Host "  Missing: $($result.Summary.Missing)" -ForegroundColor Yellow
    Write-Host "  Errors: $($result.Summary.Errors)" -ForegroundColor Red
    
    return $result
}

function Invoke-Statistics {
    Write-Banner "Cache Statistics"
    
    $result = Get-CacheStatistics -CacheDirectory $CacheDirectory
    
    Write-Host "Cache Statistics:" -ForegroundColor Green
    Write-Host "  Total Files: $($result.TotalFiles)" -ForegroundColor White
    Write-Host "  Total Size: $($result.TotalSizeFormatted)" -ForegroundColor White
    Write-Host "  Directory: $CacheDirectory" -ForegroundColor Gray
    
    return $result
}

function Invoke-All {
    Write-Banner "Running Complete Cache Workflow"
    
    # Validate required parameters
    if (-not $UpstreamReportUrl -or -not $ToolsetPaths) {
        throw "UpstreamReportUrl and ToolsetPaths are required for All action"
    }
    
    $results = @{}
    
    try {
        # Build or update source list
        if (Test-Path $SourceListPath) {
            Write-Host "Updating existing source list..." -ForegroundColor Yellow
            $results.Sources = Invoke-UpdateSources
        } else {
            Write-Host "Building new source list..." -ForegroundColor Yellow
            $results.Sources = Invoke-BuildSources
        }
        
        # Download tools
        $results.Download = Invoke-Download
        
        # Generate report
        if (-not $OutputPath) {
            $OutputPath = "cache-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').$($Format.ToLower())"
        }
        $results.Report = Invoke-Report
        
        # Check integrity
        $results.Integrity = Invoke-Integrity
        
        # Show statistics
        $results.Statistics = Invoke-Statistics
        
        Write-Banner "Workflow Completed Successfully"
        Write-Host "Summary:" -ForegroundColor Green
        Write-Host "  Sources: $($results.Sources.sources.Count)" -ForegroundColor White
        Write-Host "  Downloaded: $($results.Download.Summary.Downloaded)" -ForegroundColor White
        Write-Host "  Coverage: $($results.Report.summary.coveragePercentage)%" -ForegroundColor White
        Write-Host "  Cache Size: $($results.Statistics.TotalSizeFormatted)" -ForegroundColor White
        
        if ($results.Download.Summary.Errors -gt 0) {
            Write-Host "  Errors: $($results.Download.Summary.Errors) (check logs above)" -ForegroundColor Red
        }
        
        return $results
    }
    catch {
        Write-Host "Workflow failed: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# Main execution
try {
    Write-Host "Cache Manager - $Action" -ForegroundColor Cyan
    Write-Host "Working Directory: $PWD" -ForegroundColor Gray
    
    switch ($Action) {
        'BuildSources' { $result = Invoke-BuildSources }
        'UpdateSources' { $result = Invoke-UpdateSources }
        'Download' { $result = Invoke-Download }
        'Report' { $result = Invoke-Report }
        'Integrity' { $result = Invoke-Integrity }
        'Statistics' { $result = Invoke-Statistics }
        'All' { $result = Invoke-All }
    }
    
    Write-Host ""
    Write-Host "✅ $Action completed successfully!" -ForegroundColor Green
    
    # Return result for programmatic use
    return $result
}
catch {
    Write-Host ""
    Write-Host "❌ $Action failed: $($_.Exception.Message)" -ForegroundColor Red
    
    if ($Verbose) {
        Write-Host "Stack trace:" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    
    exit 1
}
