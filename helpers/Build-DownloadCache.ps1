################################################################################
##  File:  Build-DownloadCache.ps1
##  Desc:  Pre-build phase: Extract and download all URLs from scripts and toolsets
##  Usage: .\Build-DownloadCache.ps1 [-CacheLocation "D:\BuildCache"] [-Platform "windows"]
##  Note:  Defaults to %TEMP%\RunnerImageCache. Currently supports Windows platform only.
################################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CacheLocation = (Join-Path $env:TEMP "RunnerImageCache"),
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("windows")]
    [string]$Platform = "windows",
    
    [Parameter(Mandatory = $false)]
    [string]$ToolsetVersion = $null, # Auto-detect if not specified
    
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Import required modules
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

# Platform-specific paths
$platformPath = Join-Path $repoRoot "images" $Platform
$scriptsPath = Join-Path $platformPath "scripts"
$toolsetsPath = Join-Path $platformPath "toolsets"

# Initialize cache structure
$cacheStructure = @{
    Platform    = $Platform
    GeneratedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    Downloads   = @()
    Statistics  = @{
        TotalUrls    = 0
        ToolsetUrls  = 0
        ScriptUrls   = 0
        ManifestUrls = 0
    }
}

Write-Host "=== Build Download Cache for $Platform ===" -ForegroundColor Green
Write-Host "Cache Location: $CacheLocation"
Write-Host "Platform Path: $platformPath"

# Ensure cache directory exists
if (-not $WhatIf) {
    New-Item -ItemType Directory -Path $CacheLocation -Force | Out-Null
}

#region Helper Functions

function Get-UrlHash {
    param([string]$Url)
    $hasher = [System.Security.Cryptography.MD5]::Create()
    $hash = [System.BitConverter]::ToString($hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url)))
    return $hash -replace '-', ''
}

function Add-DownloadEntry {
    param(
        [string]$Url,
        [string]$Source,
        [string]$Category,
        [string]$ExpectedSHA256 = $null,
        [string]$ExpectedSHA512 = $null,
        [hashtable]$Metadata = @{}
    )
    
    $urlHash = Get-UrlHash -Url $Url
    $fileName = Split-Path $Url -Leaf
    if (-not $fileName -or $fileName -eq '/') {
        $fileName = "download_$urlHash"
    }
    
    $entry = @{
        Url            = $Url
        UrlHash        = $urlHash
        FileName       = $fileName
        Source         = $Source
        Category       = $Category
        CachePath      = Join-Path $Category "${urlHash}_${fileName}"
        ExpectedSHA256 = $ExpectedSHA256
        ExpectedSHA512 = $ExpectedSHA512
        Metadata       = $Metadata
    }
    
    # Check for duplicates
    $existing = $cacheStructure.Downloads | Where-Object { $_.Url -eq $Url }
    if (-not $existing) {
        $cacheStructure.Downloads += $entry
        $cacheStructure.Statistics.TotalUrls++
        Write-Host "  + $Url" -ForegroundColor Cyan
    }
}

function Get-UrlsFromToolset {
    param([string]$ToolsetPath)
    
    Write-Host "Parsing toolset: $(Split-Path $ToolsetPath -Leaf)" -ForegroundColor Yellow
    
    $toolset = Get-Content $ToolsetPath | ConvertFrom-Json
    $cacheStructure.Statistics.ToolsetUrls = 0
    
    # Extract manifest URLs from toolcache entries
    if ($toolset.toolcache) {
        foreach ($tool in $toolset.toolcache) {
            if ($tool.url) {
                Add-DownloadEntry -Url $tool.url -Source "Toolset" -Category "manifests" -Metadata @{
                    ToolName     = $tool.name
                    Platform     = $tool.platform
                    Architecture = $tool.arch
                }
                $cacheStructure.Statistics.ToolsetUrls++
                $cacheStructure.Statistics.ManifestUrls++
            }
        }
    }
    
    # Add more toolset parsing logic as needed for other sections
    # TODO: Parse other sections like visualStudio, android, etc.
}

function Get-UrlsFromScript {
    param([string]$ScriptPath)
    
    $scriptName = Split-Path $ScriptPath -Leaf
    Write-Host "Parsing script: $scriptName" -ForegroundColor Yellow
    
    $content = Get-Content $ScriptPath -Raw
    
    # Regex patterns to find URLs
    $patterns = @(
        'Install-Binary\s+-Url\s+"([^"]+)"',
        'Invoke-DownloadWithRetry\s+-Url\s+"([^"]+)"',
        '\$downloadUrl\s*=\s*"([^"]+)"',
        '\$.*Url\s*=\s*"(https?://[^"]+)"',
        '"(https?://[^"]+\.(?:msi|exe|zip|tar\.gz|deb|rpm))"'
    )
    
    foreach ($pattern in $patterns) {
        $urlMatches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($match in $urlMatches) {
            $url = $match.Groups[1].Value
            if ($url -and $url.StartsWith('http')) {
                # Extract checksum if available in same context
                $checksumMatch = [regex]::Match($content, "ExpectedSHA256Sum\s+`$(\w+)|ExpectedSHA256Sum\s+""([^""]+)""")
                $checksum = if ($checksumMatch.Success) { $checksumMatch.Groups[1].Value + $checksumMatch.Groups[2].Value } else { $null }
                
                Add-DownloadEntry -Url $url -Source "Script:$scriptName" -Category "packages" -ExpectedSHA256 $checksum
                $cacheStructure.Statistics.ScriptUrls++
            }
        }
    }
}

