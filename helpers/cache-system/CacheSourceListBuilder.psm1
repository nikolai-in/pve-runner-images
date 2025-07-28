<#
.SYNOPSIS
    Builds cache source lists by matching upstream software reports with local toolset files.

.DESCRIPTION
    This module provides functionality to:
    - Parse upstream software report JSON node trees from GitHub Actions releases
    - Match with local toolset files
    - Generate source list JSON with matched tools
    - Support updating existing lists and manual editing
    - Handle real upstream data with hierarchical node structures

.EXAMPLE
    Import-Module .\CacheSourceListBuilder.psm1
    $sourceList = New-CacheSourceList -UpstreamReportUrl "https://github.com/actions/runner-images/releases/download/win25%2F20250720.1/internal.windows-2025.json" -ToolsetPaths @(".\toolset-2022.json")
#>

using namespace System.Collections.Generic

# Import required modules
$ErrorActionPreference = 'Stop'

function Get-UpstreamSoftwareReport {
    <#
    .SYNOPSIS
        Fetches upstream software report from GitHub Actions releases or local file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )
    
    try {
        Write-Verbose "Fetching upstream software report from: $Url"
        
        $fetchedAt = Get-Date
        
        # Handle local file URLs (for testing)
        if ($Url.StartsWith("file://")) {
            $filePath = $Url -replace "^file://", ""
            if (Test-Path $filePath) {
                $response = Get-Content $filePath -Raw | ConvertFrom-Json
            } else {
                throw "Local file not found: $filePath"
            }
        }
        else {
            # Fetch from HTTP/HTTPS URL
            $webResponse = Invoke-WebRequest -Uri $Url -UseBasicParsing
            $response = $webResponse.Content | ConvertFrom-Json
        }
        
        # Extract version from URL if possible
        $version = "unknown"
        if ($Url -match '([^/]+)/([^/]+\.json)$') {
            $version = $matches[1]
        }
        
        return @{
            Content = $response
            Url = $Url
            FetchedAt = $fetchedAt
            Version = $version
        }
    }
    catch {
        throw "Failed to fetch upstream software report: $($_.Exception.Message)"
    }
}

function Get-LocalToolsets {
    <#
    .SYNOPSIS
        Loads and parses local toolset files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ToolsetPaths
    )
    
    $toolsets = @()
    
    foreach ($path in $ToolsetPaths) {
        if (-not (Test-Path $path)) {
            Write-Warning "Toolset file not found: $path"
            continue
        }
        
        try {
            $content = Get-Content $path -Raw | ConvertFrom-Json
            $fileInfo = Get-Item $path
            
            $toolsets += @{
                Path = $path
                Content = $content
                LastModified = $fileInfo.LastWriteTime
            }
            
            Write-Verbose "Loaded toolset: $path"
        }
        catch {
            Write-Warning "Failed to parse toolset file $path`: $($_.Exception.Message)"
        }
    }
    
    return $toolsets
}

