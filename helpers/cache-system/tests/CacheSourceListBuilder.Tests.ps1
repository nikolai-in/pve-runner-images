BeforeAll {
    # Import modules for testing
    $ModulePath = Join-Path $PSScriptRoot ".." "CacheSourceListBuilder.psm1"
    Import-Module $ModulePath -Force
    
    # Create test data directory
    $TestDataPath = Join-Path $PSScriptRoot "TestData"
    if (-not (Test-Path $TestDataPath)) {
        New-Item -ItemType Directory -Path $TestDataPath -Force | Out-Null
    }
    
    # Mock upstream report data
    $script:MockUpstreamReport = @{
        software = @{
            toolcache = @(
                @{
                    name = "Python"
                    versions = @(
                        @{
                            version = "3.11.5"
                            download_url = "https://example.com/python-3.11.5.zip"
                            sha256 = "abc123"
                            size = 1024000
                        },
                        @{
                            version = "3.12.0"
                            download_url = "https://example.com/python-3.12.0.zip"
                            sha256 = "def456"
                            size = 1048576
                        }
                    )
                },
                @{
                    name = "Node.js"
                    versions = @(
                        @{
                            version = "18.17.0"
                            download_url = "https://example.com/node-18.17.0.zip"
                            sha256 = "ghi789"
                            size = 2048000
                        }
                    )
                }
            )
        }
    }
    
    # Mock toolset data
    $script:MockToolset = @{
        toolcache = @(
            @{
                name = "Python"
                arch = "x64"
                platform = "win32"
                versions = @("3.11.*", "3.12.*")
                default = "3.11.*"
            },
            @{
                name = "Node.js"
                arch = "x64"
                platform = "win32"
                versions = @("18.*")
                default = "18.*"
            }
        )
    }
}

