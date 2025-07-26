################################################################################
##  File:  Compare-CacheStatus.ps1
##  Desc:  Compare expected toolset URLs vs cached files status
##  Usage: .\Compare-CacheStatus.ps1 [-CacheLocation "P:\Cache"] [-OutputFormat "Table"]
##  Note:  Generates comparison report of cache coverage
################################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CacheLocation = (Join-Path $env:TEMP "RunnerImageCache"),
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("windows")]
    [string]$Platform = "windows",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Table", "Markdown", "Json")]
    [string]$OutputFormat = "Markdown",
    
    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "README-CACHE.md"
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
            
            # Parse other sections that might contain direct URLs
            $sections = @('dotnet', 'node', 'powershellModules', 'azureModules', 'vcRedist', 'visualStudio', 'wix')
            foreach ($section in $sections) {
                if ($toolset.$section) {
                    $sectionData = $toolset.$section
                    
                    # Look for URL properties recursively
                    function Find-UrlsInObject {
                        param($obj, $path)
                        
                        if ($obj -is [string] -and $obj -match '^https?://') {
                            return @{
                                Url = $obj
                                Source = "Toolset:$path"
                                Category = "packages"
                                Type = if ($obj -match '\.(json|xml)$') { "Manifest" } 
                                       elseif ($obj -match '\.(msi|exe)$') { "Installer" } 
                                       elseif ($obj -match '\.(zip|tar\.gz|tgz)$') { "Archive" } 
                                       else { "Package" }
                            }
                        }
                        elseif ($obj -is [PSCustomObject] -or $obj -is [hashtable]) {
                            $results = @()
                            $obj.PSObject.Properties | ForEach-Object {
                                if ($_.Name -match 'url|link|download|href' -and $_.Value -match '^https?://') {
                                    $results += @{
                                        Url = $_.Value
                                        Source = "Toolset:$path.$($_.Name)"
                                        Category = "packages"
                                        Type = if ($_.Value -match '\.(json|xml)$') { "Manifest" } 
                                               elseif ($_.Value -match '\.(msi|exe)$') { "Installer" } 
                                               elseif ($_.Value -match '\.(zip|tar\.gz|tgz)$') { "Archive" } 
                                               else { "Package" }
                                    }
                                } else {
                                    $subResults = Find-UrlsInObject $_.Value "$path.$($_.Name)"
                                    if ($subResults) { $results += $subResults }
                                }
                            }
                            return $results
                        }
                        elseif ($obj -is [array]) {
                            $results = @()
                            for ($i = 0; $i -lt $obj.Count; $i++) {
                                $subResults = Find-UrlsInObject $obj[$i] "$path[$i]"
                                if ($subResults) { $results += $subResults }
                            }
                            return $results
                        }
                    }
                    
                    $foundUrls = Find-UrlsInObject $sectionData $section
                    if ($foundUrls) {
                        foreach ($urlInfo in $foundUrls) {
                            $null = $expectedUrls.Add($urlInfo)
                        }
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
        
        # Determine cacheable status
        $cacheability = if ($hasVariables) { "Variable" }
                       elseif ($expected.Url -match 'aka\.ms|go\.microsoft\.com/fwlink') { "Redirect" }
                       elseif ($expected.Source -match '^Toolset:') { "Toolset-Defined" }
                       elseif ($expected.Type -eq "Manifest") { "Dynamic-Content" }
                       else { "Cacheable" }
        
        $status += [PSCustomObject]@{
            Url = $expected.Url
            Source = $expected.Source
            Type = $expected.Type
            Category = $expected.Category
            Cached = $exists
            SizeMB = $size
            HasVariables = $hasVariables
            Cacheability = $cacheability
            Status = if ($exists) { "Cached" } else { "Missing" }
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
        @{Name='Cacheability'; Expression={$_.Cacheability}; Width=15},
        @{Name='Type'; Expression={$_.Type}; Width=10},
        @{Name='Size(MB)'; Expression={if($_.SizeMB -gt 0){$_.SizeMB}else{'-'}}; Width=8},
        @{Name='Source'; Expression={$_.Source}; Width=25},
        @{Name='URL'; Expression={if($_.Url.Length -gt 50){$_.Url.Substring(0,47)+'...'}else{$_.Url}}; Width=50}
    ) -AutoSize | Out-String
    
    Write-Host $tableOutput
    
    # Summary
    $total = $Status.Count
    $cached = ($Status | Where-Object {$_.Cached}).Count
    $missing = ($Status | Where-Object {$_.Status -eq "Missing"}).Count
    $variables = ($Status | Where-Object {$_.HasVariables}).Count
    $totalSize = ($Status | Where-Object {$_.Cached} | Measure-Object -Property SizeMB -Sum).Sum
    
    # Cacheability analysis
    $cacheable = ($Status | Where-Object {$_.Cacheability -eq "Cacheable"}).Count
    $toolsetDefined = ($Status | Where-Object {$_.Cacheability -eq "Toolset-Defined"}).Count
    $redirects = ($Status | Where-Object {$_.Cacheability -eq "Redirect"}).Count
    $dynamic = ($Status | Where-Object {$_.Cacheability -eq "Dynamic-Content"}).Count
    
    Write-Host "`n=== Summary ===" -ForegroundColor Green
    Write-Host "Total URLs: $total" -ForegroundColor Yellow
    Write-Host "Cached: $cached" -ForegroundColor Green
    Write-Host "Missing: $missing" -ForegroundColor Red  
    Write-Host "With Variables: $variables" -ForegroundColor Cyan
    Write-Host "Total Cache Size: $([Math]::Round($totalSize, 2)) MB" -ForegroundColor Yellow
    Write-Host "Cache Coverage: $([Math]::Round(($cached/$total)*100, 1))%" -ForegroundColor $(if($cached/$total -gt 0.5){'Green'}else{'Red'})
    
    Write-Host "`n=== Cacheability Analysis ===" -ForegroundColor Green
    Write-Host "Directly Cacheable: $cacheable" -ForegroundColor Green
    Write-Host "Toolset-Defined: $toolsetDefined" -ForegroundColor Cyan
    Write-Host "Redirects (aka.ms): $redirects" -ForegroundColor Yellow
    Write-Host "Dynamic Content: $dynamic" -ForegroundColor Magenta
    Write-Host "Variable URLs: $variables" -ForegroundColor Red
}

function Format-AsMarkdown {
    param([array]$Status)
    
    # Calculate summary metrics
    $totalUrls = $Status.Count
    $cachedCount = ($Status | Where-Object {$_.Cached}).Count
    $missingCount = ($Status | Where-Object {$_.Status -eq "Missing"}).Count
    $variableCount = ($Status | Where-Object {$_.HasVariables}).Count
    $totalSize = [Math]::Round(($Status | Where-Object {$_.Cached} | Measure-Object -Property SizeMB -Sum).Sum, 2)
    $coverage = [Math]::Round(($cachedCount/$totalUrls)*100, 1)
    
    # Build markdown as array of lines
    $lines = @()
    $lines += "# Cache Status Report"
    $lines += ""
    $lines += "**Cache Location:** $CacheLocation"
    $lines += "**Platform:** $Platform"
    $lines += "**Generated:** $(Get-Date)"
    $lines += ""
    $lines += "## Summary"
    $lines += ""
    $lines += "| Metric | Value |"
    $lines += "| ------ | ----- |"
    $lines += "| Total URLs | $totalUrls |"
    $lines += "| Cached | $cachedCount |"
    $lines += "| Missing | $missingCount |"
    $lines += "| With Variables | $variableCount |"
    $lines += "| Total Size | $totalSize MB |"
    $lines += "| Coverage | $coverage% |"
    $lines += ""
    $lines += "## Detailed Status"
    $lines += ""
    $lines += "| Status | Type | Size (MB) | Source | URL |"
    $lines += "| ------ | ---- | --------- | ------ | --- |"
    
    foreach ($item in $Status | Sort-Object Status, Type, Source) {
        $size = if ($item.SizeMB -gt 0) { [Math]::Round($item.SizeMB, 2) } else { "-" }
        $url = if ($item.Url.Length -gt 80) { $item.Url.Substring(0, 77) + "..." } else { $item.Url }
        $lines += "| $($item.Status) | $($item.Type) | $size | $($item.Source) | ``$url`` |"
    }
    
    return ($lines -join "`n")
}

#endregion

#region Main Execution

Write-Host "Analyzing cache status..." -ForegroundColor Yellow

# Get expected URLs
$expectedUrls = Get-ExpectedUrls -Platform $Platform
Write-Host "Found $($expectedUrls.Count) expected URLs" -ForegroundColor Cyan

# Check cache status
$cacheStatus = Get-CacheStatus -CacheLocation $CacheLocation -ExpectedUrls $expectedUrls

# Output in requested format
switch ($OutputFormat) {
    "Table" {
        Format-AsTable -Status $cacheStatus
    }
    "Markdown" {
        $markdown = Format-AsMarkdown -Status $cacheStatus
        if ($OutputFile) {
            Set-Content -Path $OutputFile -Value $markdown -Encoding UTF8
            Write-Host "`nMarkdown report saved to: $OutputFile" -ForegroundColor Green
        } else {
            Write-Output $markdown
        }
    }
    "Json" {
        $jsonOutput = @{
            GeneratedAt = Get-Date
            CacheLocation = $CacheLocation
            Platform = $Platform
            Summary = @{
                TotalUrls = $cacheStatus.Count
                Cached = ($cacheStatus | Where-Object {$_.Cached}).Count
                Missing = ($cacheStatus | Where-Object {$_.Status -eq "Missing"}).Count
                WithVariables = ($cacheStatus | Where-Object {$_.HasVariables}).Count
                TotalSizeMB = [Math]::Round(($cacheStatus | Where-Object {$_.Cached} | Measure-Object -Property SizeMB -Sum).Sum, 2)
            }
            Details = $cacheStatus
        }
        
        if ($OutputFile) {
            $jsonOutput | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding UTF8
            Write-Host "`nJSON report saved to: $OutputFile" -ForegroundColor Green
        } else {
            $jsonOutput | ConvertTo-Json -Depth 10
        }
    }
}

#endregion