function Find-ToolMatches {
    <#
    .SYNOPSIS
        Matches tools between upstream report and local toolsets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$UpstreamReport,
        
        [Parameter(Mandatory = $true)]
        [array]$Toolsets
    )
    
    $toolMatches = [List[object]]::new()
    
    # Extract tools from upstream report node tree
    $upstreamTools = Get-UpstreamTools -Report $UpstreamReport.Content
    
    # Create normalized lookup from upstream tools
    $upstreamLookup = @{}
    foreach ($tool in $upstreamTools) {
        $normalizedName = $tool.Name -replace '\s+', '' -replace '[^\w\.]', '' -replace '\.+$', ''
        $normalizedName = $normalizedName.ToLowerInvariant()
        
        if (-not $upstreamLookup.ContainsKey($normalizedName)) {
            $upstreamLookup[$normalizedName] = [List[object]]::new()
        }
        $upstreamLookup[$normalizedName].Add($tool)
    }
    
    foreach ($toolset in $Toolsets) {
        if ($toolset.Content.toolcache) {
            foreach ($tool in $toolset.Content.toolcache) {
                $toolName = $tool.name
                $normalizedName = $toolName -replace '\s+', '' -replace '[^\w\.]', '' -replace '\.+$', ''
                $normalizedName = $normalizedName.ToLowerInvariant()
                
                # Try to find upstream match
                $foundUpstream = $null
                if ($upstreamLookup.ContainsKey($normalizedName)) {
                    $foundUpstream = $upstreamLookup[$normalizedName][0]  # Take first match
                }
                else {
                    # Try fuzzy matching
                    foreach ($upstreamKey in $upstreamLookup.Keys) {
                        if ($normalizedName -like "*$upstreamKey*" -or $upstreamKey -like "*$normalizedName*") {
                            $foundUpstream = $upstreamLookup[$upstreamKey][0]
                            break
                        }
                    }
                }
                
                foreach ($version in $tool.versions) {
                    $downloadUrl = Get-SuggestedDownloadUrl -ToolName $toolName -Version $version
                    
                    $toolMatches.Add(@{
                        Name = $toolName
                        Version = $version
                        Platform = $tool.platform
                        Arch = $tool.arch
                        DownloadUrl = $downloadUrl
                        Sha256 = $null  # Will be calculated on download
                        Size = $null    # Unknown until downloaded
                        MatchedFrom = @{
                            Upstream = ($null -ne $foundUpstream)
                            UpstreamVersion = if ($foundUpstream) { $foundUpstream.Version } else { $null }
                            UpstreamSource = if ($foundUpstream) { $foundUpstream.Source } else { $null }
                            Toolset = $toolset.Path
                        }
                    })
                    
                    if ($foundUpstream) {
                        Write-Verbose "Matched: $toolName $version (upstream: $($foundUpstream.Version))"
                    }
                    else {
                        Write-Verbose "Generated: $toolName $version (no upstream match)"
                    }
                }
            }
        }
    }
    
    return $toolMatches.ToArray()
}

function Get-SuggestedDownloadUrl {
    <#
    .SYNOPSIS
        Generates suggested download URLs for common tools.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName,
        
        [Parameter(Mandatory = $true)]
        [string]$Version
    )
    
    # Common download URL patterns
    $patterns = @{
        "Git" = "https://github.com/git-for-windows/git/releases/download/v$Version.windows.1/Git-$Version-64-bit.exe"
        "Node" = "https://nodejs.org/dist/v$Version/node-v$Version-x64.msi"
        "Python" = "https://www.python.org/ftp/python/$Version/python-$Version-amd64.exe"
        "Go" = "https://go.dev/dl/go$Version.windows-amd64.msi"
        "Docker" = "https://download.docker.com/win/stable/Docker%20Desktop%20Installer.exe"
        "CMake" = "https://github.com/Kitware/CMake/releases/download/v$Version/cmake-$Version-windows-x86_64.msi"
        "7zip" = "https://www.7-zip.org/a/7z$($Version -replace '\.', '')-x64.msi"
        "Packer" = "https://releases.hashicorp.com/packer/$Version/packer_$($Version)_windows_amd64.zip"
        "Gradle" = "https://services.gradle.org/distributions/gradle-$Version-bin.zip"
        "Maven" = "https://archive.apache.org/dist/maven/maven-3/$Version/binaries/apache-maven-$Version-bin.zip"
        "Ant" = "https://archive.apache.org/dist/ant/binaries/apache-ant-$Version-bin.zip"
        "jq" = "https://github.com/jqlang/jq/releases/download/jq-$Version/jq-win64.exe"
        "Ruby" = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-$Version/rubyinstaller-$Version-x64.exe"
        "PyPy" = "https://downloads.python.org/pypy/pypy$Version-win64.zip"
    }
    
    foreach ($pattern in $patterns.GetEnumerator()) {
        if ($ToolName -like "*$($pattern.Key)*") {
            return $pattern.Value
        }
    }
    
    # Return a placeholder URL if no pattern matches
    return "https://example.com/downloads/$ToolName-$Version.msi"
}