Describe "CacheSourceListBuilder Module" {
    Context "Get-UpstreamSoftwareReport" {
        It "Should parse upstream report correctly" {
            # Mock Invoke-RestMethod
            Mock Invoke-RestMethod { return $script:MockUpstreamReport }
            
            $result = Get-UpstreamSoftwareReport -Url "https://example.com/report.json"
            
            $result.Content | Should -Not -BeNullOrEmpty
            $result.Url | Should -Be "https://example.com/report.json"
            $result.FetchedAt | Should -BeOfType [DateTime]
        }
        
        It "Should handle network errors gracefully" {
            Mock Invoke-RestMethod { throw "Network error" }
            
            { Get-UpstreamSoftwareReport -Url "https://invalid.com/report.json" } | Should -Throw "Failed to fetch upstream software report*"
        }
        
        It "Should use cached report when available and recent" {
            $cachePath = Join-Path $TestDataPath "cached-report.json"
            $script:MockUpstreamReport | ConvertTo-Json -Depth 10 | Set-Content $cachePath
            
            $result = Get-UpstreamSoftwareReport -Url "https://example.com/report.json" -CachePath $cachePath
            
            $result.Content | Should -Not -BeNullOrEmpty
            $result.Version | Should -Be "cached"
        }
    }
    
    Context "Get-LocalToolsets" {
        BeforeEach {
            $script:TestToolsetPath = Join-Path $TestDataPath "test-toolset.json"
            $script:MockToolset | ConvertTo-Json -Depth 10 | Set-Content $script:TestToolsetPath
        }
        
        It "Should load valid toolset files" {
            $result = Get-LocalToolsets -ToolsetPaths @($script:TestToolsetPath)
            
            $result | Should -HaveCount 1
            $result[0].Path | Should -Be $script:TestToolsetPath
            $result[0].Content | Should -Not -BeNullOrEmpty
            $result[0].LastModified | Should -BeOfType [DateTime]
        }
        
        It "Should handle missing toolset files gracefully" {
            $missingPath = Join-Path $TestDataPath "missing.json"
            
            $result = Get-LocalToolsets -ToolsetPaths @($missingPath)
            
            $result | Should -HaveCount 0
        }
        
        It "Should handle malformed JSON gracefully" {
            $malformedPath = Join-Path $TestDataPath "malformed.json"
            "{ invalid json" | Set-Content $malformedPath
            
            $result = Get-LocalToolsets -ToolsetPaths @($malformedPath)
            
            $result | Should -HaveCount 0
        }
    }
    
    Context "Find-BestVersionMatch" {
        It "Should find exact version matches" {
            $availableVersions = @(
                @{ Version = "3.11.5"; DownloadUrl = "url1" },
                @{ Version = "3.12.0"; DownloadUrl = "url2" }
            )
            
            $result = Find-BestVersionMatch -RequestedVersion "3.11.5" -AvailableVersions $availableVersions
            
            $result | Should -Not -BeNullOrEmpty
            $result.Version | Should -Be "3.11.5"
        }
        
        It "Should find wildcard version matches" {
            $availableVersions = @(
                @{ Version = "3.11.5"; DownloadUrl = "url1" },
                @{ Version = "3.11.6"; DownloadUrl = "url2" },
                @{ Version = "3.12.0"; DownloadUrl = "url3" }
            )
            
            $result = Find-BestVersionMatch -RequestedVersion "3.11.*" -AvailableVersions $availableVersions
            
            $result | Should -Not -BeNullOrEmpty
            $result.Version | Should -Be "3.11.6"  # Should pick the latest 3.11.x
        }
        
        It "Should return null for no matches" {
            $availableVersions = @(
                @{ Version = "3.11.5"; DownloadUrl = "url1" }
            )
            
            $result = Find-BestVersionMatch -RequestedVersion "3.13.*" -AvailableVersions $availableVersions
            
            $result | Should -BeNullOrEmpty
        }
    }
    
    Context "Find-ToolMatches" {
        BeforeEach {
            $script:TestToolsetPath = Join-Path $TestDataPath "test-toolset.json"
            $script:MockToolset | ConvertTo-Json -Depth 10 | Set-Content $script:TestToolsetPath
            
            $script:TestToolsets = @(
                @{
                    Path = $script:TestToolsetPath
                    Content = $script:MockToolset
                    LastModified = (Get-Date)
                }
            )
            
            $script:TestUpstreamReport = @{
                Content = $script:MockUpstreamReport
                Url = "https://example.com/report.json"
                FetchedAt = (Get-Date)
                Version = "test"
            }
        }
        
        It "Should find matches between upstream and toolsets" {
            $result = Find-ToolMatches -UpstreamReport $script:TestUpstreamReport -Toolsets $script:TestToolsets
            
            $result | Should -Not -BeNullOrEmpty
            $result | Should -HaveCount 3  # Python 3.11.*, 3.12.*, Node.js 18.*
            
            $pythonMatches = $result | Where-Object { $_.Name -eq "Python" }
            $pythonMatches | Should -HaveCount 2
            
            $nodeMatches = $result | Where-Object { $_.Name -eq "Node.js" }
            $nodeMatches | Should -HaveCount 1
        }
        
        It "Should include proper metadata in matches" {
            $result = Find-ToolMatches -UpstreamReport $script:TestUpstreamReport -Toolsets $script:TestToolsets
            
            $match = $result[0]
            $match.Name | Should -Not -BeNullOrEmpty
            $match.Version | Should -Not -BeNullOrEmpty
            $match.Platform | Should -Be "win32"
            $match.Arch | Should -Be "x64"
            $match.DownloadUrl | Should -Not -BeNullOrEmpty
            $match.MatchedFrom.Upstream | Should -Be $true
            $match.MatchedFrom.Toolset | Should -Be $script:TestToolsetPath
        }
    }
    
    Context "New-CacheSourceList" {
        BeforeEach {
            $script:TestToolsetPath = Join-Path $TestDataPath "test-toolset.json"
            $script:MockToolset | ConvertTo-Json -Depth 10 | Set-Content $script:TestToolsetPath
            
            Mock Get-UpstreamSoftwareReport {
                return @{
                    Content = $script:MockUpstreamReport
                    Url = $args[0]
                    FetchedAt = (Get-Date)
                    Version = "test"
                }
            }
        }
        
        It "Should create a valid source list" {
            $result = New-CacheSourceList -UpstreamReportUrl "https://example.com/report.json" -ToolsetPaths @($script:TestToolsetPath)
            
            $result | Should -Not -BeNullOrEmpty
            $result.metadata | Should -Not -BeNullOrEmpty
            $result.metadata.generatedAt | Should -Not -BeNullOrEmpty
            $result.metadata.upstreamReport | Should -Not -BeNullOrEmpty
            $result.metadata.toolsetFiles | Should -HaveCount 1
            $result.sources | Should -Not -BeNullOrEmpty
        }
        
        It "Should save source list to file when OutputPath specified" {
            $outputPath = Join-Path $TestDataPath "test-sources.json"
            
            $result = New-CacheSourceList -UpstreamReportUrl "https://example.com/report.json" -ToolsetPaths @($script:TestToolsetPath) -OutputPath $outputPath
            
            $outputPath | Should -Exist
            $savedContent = Get-Content $outputPath -Raw | ConvertFrom-Json
            $savedContent.sources | Should -HaveCount $result.sources.Count
        }
    }
    
    Context "Update-CacheSourceList" {
        BeforeEach {
            $script:TestToolsetPath = Join-Path $TestDataPath "test-toolset.json"
            $script:MockToolset | ConvertTo-Json -Depth 10 | Set-Content $script:TestToolsetPath
            
            # Create initial source list
            $initialList = @{
                metadata = @{
                    generatedAt = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o')
                    upstreamReport = @{
                        url = "https://example.com/old-report.json"
                        version = "old"
                        fetchedAt = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o')
                    }
                    toolsetFiles = @(
                        @{
                            path = $script:TestToolsetPath
                            lastModified = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o')
                        }
                    )
                }
                sources = @(
                    @{
                        name = "ManualTool"
                        version = "1.0.0"
                        platform = "win32"
                        arch = "x64"
                        downloadUrl = "https://example.com/manual-tool.zip"
                        matchedFrom = @{
                            upstream = $false
                            toolset = "manual"
                        }
                    }
                )
            }
            
            $script:TestSourceListPath = Join-Path $TestDataPath "existing-sources.json"
            $initialList | ConvertTo-Json -Depth 10 | Set-Content $script:TestSourceListPath
            
            Mock Get-UpstreamSoftwareReport {
                return @{
                    Content = $script:MockUpstreamReport
                    Url = $args[0]
                    FetchedAt = (Get-Date)
                    Version = "new"
                }
            }
        }
        
        It "Should update existing source list" {
            $result = Update-CacheSourceList -SourceListPath $script:TestSourceListPath -UpstreamReportUrl "https://example.com/new-report.json" -ToolsetPaths @($script:TestToolsetPath)
            
            $result | Should -Not -BeNullOrEmpty
            $result.metadata.upstreamReport.version | Should -Be "new"
            $result.sources | Should -Not -BeNullOrEmpty
        }
        
        It "Should preserve manual entries during update" {
            $result = Update-CacheSourceList -SourceListPath $script:TestSourceListPath -UpstreamReportUrl "https://example.com/new-report.json" -ToolsetPaths @($script:TestToolsetPath)
            
            $manualEntries = $result.sources | Where-Object { -not $_.matchedFrom.upstream }
            $manualEntries | Should -HaveCount 1
            $manualEntries[0].name | Should -Be "ManualTool"
        }
        
        It "Should throw error for missing source list file" {
            { Update-CacheSourceList -SourceListPath "missing.json" -UpstreamReportUrl "https://example.com/report.json" -ToolsetPaths @($script:TestToolsetPath) } | Should -Throw "Source list file not found*"
        }
    }
}

