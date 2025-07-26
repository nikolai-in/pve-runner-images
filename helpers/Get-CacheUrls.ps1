################################################################################
##  File:  Enhance-CacheDiscovery.ps1
##  Desc:  Intelligent URL discovery - resolve variables, follow redirects, map software
##  Usage: .\Enhance-CacheDiscovery.ps1 [-Platform "windows"]
##  Note:  Enhances cache system with smarter URL discovery
################################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("windows")]
    [string]$Platform = "windows"
)

$ErrorActionPreference = "Stop"

# Import required modules
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

#region Smart URL Discovery Functions

function Get-ToolsetVariables {
    param([string]$Platform)
    
    $platformPath = Join-Path $repoRoot "images" $Platform
    $toolsetsPath = Join-Path $platformPath "toolsets"
    
    $toolsetFiles = Get-ChildItem $toolsetsPath -Name "toolset-*.json" | Sort-Object -Descending
    if (-not $toolsetFiles) { return @{} }
    
    $toolsetFile = Join-Path $toolsetsPath $toolsetFiles[0]
    $toolset = Get-Content $toolsetFile | ConvertFrom-Json
    
    $variables = @{}
    
    # Extract version variables from toolset
    if ($toolset.node -and $toolset.node.default) {
        $variables['nodeVersion'] = $toolset.node.default
    }
    
    if ($toolset.go -and $toolset.go.default) {
        $variables['goVersion'] = $toolset.go.default
    }
    
    if ($toolset.python -and $toolset.python.default) {
        $variables['pythonVersion'] = $toolset.python.default
    }
    
    # Add more variables as needed
    $variables['latestVersion'] = 'latest'
    $variables['composeVersion'] = '2.24.5'  # Example
    $variables['ghver'] = '0.99.0'  # Example
    
    Write-Verbose "Extracted variables: $($variables.Keys -join ', ')"
    return $variables
}

function Resolve-VariableUrls {
    param(
        [array]$Urls,
        [hashtable]$Variables
    )
    
    $resolvedUrls = [System.Collections.ArrayList]::new()
    
    foreach ($urlInfo in $Urls) {
        $originalUrl = $urlInfo.Url
        $resolvedUrl = $originalUrl
        
        # Replace common variable patterns
        foreach ($varName in $Variables.Keys) {
            $varValue = $Variables[$varName]
            
            # Replace ${varName} pattern
            $resolvedUrl = $resolvedUrl -replace [regex]::Escape("`${$varName}"), $varValue
            
            # Replace $varName pattern  
            $resolvedUrl = $resolvedUrl -replace [regex]::Escape("`$$varName"), $varValue
            
            # Replace $(varName) pattern
            $resolvedUrl = $resolvedUrl -replace [regex]::Escape("`$($varName)"), $varValue
        }
        
        # If URL was resolved, add both original and resolved
        if ($resolvedUrl -ne $originalUrl) {
            # Add original with Variable cacheability
            $null = $resolvedUrls.Add($urlInfo)
            
            # Add resolved version
            $resolvedInfo = $urlInfo.Clone()
            $resolvedInfo.Url = $resolvedUrl
            $resolvedInfo.Source = $urlInfo.Source + " (resolved)"
            $resolvedInfo.Cacheability = "Resolved"
            $null = $resolvedUrls.Add($resolvedInfo)
            
            Write-Verbose "Resolved: $originalUrl -> $resolvedUrl"
        } else {
            $null = $resolvedUrls.Add($urlInfo)
        }
    }
    
    return $resolvedUrls.ToArray()
}

function Test-UrlRedirect {
    param([string]$Url)
    
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 0 -ErrorAction SilentlyContinue
        if ($response.StatusCode -in @(301, 302, 303, 307, 308)) {
            $redirectUrl = $response.Headers.Location
            if ($redirectUrl) {
                Write-Verbose "Redirect found: $Url -> $redirectUrl"
                return $redirectUrl
            }
        }
    }
    catch {
        Write-Verbose "Could not check redirect for: $Url"
    }
    
    return $null
}

