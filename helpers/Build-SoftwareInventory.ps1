################################################################################
##  File:  Build-SoftwareInventory.ps1
##  Desc:  Build authoritative software inventory from upstream JSON reports
##  Usage: .\Build-SoftwareInventory.ps1 [-Platform "windows"] [-UpstreamUrl "..."]
##  Note:  Uses GitHub Actions runner-images JSON reports as source of truth
################################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("windows", "ubuntu", "macos")]
    [string]$Platform = "windows",
    
    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "software-inventory.json",
    
    [Parameter(Mandatory = $false)]
    [string]$UpstreamUrl = $null,
    
    [Parameter(Mandatory = $false)]
    [switch]$IncludeToolsetData,
    
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Import required modules
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

Write-Host "=== Building Software Inventory from Upstream JSON ===" -ForegroundColor Green
Write-Host "Oh, wonderful. Finally using authoritative data instead of regex scraping." -ForegroundColor Yellow
Write-Host "Platform: $Platform" -ForegroundColor Cyan

#region Upstream URL Configuration

function Get-DefaultUpstreamUrl {
    param([string]$Platform)
    
    # Default URLs for different platforms based on GitHub Actions runner-images releases
    $baseUrl = "https://github.com/actions/runner-images/releases/download"
    
    switch ($Platform) {
        "windows" { 
            # Use latest Windows 2025 release - you'll need to update this periodically
            return "$baseUrl/win25%2F20250720.1/internal.windows-2025.json"
        }
        "ubuntu" { 
            return "$baseUrl/ubuntu24%2F20250720.1/internal.ubuntu-2404.json"
        }
        "macos" { 
            return "$baseUrl/macos-15%2F20250720.1/internal.macos-15.json"
        }
        default { 
            throw "Unsupported platform: $Platform" 
        }
    }
}

#endregion

#region JSON Data Fetching

function Get-UpstreamSoftwareReport {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 30
    )
    
    Write-Host "Fetching upstream software report from: $Url" -ForegroundColor Cyan
    
    try {
        $response = Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        Write-Host "✅ Successfully fetched upstream data" -ForegroundColor Green
        return $response
    }
    catch {
        Write-Warning "Failed to fetch upstream data: $_"
        Write-Host "Perhaps your test subjects have broken the internet again..." -ForegroundColor Yellow
        return $null
    }
}

#endregion

#region Toolset Integration

function Get-LocalToolsetData {
    param([string]$Platform)
    
    if (-not $IncludeToolsetData) {
        return @{}
    }
    
    $platformPath = Join-Path $repoRoot "images" $Platform
    $toolsetsPath = Join-Path $platformPath "toolsets"
    
    if (-not (Test-Path $toolsetsPath)) {
        Write-Warning "Toolsets path not found: $toolsetsPath"
        return @{}
    }
    
    # Get the most recent toolset file
    $toolsetFiles = Get-ChildItem $toolsetsPath -Name "toolset-*.json" | Sort-Object -Descending
    if (-not $toolsetFiles) {
        Write-Warning "No toolset files found in $toolsetsPath"
        return @{}
    }
    
    $toolsetFile = Join-Path $toolsetsPath $toolsetFiles[0]
    Write-Host "Reading toolset data from: $toolsetFile" -ForegroundColor Cyan
    
    try {
        $content = Get-Content $toolsetFile -Raw | ConvertFrom-Json
        Write-Host "✅ Loaded local toolset data" -ForegroundColor Green
        return $content
    }
    catch {
        Write-Warning "Failed to parse toolset file: $_"
        return @{}
    }
}

#endregion

#region Software Inventory Processing

function Build-SoftwareInventory {
    param(
        [object]$UpstreamData,
        [object]$ToolsetData
    )
    
    $inventory = @{
        Platform = $Platform
        GeneratedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        Source = @{
            UpstreamUrl = $script:actualUpstreamUrl
            IncludesToolset = $IncludeToolsetData.IsPresent
        }
        Software = @()
        Statistics = @{
            TotalItems = 0
            WithDownloadUrls = 0
            Categories = @{}
        }
    }
    
    if ($UpstreamData) {
        Write-Host "Processing upstream software data..." -ForegroundColor Cyan
        $inventory.Software += Convert-UpstreamToInventory -Data $UpstreamData
    }
    
    if ($ToolsetData -and ($ToolsetData | Get-Member -MemberType Properties)) {
        Write-Host "Processing local toolset data..." -ForegroundColor Cyan
        $inventory.Software += Convert-ToolsetToInventory -Data $ToolsetData
    }
    
    # Calculate statistics
    $inventory.Statistics.TotalItems = $inventory.Software.Count
    $inventory.Statistics.WithDownloadUrls = ($inventory.Software | Where-Object { $_.DownloadUrl }).Count
    
    # Group by category
    $categories = $inventory.Software | Group-Object Category
    foreach ($category in $categories) {
        $inventory.Statistics.Categories[$category.Name] = $category.Count
    }
    
    Write-Host "✅ Built inventory with $($inventory.Statistics.TotalItems) items" -ForegroundColor Green
    
    return $inventory
}