Describe "JSON Schema Validation" {
    Context "Source List Schema" {
        BeforeEach {
            $script:SourceListSchemaPath = Join-Path $PSScriptRoot ".." "schemas" "source-list-schema.json"
            $script:TestSourceList = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    upstreamReport = @{
                        url = "https://example.com/report.json"
                        version = "test"
                        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    toolsetFiles = @(
                        @{
                            path = "test.json"
                            lastModified = (Get-Date).ToUniversalTime().ToString('o')
                        }
                    )
                }
                sources = @(
                    @{
                        name = "Python"
                        version = "3.11.5"
                        platform = "win32"
                        arch = "x64"
                        downloadUrl = "https://example.com/python.zip"
                        matchedFrom = @{
                            upstream = $true
                            toolset = "test.json"
                        }
                    }
                )
            }
        }
        
        It "Should have valid source list schema file" {
            $script:SourceListSchemaPath | Should -Exist
            
            $schema = Get-Content $script:SourceListSchemaPath -Raw | ConvertFrom-Json
            $schema.'$schema' | Should -Be "https://json-schema.org/draft-07/schema#"
            $schema.title | Should -Be "Cache Source List Schema"
        }
        
        It "Should validate against schema structure" {
            # This is a basic structure validation
            # In a real scenario, you'd use a JSON schema validation library
            
            $json = $script:TestSourceList | ConvertTo-Json -Depth 10
            $parsed = $json | ConvertFrom-Json
            
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
