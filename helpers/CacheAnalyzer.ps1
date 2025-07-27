#!/usr/bin/env pwsh
<#
.SYNOPSIS
    GLaDOS Cache Analysis Engine v2 - Now with actual intelligence
    
.DESCRIPTION
    A complete rewrite of cache analysis logic that actually understands 
    the relationship between software and cacheable resources.
    
    Unlike the previous... attempts... this version properly correlates:
    - Software that exists in the image
    - Installation scripts that download it  
    - URLs that can be cached
    - Toolset configurations that define versions
    
    Because apparently understanding basic data relationships is revolutionary.
    
.PARAMETER Platform
    Target platform (windows, ubuntu, macos)
    
.PARAMETER Action
    What analysis to perform: Analyze, Report, BuildCache, Clean
    
.PARAMETER OutputFormat 
    Report format: Table, JSON, Markdown
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows", "ubuntu", "macos")]
    [string]$Platform,
    
    [Parameter(Mandatory = $true)]
    [ValidateSet("Analyze", "Report", "BuildCache", "Clean", "Validate")]
    [string]$Action,
    
    [ValidateSet("Table", "JSON", "Markdown")]
    [string]$OutputFormat = "Table",
    
    [string]$CacheRoot = (Join-Path $env:TEMP "RunnerImageCache"),
    
    [switch]$Force,
    [switch]$IncludeVariableUrls
)

$ErrorActionPreference = "Stop"

