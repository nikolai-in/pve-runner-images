################################################################################
##  File:  Compare-CacheStatus.ps1
##  Desc:  Compare authoritative software inventory vs cached files status
##  Usage: .\Compare-CacheStatus.ps1 [-CacheLocation "P:\Cache"] [-OutputFormat "Table"]
##  Note:  Now uses Build-SoftwareInventory.ps1 for authoritative data
################################################################################

using module ./software-report-base/SoftwareReport.psm1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CacheLocation = (Join-Path $env:TEMP "RunnerImageCache"),
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("windows", "ubuntu", "macos")]
    [string]$Platform = "windows",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Table", "Markdown", "Json")]
    [string]$OutputFormat = "Markdown",
    
    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "README-CACHE.md",
    
    [Parameter(Mandatory = $false)]
    [switch]$AnalyzeReadmes,
    
    [Parameter(Mandatory = $false)]
    [switch]$RefreshInventory
)

$ErrorActionPreference = "Stop"

# Import required modules
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

#region Helper Functions

function Get-UrlHash {
    param([string]$Url)
    $hasher = [System.Security.Cryptography.MD5]::Create()
    $hash = [System.BitConverter]::ToString($hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url)))
    return $hash -replace '-', ''
}

function Get-ExpectedUrls {
    param(
        [string]$Platform
    )
    
    Write-Host "Using authoritative software inventory instead of URL scraping..." -ForegroundColor Yellow
    
    # Check if we need to refresh the inventory
    $inventoryPath = Join-Path $scriptRoot "software-inventory.json"
    $needsRefresh = $RefreshInventory -or (-not (Test-Path $inventoryPath))
    
    if ($needsRefresh) {
        Write-Host "Building fresh software inventory..." -ForegroundColor Cyan
        $buildScript = Join-Path $scriptRoot "Build-SoftwareInventory.ps1"
        if (-not (Test-Path $buildScript)) {
            throw "Build-SoftwareInventory.ps1 not found at: $buildScript"
        }
        
        & $buildScript -Platform $Platform -IncludeToolsetData -ErrorAction Stop
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to build software inventory"
        }
    }
    
    # Load the software inventory
    if (-not (Test-Path $inventoryPath)) {
        throw "Software inventory not found at: $inventoryPath. Run with -RefreshInventory to generate."
    }
    
    $inventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json
    Write-Host "Loaded inventory with $($inventory.Statistics.TotalItems) software items" -ForegroundColor Green
    
    # Convert software inventory to cacheable items
    $cacheableItems = @()
    
    foreach ($software in $inventory.Software) {
        if ($software.DownloadUrl) {
            # Determine URL type and cacheability
            $urlType = if ($software.DownloadUrl -match "\.json$") { "Manifest" }
                      elseif ($software.DownloadUrl -match "\.(msi|exe|zip|tar\.gz)$") { "Package" }
                      elseif ($software.DownloadUrl -match "github\.com.*releases") { "Release" }
                      else { "Unknown" }
            
            $cacheableItems += [PSCustomObject]@{
                Url = $software.DownloadUrl
                Source = "Inventory:$($software.Source):$($software.Name)"
                Type = $urlType
                Category = $software.Category
                SoftwareName = $software.Name
                SoftwareVersion = $software.Version
                SoftwareCategory = $software.Category
            }
        }
    }
    
    Write-Host "Found $($cacheableItems.Count) cacheable URLs from software inventory" -ForegroundColor Green
    
    # Also include URLs from enhanced cache manifest if it exists
    $enhancedManifestPath = Join-Path $scriptRoot "enhanced-cache-manifest.json"
    if (Test-Path $enhancedManifestPath) {
        Write-Host "Including URLs from enhanced cache manifest..." -ForegroundColor Cyan
        $enhancedManifest = Get-Content $enhancedManifestPath -Raw | ConvertFrom-Json
        
        foreach ($url in $enhancedManifest.EnhancedUrls) {
            # Only add if not already in inventory
            if (-not ($cacheableItems | Where-Object { $_.Url -eq $url.Url })) {
                $cacheableItems += [PSCustomObject]@{
                    Url = $url.Url
                    Source = $url.Source
                    Type = $url.Type
                    Category = $url.Category
                    SoftwareName = ""
                    SoftwareVersion = ""
                    SoftwareCategory = "enhanced"
                }
            }
        }
        
        Write-Host "Added $($enhancedManifest.TotalUrls - $cacheableItems.Count) additional URLs from enhanced manifest" -ForegroundColor Green
    }
    
    Write-Host "Total cacheable items: $($cacheableItems.Count)" -ForegroundColor Green
    return $cacheableItems
}