function Get-KnownSoftwareUrls {
    param([string]$Platform)
    
    # Known software download patterns based on common tools
    $knownUrls = @()
    
    # GitHub releases pattern
    $githubTools = @(
        @{ Tool = "docker-compose"; Repo = "docker/compose"; Pattern = "docker-compose-windows-x86_64.exe" },
        @{ Tool = "helm"; Repo = "helm/helm"; Pattern = "helm-*-windows-amd64.zip" },
        @{ Tool = "kubectl"; Repo = "kubernetes/kubernetes"; Pattern = "kubernetes-client-windows-amd64.tar.gz" },
        @{ Tool = "terraform"; Repo = "hashicorp/terraform"; Pattern = "terraform_*_windows_amd64.zip" },
        @{ Tool = "packer"; Repo = "hashicorp/packer"; Pattern = "packer_*_windows_amd64.zip" },
        @{ Tool = "gh"; Repo = "cli/cli"; Pattern = "gh_*_windows_amd64.zip" }
    )
    
    foreach ($tool in $githubTools) {
        $knownUrls += @{
            Url = "https://github.com/$($tool.Repo)/releases/latest/download/$($tool.Pattern)"
            Source = "KnownSoftware:$($tool.Tool)"
            Category = "packages"
            Type = if ($tool.Pattern -match '\.exe$') { "Installer" } else { "Archive" }
            Cacheability = "GitHub-Latest"
        }
    }
    
    # Direct download URLs for common tools
    $directUrls = @(
        @{
            Url = "https://download.docker.com/win/static/stable/x86_64/docker-20.10.21.zip"
            Source = "KnownSoftware:docker"
            Category = "packages"
            Type = "Archive"
            Cacheability = "Direct"
        },
        @{
            Url = "https://nodejs.org/dist/v20.10.0/node-v20.10.0-x64.msi"
            Source = "KnownSoftware:nodejs-lts"
            Category = "packages" 
            Type = "Installer"
            Cacheability = "Direct"
        },
        @{
            Url = "https://www.python.org/ftp/python/3.11.7/python-3.11.7-amd64.exe"
            Source = "KnownSoftware:python"
            Category = "packages"
            Type = "Installer" 
            Cacheability = "Direct"
        }
    )
    
    $knownUrls += $directUrls
    
    Write-Verbose "Generated $($knownUrls.Count) known software URLs"
    return $knownUrls
}

function Get-PackageManagerUrls {
    param([string]$Platform)
    
    $packageUrls = @()
    
    # Chocolatey packages (can be pre-downloaded)
    $chocoPackages = @("git", "nodejs", "python", "golang", "docker-desktop", "kubernetes-cli", "terraform", "packer")
    
    foreach ($package in $chocoPackages) {
        $packageUrls += @{
            Url = "https://community.chocolatey.org/api/v2/package/$package"
            Source = "PackageManager:chocolatey.$package"
            Category = "packages"
            Type = "Package"
            Cacheability = "PackageManager"
        }
    }
    
    # NuGet packages
    $nugetPackages = @("Microsoft.Web.WebJobs.Publish", "Microsoft.VisualStudio.Web.CodeGeneration.Tools")
    
    foreach ($package in $nugetPackages) {
        $packageUrls += @{
            Url = "https://api.nuget.org/v3-flatcontainer/$($package.ToLower())/index.json"
            Source = "PackageManager:nuget.$package"
            Category = "packages"
            Type = "Package"
            Cacheability = "PackageManager"
        }
    }
    
    Write-Verbose "Generated $($packageUrls.Count) package manager URLs"
    return $packageUrls
}