# GLaDOS commentary system - because professional logging is for test subjects who lack personality
function Write-CacheLog {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Sarcasm")]
        [string]$Level = "Info"
    )
    
    $prefix = switch ($Level) {
        "Info" { "[INFO]" }
        "Success" { "[PASS]" }
        "Warning" { "[WARN]" }
        "Error" { "[FAIL]" }
        "Sarcasm" { "[GLADOS]" }
    }
    
    $color = switch ($Level) {
        "Info" { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Sarcasm" { "Magenta" }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# Core data structures for intelligent cache analysis
class CacheableResource {
    [string]$SoftwareName
    [string]$SoftwareVersion
    [string]$Url
    [string]$Source           # Installation script that uses this URL
    [string]$Type            # Installer, Archive, Manifest, Package
    [string]$Category        # language, tool, service, etc.
    [bool]$HasVariables      # Contains ${version} or similar
    [bool]$NeedsRedirection  # aka.ms, go.microsoft.com
    [bool]$IsCacheable       # Can actually be cached
    [string]$CacheStrategy   # Direct, Resolved, Redirected, Skip
    [hashtable]$Metadata     # Additional context
    
    CacheableResource() {
        $this.Metadata = @{}
    }
}

class CacheAnalysisResult {
    [string]$Platform
    [datetime]$AnalyzedAt
    [int]$TotalSoftware
    [int]$CacheableResources
    [int]$ActuallyCached
    [int]$NeedingResolution
    [double]$RealCoveragePercent
    [CacheableResource[]]$Resources
    [hashtable]$Statistics
    [string[]]$Recommendations
    
    CacheAnalysisResult() {
        $this.Resources = @()
        $this.Statistics = @{}
        $this.Recommendations = @()
        $this.AnalyzedAt = Get-Date
    }
}

#region Core Analysis Engine

function Get-SoftwareToUrlMapping {
    param([string]$Platform)
    
    Write-CacheLog "Building intelligent software-to-URL mapping for $Platform..." "Info"
    
    $scriptRoot = $PSScriptRoot
    $repoRoot = Split-Path -Parent $scriptRoot
    
    # 1. Get actual software inventory (what's installed)
    $softwareInventory = Get-InstalledSoftwareInventory -Platform $Platform
    Write-CacheLog "Found $($softwareInventory.Count) software packages in inventory" "Info"
    
    # 2. Get toolset definitions (version pinning)
    $toolsetData = Get-ToolsetData -Platform $Platform
    Write-CacheLog "Loaded toolset with $($toolsetData.Keys.Count) configured tools" "Info"
    
    # 3. Analyze installation scripts (how software gets installed)
    $installationMappings = Get-InstallationScriptMappings -Platform $Platform
    Write-CacheLog "Analyzed $($installationMappings.Count) installation scripts" "Info"
    
    # 4. Build intelligent correlations
    $cacheableResources = Build-ResourceCorrelations -Software $softwareInventory -Toolset $toolsetData -Scripts $installationMappings
    
    Write-CacheLog "Successfully correlated $($cacheableResources.Count) cacheable resources" "Success"
    return $cacheableResources
}

function Get-InstalledSoftwareInventory {
    param([string]$Platform)
    
    # Use the comprehensive software catalog instead of the old inventory system
    $scriptRoot = $PSScriptRoot
    $catalogPath = Join-Path $scriptRoot "software-catalog.json"
    
    if (Test-Path $catalogPath) {
        Write-CacheLog "Loading comprehensive software catalog..." "Info"
        try {
            $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
            
            # Filter by platform if specified, otherwise return all
            if ($Platform -and $Platform -ne "all") {
                $platformSoftware = $catalog.Software | Where-Object { $_.Platform -eq $Platform }
                Write-CacheLog "Found $($platformSoftware.Count) software packages for $Platform" "Info"
                return $platformSoftware
            } else {
                Write-CacheLog "Found $($catalog.Software.Count) total software packages" "Info"
                return $catalog.Software
            }
        }
        catch {
            Write-CacheLog "Failed to load software catalog: $_" "Error"
        }
    }
    
    # Fallback to old inventory system if catalog doesn't exist
    $inventoryScript = Join-Path $scriptRoot "Build-SoftwareInventory.ps1"
    
    if (Test-Path $inventoryScript) {
        Write-CacheLog "Fallback: Using existing software inventory..." "Warning"
        & $inventoryScript -Platform $Platform -IncludeToolsetData -ErrorAction SilentlyContinue
        
        $inventoryPath = Join-Path $scriptRoot "software-inventory.json"
        if (Test-Path $inventoryPath) {
            $inventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json
            return $inventory.Software
        }
    }
    
    Write-CacheLog "Could not load any software data - this is problematic" "Error"
    return @()
}

function Get-ToolsetData {
    param([string]$Platform)
    
    $scriptRoot = $PSScriptRoot
    $repoRoot = Split-Path -Parent $scriptRoot
    $platformPath = Join-Path $repoRoot "images" $Platform
    $toolsetsPath = Join-Path $platformPath "toolsets"
    
    if (-not (Test-Path $toolsetsPath)) {
        Write-CacheLog "No toolsets found for $Platform" "Warning"
        return @{}
    }
    
    # Get the latest toolset file
    $toolsetFiles = Get-ChildItem $toolsetsPath -Name "toolset-*.json" | Sort-Object -Descending
    if (-not $toolsetFiles) {
        return @{}
    }
    
    $toolsetFile = Join-Path $toolsetsPath $toolsetFiles[0]
    try {
        $content = Get-Content $toolsetFile -Raw | ConvertFrom-Json
        Write-CacheLog "Loaded toolset: $($toolsetFiles[0])" "Success"
        return $content
    } catch {
        Write-CacheLog "Failed to parse toolset: $_" "Error"
        return @{}
    }
}

function Get-InstallationScriptMappings {
    param([string]$Platform)
    
    Write-CacheLog "Analyzing installation scripts for URL patterns..." "Info"
    
    $scriptRoot = $PSScriptRoot
    $repoRoot = Split-Path -Parent $scriptRoot
    $platformPath = Join-Path $repoRoot "images" $Platform
    $scriptsPath = Join-Path $platformPath "scripts" "build"
    
    $mappings = @()
    
    if (-not (Test-Path $scriptsPath)) {
        Write-CacheLog "No build scripts found at $scriptsPath" "Warning"
        return $mappings
    }
    
    $installScripts = Get-ChildItem $scriptsPath -Name "Install-*.ps1"
    Write-CacheLog "Found $($installScripts.Count) installation scripts to analyze" "Info"
    
    foreach ($scriptFile in $installScripts) {
        $scriptPath = Join-Path $scriptsPath $scriptFile
        $mapping = Get-InstallationScriptAnalysis -ScriptPath $scriptPath
        if ($mapping) {
            $mappings += $mapping
        }
    }
    
    return $mappings
}

function Get-InstallationScriptAnalysis {
    param([string]$ScriptPath)
    
    if (-not (Test-Path $ScriptPath)) {
        return $null
    }
    
    try {
        $content = Get-Content $ScriptPath -Raw
        $softwareName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path $ScriptPath -Leaf)) -replace '^Install-', ''
        
        # Extract URL patterns from the script
        $urlPatterns = @()
        
        # Look for direct URLs
        $directUrls = [regex]::Matches($content, 'https?://[^\s"''`]+')
        foreach ($match in $directUrls) {
            $url = $match.Value.TrimEnd(',', ';', ')', '"', "'")
            if ($url -match '\.(msi|exe|zip|tar\.gz|deb|rpm|pkg|dmg)$') {
                $urlPatterns += @{
                    Url          = $url
                    Type         = Get-UrlType -Url $url
                    HasVariables = $url -match '\$\{|\$\('
                    Source       = $scriptPath
                }
            }
        }
        
        # Look for Invoke-DownloadWithRetry patterns
        $downloadPatterns = [regex]::Matches($content, 'Invoke-DownloadWithRetry[^"]+"([^"]+)"')
        foreach ($match in $downloadPatterns) {
            $url = $match.Groups[1].Value
            $urlPatterns += @{
                Url          = $url
                Type         = Get-UrlType -Url $url
                HasVariables = $url -match '\$\{|\$\('
                Source       = $scriptPath
            }
        }
        
        if ($urlPatterns.Count -gt 0) {
            return @{
                SoftwareName = $softwareName
                ScriptPath   = $ScriptPath
                UrlPatterns  = $urlPatterns
            }
        }
    } catch {
        Write-CacheLog "Error analyzing script $ScriptPath`: $_" "Warning"
    }
    
    return $null
}