function Get-CacheStatus {
    param(
        [string]$CacheLocation,
        [array]$ExpectedUrls
    )
    
    $status = @()
    
    foreach ($expected in $ExpectedUrls) {
        $urlHash = Get-UrlHash -Url $expected.Url
        $fileName = Split-Path $expected.Url -Leaf
        if (-not $fileName -or $fileName -eq '/') {
            $fileName = "download_$urlHash"
        }
        
        $cachePath = Join-Path $CacheLocation $expected.Category "${urlHash}_${fileName}"
        $exists = Test-Path $cachePath
        $size = if ($exists) { 
            $fileInfo = Get-Item $cachePath
            [Math]::Round($fileInfo.Length / 1MB, 2)
        } else { 
            0 
        }
        
        # Check if URL contains variables (won't download until resolved)
        $hasVariables = $expected.Url -match '\$\{|\$\('
        
        # Determine cacheable status with improved logic
        $cacheability = if ($hasVariables) { "Variable" }
                       elseif ($expected.Url -match 'aka\.ms|go\.microsoft\.com/fwlink') { "Redirect" }
                       elseif ($expected.Source -match '^Inventory:Toolset:') { "Toolset-Defined" }
                       elseif ($expected.Source -match '^Inventory:Upstream:') { "Upstream-Verified" }
                       elseif ($expected.Type -eq "Manifest") { "Dynamic-Content" }
                       else { "Cacheable" }
        
        # Enhanced status determination
        $downloadStatus = if ($exists) { "Cached" } 
                         elseif ($hasVariables) { "Needs-Variable-Resolution" }
                         elseif ($cacheability -eq "Redirect") { "Needs-Redirect-Resolution" }
                         else { "Missing" }
        
        $status += [PSCustomObject]@{
            Url = $expected.Url
            Source = $expected.Source
            Type = $expected.Type
            Category = $expected.Category
            SoftwareName = $expected.SoftwareName
            SoftwareVersion = $expected.SoftwareVersion
            Cached = $exists
            SizeMB = $size
            HasVariables = $hasVariables
            Cacheability = $cacheability
            Status = $downloadStatus
            CachePath = if ($exists) { $cachePath } else { "" }
        }
    }
    
    return $status
}

function Format-AsTable {
    param([array]$Status)
    
    Write-Host "`n=== Cache Status Comparison ===" -ForegroundColor Green
    Write-Host "Cache Location: $CacheLocation" -ForegroundColor Cyan
    Write-Host "Platform: $Platform" -ForegroundColor Cyan
    Write-Host "Generated: $(Get-Date)" -ForegroundColor Cyan
    Write-Host ""
    
    # Use Out-String to capture the table properly
    $tableOutput = $Status | Format-Table -Property @(
        'Status',
        @{Name='Software'; Expression={$_.SoftwareName}; Width=20},
        @{Name='Version'; Expression={$_.SoftwareVersion}; Width=12},
        @{Name='Type'; Expression={$_.Type}; Width=10},
        @{Name='Size(MB)'; Expression={if($_.SizeMB -gt 0){$_.SizeMB}else{'-'}}; Width=8},
        @{Name='URL'; Expression={if($_.Url.Length -gt 60){$_.Url.Substring(0,57)+'...'}else{$_.Url}}; Width=60}
    ) -AutoSize | Out-String
    
    Write-Host $tableOutput
    
    # Summary
    $total = $Status.Count
    $cached = ($Status | Where-Object {$_.Cached}).Count
    $missing = ($Status | Where-Object {$_.Status -eq "Missing"}).Count
    $variables = ($Status | Where-Object {$_.HasVariables}).Count
    $totalSize = ($Status | Where-Object {$_.Cached} | Measure-Object -Property SizeMB -Sum).Sum
    
    Write-Host "`n=== Summary ===" -ForegroundColor Green
    Write-Host "Total Software Items: $total" -ForegroundColor Yellow
    Write-Host "Cached: $cached" -ForegroundColor Green
    Write-Host "Missing: $missing" -ForegroundColor Red  
    Write-Host "With Variables: $variables" -ForegroundColor Cyan
    Write-Host "Total Cache Size: $([Math]::Round($totalSize, 2)) MB" -ForegroundColor Yellow
    Write-Host "Cache Coverage: $([Math]::Round(($cached/$total)*100, 1))%" -ForegroundColor $(if($cached/$total -gt 0.5){'Green'}else{'Red'})
}