function Invoke-CacheDownload {
    param([hashtable]$Entry)
    
    $fullCachePath = Join-Path $CacheLocation $Entry.CachePath
    $cacheDir = Split-Path $fullCachePath -Parent
    
    if (-not $WhatIf) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        
        if (Test-Path $fullCachePath) {
            Write-Host "  [CACHED] $($Entry.FileName)" -ForegroundColor Green
            return
        }
        
        try {
            Write-Host "  [DOWNLOAD] $($Entry.Url)" -ForegroundColor Cyan
            Invoke-WebRequest -Uri $Entry.Url -OutFile $fullCachePath -UseBasicParsing
            
            # Validate checksum if available
            if ($Entry.ExpectedSHA256) {
                $actualHash = (Get-FileHash $fullCachePath -Algorithm SHA256).Hash
                if ($actualHash -ne $Entry.ExpectedSHA256) {
                    throw "SHA256 mismatch for $($Entry.Url). Expected: $($Entry.ExpectedSHA256), Actual: $actualHash"
                }
                Write-Host "    ✓ SHA256 validated" -ForegroundColor Green
            }
        } catch {
            Write-Warning "Failed to download $($Entry.Url): $_"
            if (Test-Path $fullCachePath) {
                Remove-Item $fullCachePath -Force
            }
        }
    } else {
        Write-Host "  [WOULD DOWNLOAD] $($Entry.Url) -> $($Entry.CachePath)" -ForegroundColor Magenta
    }
}

#endregion

#region Main Execution

# Auto-detect toolset version if not specified
if (-not $ToolsetVersion) {
    $toolsetFiles = Get-ChildItem $toolsetsPath -Name "toolset-*.json" | Sort-Object -Descending
    if ($toolsetFiles) {
        $ToolsetVersion = ($toolsetFiles[0] -replace 'toolset-|\.json', '')
        Write-Host "Auto-detected toolset version: $ToolsetVersion"
    }
}

# Extract URLs from toolset
$toolsetFile = Join-Path $toolsetsPath "toolset-$ToolsetVersion.json"
if (Test-Path $toolsetFile) {
    Get-UrlsFromToolset -ToolsetPath $toolsetFile
} else {
    Write-Warning "Toolset file not found: $toolsetFile"
}

# Extract URLs from build scripts
$buildScriptsPath = Join-Path $scriptsPath "build"
if (Test-Path $buildScriptsPath) {
    $scriptFiles = Get-ChildItem $buildScriptsPath -Filter "*.ps1" -Recurse
    foreach ($scriptFile in $scriptFiles) {
        Get-UrlsFromScript -ScriptPath $scriptFile.FullName
    }
}

Write-Host "`n=== Download Summary ===" -ForegroundColor Green
Write-Host "Total URLs found: $($cacheStructure.Statistics.TotalUrls)"
Write-Host "  - From toolsets: $($cacheStructure.Statistics.ToolsetUrls)"
Write-Host "  - From scripts: $($cacheStructure.Statistics.ScriptUrls)"
Write-Host "  - Manifest URLs: $($cacheStructure.Statistics.ManifestUrls)"

# Save cache manifest
$manifestPath = Join-Path $CacheLocation "cache-manifest.json"
if (-not $WhatIf) {
    $cacheStructure | ConvertTo-Json -Depth 10 | Set-Content $manifestPath -Encoding UTF8
    Write-Host "Cache manifest saved: $manifestPath"
    
    # Copy helper scripts into cache for VM integration
    $helpersInCache = Join-Path $CacheLocation "helpers"
    if (-not (Test-Path $helpersInCache)) {
        New-Item -ItemType Directory -Path $helpersInCache -Force | Out-Null
    }
    
    $helperFiles = @(
        "CachedInstallHelpers.ps1",
        "Initialize-CacheEnvironment.ps1", 
        "Initialize-CacheInVM.ps1"
    )
    
    foreach ($helperFile in $helperFiles) {
        $sourcePath = Join-Path $scriptRoot $helperFile
        if (Test-Path $sourcePath) {
            $destPath = Join-Path $helpersInCache $helperFile
            Copy-Item -Path $sourcePath -Destination $destPath -Force
            Write-Host "Copied helper: $helperFile"
        }
    }
}

# Download all entries
Write-Host "`n=== Downloading Files ===" -ForegroundColor Green
foreach ($entry in $cacheStructure.Downloads) {
    Invoke-CacheDownload -Entry $entry
}

Write-Host "`n=== Cache Build Complete ===" -ForegroundColor Green

#endregion