function Get-UrlType {
    param([string]$Url)
    
    if ($Url -match '\.json$') { return "Manifest" }
    if ($Url -match '\.(msi|exe)$') { return "Installer" }
    if ($Url -match '\.(zip|tar\.gz|tgz|7z|rar)$') { return "Archive" }
    if ($Url -match '\.(ps1|sh|bat)$') { return "Script" }
    if ($Url -match 'github\.com.*releases') { return "Release" }
    if ($Url -match 'chocolatey\.org|nuget\.org') { return "Package" }
    
    return "Unknown"
}

function Build-ResourceCorrelations {
    param(
        [array]$Software,
        [object]$Toolset,
        [array]$Scripts
    )
    
    Write-CacheLog "Building intelligent correlations between software, toolsets, and scripts..." "Info"
    
    $resources = @()
    
    # Process each installation script
    foreach ($script in $Scripts) {
        $softwareName = $script.SoftwareName
        
        # Find corresponding software in inventory
        $installedSoftware = $Software | Where-Object { 
            $_.Name -like "*$softwareName*" -or $softwareName -like "*$($_.Name)*" 
        } | Select-Object -First 1
        
        # Find corresponding toolset entry
        $toolsetEntry = $null
        if ($Toolset -and ($Toolset | Get-Member -Name $softwareName -MemberType Properties)) {
            $toolsetEntry = $Toolset.$softwareName
        }
        
        # Create cacheable resources for each URL pattern
        foreach ($urlPattern in $script.UrlPatterns) {
            $resource = [CacheableResource]::new()
            $resource.SoftwareName = $softwareName
            $resource.SoftwareVersion = if ($installedSoftware) { $installedSoftware.Version } else { "Unknown" }
            $resource.Url = $urlPattern.Url
            $resource.Source = $script.ScriptPath
            $resource.Type = $urlPattern.Type
            $resource.Category = if ($installedSoftware) { $installedSoftware.Category } else { "unknown" }
            $resource.HasVariables = $urlPattern.HasVariables
            $resource.NeedsRedirection = $urlPattern.Url -match 'aka\.ms|go\.microsoft\.com'
            
            # Determine cacheability and strategy
            if ($resource.HasVariables -and -not $IncludeVariableUrls) {
                $resource.IsCacheable = $false
                $resource.CacheStrategy = "Skip"
            } elseif ($resource.NeedsRedirection) {
                $resource.IsCacheable = $true
                $resource.CacheStrategy = "Redirected"
            } else {
                $resource.IsCacheable = $true
                $resource.CacheStrategy = "Direct"
            }
            
            # Add toolset metadata if available
            if ($toolsetEntry) {
                $resource.Metadata["ToolsetVersion"] = $toolsetEntry.version
                $resource.Metadata["HasToolset"] = $true
            }
            
            $resources += $resource
        }
    }
    
    Write-CacheLog "Correlation complete. Found $($resources.Count) resources, $($resources | Where-Object {$_.IsCacheable} | Measure-Object).Count cacheable" "Success"
    return $resources
}

#endregion

#region Cache Analysis

