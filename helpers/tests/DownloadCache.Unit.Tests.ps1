################################################################################
##  File:  DownloadCache.Unit.Tests.ps1
##  Desc:  Unit tests for the download cache system
################################################################################

BeforeDiscovery {
    $helperPath = Split-Path -Parent $PSScriptRoot
    # Import the module using the full path
    try {
        . "$helperPath\CachedInstallHelpers.ps1"
        Write-Host "Cache functions loaded directly" -ForegroundColor Cyan
    } catch {
        Write-Warning "Failed to load cache functions: $_"
    }
}

Describe "Download Cache System Unit Tests" {
    BeforeAll {
        # Import functions at the start of the test
        $helperPath = Split-Path -Parent $PSScriptRoot
        . "$helperPath\CachedInstallHelpers.ps1"
        
        # Setup test environment
        $script:TestCacheDir = Join-Path $env:TEMP "PesterTestCache_$(Get-Random)"
        $script:TestManifest = @{
            Platform = "windows"
            GeneratedAt = "2025-01-01T00:00:00Z"
            Downloads = @(
                @{
                    Url = "https://example.com/test.exe"
                    UrlHash = "ABC123"
                    FileName = "test.exe"
                    Category = "packages"
                    CachePath = "packages\ABC123_test.exe"
                },
                @{
                    Url = "https://api.github.com/repos/microsoft/dotnet/releases"
                    UrlHash = "DEF456" 
                    FileName = "releases"
                    Category = "manifests"
                    CachePath = "manifests\DEF456_releases"
                }
            )
            Statistics = @{
                TotalUrls = 2
                ToolsetUrls = 1
                ScriptUrls = 1
                ManifestUrls = 0
            }
        }
        
        # Create test cache structure
        New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
        New-Item -ItemType Directory -Path "$script:TestCacheDir\packages" -Force | Out-Null
        New-Item -ItemType Directory -Path "$script:TestCacheDir\manifests" -Force | Out-Null
        
        # Create manifest file
        $script:TestManifest | ConvertTo-Json -Depth 10 | Set-Content "$script:TestCacheDir\cache-manifest.json"
        
        # Create test cached files
        "Test binary content" | Set-Content "$script:TestCacheDir\packages\ABC123_test.exe"
        "Test manifest content" | Set-Content "$script:TestCacheDir\manifests\DEF456_releases"
    }
    
    AfterAll {
        # Cleanup test cache
        if (Test-Path $script:TestCacheDir) {
            Remove-Item $script:TestCacheDir -Recurse -Force
        }
    }
    
    Context "Cache Initialization" {
        It "Should initialize cache successfully with valid manifest" {
            { Initialize-BuildCache -CacheLocation $script:TestCacheDir -Platform "windows" } | Should -Not -Throw
            
            # Verify global cache config is set
            $Script:CacheConfig.Enabled | Should -Be $true
            $Script:CacheConfig.Location | Should -Be $script:TestCacheDir
            $Script:CacheConfig.Manifest | Should -Not -BeNullOrEmpty
            $Script:CacheConfig.Manifest.Platform | Should -Be "windows"
        }
        
        It "Should throw error for non-existent cache location" {
            { Initialize-BuildCache -CacheLocation "C:\NonExistent" -Platform "windows" } | Should -Throw "*does not exist*"
        }
        
        It "Should throw error for missing manifest" {
            $tempDir = Join-Path $env:TEMP "PesterTestNoManifest_$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            
            try {
                { Initialize-BuildCache -CacheLocation $tempDir -Platform "windows" } | Should -Throw "*manifest not found*"
            } finally {
                Remove-Item $tempDir -Force
            }
        }
    }
    
    Context "Cache Lookup Functions" {
        BeforeEach {
            Initialize-BuildCache -CacheLocation $script:TestCacheDir -Platform "windows"
        }
        
        It "Should find cached file by URL" {
            $result = Find-CachedFile -Url "https://example.com/test.exe"
            
            $result | Should -Not -BeNullOrEmpty
            $result.Found | Should -Be $true
            $result.Path | Should -Be "$script:TestCacheDir\packages\ABC123_test.exe"
            Test-Path $result.Path | Should -Be $true
        }
        
        It "Should return not found for non-cached URL" {
            $result = Find-CachedFile -Url "https://example.com/notcached.exe"
            
            $result | Should -Not -BeNullOrEmpty
            $result.Found | Should -Be $false
            $result.Path | Should -BeNullOrEmpty
        }
        
        It "Should calculate correct URL hash" {
            $hash1 = Get-CacheUrlHash -Url "https://example.com/test.exe"
            $hash2 = Get-CacheUrlHash -Url "https://example.com/test.exe"
            $hash3 = Get-CacheUrlHash -Url "https://example.com/different.exe"
            
            $hash1 | Should -Be $hash2
            $hash1 | Should -Not -Be $hash3
            $hash1.Length | Should -BeGreaterThan 0
        }
    }
    
    Context "Cached Installation Functions" {
        BeforeEach {
            Initialize-BuildCache -CacheLocation $script:TestCacheDir -Platform "windows"
        }
        
        It "Should use cached file when available" {
            $result = Install-BinaryFromCache -Url "https://example.com/test.exe" -Name "TestBinary" -WhatIf
            
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be "Cache"
            $result.CachePath | Should -Be "$script:TestCacheDir\packages\ABC123_test.exe"
        }
        
        It "Should fall back to download when cache disabled" {
            $Script:CacheConfig.Enabled = $false
            
            $result = Install-BinaryFromCache -Url "https://example.com/test.exe" -Name "TestBinary" -WhatIf
            
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be "Download"
        }
        
        It "Should fall back to download when file not in cache" {
            $result = Install-BinaryFromCache -Url "https://example.com/notcached.exe" -Name "TestBinary" -WhatIf
            
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be "Download"
        }
    }
    
    Context "Download Cache Wrapper Functions" {
        BeforeEach {
            Initialize-BuildCache -CacheLocation $script:TestCacheDir -Platform "windows"
        }
        
        It "Should invoke cached download when available" {
            $result = Invoke-DownloadWithCacheRetry -Url "https://example.com/test.exe" -WhatIf
            
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be "Cache"
            $result.CachePath | Should -Be "$script:TestCacheDir\packages\ABC123_test.exe"
        }
        
        It "Should handle retry parameters correctly" {
            $result = Invoke-DownloadWithCacheRetry -Url "https://example.com/test.exe" -Retries 5 -WhatIf
            
            $result | Should -Not -BeNullOrEmpty
            $result.Source | Should -Be "Cache"
            $result.Retries | Should -Be 5
        }
    }
    
    Context "Cache Statistics and Information" {
        BeforeEach {
            Initialize-BuildCache -CacheLocation $script:TestCacheDir -Platform "windows"
        }
        
        It "Should return cache statistics" {
            $stats = Get-BuildCacheStatistics
            
            $stats | Should -Not -BeNullOrEmpty
            $stats.Location | Should -Be $script:TestCacheDir
            $stats.Platform | Should -Be "windows"
            $stats.TotalFiles | Should -Be 2
            $stats.Categories | Should -Not -BeNullOrEmpty
            $stats.Categories.packages | Should -Be 1
            $stats.Categories.manifests | Should -Be 1
        }
        
        It "Should identify cache status correctly" {
            Test-BuildCacheEnabled | Should -Be $true
            
            $Script:CacheConfig.Enabled = $false
            Test-BuildCacheEnabled | Should -Be $false
        }
    }
}

