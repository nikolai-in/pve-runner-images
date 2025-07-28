BeforeAll {
    # Import modules for testing
    $ModulePath = Join-Path $PSScriptRoot ".." "CacheReporter.psm1"
    Import-Module $ModulePath -Force
    
    # Create test data directory
    $TestDataPath = Join-Path $PSScriptRoot "TestData"
    if (-not (Test-Path $TestDataPath)) {
        New-Item -ItemType Directory -Path $TestDataPath -Force | Out-Null
    }
    
    # Mock source data
    $script:MockSourceList = @{
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
                sha256 = "abc123"
                size = 1048576
                matchedFrom = @{
                    upstream = $true
                    toolset = "test.json"
                }
            },
            @{
                name = "Node.js"
                version = "18.17.0"
                platform = "win32"
                arch = "x64"
                downloadUrl = "https://example.com/node.zip"
                sha256 = "def456"
                size = 2097152
                matchedFrom = @{
                    upstream = $true
                    toolset = "test.json"
                }
            }
        )
    }
}

Describe "CacheReporter Module" {
    Context "Get-CacheFileName" {
        It "Should generate consistent file names with CacheDownloader" {
            $source = $script:MockSourceList.sources[0]
            $result = Get-CacheFileName -Source $source
            
            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeLike "*win32*x64*Python*3.11.5*"
        }
    }
    
    Context "Get-CacheAnalysis" {
        BeforeEach {
            $script:TestCacheDir = Join-Path $TestDataPath "cache"
            if (Test-Path $script:TestCacheDir) {
                Remove-Item $script:TestCacheDir -Recurse -Force
            }
            New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
        }
        
        It "Should analyze empty cache correctly" {
            $result = Get-CacheAnalysis -SourceList $script:MockSourceList -CacheDirectory $script:TestCacheDir
            
            $result.Summary.totalSources | Should -Be 2
            $result.Summary.cachedSources | Should -Be 0
            $result.Summary.missingSources | Should -Be 2
            $result.Summary.coveragePercentage | Should -Be 0
            $result.Summary.totalCacheSize | Should -Be 0
            $result.CachedItems | Should -HaveCount 0
            $result.MissingItems | Should -HaveCount 2
        }
        
        It "Should analyze partially cached directory" {
            # Create one cached file
            $source = $script:MockSourceList.sources[0]
            $fileName = Get-CacheFileName -Source $source
            $filePath = Join-Path $script:TestCacheDir $fileName
            $fileDir = Split-Path $filePath -Parent
            New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
            "test content" | Set-Content $filePath
            
            Mock Get-FileHash { 
                return @{ Hash = "abc123" }
            }
            
            $result = Get-CacheAnalysis -SourceList $script:MockSourceList -CacheDirectory $script:TestCacheDir
            
            $result.Summary.totalSources | Should -Be 2
            $result.Summary.cachedSources | Should -Be 1
            $result.Summary.missingSources | Should -Be 1
            $result.Summary.coveragePercentage | Should -Be 50
            $result.Summary.totalCacheSize | Should -BeGreaterThan 0
            $result.CachedItems | Should -HaveCount 1
            $result.MissingItems | Should -HaveCount 1
        }
        
        It "Should analyze fully cached directory" {
            # Create all cached files
            foreach ($source in $script:MockSourceList.sources) {
                $fileName = Get-CacheFileName -Source $source
                $filePath = Join-Path $script:TestCacheDir $fileName
                $fileDir = Split-Path $filePath -Parent
                New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
                "test content for $($source.name)" | Set-Content $filePath
            }
            
            Mock Get-FileHash { 
                param($Path)
                if ($Path -like "*Python*") {
                    return @{ Hash = "abc123" }
                } else {
                    return @{ Hash = "def456" }
                }
            }
            
            $result = Get-CacheAnalysis -SourceList $script:MockSourceList -CacheDirectory $script:TestCacheDir
            
            $result.Summary.totalSources | Should -Be 2
            $result.Summary.cachedSources | Should -Be 2
            $result.Summary.missingSources | Should -Be 0
            $result.Summary.coveragePercentage | Should -Be 100
            $result.CachedItems | Should -HaveCount 2
            $result.MissingItems | Should -HaveCount 0
        }
        
        It "Should include checksum validation in cached items" {
            $source = $script:MockSourceList.sources[0]
            $fileName = Get-CacheFileName -Source $source
            $filePath = Join-Path $script:TestCacheDir $fileName
            $fileDir = Split-Path $filePath -Parent
            New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
            "test content" | Set-Content $filePath
            
            Mock Get-FileHash { 
                return @{ Hash = "abc123" }  # Matches expected hash
            }
            
            $result = Get-CacheAnalysis -SourceList $script:MockSourceList -CacheDirectory $script:TestCacheDir
            
            $cachedItem = $result.CachedItems[0]
            $cachedItem.name | Should -Be "Python"
            $cachedItem.version | Should -Be "3.11.5"
            $cachedItem.platform | Should -Be "win32"
            $cachedItem.arch | Should -Be "x64"
            $cachedItem.filePath | Should -Be $filePath
            $cachedItem.sha256 | Should -Be "abc123"
            $cachedItem.isValidChecksum | Should -Be $true
        }
        
        It "Should detect checksum mismatches" {
            $source = $script:MockSourceList.sources[0]
            $fileName = Get-CacheFileName -Source $source
            $filePath = Join-Path $script:TestCacheDir $fileName
            $fileDir = Split-Path $filePath -Parent
            New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
            "test content" | Set-Content $filePath
            
            Mock Get-FileHash { 
                return @{ Hash = "wrong_hash" }  # Doesn't match expected hash
            }
            
            $result = Get-CacheAnalysis -SourceList $script:MockSourceList -CacheDirectory $script:TestCacheDir
            
            $cachedItem = $result.CachedItems[0]
            $cachedItem.isValidChecksum | Should -Be $false
        }
        
        It "Should include proper missing item details" {
            $result = Get-CacheAnalysis -SourceList $script:MockSourceList -CacheDirectory $script:TestCacheDir
            
            $missingItem = $result.MissingItems[0]
            $missingItem.name | Should -Not -BeNullOrEmpty
            $missingItem.version | Should -Not -BeNullOrEmpty
            $missingItem.platform | Should -Not -BeNullOrEmpty
            $missingItem.arch | Should -Not -BeNullOrEmpty
            $missingItem.downloadUrl | Should -Not -BeNullOrEmpty
            $missingItem.reason | Should -Be "File not found in cache"
        }
    }
    
    Context "New-CacheReport" {
        BeforeEach {
            $script:TestCacheDir = Join-Path $TestDataPath "cache"
            if (Test-Path $script:TestCacheDir) {
                Remove-Item $script:TestCacheDir -Recurse -Force
            }
            New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
            
            $script:TestSourceListPath = Join-Path $TestDataPath "sources.json"
            $script:MockSourceList | ConvertTo-Json -Depth 10 | Set-Content $script:TestSourceListPath
        }
        
        It "Should generate a complete cache report" {
            $result = New-CacheReport -SourceListPath $script:TestSourceListPath -CacheDirectory $script:TestCacheDir
            
            $result | Should -Not -BeNullOrEmpty
            $result.metadata | Should -Not -BeNullOrEmpty
            $result.metadata.generatedAt | Should -Not -BeNullOrEmpty
            $result.metadata.cacheDirectory | Should -Be $script:TestCacheDir
            $result.metadata.sourceListPath | Should -Be $script:TestSourceListPath
            $result.summary | Should -Not -BeNullOrEmpty
            $result.cachedItems | Should -Not -BeNullOrEmpty
            $result.missingItems | Should -Not -BeNullOrEmpty
        }
        
        It "Should save JSON report to file" {
            $outputPath = Join-Path $TestDataPath "report.json"
            
            New-CacheReport -SourceListPath $script:TestSourceListPath -CacheDirectory $script:TestCacheDir -OutputPath $outputPath -Format "Json"
            
            $outputPath | Should -Exist
            $savedReport = Get-Content $outputPath -Raw | ConvertFrom-Json
            $savedReport.metadata | Should -Not -BeNullOrEmpty
            $savedReport.summary | Should -Not -BeNullOrEmpty
        }
        
        It "Should save HTML report to file" {
            $outputPath = Join-Path $TestDataPath "report.html"
            
            New-CacheReport -SourceListPath $script:TestSourceListPath -CacheDirectory $script:TestCacheDir -OutputPath $outputPath -Format "Html"
            
            $outputPath | Should -Exist
            $htmlContent = Get-Content $outputPath -Raw
            $htmlContent | Should -BeLike "*<!DOCTYPE html>*"
            $htmlContent | Should -BeLike "*Cache Report*"
        }
        
        It "Should save text report to file" {
            $outputPath = Join-Path $TestDataPath "report.txt"
            
            New-CacheReport -SourceListPath $script:TestSourceListPath -CacheDirectory $script:TestCacheDir -OutputPath $outputPath -Format "Text"
            
            $outputPath | Should -Exist
            $textContent = Get-Content $outputPath -Raw
            $textContent | Should -BeLike "*CACHE REPORT*"
            $textContent | Should -BeLike "*SUMMARY*"
        }
        
        It "Should handle missing source list file" {
            { New-CacheReport -SourceListPath "missing.json" -CacheDirectory $script:TestCacheDir } | Should -Throw "Source list file not found*"
        }
    }
    
    Context "ConvertTo-HtmlReport" {
        BeforeEach {
            $script:TestReport = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    cacheDirectory = "C:\cache"
                    sourceListPath = "sources.json"
                }
                summary = @{
                    totalSources = 2
                    cachedSources = 1
                    missingSources = 1
                    coveragePercentage = 50.0
                    totalCacheSize = 1048576
                }
                cachedItems = @(
                    @{
                        name = "Python"
                        version = "3.11.5"
                        platform = "win32"
                        arch = "x64"
                        fileSize = 1048576
                        downloadedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }
                )
                missingItems = @(
                    @{
                        name = "Node.js"
                        version = "18.17.0"
                        platform = "win32"
                        arch = "x64"
                        reason = "File not found in cache"
                    }
                )
            }
        }
        
        It "Should generate valid HTML" {
            $html = ConvertTo-HtmlReport -Report $script:TestReport
            
            $html | Should -BeLike "*<!DOCTYPE html>*"
            $html | Should -BeLike "*<html>*"
            $html | Should -BeLike "*Cache Report*"
            $html | Should -BeLike "*Summary*"
            $html | Should -BeLike "*50%*"  # Coverage percentage
        }
        
        It "Should include cached items table" {
            $html = ConvertTo-HtmlReport -Report $script:TestReport
            
            $html | Should -BeLike "*Cached Items (1)*"
            $html | Should -BeLike "*Python*"
            $html | Should -BeLike "*3.11.5*"
            $html | Should -BeLike "*win32*"
            $html | Should -BeLike "*x64*"
        }
        
        It "Should include missing items table" {
            $html = ConvertTo-HtmlReport -Report $script:TestReport
            
            $html | Should -BeLike "*Missing Items (1)*"
            $html | Should -BeLike "*Node.js*"
            $html | Should -BeLike "*18.17.0*"
            $html | Should -BeLike "*File not found in cache*"
        }
        
        It "Should include progress bar" {
            $html = ConvertTo-HtmlReport -Report $script:TestReport
            
            $html | Should -BeLike "*progress-bar*"
            $html | Should -BeLike "*width: 50%*"
        }
    }
    
    Context "ConvertTo-TextReport" {
        BeforeEach {
            $script:TestReport = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    cacheDirectory = "C:\cache"
                    sourceListPath = "sources.json"
                }
                summary = @{
                    totalSources = 2
                    cachedSources = 1
                    missingSources = 1
                    coveragePercentage = 50.0
                    totalCacheSize = 1048576
                }
                cachedItems = @(
                    @{
                        name = "Python"
                        version = "3.11.5"
                        platform = "win32"
                        arch = "x64"
                        fileSize = 1048576
                    }
                )
                missingItems = @(
                    @{
                        name = "Node.js"
                        version = "18.17.0"
                        platform = "win32"
                        arch = "x64"
                        reason = "File not found in cache"
                    }
                )
            }
        }
        
        It "Should generate valid text report" {
            $text = ConvertTo-TextReport -Report $script:TestReport
            
            $text | Should -BeLike "*CACHE REPORT*"
            $text | Should -BeLike "*Generated:*"
            $text | Should -BeLike "*SUMMARY*"
            $text | Should -BeLike "*Total Sources: 2*"
            $text | Should -BeLike "*Coverage: 50%*"
        }
        
        It "Should include cached items section" {
            $text = ConvertTo-TextReport -Report $script:TestReport
            
            $text | Should -BeLike "*CACHED ITEMS (1)*"
            $text | Should -BeLike "*Python 3.11.5 (win32/x64)*"
        }
        
        It "Should include missing items section" {
            $text = ConvertTo-TextReport -Report $script:TestReport
            
            $text | Should -BeLike "*MISSING ITEMS (1)*"
            $text | Should -BeLike "*Node.js 18.17.0 (win32/x64)*"
        }
    }
    
    Context "Compare-CacheReports" {
        BeforeEach {
            $script:OldReport = @{
                metadata = @{
                    generatedAt = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o')
                }
                summary = @{
                    totalSources = 2
                    cachedSources = 1
                    missingSources = 1
                    coveragePercentage = 50.0
                    totalCacheSize = 1048576
                }
                cachedItems = @(
                    @{
                        name = "Python"
                        version = "3.11.5"
                        platform = "win32"
                        arch = "x64"
                    }
                )
            }
            
            $script:NewReport = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                }
                summary = @{
                    totalSources = 3
                    cachedSources = 2
                    missingSources = 1
                    coveragePercentage = 66.67
                    totalCacheSize = 2097152
                }
                cachedItems = @(
                    @{
                        name = "Python"
                        version = "3.11.5"
                        platform = "win32"
                        arch = "x64"
                    },
                    @{
                        name = "Node.js"
                        version = "18.17.0"
                        platform = "win32"
                        arch = "x64"
                    }
                )
            }
            
            $script:OldReportPath = Join-Path $TestDataPath "old-report.json"
            $script:NewReportPath = Join-Path $TestDataPath "new-report.json"
            
            $script:OldReport | ConvertTo-Json -Depth 10 | Set-Content $script:OldReportPath
            $script:NewReport | ConvertTo-Json -Depth 10 | Set-Content $script:NewReportPath
        }
        
        It "Should compare reports and show changes" {
            $result = Compare-CacheReports -OldReportPath $script:OldReportPath -NewReportPath $script:NewReportPath
            
            $result.changes.totalSources | Should -Be 1
            $result.changes.cachedSources | Should -Be 1
            $result.changes.missingSources | Should -Be 0
            $result.changes.coverageChange | Should -BeGreaterThan 0
            $result.changes.sizeChange | Should -Be 1048576
        }
        
        It "Should identify new items" {
            $result = Compare-CacheReports -OldReportPath $script:OldReportPath -NewReportPath $script:NewReportPath
            
            $result.newItems | Should -HaveCount 1
            $result.newItems[0].name | Should -Be "Node.js"
        }
        
        It "Should save comparison report to file" {
            $outputPath = Join-Path $TestDataPath "comparison.json"
            
            Compare-CacheReports -OldReportPath $script:OldReportPath -NewReportPath $script:NewReportPath -OutputPath $outputPath
            
            $outputPath | Should -Exist
            $savedComparison = Get-Content $outputPath -Raw | ConvertFrom-Json
            $savedComparison.changes | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Format-FileSize" {
        It "Should format file sizes correctly" {
            Format-FileSize -Bytes 0 | Should -Be "0.00 B"
            Format-FileSize -Bytes 1024 | Should -Be "1.00 KB"
            Format-FileSize -Bytes 1048576 | Should -Be "1.00 MB"
            Format-FileSize -Bytes 1073741824 | Should -Be "1.00 GB"
            Format-FileSize -Bytes 1536 | Should -Be "1.50 KB"
        }
    }
    
    Context "Show-CacheReportSummary" {
        It "Should display report summary without errors" {
            $testReport = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    cacheDirectory = "C:\cache"
                }
                summary = @{
                    totalSources = 2
                    cachedSources = 1
                    missingSources = 1
                    coveragePercentage = 50.0
                    totalCacheSize = 1048576
                }
                cachedItems = @(
                    @{
                        name = "Python"
                        version = "3.11.5"
                        platform = "win32"
                        arch = "x64"
                    }
                )
                missingItems = @(
                    @{
                        name = "Node.js"
                        version = "18.17.0"
                        platform = "win32"
                        arch = "x64"
                    }
                )
            }
            
            { Show-CacheReportSummary -Report $testReport } | Should -Not -Throw
        }
    }
}

