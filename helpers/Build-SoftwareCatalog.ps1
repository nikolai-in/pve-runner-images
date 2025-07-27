#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Software Catalog Builder v2 - Fire-once upstream scraper
    
.DESCRIPTION
    A proper approach to cache analysis that builds an authoritative catalog
    by scraping ALL software report JSONs from the upstream GitHub repo.
    
    This creates a comprehensive database that can be manually populated
    with additional sources (package managers, etc.) and updated when 
    upstream adds new software.
    
    Finally, someone who understands the difference between data and noise.
    
.PARAMETER Platform
    Target platform to analyze (windows, ubuntu, macos, all)
    
.PARAMETER OutputFile
    Where to save the comprehensive software catalog
    
.PARAMETER IncludeAllReleases
    Scrape multiple releases to get comprehensive version history
    
.PARAMETER Force
    Overwrite existing catalog without whining
#>

[CmdletBinding()]
param(
    [ValidateSet("windows", "ubuntu", "macos", "all")]
    [string]$Platform = "all",
    
    [string]$OutputFile = "software-catalog.json",
    
    [switch]$IncludeAllReleases,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# GLaDOS commentary system - because corporate speak is for test subjects
function Write-CatalogLog {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Sarcasm")]
        [string]$Type = "Info"
    )
    
    $prefix = switch ($Type) {
        "Info"     { "[INFO]" }
        "Success"  { "[PASS]" }
        "Warning"  { "[WARN]" }
        "Error"    { "[FAIL]" }
        "Sarcasm"  { "[GLADOS]" }
    }
    
    $color = switch ($Type) {
        "Info"     { "Cyan" }
        "Success"  { "Green" }
        "Warning"  { "Yellow" }
        "Error"    { "Red" }
        "Sarcasm"  { "Magenta" }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# Comprehensive software catalog structure
class SoftwareEntry {
    [string]$Name
    [string]$Version
    [string]$Platform
    [string]$Category
    [string]$UpstreamSource        # Which JSON report this came from
    [string]$UpstreamReleaseTag    # GitHub release tag
    [datetime]$UpstreamDate        # When this report was published
    [hashtable]$VersionHistory     # Multiple versions seen across releases
    [string[]]$KnownSources        # Where this software can be downloaded
    [hashtable]$PackageManagers    # Package manager sources (manually populated)
    [hashtable]$DirectUrls         # Direct download URLs (manually populated)
    [hashtable]$Metadata           # Additional context
    [bool]$RequiresManualMapping   # Needs human intervention for source mapping
    
    SoftwareEntry() {
        $this.VersionHistory = @{}
        $this.KnownSources = @()
        $this.PackageManagers = @{}
        $this.DirectUrls = @{}
        $this.Metadata = @{}
        $this.RequiresManualMapping = $true
    }
}

class SoftwareCatalog {
    [string]$GeneratedAt
    [string]$UpstreamRepository
    [int]$TotalSoftware
    [int]$WindowsSoftware
    [int]$UbuntuSoftware
    [int]$MacOSSoftware
    [int]$ReleasesAnalyzed
    [SoftwareEntry[]]$Software
    [hashtable]$Statistics
    [string[]]$AnalyzedReleases    # GitHub release tags that were processed
    
    SoftwareCatalog() {
        $this.Software = @()
        $this.Statistics = @{}
        $this.AnalyzedReleases = @()
        $this.GeneratedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $this.UpstreamRepository = "https://github.com/actions/runner-images"
    }
}

#region GitHub Repository Analysis

function Get-GitHubReleases {
    param(
        [string]$Owner = "actions",
        [string]$Repo = "runner-images",
        [int]$MaxReleases = 10
    )
    
    Write-CatalogLog "Fetching GitHub releases from $Owner/$Repo..." "Info"
    
    try {
        $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases"
        $headers = @{
            'Accept' = 'application/vnd.github.v3+json'
            'User-Agent' = 'GLaDOS-Software-Catalog-Builder/1.0'
        }
        
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 60
        
        if ($IncludeAllReleases) {
            $targetReleases = $releases | Select-Object -First $MaxReleases
        } else {
            # Get latest release for each platform
            $targetReleases = @()
            $platforms = @("win25", "win22", "win19", "ubuntu24", "ubuntu22", "ubuntu20", "macos-15", "macos-14", "macos-13")
            
            foreach ($platform in $platforms) {
                $latestForPlatform = $releases | Where-Object { $_.tag_name -like "*$platform*" } | Select-Object -First 1
                if ($latestForPlatform) {
                    $targetReleases += $latestForPlatform
                }
            }
        }
        
        Write-CatalogLog "Found $($targetReleases.Count) releases to analyze" "Success"
        return $targetReleases
    }
    catch {
        Write-CatalogLog "Failed to fetch GitHub releases: $_" "Error"
        throw
    }
}

function Get-SoftwareReportsFromRelease {
    param([object]$Release)
    
    Write-CatalogLog "Analyzing release: $($Release.tag_name)" "Info"
    
    $softwareReports = @()
    
    # Look for internal JSON files in release assets
    $jsonAssets = $Release.assets | Where-Object { 
        $_.name -match "internal\.(windows|ubuntu|macos).*\.json$" 
    }
    
    foreach ($asset in $jsonAssets) {
        Write-CatalogLog "  Downloading: $($asset.name)" "Info"
        
        try {
            $reportData = Invoke-RestMethod -Uri $asset.browser_download_url -TimeoutSec 120
            
            # Extract platform from filename
            $platform = if ($asset.name -match "windows") { "windows" }
                        elseif ($asset.name -match "ubuntu") { "ubuntu" }
                        elseif ($asset.name -match "macos") { "macos" }
                        else { "unknown" }
            
            $softwareReports += @{
                Platform = $platform
                ReleaseTag = $Release.tag_name
                ReleaseDate = [datetime]$Release.published_at
                AssetName = $asset.name
                Data = $reportData
            }
            
            Write-CatalogLog "    ✅ Loaded $platform report" "Success"
        }
        catch {
            Write-CatalogLog "    ❌ Failed to load $($asset.name): $_" "Warning"
        }
    }
    
    return $softwareReports
}

#endregion

#region Software Catalog Building

function Build-ComprehensiveCatalog {
    param([array]$SoftwareReports)
    
    Write-CatalogLog "Building comprehensive software catalog..." "Info"
    
    $catalog = [SoftwareCatalog]::new()
    $softwareMap = @{}  # To deduplicate and merge versions
    
    foreach ($report in $SoftwareReports) {
        Write-CatalogLog "Processing $($report.Platform) report from $($report.ReleaseTag)..." "Info"
        
        $catalog.AnalyzedReleases += $report.ReleaseTag
        
        # Extract software from the report data
        $extractedSoftware = Get-SoftwareFromReport -Report $report
        
        foreach ($software in $extractedSoftware) {
            $key = "$($software.Name)|$($software.Platform)"
            
            if ($softwareMap.ContainsKey($key)) {
                # Merge with existing entry
                $existing = $softwareMap[$key]
                
                # Add version to history
                if (-not $existing.VersionHistory.ContainsKey($software.Version)) {
                    $existing.VersionHistory[$software.Version] = @{
                        ReleaseTag = $report.ReleaseTag
                        ReleaseDate = $report.ReleaseDate
                        Category = $software.Category
                    }
                }
                
                # Update to latest version if this is newer
                if ($report.ReleaseDate -gt $existing.UpstreamDate) {
                    $existing.Version = $software.Version
                    $existing.UpstreamDate = $report.ReleaseDate
                    $existing.UpstreamReleaseTag = $report.ReleaseTag
                }
            }
            else {
                # New software entry
                $software.VersionHistory[$software.Version] = @{
                    ReleaseTag = $report.ReleaseTag
                    ReleaseDate = $report.ReleaseDate
                    Category = $software.Category
                }
                $softwareMap[$key] = $software
            }
        }
    }
    
    # Convert map to array and populate catalog
    $catalog.Software = $softwareMap.Values
    
    # Calculate statistics
    $catalog.TotalSoftware = $catalog.Software.Count
    $catalog.WindowsSoftware = ($catalog.Software | Where-Object { $_.Platform -eq "windows" }).Count
    $catalog.UbuntuSoftware = ($catalog.Software | Where-Object { $_.Platform -eq "ubuntu" }).Count
    $catalog.MacOSSoftware = ($catalog.Software | Where-Object { $_.Platform -eq "macos" }).Count
    $catalog.ReleasesAnalyzed = $catalog.AnalyzedReleases.Count
    
    # Generate category statistics
    $categoryStats = $catalog.Software | Group-Object Category | ForEach-Object {
        @{ $_.Name = $_.Count }
    }
    $catalog.Statistics["Categories"] = $categoryStats
    
    # Generate platform statistics
    $platformStats = $catalog.Software | Group-Object Platform | ForEach-Object {
        @{ $_.Name = $_.Count }
    }
    $catalog.Statistics["Platforms"] = $platformStats
    
    Write-CatalogLog "Catalog complete: $($catalog.TotalSoftware) unique software packages" "Success"
    return $catalog
}

function Get-SoftwareFromReport {
    param([object]$Report)
    
    if (-not $Report.Data) {
        Write-CatalogLog "No data in report" "Warning"
        return @()
    }
    
    # The JSON structure is hierarchical with NodeType-based navigation
    Write-CatalogLog "  Parsing hierarchical node structure..." "Info"
    $extractedSoftware = Get-SoftwareFromNodeTree -Node $Report.Data -Report $Report
    
    Write-CatalogLog "  Extracted $($extractedSoftware.Count) software entries" "Info"
    return $extractedSoftware
}

function Get-SoftwareFromNodeTree {
    param(
        [object]$Node,
        [object]$Report,
        [string]$CategoryPath = ""
    )
    
    $software = @()
    
    if (-not $Node) { return $software }
    
    # Handle different node types
    switch ($Node.NodeType) {
        "HeaderNode" {
            # This is a category header, recurse into children
            $newCategoryPath = if ($CategoryPath) { "$CategoryPath.$($Node.Title)" } else { $Node.Title }
            
            if ($Node.Children -is [array]) {
                foreach ($child in $Node.Children) {
                    $software += Get-SoftwareFromNodeTree -Node $child -Report $Report -CategoryPath $newCategoryPath
                }
            }
        }
        
        "ToolVersionNode" {
            # This is actual software! Extract it
            $entry = New-SoftwareEntry -Item $Node -Category $CategoryPath -Report $Report
            if ($entry) {
                $software += $entry
            }
        }
        
        "TableNode" {
            # Tables might contain software lists, recurse into rows
            if ($Node.Headers -and $Node.Rows) {
                foreach ($row in $Node.Rows) {
                    if ($row -is [array] -and $row.Count -ge 2) {
                        # Treat table rows as name/version pairs
                        $tableItem = [PSCustomObject]@{
                            ToolName = $row[0]
                            Version = $row[1]
                            NodeType = "ToolVersionNode"
                        }
                        $entry = New-SoftwareEntry -Item $tableItem -Category $CategoryPath -Report $Report
                        if ($entry) {
                            $software += $entry
                        }
                    }
                }
            }
        }
        
        "ListNode" {
            # Lists might contain software, recurse into items
            if ($Node.Items -is [array]) {
                foreach ($item in $Node.Items) {
                    $software += Get-SoftwareFromNodeTree -Node $item -Report $Report -CategoryPath $CategoryPath
                }
            }
        }
        
        Default {
            # Unknown node type, but might have children
            if ($Node.Children -is [array]) {
                foreach ($child in $Node.Children) {
                    $software += Get-SoftwareFromNodeTree -Node $child -Report $Report -CategoryPath $CategoryPath
                }
            }
        }
    }
    
    return $software
}

function New-SoftwareEntry {
    param(
        [object]$Item,
        [string]$Category,
        [object]$Report
    )
    
    if (-not $Item) { return $null }
    
    $software = [SoftwareEntry]::new()
    $software.Platform = $Report.Platform
    $software.Category = $Category
    $software.UpstreamSource = $Report.AssetName
    $software.UpstreamReleaseTag = $Report.ReleaseTag
    $software.UpstreamDate = $Report.ReleaseDate
    
    # Handle ToolVersionNode structure specifically
    if ($Item.NodeType -eq "ToolVersionNode" -and $Item.ToolName -and $Item.Version) {
        $software.Name = $Item.ToolName -replace ':$', ''  # Remove trailing colon
        $software.Version = $Item.Version
        
        # Capture node metadata
        $software.Metadata["NodeType"] = $Item.NodeType
        if ($Item.Note) {
            $software.Metadata["Note"] = $Item.Note
        }
    }
    else {
        # Fallback parsing for other structures
        if ($Item -is [string]) {
            # Simple string format like "Node.js 18.19.0"
            if ($Item -match "^([^0-9]+)\s+(.+)$") {
                $software.Name = $Matches[1].Trim()
                $software.Version = $Matches[2].Trim()
            } else {
                $software.Name = $Item
                $software.Version = "Unknown"
            }
        }
        elseif ($Item.name -and $Item.version) {
            # Structured object
            $software.Name = $Item.name
            $software.Version = $Item.version
            
            # Capture additional metadata
            foreach ($prop in $Item.PSObject.Properties) {
                if ($prop.Name -notin @("name", "version")) {
                    $software.Metadata[$prop.Name] = $prop.Value
                }
            }
        }
        elseif ($Item.Name) {
            # PowerShell object with Name property
            $software.Name = $Item.Name
            $software.Version = if ($Item.Version) { $Item.Version } else { "Unknown" }
        }
        else {
            # Try to extract from string representation
            $itemStr = $Item.ToString()
            if ($itemStr -match "^([^0-9]+)\s+(.+)$") {
                $software.Name = $Matches[1].Trim()
                $software.Version = $Matches[2].Trim()
            } else {
                $software.Name = $itemStr
                $software.Version = "Unknown"
            }
        }
    }
    
    # Clean up the name
    $software.Name = $software.Name -replace "^\s+|\s+$", ""
    
    if ([string]::IsNullOrWhiteSpace($software.Name)) {
        return $null
    }
    
    # Skip obvious non-software entries
    if ($software.Name -match "^(OS Version|Image Version|Kernel Version|Build|Total|Available)") {
        return $null
    }
    
    return $software
}

#endregion

#region Manual Source Population Templates

function Add-ManualSourceTemplates {
    param([SoftwareCatalog]$Catalog)
    
    Write-CatalogLog "Adding manual source population templates..." "Info"
    
    # Add common package manager patterns
    foreach ($software in $Catalog.Software) {
        $name = $software.Name.ToLower()
        
        # Add package manager templates based on platform and software name
        switch ($software.Platform) {
            "windows" {
                # Chocolatey packages
                if ($name -in @("git", "nodejs", "python", "golang", "docker", "kubernetes-cli", "terraform", "packer")) {
                    $software.PackageManagers["chocolatey"] = "https://community.chocolatey.org/api/v2/package/$name"
                }
                
                # NuGet packages for .NET tools
                if ($name -match "(dotnet|nuget|msbuild|visual-studio)") {
                    $software.PackageManagers["nuget"] = "https://api.nuget.org/v3-flatcontainer/$name/"
                }
                
                # MSI/EXE direct downloads
                $software.DirectUrls["official_installer"] = "# TODO: Add official installer URL"
            }
            
            "ubuntu" {
                # APT packages
                $software.PackageManagers["apt"] = "apt install $name"
                
                # Snap packages
                if ($name -in @("docker", "kubectl", "terraform", "packer", "code")) {
                    $software.PackageManagers["snap"] = "snap install $name"
                }
                
                # PPA repositories
                $software.PackageManagers["ppa"] = "# TODO: Add PPA if needed"
            }
            
            "macos" {
                # Homebrew
                $software.PackageManagers["homebrew"] = "brew install $name"
                
                # MacPorts
                $software.PackageManagers["macports"] = "port install $name"
                
                # Direct DMG/PKG
                $software.DirectUrls["official_installer"] = "# TODO: Add official installer URL"
            }
        }
        
        # Add GitHub releases pattern if it looks like a GitHub project
        if ($software.Metadata["homepage"] -match "github.com/([^/]+)/([^/]+)") {
            $owner = $Matches[1]
            $repo = $Matches[2]
            $software.DirectUrls["github_releases"] = "https://github.com/$owner/$repo/releases/latest"
        }
        
        # Mark as requiring manual review
        $software.RequiresManualMapping = $true
    }
    
    Write-CatalogLog "Added source templates for manual population" "Success"
}

#endregion

#region Main Execution

Write-CatalogLog "Software Catalog Builder initializing..." "Info"
Write-CatalogLog "Building comprehensive software catalog from upstream sources." "Sarcasm"

# Check if output file exists and handle Force parameter
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputPath = if ([System.IO.Path]::IsPathRooted($OutputFile)) { $OutputFile } else { Join-Path $scriptRoot $OutputFile }

if ((Test-Path $outputPath) -and -not $Force) {
    Write-CatalogLog "Output file already exists: $outputPath" "Warning"
    Write-CatalogLog "Use -Force to overwrite, or specify a different -OutputFile" "Info"
    exit 1
}

try {
    # Step 1: Get GitHub releases
    $releases = Get-GitHubReleases
    
    # Step 2: Download and parse software reports
    $allReports = @()
    foreach ($release in $releases) {
        $reports = Get-SoftwareReportsFromRelease -Release $release
        $allReports += $reports
    }
    
    if ($allReports.Count -eq 0) {
        Write-CatalogLog "No software reports found. This is... disappointing." "Error"
        exit 1
    }
    
    # Step 3: Build comprehensive catalog
    $catalog = Build-ComprehensiveCatalog -SoftwareReports $allReports
    
    # Step 4: Add manual source templates
    Add-ManualSourceTemplates -Catalog $catalog
    
    # Step 5: Save catalog
    Write-CatalogLog "Saving catalog to: $outputPath" "Info"
    $catalog | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
    
    # Step 6: Generate summary
    Write-CatalogLog "`n=== Software Catalog Generated ===" "Success"
    Write-CatalogLog "Output: $outputPath" "Info"
    Write-CatalogLog "Total Software: $($catalog.TotalSoftware)" "Info"
    Write-CatalogLog "  Windows: $($catalog.WindowsSoftware)" "Info"
    Write-CatalogLog "  Ubuntu: $($catalog.UbuntuSoftware)" "Info"
    Write-CatalogLog "  macOS: $($catalog.MacOSSoftware)" "Info"
    Write-CatalogLog "Releases Analyzed: $($catalog.ReleasesAnalyzed)" "Info"
    Write-CatalogLog "`nNow you can manually populate the package manager sources" "Info"
    Write-CatalogLog "and use this as the authoritative source for cache analysis." "Success"
    
}
catch {
    Write-CatalogLog "Catalog building failed: $_" "Error"
    Write-CatalogLog "Even with proper architecture, you managed to break it. Impressive." "Sarcasm"
    throw
}

Write-CatalogLog "Software catalog generation complete. Try not to break it." "Success"

#endregion