function Get-BaseUrlsFromSources {
    param([string]$Platform)
    
    $platformPath = Join-Path $repoRoot "images" $Platform
    $scriptsPath = Join-Path $platformPath "scripts"
    $toolsetsPath = Join-Path $platformPath "toolsets"
    
    $expectedUrls = [System.Collections.ArrayList]::new()
    
    # Get from toolset JSON - focus on items with actual URLs
    $toolsetFiles = Get-ChildItem $toolsetsPath -Name "toolset-*.json" | Sort-Object -Descending
    if ($toolsetFiles) {
        $toolsetVersion = ($toolsetFiles[0] -replace 'toolset-|\.json', '')
        $toolsetFile = Join-Path $toolsetsPath "toolset-$toolsetVersion.json"
        
        if (Test-Path $toolsetFile) {
            Write-Verbose "Parsing toolset file: $toolsetFile"
            $toolset = Get-Content $toolsetFile | ConvertFrom-Json
            
            # Parse toolcache section (contains manifest URLs)
            if ($toolset.toolcache) {
                foreach ($tool in $toolset.toolcache) {
                    if ($tool.url) {
                        $null = $expectedUrls.Add(@{
                            Url = $tool.url
                            Source = "Toolset:toolcache.$($tool.name)"
                            Category = "manifests"
                            Type = "Manifest"
                        })
                    }
                }
            }
        }
    }
    
    # Get from scripts - this is where the actual downloadable URLs are
    $buildScriptsPath = Join-Path $scriptsPath "build"
    if (Test-Path $buildScriptsPath) {
        $scriptFiles = Get-ChildItem $buildScriptsPath -Filter "*.ps1" -Recurse
        
        # Enhanced patterns to catch more URL types including common helper functions
        $patterns = @(
            # Standard download functions
            'Install-Binary\s+-Url\s+"([^"]+)"',
            'Invoke-DownloadWithRetry\s+[^"]*"([^"]+)"',
            'Download-WithRetry\s+-Url\s+"([^"]+)"',
            'Get-ToolsetContent\)\.([^.]+)\.url',
            
            # Variable assignments with URLs
            '\$[^=]*[Uu]rl[^=]*=\s*"(https?://[^"]+)"',
            '\$downloadUrl\s*=\s*"([^"]+)"',
            '\$bootstrapperUrl\s*=\s*"([^"]+)"',
            '\$.*[Bb]ase[Uu]rl[^=]*=\s*"([^"]+)"',
            
            # Direct URL patterns in strings
            '"(https?://[^"]+\.(?:msi|exe|zip|tar\.gz|tgz|deb|rpm|jar|vsix))"',
            "'(https?://[^']+\.(?:msi|exe|zip|tar\.gz|tgz|deb|rpm|jar|vsix))'",
            
            # Web request patterns
            'Invoke-WebRequest[^"]*"(https?://[^"]+)"',
            'curl[^"]*"(https?://[^"]+)"',
            'wget[^"]*"(https?://[^"]+)"',
            
            # Install patterns with URL concatenation
            '-Url\s+"([^"$]+)[^"]*"',
            '-Url\s+\$\{[^}]+\}[^"]*"([^"]+)"',
            
            # GitHub and other common patterns
            'github\.com/[^/]+/[^/]+/releases/download/[^"]+',
            'aka\.ms/[^"]+',
            'download\.microsoft\.com/[^"]+',
            'static\.rust-lang\.org/[^"]+',
            'nodejs\.org/dist/[^"]+',
            'downloads\.haskell\.org/[^"]+',
            'fastdl\.mongodb\.org/[^"]+',
            'get\.enterprisedb\.com/[^"]+',
            'cdn\.mysql\.com/[^"]+',
            's3\.amazonaws\.com/[^"]+',
            'cloudbase\.it/downloads/[^"]+'
        )
        
        foreach ($scriptFile in $scriptFiles) {
            $content = Get-Content $scriptFile.FullName -Raw
            $scriptName = $scriptFile.Name
            
            foreach ($pattern in $patterns) {
                $urlMatches = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                foreach ($match in $urlMatches) {
                    $url = $match.Groups[1].Value
                    if ($url -and $url.StartsWith('http')) {
                        # Determine type based on URL
                        $type = "Package"
                        if ($url -match '\.(json|xml)$') { $type = "Manifest" }
                        elseif ($url -match '\.(ps1|sh)$') { $type = "Script" }
                        elseif ($url -match '\.(msi|exe)$') { $type = "Installer" }
                        elseif ($url -match '\.(zip|tar\.gz|tgz)$') { $type = "Archive" }
                        elseif ($url -match '\.(jar)$') { $type = "Library" }
                        
                        $null = $expectedUrls.Add(@{
                            Url = $url
                            Source = "Script:$scriptName"
                            Category = "packages"
                            Type = $type
                        })
                    }
                }
            }
        }
    }
    
    # Remove duplicates based on URL using a HashSet for efficient deduplication
    $uniqueUrls = [System.Collections.Generic.HashSet[string]]::new()
    $deduplicatedUrls = [System.Collections.ArrayList]::new()
    
    foreach ($urlInfo in $expectedUrls) {
        if ($uniqueUrls.Add($urlInfo.Url)) {  # Add returns true if item was added (wasn't already present)
            $null = $deduplicatedUrls.Add($urlInfo)
        }
    }
    
    Write-Verbose "Found $($deduplicatedUrls.Count) unique URLs from toolset and scripts"
    return $deduplicatedUrls.ToArray()
}