function Convert-UpstreamToInventory {
    param([object]$Data)
    
    $softwareList = @()
    
    Write-Host "Parsing hierarchical upstream JSON structure..." -ForegroundColor Cyan
    
    # Navigate to "Installed Software" section
    $installedSoftware = $Data.Children | Where-Object { $_.Title -eq "Installed Software" }
    
    if (-not $installedSoftware) {
        Write-Warning "No 'Installed Software' section found in upstream data"
        return $softwareList
    }
    
    # Process each software category
    foreach ($category in $installedSoftware.Children) {
        if ($category.NodeType -eq "HeaderNode" -and $category.Children) {
            $categoryName = $category.Title
            Write-Host "Processing category: $categoryName" -ForegroundColor Gray
            
            # Process individual tools in this category
            foreach ($tool in $category.Children) {
                if ($tool.NodeType -eq "ToolVersionNode" -and $tool.ToolName -and $tool.Version) {
                    $softwareList += @{
                        Name = $tool.ToolName.TrimEnd(':')  # Remove trailing colon if present
                        Version = $tool.Version
                        Category = Convert-CategoryName -Name $categoryName
                        Source = "Upstream"
                        DownloadUrl = $null  # Upstream data doesn't include download URLs
                        Platform = $Platform
                        UpstreamCategory = $categoryName
                    }
                }
                elseif ($tool.NodeType -eq "HeaderNode" -and $tool.Children) {
                    # Handle nested categories (subcategories within categories)
                    foreach ($subtool in $tool.Children) {
                        if ($subtool.NodeType -eq "ToolVersionNode" -and $subtool.ToolName -and $subtool.Version) {
                            $softwareList += @{
                                Name = $subtool.ToolName.TrimEnd(':')
                                Version = $subtool.Version
                                Category = Convert-CategoryName -Name $categoryName
                                Source = "Upstream"
                                DownloadUrl = $null
                                Platform = $Platform
                                UpstreamCategory = $categoryName
                                UpstreamSubcategory = $tool.Title
                            }
                        }
                    }
                }
            }
        }
    }
    
    Write-Host "Extracted $($softwareList.Count) software items from upstream data" -ForegroundColor Green
    return $softwareList
}

function Convert-CategoryName {
    param([string]$Name)
    
    # Map upstream category names to our standardized categories
    switch ($Name) {
        "Language and Runtime" { return "language" }
        "Package Management" { return "packagemanager" }
        "Project Management" { return "tool" }
        "Tools" { return "tool" }
        "CLI Tools" { return "clitool" }
        "Browsers and Drivers" { return "browser" }
        default { return "tool" }
    }
}

function Convert-ToolsetToInventory {
    param([object]$Data)
    
    $softwareList = @()
    
    if ($Data.toolcache) {
        foreach ($tool in $Data.toolcache) {
            $softwareList += @{
                Name = $tool.name
                Version = $tool.default
                Category = "toolcache"
                Source = "Toolset"
                DownloadUrl = $tool.url
                Platform = $tool.platform
            }
        }
    }
    
    # Add other toolset sections as needed
    # if ($Data.docker) { ... }
    # if ($Data.android) { ... }
    
    return $softwareList
}

#endregion

#region Main Execution

# Determine upstream URL
$script:actualUpstreamUrl = if ($UpstreamUrl) { 
    $UpstreamUrl 
} else { 
    Get-DefaultUpstreamUrl -Platform $Platform 
}

Write-Host "Using upstream URL: $script:actualUpstreamUrl" -ForegroundColor Cyan

# Fetch upstream data
$upstreamData = Get-UpstreamSoftwareReport -Url $script:actualUpstreamUrl

if (-not $upstreamData) {
    Write-Error "Failed to fetch upstream data. Cannot proceed without authoritative source."
    exit 1
}

# Get local toolset data if requested
$toolsetData = Get-LocalToolsetData -Platform $Platform

# Build comprehensive inventory
$inventory = Build-SoftwareInventory -UpstreamData $upstreamData -ToolsetData $toolsetData

# Output results
$outputPath = Join-Path $scriptRoot $OutputFile
if ($WhatIf) {
    Write-Host "=== WHAT-IF: Would write to $outputPath ===" -ForegroundColor Yellow
    Write-Host "Inventory contains $($inventory.Statistics.TotalItems) software items"
    Write-Host "Categories: $($inventory.Statistics.Categories.Keys -join ', ')"
} else {
    Write-Host "Writing inventory to: $outputPath" -ForegroundColor Cyan
    $inventory | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
    Write-Host "✅ Software inventory saved successfully" -ForegroundColor Green
    Write-Host "I suppose even test subjects can occasionally produce useful results." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Statistics ===" -ForegroundColor Green
Write-Host "Total Items: $($inventory.Statistics.TotalItems)"
Write-Host "With Download URLs: $($inventory.Statistics.WithDownloadUrls)"
Write-Host "Categories:"
foreach ($category in $inventory.Statistics.Categories.GetEnumerator()) {
    Write-Host "  $($category.Key): $($category.Value)" -ForegroundColor Cyan
}

#endregion