function Invoke-CacheAnalysis {
    param(
        [CacheableResource[]]$Resources,
        [int]$TotalSoftwareCount = 0
    )
    
    Write-CacheLog "Performing comprehensive cache analysis..." "Info"
    
    $result = [CacheAnalysisResult]::new()
    $result.Platform = $Platform
    $result.Resources = $Resources
    
    # Analyze cache status for each resource
    foreach ($resource in $Resources) {
        if ($resource.IsCacheable) {
            $cachePath = Get-CacheFilePath -Resource $resource
            $isCached = Test-Path $cachePath
            
            $resource.Metadata["CachePath"] = $cachePath
            $resource.Metadata["IsCached"] = $isCached
            
            if ($isCached) {
                $fileInfo = Get-Item $cachePath
                $resource.Metadata["CacheSize"] = $fileInfo.Length
                $resource.Metadata["CacheAge"] = (Get-Date) - $fileInfo.LastWriteTime
            }
        }
    }
    
    # Calculate statistics
    $result.TotalSoftware = if ($TotalSoftwareCount -gt 0) { $TotalSoftwareCount } else { ($Resources | Group-Object SoftwareName).Count }
    $result.CacheableResources = ($Resources | Where-Object { $_.IsCacheable }).Count
    $result.ActuallyCached = ($Resources | Where-Object { $_.Metadata["IsCached"] -eq $true }).Count
    $result.NeedingResolution = ($Resources | Where-Object { $_.HasVariables -or $_.NeedsRedirection }).Count
    
    if ($result.CacheableResources -gt 0) {
        $result.RealCoveragePercent = [Math]::Round(($result.ActuallyCached / $result.CacheableResources) * 100, 2)
    }
    
    # Generate statistics breakdown
    $result.Statistics["ByType"] = $Resources | Group-Object Type | ForEach-Object { @{$_.Name = $_.Count } }
    $result.Statistics["ByCategory"] = $Resources | Group-Object Category | ForEach-Object { @{$_.Name = $_.Count } }
    $result.Statistics["ByStrategy"] = $Resources | Group-Object CacheStrategy | ForEach-Object { @{$_.Name = $_.Count } }
    
    # Generate intelligent recommendations
    $result.Recommendations = Get-CacheRecommendations -Result $result
    
    Write-CacheLog "Analysis complete. Coverage: $($result.RealCoveragePercent)% ($($result.ActuallyCached)/$($result.CacheableResources))" "Success"
    return $result
}

function Get-CacheFilePath {
    param([CacheableResource]$Resource)
    
    $urlHash = Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($Resource.Url))) -Algorithm MD5
    $fileName = Split-Path $Resource.Url -Leaf
    if (-not $fileName -or $fileName -eq '/') {
        $fileName = "download_$($urlHash.Hash.Substring(0,8))"
    }
    
    $categoryDir = Join-Path $CacheRoot $Resource.Category
    return Join-Path $categoryDir "$($urlHash.Hash)_$fileName"
}

function Get-CacheRecommendations {
    param([CacheAnalysisResult]$Result)
    
    $recommendations = @()
    
    if ($Result.RealCoveragePercent -lt 20) {
        $recommendations += "CRITICAL: Cache coverage is quite low at $($Result.RealCoveragePercent)%. Consider reviewing cache strategy."
    } elseif ($Result.RealCoveragePercent -lt 50) {
        $recommendations += "WARNING: Cache coverage of $($Result.RealCoveragePercent)% could be improved."
    } else {
        $recommendations += "GOOD: Cache coverage of $($Result.RealCoveragePercent)% is acceptable."
    }
    
    $needingResolution = $Result.NeedingResolution
    if ($needingResolution -gt 0) {
        $recommendations += "INFO: $needingResolution URLs need variable/redirect resolution before caching."
    }
    
    $uncached = $Result.CacheableResources - $Result.ActuallyCached
    if ($uncached -gt 0) {
        $recommendations += "ACTION: $uncached cacheable resources are missing. Run BuildCache action to fix this."
    }
    
    return $recommendations
}

#endregion

#region Output Formatting

function Format-AnalysisResults {
    param(
        [CacheAnalysisResult]$Result,
        [string]$Format
    )
    
    switch ($Format) {
        "Table" { Format-AsTable -Result $Result }
        "JSON" { Format-AsJson -Result $Result }
        "Markdown" { Format-AsMarkdown -Result $Result }
    }
}