Describe "JSON Schema Validation" {
    Context "Cache Report Schema" {
        BeforeEach {
            $script:CacheReportSchemaPath = Join-Path $PSScriptRoot ".." "schemas" "cache-report-schema.json"
            $script:TestCacheReport = @{
                metadata = @{
                    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    cacheDirectory = "C:\cache"
                    sourceListPath = "sources.json"
                }
                summary = @{
                    totalSources = 1
                    cachedSources = 1
                    missingSources = 0
                    coveragePercentage = 100.0
                    totalCacheSize = 1048576
                }
                cachedItems = @(
                    @{
                        name = "Python"
                        version = "3.11.5"
                        platform = "win32"
                        arch = "x64"
                        filePath = "C:\cache\python.zip"
                        fileSize = 1048576
                        downloadedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }
                )
                missingItems = @()
            }
        }
        
        It "Should have valid cache report schema file" {
            $script:CacheReportSchemaPath | Should -Exist
            
            $schema = Get-Content $script:CacheReportSchemaPath -Raw | ConvertFrom-Json
            $schema.'$schema' | Should -Be "https://json-schema.org/draft-07/schema#"
            $schema.title | Should -Be "Cache Report Schema"
        }
        
        It "Should validate against schema structure" {
            $json = $script:TestCacheReport | ConvertTo-Json -Depth 10
            $parsed = $json | ConvertFrom-Json
            
            $parsed.metadata | Should -Not -BeNullOrEmpty
            $parsed.metadata.generatedAt | Should -Not -BeNullOrEmpty
            $parsed.metadata.cacheDirectory | Should -Not -BeNullOrEmpty
            $parsed.summary | Should -Not -BeNullOrEmpty
            $parsed.summary.totalSources | Should -BeOfType [int]
            $parsed.summary.coveragePercentage | Should -BeOfType [double]
            $parsed.cachedItems | Should -Not -BeNullOrEmpty
            $parsed.missingItems | Should -Not -BeNullOrEmpty
            
            if ($parsed.cachedItems.Count -gt 0) {
                $item = $parsed.cachedItems[0]
                $item.name | Should -Not -BeNullOrEmpty
                $item.version | Should -Not -BeNullOrEmpty
                $item.platform | Should -Not -BeNullOrEmpty
                $item.arch | Should -Not -BeNullOrEmpty
                $item.filePath | Should -Not -BeNullOrEmpty
                $item.fileSize | Should -BeOfType [int]
            }
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
