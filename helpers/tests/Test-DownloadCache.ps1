################################################################################
##  File:  Test-DownloadCache.ps1
##  Desc:  Test runner for download cache system
##  Usage: .\helpers\tests\Test-DownloadCache.ps1 [-UnitTests] [-IntegrationTests] [-SmokeTests] [-All] [-Detailed]
################################################################################

[CmdletBinding()]
param(
    [switch]$UnitTests,
    [switch]$IntegrationTests,
    [switch]$SmokeTests,
    [switch]$All,
    [switch]$Detailed
)

$ErrorActionPreference = "Stop"

# Default to running smoke tests if no specific test type is selected
if (-not $UnitTests -and -not $IntegrationTests -and -not $SmokeTests) {
    $SmokeTests = $true
}

Write-Host "=== Download Cache System Test Runner ===" -ForegroundColor Green

# Get test directory
$testDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$helperDir = Split-Path -Parent $testDir

# Check if Pester is available
try {
    Import-Module Pester -MinimumVersion 5.0 -Force
    Write-Host "Using Pester version: $((Get-Module Pester).Version)" -ForegroundColor Cyan
} catch {
    throw "Pester 5.0+ is required. Install with: Install-Module Pester -Force"
}

$testResults = @()
$totalTests = 0
$passedTests = 0
$failedTests = 0

if ($SmokeTests -or $All) {
    Write-Host "`n--- Running Smoke Tests ---" -ForegroundColor Yellow
    
    $smokeTestPath = Join-Path $testDir "DownloadCache.Smoke.Tests.ps1"
    if (Test-Path $smokeTestPath) {
        $config = [PesterConfiguration]::Default
        $config.Run.Path = $smokeTestPath
        $config.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputPath = Join-Path $testDir "SmokeTestResults.xml"
        
        $result = Invoke-Pester -Configuration $config
        $testResults += $result
        $totalTests += $result.TotalCount
        $passedTests += $result.PassedCount
        $failedTests += $result.FailedCount
        
        Write-Host "Smoke Tests: $($result.PassedCount) passed, $($result.FailedCount) failed" -ForegroundColor $(if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' })
    } else {
        Write-Warning "Smoke test file not found: $smokeTestPath"
    }
}

if ($UnitTests -or $All) {
    Write-Host "`n--- Running Unit Tests ---" -ForegroundColor Yellow
    
    $unitTestPath = Join-Path $testDir "DownloadCache.Unit.Tests.ps1"
    if (Test-Path $unitTestPath) {
        $config = [PesterConfiguration]::Default
        $config.Run.Path = $unitTestPath
        $config.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputPath = Join-Path $testDir "UnitTestResults.xml"
        
        $result = Invoke-Pester -Configuration $config
        $testResults += $result
        $totalTests += $result.TotalCount
        $passedTests += $result.PassedCount
        $failedTests += $result.FailedCount
        
        Write-Host "Unit Tests: $($result.PassedCount) passed, $($result.FailedCount) failed" -ForegroundColor $(if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' })
    } else {
        Write-Warning "Unit test file not found: $unitTestPath"
    }
}

if ($IntegrationTests -or $All) {
    Write-Host "`n--- Running Integration Tests ---" -ForegroundColor Yellow
    
    $integrationTestPath = Join-Path $testDir "DownloadCache.Integration.Tests.ps1"
    if (Test-Path $integrationTestPath) {
        $config = [PesterConfiguration]::Default
        $config.Run.Path = $integrationTestPath
        $config.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }
        $config.TestResult.Enabled = $true
        $config.TestResult.OutputPath = Join-Path $testDir "IntegrationTestResults.xml"
        
        $result = Invoke-Pester -Configuration $config
        $testResults += $result
        $totalTests += $result.TotalCount
        $passedTests += $result.PassedCount
        $failedTests += $result.FailedCount
        
        Write-Host "Integration Tests: $($result.PassedCount) passed, $($result.FailedCount) failed" -ForegroundColor $(if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' })
    } else {
        Write-Warning "Integration test file not found: $integrationTestPath"
    }
}

# Summary
Write-Host "`n=== Test Summary ===" -ForegroundColor Green
Write-Host "Total Tests: $totalTests"
Write-Host "Passed: $passedTests" -ForegroundColor Green
Write-Host "Failed: $failedTests" -ForegroundColor $(if ($failedTests -eq 0) { 'Green' } else { 'Red' })

if ($failedTests -gt 0) {
    Write-Host "`nSome tests failed. Check the detailed output above." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests passed!" -ForegroundColor Green
    exit 0
}
