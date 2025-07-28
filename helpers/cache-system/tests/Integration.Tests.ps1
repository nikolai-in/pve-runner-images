BeforeAll {
    # Import the main orchestrator
    $script:CacheManagerPath = Join-Path $PSScriptRoot ".." "CacheManager.ps1"
    
    # Create test data directory
    $TestDataPath = Join-Path $PSScriptRoot "TestData"
    if (-not (Test-Path $TestDataPath)) {
        New-Item -ItemType Directory -Path $TestDataPath -Force | Out-Null
    }
    
    # Create mock toolset file
    $MockToolset = @{
        toolcache = @(
            @{
                name = "Python"
                arch = "x64"
                platform = "win32"
                versions = @("3.11.*", "3.12.*")
                default = "3.11.*"
            }
        )
    }
    
    $script:TestToolsetPath = Join-Path $TestDataPath "test-toolset.json"
    $MockToolset | ConvertTo-Json -Depth 10 | Set-Content $script:TestToolsetPath
    
    # Mock upstream report URL (we'll mock the actual call)
    $script:MockUpstreamUrl = "https://example.com/report.json"
}

Describe "Cache System Integration Tests" {
    Context "End-to-End Workflow" {
        BeforeEach {
            $script:TestWorkDir = Join-Path $TestDataPath "workflow"
            if (Test-Path $script:TestWorkDir) {
                Remove-Item $script:TestWorkDir -Recurse -Force
            }
            New-Item -ItemType Directory -Path $script:TestWorkDir -Force | Out-Null
            
            Push-Location $script:TestWorkDir
        }
        
        AfterEach {
            Pop-Location
        }
        
        It "Should execute BuildSources action successfully" {
            # Mock the upstream report fetch
            Mock -ModuleName CacheSourceListBuilder Get-UpstreamSoftwareReport {
                return @{
                    Content = @{
                        software = @{
                            toolcache = @(
                                @{
                                    name = "Python"
                                    versions = @(
                                        @{
                                            version = "3.11.5"
                                            download_url = "https://example.com/python-3.11.5.zip"
                                            sha256 = "abc123"
                                            size = 1048576
                                        }
                                    )
                                }
                            )
                        }
                    }
                    Url = $args[0]
                    FetchedAt = (Get-Date)
                    Version = "test"
                }
            }
            
            # Execute via PowerShell call to avoid module import issues
            & $script:CacheManagerPath -Action BuildSources -UpstreamReportUrl $script:MockUpstreamUrl -ToolsetPaths @($script:TestToolsetPath) -SourceListPath "test-sources.json"
            
            "test-sources.json" | Should -Exist
            $sourceList = Get-Content "test-sources.json" -Raw | ConvertFrom-Json
            $sourceList.metadata | Should -Not -BeNullOrEmpty
            $sourceList.sources | Should -Not -BeNullOrEmpty
        }
        
        It "Should handle missing parameters gracefully" {
            { & $script:CacheManagerPath -Action BuildSources } | Should -Throw "*UpstreamReportUrl is required*"
        }
        
        It "Should execute Statistics action on empty directory" {
            & $script:CacheManagerPath -Action Statistics -CacheDirectory "empty-cache"
            
            # Should not throw errors even with empty/missing directory
            $LASTEXITCODE | Should -Be 0
        }
    }
    
    Context "Module Integration" {
        BeforeEach {
            # Import all modules in fresh session
            Import-Module (Join-Path $PSScriptRoot ".." "CacheSourceListBuilder.psm1") -Force
            Import-Module (Join-Path $PSScriptRoot ".." "CacheDownloader.psm1") -Force
            Import-Module (Join-Path $PSScriptRoot ".." "CacheReporter.psm1") -Force
            
            $script:TestWorkDir = Join-Path $TestDataPath "integration"
            if (Test-Path $script:TestWorkDir) {
                Remove-Item $script:TestWorkDir -Recurse -Force
            }
            New-Item -ItemType Directory -Path $script:TestWorkDir -Force | Out-Null
        }
        
        It "Should pass data correctly between modules" {
            # Mock upstream report
            Mock Get-UpstreamSoftwareReport {
                return @{
                    Content = @{
                        software = @{
                            toolcache = @(
                                @{
                                    name = "Python"
                                    versions = @(
                                        @{
                                            version = "3.11.5"
                                            download_url = "https://example.com/python-3.11.5.zip"
                                            sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  # Empty string hash
                                            size = 1048576
                                        }
                                    )
                                }
                            )
                        }
                    }
                    Url = $args[0]
                    FetchedAt = (Get-Date)
                    Version = "test"
                }
            }
            
            # Step 1: Create source list
            $sourceListPath = Join-Path $script:TestWorkDir "sources.json"
            $sourceList = New-CacheSourceList -UpstreamReportUrl $script:MockUpstreamUrl -ToolsetPaths @($script:TestToolsetPath) -OutputPath $sourceListPath
            
            $sourceList | Should -Not -BeNullOrEmpty
            $sourceList.sources | Should -HaveCount 1
            $sourceListPath | Should -Exist
            
            # Step 2: Mock download (create fake cache file)
            $cacheDir = Join-Path $script:TestWorkDir "cache"
            $source = $sourceList.sources[0]
            $fileName = Get-CacheFileName -Source $source
            $filePath = Join-Path $cacheDir $fileName
            $fileDir = Split-Path $filePath -Parent
            New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
            "" | Set-Content $filePath  # Empty file matches the hash
            
            # Step 3: Generate report
            $report = New-CacheReport -SourceListPath $sourceListPath -CacheDirectory $cacheDir
            
            $report | Should -Not -BeNullOrEmpty
            $report.summary.totalSources | Should -Be 1
            $report.summary.cachedSources | Should -Be 1
            $report.summary.coveragePercentage | Should -Be 100
            $report.cachedItems | Should -HaveCount 1
            $report.missingItems | Should -HaveCount 0
        }
        
        It "Should maintain data consistency across schema validation" {
            # Create a valid source list
            $sourceList = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    upstreamReport = @{
                        url = $script:MockUpstreamUrl
                        version = "test"
                        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    toolsetFiles = @(
                        @{
                            path = $script:TestToolsetPath
                            lastModified = (Get-Date).ToUniversalTime().ToString('o')
                        }
                    )
                }
                sources = @(
                    @{
                        name = "TestTool"
                        version = "1.0.0"
                        platform = "win32"
                        arch = "x64"
                        downloadUrl = "https://example.com/tool.zip"
                        matchedFrom = @{
                            upstream = $true
                            toolset = $script:TestToolsetPath
                        }
                    }
                )
            }
            
            # Convert to JSON and back to simulate file I/O
            $json = $sourceList | ConvertTo-Json -Depth 10
            $parsed = $json | ConvertFrom-Json
            
            # Verify all required schema fields are present
            $parsed.metadata | Should -Not -BeNullOrEmpty
            $parsed.metadata.generatedAt | Should -Not -BeNullOrEmpty
            $parsed.metadata.upstreamReport | Should -Not -BeNullOrEmpty
            $parsed.metadata.toolsetFiles | Should -Not -BeNullOrEmpty
            $parsed.sources | Should -Not -BeNullOrEmpty
            
            $source = $parsed.sources[0]
            $source.name | Should -Not -BeNullOrEmpty
            $source.version | Should -Not -BeNullOrEmpty
            $source.platform | Should -Not -BeNullOrEmpty
            $source.arch | Should -Not -BeNullOrEmpty
            $source.downloadUrl | Should -Not -BeNullOrEmpty
            $source.matchedFrom | Should -Not -BeNullOrEmpty
            $source.matchedFrom.upstream | Should -Not -BeNullOrEmpty
            $source.matchedFrom.toolset | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Error Handling and Recovery" {
        It "Should handle malformed toolset files gracefully" {
            $malformedToolsetPath = Join-Path $TestDataPath "malformed.json"
            "{ invalid json" | Set-Content $malformedToolsetPath
            
            Mock Get-UpstreamSoftwareReport {
                return @{
                    Content = @{ software = @{} }
                    Url = $args[0]
                    FetchedAt = (Get-Date)
                    Version = "test"
                }
            }
            
            # Should not throw but should produce empty results
            $result = New-CacheSourceList -UpstreamReportUrl $script:MockUpstreamUrl -ToolsetPaths @($malformedToolsetPath)
            
            $result | Should -Not -BeNullOrEmpty
            $result.sources | Should -HaveCount 0
        }
        
        It "Should handle network failures in upstream report fetch" {
            Mock Get-UpstreamSoftwareReport { throw "Network error" }
            
            { New-CacheSourceList -UpstreamReportUrl $script:MockUpstreamUrl -ToolsetPaths @($script:TestToolsetPath) } | Should -Throw "*Failed to fetch upstream software report*"
        }
        
        It "Should handle missing cache directory in report generation" {
            $sourceListPath = Join-Path $TestDataPath "empty-sources.json"
            $emptySourceList = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    upstreamReport = @{
                        url = $script:MockUpstreamUrl
                        version = "test"
                        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    toolsetFiles = @()
                }
                sources = @()
            }
            $emptySourceList | ConvertTo-Json -Depth 10 | Set-Content $sourceListPath
            
            $result = New-CacheReport -SourceListPath $sourceListPath -CacheDirectory "nonexistent-cache"
            
            $result | Should -Not -BeNullOrEmpty
            $result.summary.totalSources | Should -Be 0
            $result.summary.cachedSources | Should -Be 0
            $result.summary.coveragePercentage | Should -Be 0
        }
    }
    
    Context "Performance and Scale" {
        It "Should handle large source lists efficiently" {
            # Create a source list with many items
            $largeSources = @()
            for ($i = 1; $i -le 100; $i++) {
                $largeSources += @{
                    name = "Tool$i"
                    version = "1.0.$i"
                    platform = "win32"
                    arch = "x64"
                    downloadUrl = "https://example.com/tool$i.zip"
                    matchedFrom = @{
                        upstream = $true
                        toolset = $script:TestToolsetPath
                    }
                }
            }
            
            $largeSourceList = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    upstreamReport = @{
                        url = $script:MockUpstreamUrl
                        version = "test"
                        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    toolsetFiles = @(
                        @{
                            path = $script:TestToolsetPath
                            lastModified = (Get-Date).ToUniversalTime().ToString('o')
                        }
                    )
                }
                sources = $largeSources
            }
            
            $sourceListPath = Join-Path $TestDataPath "large-sources.json"
            $largeSourceList | ConvertTo-Json -Depth 10 | Set-Content $sourceListPath
            
            # Test report generation performance
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = New-CacheReport -SourceListPath $sourceListPath -CacheDirectory "empty-cache"
            $stopwatch.Stop()
            
            $result.summary.totalSources | Should -Be 100
            $result.summary.missingSources | Should -Be 100
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 5000  # Should complete within 5 seconds
        }
    }
}

AfterAll {
    # Cleanup test data
    $TestDataPath = Join-Path $PSScriptRoot "TestData"
    if (Test-Path $TestDataPath) {
        Remove-Item $TestDataPath -Recurse -Force
    }
}