Describe "Build-DownloadCache Script Tests" {
    BeforeAll {
        $script:BuildScript = Join-Path (Split-Path -Parent $PSScriptRoot) "Build-DownloadCache.ps1"
        $script:TestOutputDir = Join-Path $env:TEMP "PesterBuildCacheTest_$(Get-Random)"
    }
    
    AfterAll {
        if (Test-Path $script:TestOutputDir) {
            Remove-Item $script:TestOutputDir -Recurse -Force
        }
    }
    
    Context "Script Parameter Validation" {
        It "Should accept valid platform parameters" {
            $validPlatforms = @("windows", "ubuntu", "macos")
            
            foreach ($platform in $validPlatforms) {
                { & $script:BuildScript -CacheLocation $script:TestOutputDir -Platform $platform -WhatIf } | Should -Not -Throw
            }
        }
        
        It "Should reject invalid platform parameters" {
            { & $script:BuildScript -CacheLocation $script:TestOutputDir -Platform "invalid" -WhatIf } | Should -Throw
        }
        
        It "Should require mandatory parameters" {
            { & $script:BuildScript } | Should -Throw
        }
    }
    
    Context "Cache Generation" {
        It "Should generate cache structure in WhatIf mode" {
            $output = & $script:BuildScript -CacheLocation $script:TestOutputDir -Platform "windows" -WhatIf 2>&1
            
            $output -join "`n" | Should -Match "=== Build Download Cache for windows ==="
            $output -join "`n" | Should -Match "WhatIf: Would create cache directory"
        }
    }
}
