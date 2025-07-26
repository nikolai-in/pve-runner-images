################################################################################
##  File:  DownloadCache.Smoke.Tests.ps1
##  Desc:  Smoke tests for download cache system - validates core functionality
################################################################################

Describe "Download Cache System - Smoke Tests" {
    Context "URL Extraction Functionality" {
        BeforeAll {
            $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $script:BuildScript = Join-Path $script:RepoRoot "helpers\Build-DownloadCache.ps1"
            $script:TestCacheDir = Join-Path $env:TEMP "PesterSmokeTest_$(Get-Random)"
        }
        
        AfterAll {
            if (Test-Path $script:TestCacheDir) {
                Remove-Item $script:TestCacheDir -Recurse -Force
            }
        }
        
        It "Should successfully extract URLs from Windows platform" {
            $output = & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf 2>&1 | Out-String
            
            $output | Should -Match "=== Build Download Cache for windows ==="
            $output | Should -Match "Total URLs found: \d+"
            $output | Should -Match "From toolsets: \d+"
            $output | Should -Match "From scripts: \d+"
            $output | Should -Match "=== Cache Build Complete ==="
        }
        
        It "Should extract manifest URLs from toolsets" {
            $output = & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf 2>&1 | Out-String
            
            # Should find GitHub Actions version manifests
            $output | Should -Match "python-versions/main/versions-manifest.json"
            $output | Should -Match "node-versions/main/versions-manifest.json"
            $output | Should -Match "go-versions/main/versions-manifest.json"
        }
        
        It "Should extract download URLs from scripts" {
            $output = & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf 2>&1 | Out-String
            
            # Should find some common installer URLs
            $output | Should -Match "PowerShell.*\.msi"
            $output | Should -Match "\.exe|\.msi"  # Should find installer files
        }
        
        It "Should complete without errors" {
            { & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf } | Should -Not -Throw
        }
        
        It "Should support Windows platform" {
            { & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf } | Should -Not -Throw
        }
    }
    
    Context "Cache Environment Initialization" {
        BeforeAll {
            $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $script:InitScript = Join-Path $script:RepoRoot "helpers\Initialize-CacheEnvironment.ps1"
            $script:TestCacheDir = Join-Path $env:TEMP "PesterSmokeTest_$(Get-Random)"
            
            # Create minimal test cache
            New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
            $testManifest = @{
                Platform = "windows"
                GeneratedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                Downloads = @()
                Statistics = @{ TotalUrls = 0; ToolsetUrls = 0; ScriptUrls = 0; ManifestUrls = 0 }
            }
            $testManifest | ConvertTo-Json -Depth 10 | Set-Content "$script:TestCacheDir\cache-manifest.json"
        }
        
        AfterAll {
            if (Test-Path $script:TestCacheDir) {
                Remove-Item $script:TestCacheDir -Recurse -Force
            }
        }
        
        It "Should initialize cache environment successfully" {
            { & $script:InitScript -CacheLocation $script:TestCacheDir -Platform "windows" } | Should -Not -Throw
            
            # Check environment variables are set
            $env:BUILD_CACHE_ENABLED | Should -Be "true"
            $env:BUILD_CACHE_LOCATION | Should -Be $script:TestCacheDir
        }
        
        It "Should load cached helper functions" {
            # Source the initialization script
            . $script:InitScript -CacheLocation $script:TestCacheDir -Platform "windows"
            
            # Verify core functions are available
            Get-Command "Initialize-BuildCache" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command "Find-CachedFile" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command "Install-BinaryFromCache" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Download Cache System - Performance" {
    Context "URL Extraction Performance" {
        It "Should extract URLs within reasonable time" {
            $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $buildScript = Join-Path $repoRoot "helpers\Build-DownloadCache.ps1"
            $testCacheDir = Join-Path $env:TEMP "PesterPerfTest_$(Get-Random)"
            
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            try {
                & $buildScript -CacheLocation $testCacheDir -Platform "windows" -WhatIf | Out-Null
                $stopwatch.Stop()
                
                # Should complete URL extraction in under 30 seconds
                $stopwatch.ElapsedMilliseconds | Should -BeLessThan 30000
                
                Write-Host "URL extraction completed in $($stopwatch.ElapsedMilliseconds)ms" -ForegroundColor Cyan
            } finally {
                if (Test-Path $testCacheDir) {
                    Remove-Item $testCacheDir -Recurse -Force
                }
            }
        }
    }
}