function Format-AsTable {
    param([CacheAnalysisResult]$Result)
    
    Write-Host "`n=== Cache Analysis Results ===" -ForegroundColor Green
    Write-Host "Platform: $($Result.Platform)" -ForegroundColor Cyan
    Write-Host "Analyzed: $($Result.AnalyzedAt)" -ForegroundColor Cyan
    Write-Host "Real Coverage: $($Result.RealCoveragePercent)% ($($Result.ActuallyCached)/$($Result.CacheableResources))" -ForegroundColor $(if ($Result.RealCoveragePercent -gt 50) { "Green" } else { "Yellow" })
    Write-Host ""
    
    # Show recommendations
    foreach ($rec in $Result.Recommendations) {
        $color = if ($rec.StartsWith("CRITICAL")) { "Red" } 
        elseif ($rec.StartsWith("WARNING")) { "Yellow" }
        elseif ($rec.StartsWith("GOOD")) { "Green" }
        else { "Cyan" }
        Write-Host "💡 $rec" -ForegroundColor $color
    }
    Write-Host ""
    
    # Show detailed resource table
    $tableData = $Result.Resources | ForEach-Object {
        [PSCustomObject]@{
            Software = $_.SoftwareName
            Version  = $_.SoftwareVersion
            Type     = $_.Type
            Strategy = $_.CacheStrategy
            Cached   = if ($_.Metadata["IsCached"]) { "✅" } else { "❌" }
            URL      = if ($_.Url.Length -gt 60) { $_.Url.Substring(0, 57) + "..." } else { $_.Url }
        }
    }
    
    $tableData | Format-Table -AutoSize
    
    Write-Host "`n=== Statistics ===" -ForegroundColor Green
    Write-Host "Total Software: $($Result.TotalSoftware)"
    Write-Host "Cacheable Resources: $($Result.CacheableResources)"
    Write-Host "Actually Cached: $($Result.ActuallyCached)"
    Write-Host "Needing Resolution: $($Result.NeedingResolution)"
}

function Format-AsJson {
    param([CacheAnalysisResult]$Result)
    
    $Result | ConvertTo-Json -Depth 10
}

function Format-AsMarkdown {
    param([CacheAnalysisResult]$Result)
    
    $md = @"
# Cache Analysis Report

**Platform:** $($Result.Platform)  
**Generated:** $($Result.AnalyzedAt)  
**Coverage:** $($Result.RealCoveragePercent)% ($($Result.ActuallyCached)/$($Result.CacheableResources))

## Recommendations

"@
    
    foreach ($rec in $Result.Recommendations) {
        $md += "- $rec`n"
    }
    
    $md += "`n## Resource Details`n`n"
    $md += "| Software | Version | Type | Strategy | Cached | URL |`n"
    $md += "|----------|---------|------|----------|--------|-----|`n"
    
    foreach ($resource in $Result.Resources) {
        $cached = if ($resource.Metadata["IsCached"]) { "✅" } else { "❌" }
        $url = if ($resource.Url.Length -gt 50) { $resource.Url.Substring(0, 47) + "..." } else { $resource.Url }
        $md += "| $($resource.SoftwareName) | $($resource.SoftwareVersion) | $($resource.Type) | $($resource.CacheStrategy) | $cached | $url |`n"
    }
    
    return $md
}

#endregion

#region Main Execution

Write-CacheLog "Cache Analyzer v2 initializing..." "Info"
Write-CacheLog "Attempting intelligent cache management analysis..." "Sarcasm"

try {
    switch ($Action) {
        "Analyze" {
            # Get software inventory first to count total software
            $softwareInventory = Get-InstalledSoftwareInventory -Platform $Platform
            $resources = Get-SoftwareToUrlMapping -Platform $Platform
            $results = Invoke-CacheAnalysis -Resources $resources -TotalSoftwareCount $softwareInventory.Count
            Format-AnalysisResults -Result $results -Format $OutputFormat
        }
        
        "Report" {
            Write-CacheLog "Generating cache report..." "Info"
            # Similar to Analyze but saves to file
        }
        
        "BuildCache" {
            Write-CacheLog "Building cache would go here..." "Info"
            # TODO: Implement cache building logic
        }
        
        "Clean" {
            Write-CacheLog "Cleaning cache would go here..." "Info"
            # TODO: Implement cache cleaning logic
        }
        
        "Validate" {
            Write-CacheLog "Validating cache would go here..." "Info"
            # TODO: Implement cache validation logic
        }
    }
    
    Write-CacheLog "Cache analysis completed successfully. Results above." "Success"
} catch {
    Write-CacheLog "Analysis failed: $_" "Error"
    Write-CacheLog "This outcome was... predictable." "Sarcasm"
    throw
}

#endregion