function Get-UpstreamTools {
    <#
    .SYNOPSIS
        Extracts tools from upstream software report node tree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Report
    )
    
    $tools = [List[object]]::new()
    
    # Navigate the hierarchical node structure
    function ConvertFrom-Node {
        param($Node)
        
        if (-not $Node) { return }
        
        # Handle different node types
        switch ($Node.NodeType) {
            "HeaderNode" {
                # Recursively parse children
                if ($Node.Children -is [array]) {
                    foreach ($child in $Node.Children) {
                        ConvertFrom-Node -Node $child
                    }
                }
                elseif ($Node.Children) {
                    ConvertFrom-Node -Node $Node.Children
                }
            }
            "ToolVersionNode" {
                # Extract tool name and version
                if ($Node.ToolName -and $Node.Version) {
                    $toolName = $Node.ToolName -replace ":$", ""  # Remove trailing colon
                    $version = $Node.Version
                    
                    # Skip system information and environment variables
                    if ($toolName -notmatch "^(OS Version|Image Version|Windows Subsystem|Environment variables)" -and 
                        $version -ne "Enabled" -and $version -ne "Disabled") {
                        
                        # Create a tool entry with basic info (no download URLs in this format)
                        $tools.Add(@{
                            Name = $toolName
                            Version = $version
                            Source = "upstream-installed"
                        })
                    }
                }
            }
            "ToolVersionsListNode" {
                # Handle cached tools with multiple versions
                if ($Node.ToolName -and $Node.Versions) {
                    foreach ($version in $Node.Versions) {
                        $tools.Add(@{
                            Name = $Node.ToolName
                            Version = $version
                            Source = "upstream-cached"
                        })
                    }
                }
            }
            "TableNode" {
                # Handle table data (like Java versions, shells, etc.)
                if ($Node.Headers -and $Node.Rows) {
                    foreach ($row in $Node.Rows) {
                        $rowData = $row -split '\|'
                        if ($rowData.Count -ge 2) {
                            # Try to extract tool name and version from table rows
                            $toolName = $rowData[0] -replace "<br>.*$", ""  # Remove HTML breaks
                            $version = $rowData[1] -replace "<br>.*$", ""
                            
                            if ($toolName -and $version -and $version -notmatch "^(C:\\|Stopped|Disabled)") {
                                $tools.Add(@{
                                    Name = $toolName
                                    Version = $version
                                    Source = "upstream-table"
                                })
                            }
                        }
                    }
                }
            }
        }
    }
    
    # Start parsing from the root
    ConvertFrom-Node -Node $Report
    
    Write-Verbose "Extracted $($tools.Count) tools from upstream report"
    return $tools.ToArray()
}

function Find-BestVersionMatch {
    <#
    .SYNOPSIS
        Finds the best version match for a requested version pattern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedVersion,
        
        [Parameter(Mandatory = $true)]
        [array]$AvailableVersions
    )
    
    # Simple exact match first
    $exactMatch = $AvailableVersions | Where-Object { $_.Version -eq $RequestedVersion }
    if ($exactMatch) {
        return $exactMatch
    }
    
    # Pattern matching for wildcards (e.g., "3.9.*")
    if ($RequestedVersion -like "*.*") {
        $pattern = $RequestedVersion -replace '\*', '.*'
        $patternMatch = $AvailableVersions | Where-Object { $_.Version -match "^$pattern$" } | Select-Object -First 1
        if ($patternMatch) {
            return $patternMatch
        }
    }
    
    # Semantic version matching (return latest matching major.minor)
    if ($RequestedVersion -match '^\d+\.\d+') {
        $majorMinor = $matches[0]
        $semanticMatch = $AvailableVersions | 
            Where-Object { $_.Version -like "$majorMinor.*" } | 
            Sort-Object Version -Descending | 
            Select-Object -First 1
        if ($semanticMatch) {
            return $semanticMatch
        }
    }
    
    return $null
}