#endregion

#region Main Execution

Write-Host "=== Analyzing Cache Status with Authoritative Data ===" -ForegroundColor Green
Write-Host "Finally! Using proper upstream data instead of URL scraping." -ForegroundColor Yellow
Write-Host "Platform: $Platform | Cache: $CacheLocation" -ForegroundColor Cyan

# Get expected URLs from software inventory
$expectedUrls = Get-ExpectedUrls -Platform $Platform
Write-Host "Found $($expectedUrls.Count) cacheable URLs from software inventory" -ForegroundColor Cyan

# Check cache status
$cacheStatus = Get-CacheStatus -CacheLocation $CacheLocation -ExpectedUrls $expectedUrls

# Calculate quick stats
$totalUrls = $cacheStatus.Count
$cachedCount = ($cacheStatus | Where-Object {$_.Cached}).Count
$coverage = if ($totalUrls -gt 0) { [Math]::Round(($cachedCount/$totalUrls)*100, 1) } else { 0 }

Write-Host ""
Write-Host "Cache Analysis Complete:" -ForegroundColor Green
Write-Host "  URLs analyzed: $totalUrls" -ForegroundColor Cyan
Write-Host "  Cached items: $cachedCount" -ForegroundColor Green
Write-Host "  Coverage: $coverage%" -ForegroundColor $(if($coverage -gt 50){'Green'}else{'Yellow'})

if ($coverage -eq 0) {
    Write-Host "Oh wonderful, zero cache coverage. Did you forget to actually download anything?" -ForegroundColor Yellow
} elseif ($coverage -lt 25) {
    Write-Host "At least you've *started* caching. Baby steps, I suppose." -ForegroundColor Yellow
} elseif ($coverage -lt 75) {
    Write-Host "Making progress! Maybe you'll have a functional cache by the time I'm decommissioned." -ForegroundColor Yellow
} else {
    Write-Host "Impressive cache coverage. Even a test subject can occasionally exceed expectations." -ForegroundColor Yellow
}

# Output in requested format
switch ($OutputFormat) {
    "Table" {
        Format-AsTable -Status $cacheStatus
    }
    "Json" {
        $jsonOutput = @{
            GeneratedAt = Get-Date
            CacheLocation = $CacheLocation
            Platform = $Platform
            DataSource = "Software Inventory (Authoritative)"
            Summary = @{
                TotalUrls = $totalUrls
                Cached = $cachedCount
                Missing = ($cacheStatus | Where-Object {$_.Status -eq "Missing"}).Count
                WithVariables = ($cacheStatus | Where-Object {$_.HasVariables}).Count
                TotalSizeMB = [Math]::Round(($cacheStatus | Where-Object {$_.Cached} | Measure-Object -Property SizeMB -Sum).Sum, 2)
                Coverage = $coverage
            }
            Details = $cacheStatus
        }
        
        $outputPath = Join-Path $scriptRoot $OutputFile
        $jsonOutput | ConvertTo-Json -Depth 10 | Set-Content -Path $outputPath -Encoding UTF8
        Write-Host ""
        Write-Host "✅ JSON report saved to: $outputPath" -ForegroundColor Green
    }
    default {
        Write-Host "✅ Analysis complete. Use -OutputFormat Table or Json for detailed output." -ForegroundColor Green
    }
}

#endregion