#endregion

#region Main Execution

Write-Host "🤖 Intelligent cache discovery..." -ForegroundColor Cyan

# Get base URLs directly without circular dependency
$baseUrls = Get-BaseUrlsFromSources -Platform $Platform

Write-Host "📊 Base URLs discovered: $($baseUrls.Count)" -ForegroundColor Yellow

$enhancedUrls = [System.Collections.ArrayList]::new()
$enhancedUrls.AddRange($baseUrls)

# Always resolve variables for maximum cache coverage
Write-Host "🔧 Resolving variables in URLs..." -ForegroundColor Cyan
$variables = Get-ToolsetVariables -Platform $Platform
$resolvedUrls = Resolve-VariableUrls -Urls $baseUrls -Variables $variables

$enhancedUrls.Clear()
$enhancedUrls.AddRange($resolvedUrls)

Write-Host "✅ Variable resolution complete. URLs: $($enhancedUrls.Count)" -ForegroundColor Green

# Always map known software for maximum coverage
Write-Host "🗺️ Mapping known installed software to download URLs..." -ForegroundColor Cyan
$knownUrls = Get-KnownSoftwareUrls -Platform $Platform
$enhancedUrls.AddRange($knownUrls)

$packageUrls = Get-PackageManagerUrls -Platform $Platform
$enhancedUrls.AddRange($packageUrls)

Write-Host "✅ Software mapping complete. Total URLs: $($enhancedUrls.Count)" -ForegroundColor Green

# 3. Test redirects for aka.ms and go.microsoft.com URLs (limited to avoid spam)
Write-Host "🔗 Following redirects for aka.ms and go.microsoft.com URLs..." -ForegroundColor Cyan
$redirectUrls = $enhancedUrls | Where-Object { $_.Url -match 'aka\.ms|go\.microsoft\.com/fwlink' } | Select-Object -First 5

foreach ($urlInfo in $redirectUrls) {
    $redirected = Test-UrlRedirect -Url $urlInfo.Url
    if ($redirected) {
        $redirectInfo = $urlInfo.Clone()
        $redirectInfo.Url = $redirected
        $redirectInfo.Source = $urlInfo.Source + " (redirect)"
        $redirectInfo.Cacheability = "Redirect-Resolved"
        $enhancedUrls.Add($redirectInfo) | Out-Null
    }
}

Write-Host "✅ Redirect resolution complete. Total URLs: $($enhancedUrls.Count)" -ForegroundColor Green

# Output enhanced results
Write-Host "`n🎯 Enhanced Discovery Results:" -ForegroundColor Green
Write-Host "Total URLs: $($enhancedUrls.Count)" -ForegroundColor Yellow

$summary = $enhancedUrls | Group-Object Cacheability | Sort-Object Count -Descending
foreach ($group in $summary) {
    Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor Cyan
}

# Save enhanced URLs for use with cache system
$enhancedManifest = @{
    GeneratedAt = Get-Date
    Platform = $Platform
    TotalUrls = $enhancedUrls.Count
    EnhancedUrls = $enhancedUrls
}

$manifestPath = Join-Path $scriptRoot "enhanced-cache-manifest.json"
$enhancedManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "`n💾 Enhanced manifest saved to: enhanced-cache-manifest.json" -ForegroundColor Green
Write-Host "🚀 Use this with Build-DownloadCache.ps1 for comprehensive caching!" -ForegroundColor Magenta

# Return the enhanced URLs for integration with other scripts
return $enhancedUrls

#endregion