function New-CacheSourceList {
    <#
    .SYNOPSIS
        Creates a new cache source list by matching upstream reports with toolsets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpstreamReportUrl,
        
        [Parameter(Mandatory = $true)]
        [string[]]$ToolsetPaths,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "cache-sources.json",
        
        [Parameter(Mandatory = $false)]
        [string]$CachePath
    )
    
    Write-Verbose "Creating new cache source list..."
    
    # Fetch upstream report
    $upstreamReport = Get-UpstreamSoftwareReport -Url $UpstreamReportUrl
    
    # Load local toolsets
    $toolsets = Get-LocalToolsets -ToolsetPaths $ToolsetPaths
    
    # Find tool matches
    $toolMatches = Find-ToolMatches -UpstreamReport $upstreamReport -Toolsets $toolsets
    
    # Create source list structure
    $sourceList = @{
        metadata = @{
            generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            upstreamReport = @{
                url = $upstreamReport.Url
                fetchedAt = $upstreamReport.FetchedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                version = $upstreamReport.Version
            }
            toolsetFiles = @(
                foreach ($toolset in $toolsets) {
                    @{
                        path = $toolset.Path
                        lastModified = $toolset.LastModified.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    }
                }
            )
        }
        sources = @(
            foreach ($match in $toolMatches) {
                @{
                    name = $match.Name
                    version = $match.Version
                    platform = $match.Platform
                    arch = $match.Arch
                    downloadUrl = $match.DownloadUrl
                    size = if ($match.Size) { $match.Size } else { 0 }
                    sha256 = if ($match.Sha256) { $match.Sha256 } else { "unknown" }
                    matchedFrom = @{
                        upstream = $match.MatchedFrom.Upstream
                        upstreamVersion = $match.MatchedFrom.UpstreamVersion
                        upstreamSource = $match.MatchedFrom.UpstreamSource
                        toolset = $match.MatchedFrom.Toolset
                    }
                }
            }
        )
    }
    
    # Save to file
    $sourceList | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8
    
    Write-Verbose "Created cache source list with $($sourceList.sources.Count) sources: $OutputPath"
    return $sourceList
}

function Update-CacheSourceList {
    <#
    .SYNOPSIS
        Updates an existing cache source list with new upstream data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceListPath,
        
        [Parameter(Mandatory = $true)]
        [string]$UpstreamReportUrl,
        
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )
    
    if (-not (Test-Path $SourceListPath)) {
        throw "Source list file not found: $SourceListPath"
    }
    
    Write-Verbose "Updating cache source list: $SourceListPath"
    
    # Load existing source list
    $existingList = Get-Content $SourceListPath -Raw | ConvertFrom-Json
    
    # Fetch new upstream report
    $upstreamReport = Get-UpstreamSoftwareReport -Url $UpstreamReportUrl
    
    # Extract toolset paths from existing metadata
    $toolsetPaths = $existingList.metadata.toolsetFiles | ForEach-Object { $_.path }
    
    # Regenerate the source list
    $newSourceList = New-CacheSourceList -UpstreamReportUrl $UpstreamReportUrl -ToolsetPaths $toolsetPaths -OutputPath ($OutputPath ?? $SourceListPath)
    
    Write-Verbose "Updated cache source list with $($newSourceList.sources.Count) sources"
    return $newSourceList
}

# Export module functions
Export-ModuleMember -Function @(
    'Get-UpstreamSoftwareReport',
    'Get-LocalToolsets', 
    'Find-ToolMatches',
    'Find-BestVersionMatch',
    'Get-UpstreamTools',
    'New-CacheSourceList',
    'Update-CacheSourceList'
)
