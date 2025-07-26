################################################################################
##  File:  Initialize-CacheEnvironment.ps1
##  Desc:  Initialize build environment to use pre-downloaded cache
##  Usage: Source this script before running build scripts
################################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CacheLocation,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("windows")]
    [string]$Platform = "windows",
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Initializing Cache Environment ===" -ForegroundColor Green

# Get current script location
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import the cached install helpers
$cachedHelpersPath = Join-Path $scriptRoot "CachedInstallHelpers.ps1"
if (-not (Test-Path $cachedHelpersPath)) {
    throw "CachedInstallHelpers.ps1 not found at: $cachedHelpersPath"
}

# Source the script to make functions available globally (with error handling)
try {
    . $cachedHelpersPath
    Write-Host "Cached installation functions loaded successfully" -ForegroundColor Green
} catch {
    throw "Failed to load cached install helpers: $_"
}

# Initialize the build cache
Initialize-BuildCache -CacheLocation $CacheLocation -Platform $Platform

# Set environment variables for other scripts to detect cache availability
$env:BUILD_CACHE_ENABLED = "true"
$env:BUILD_CACHE_LOCATION = $CacheLocation
$env:BUILD_CACHE_PLATFORM = $Platform

Write-Host "Cache environment initialized successfully!" -ForegroundColor Green
Write-Host "  Functions available: Install-Binary, Invoke-DownloadWithRetry (cached versions)"
Write-Host "  Environment variables set:"
Write-Host "    BUILD_CACHE_ENABLED = $env:BUILD_CACHE_ENABLED"
Write-Host "    BUILD_CACHE_LOCATION = $env:BUILD_CACHE_LOCATION"
Write-Host "    BUILD_CACHE_PLATFORM = $env:BUILD_CACHE_PLATFORM"

# Display cache statistics
$stats = Get-CacheStatistics
if ($stats.CacheEnabled) {
    Write-Host "`nCache Statistics:" -ForegroundColor Cyan
    Write-Host "  Total cached files: $($stats.TotalFiles)"
    Write-Host "  Toolset URLs: $($stats.Statistics.ToolsetUrls)"
    Write-Host "  Script URLs: $($stats.Statistics.ScriptUrls)"
    Write-Host "  Manifest URLs: $($stats.Statistics.ManifestUrls)"
}
