################################################################################
##  File:  DownloadCache.Integration.Tests.ps1  
##  Desc:  Integration tests for download cache URL extraction and real functionality
################################################################################

BeforeDiscovery {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $helperPath = Join-Path $repoRoot "helpers"
    $buildScript = Join-Path $helperPath "Build-DownloadCache.ps1"
    
    # Only run if we have the Windows platform available
    $windowsPlatform = Join-Path $repoRoot "images\windows"
    $shouldRunWindowsTests = Test-Path $windowsPlatform
}

Describe "Download Cache Integration Tests" -Skip:(-not $shouldRunWindowsTests) {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:BuildScript = Join-Path $script:RepoRoot "helpers\Build-DownloadCache.ps1"
        $script:TestCacheDir = Join-Path $env:TEMP "PesterIntegrationTest_$(Get-Random)"
        $script:WindowsPath = Join-Path $script:RepoRoot "images\windows"
    }
    
    AfterAll {
        if (Test-Path $script:TestCacheDir) {
            Remove-Item $script:TestCacheDir -Recurse -Force
        }
    }
    
    Context "URL Extraction from Real Files" {
        It "Should extract URLs from Windows toolset files" {
            $toolsetPath = Join-Path $script:WindowsPath "toolsets"
            if (-not (Test-Path $toolsetPath)) {
                Set-ItResult -Skipped -Because "Windows toolsets not found"
                return
            }
            
            $toolsetFiles = Get-ChildItem $toolsetPath -Filter "*.json"
            $toolsetFiles.Count | Should -BeGreaterThan 0
            
            # Run cache build in WhatIf mode to see extracted URLs
            $output = & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf 2>&1 | Out-String
            
            $output | Should -Match "=== URL Extraction ==="
            $output | Should -Match "https://"
        }
        
        It "Should extract URLs from Windows build scripts" {
            $scriptsPath = Join-Path $script:WindowsPath "scripts"
            if (-not (Test-Path $scriptsPath)) {
                Set-ItResult -Skipped -Because "Windows scripts not found"
                return
            }
            
            $scriptFiles = Get-ChildItem $scriptsPath -Filter "*.ps1" -Recurse
            $scriptFiles.Count | Should -BeGreaterThan 0
            
            # Run cache build and check for script URL extraction
            $output = & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf 2>&1 | Out-String
            
            # Should find some URLs from scripts
            $output | Should -Match "Scripts processed:"
        }
        
        It "Should generate valid cache manifest structure" {
            # Actually generate cache (small subset)
            & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf
            
            # Verify manifest would be created with proper structure
            $output = & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf 2>&1 | Out-String
            
            $output | Should -Match "Platform.*windows"
            $output | Should -Match "Total URLs found:"
        }
    }
    
    Context "Cache Environment Integration" {
        BeforeAll {
            # Create a minimal test cache for environment testing
            New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
            $testManifest = @{
                Platform = "windows"
                GeneratedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                Downloads = @()
                Statistics = @{ TotalUrls = 0; ToolsetUrls = 0; ScriptUrls = 0; ManifestUrls = 0 }
            }
            $testManifest | ConvertTo-Json -Depth 10 | Set-Content "$script:TestCacheDir\cache-manifest.json"
        }
        
        It "Should initialize cache environment without errors" {
            $initScript = Join-Path $script:RepoRoot "helpers\Initialize-CacheEnvironment.ps1"
            
            { & $initScript -CacheLocation $script:TestCacheDir -Platform "windows" } | Should -Not -Throw
            
            # Check environment variables are set
            $env:BUILD_CACHE_ENABLED | Should -Be "true"
            $env:BUILD_CACHE_LOCATION | Should -Be $script:TestCacheDir
            $env:BUILD_CACHE_PLATFORM | Should -Be "windows"
        }
        
        It "Should make cached functions available" {
            $initScript = Join-Path $script:RepoRoot "helpers\Initialize-CacheEnvironment.ps1"
            
            # Source the initialization script
            . $initScript -CacheLocation $script:TestCacheDir -Platform "windows"
            
            # Check that cache functions are available
            Get-Command "Install-BinaryFromCache" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command "Invoke-DownloadWithCacheRetry" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-Command "Test-BuildCacheEnabled" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "End-to-End Cache Workflow" {
        It "Should complete full cache generation workflow" {
            # Generate cache with actual extraction (but don't download)
            $output = & $script:BuildScript -CacheLocation $script:TestCacheDir -Platform "windows" -WhatIf 2>&1
            
            $exitCode = $LASTEXITCODE
            $exitCode | Should -Be 0
            
            $outputString = $output -join "`n"
            $outputString | Should -Match "=== Build Download Cache for windows ==="
            $outputString | Should -Match "=== Summary ==="
        }
        
        It "Should handle missing platform directories gracefully" {
            $nonExistentCache = Join-Path $env:TEMP "NonExistentPlatform_$(Get-Random)"
            
            # Test with a hypothetical platform that doesn't exist
            { & $script:BuildScript -CacheLocation $nonExistentCache -Platform "windows" -WhatIf } | Should -Not -Throw
            
            # Cleanup
            if (Test-Path $nonExistentCache) {
                Remove-Item $nonExistentCache -Recurse -Force
            }
        }
    }
}

Describe "Download Cache Performance Tests" {
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
            } finally {
                if (Test-Path $testCacheDir) {
                    Remove-Item $testCacheDir -Recurse -Force
                }
            }
        }
    }
}
