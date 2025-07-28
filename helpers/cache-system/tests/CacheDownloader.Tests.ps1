BeforeAll {
    # Import modules for testing
    $ModulePath = Join-Path $PSScriptRoot ".." "CacheDownloader.psm1"
    Import-Module $ModulePath -Force
    
    # Create test data directory
    $TestDataPath = Join-Path $PSScriptRoot "TestData"
    if (-not (Test-Path $TestDataPath)) {
        New-Item -ItemType Directory -Path $TestDataPath -Force | Out-Null
    }
    
    # Mock source data
    $script:MockSource = @{
        name = "TestTool"
        version = "1.0.0"
        platform = "win32"
        arch = "x64"
        downloadUrl = "https://example.com/test-tool.zip"
        sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  # Empty string hash
        size = 1024
        matchedFrom = @{
            upstream = $true
            toolset = "test.json"
        }
    }
    
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
        sources = @($script:MockSource)
    }
}

Describe "CacheDownloader Module" {
    Context "Get-CacheFileName" {
        It "Should generate structured file names" {
            $result = Get-CacheFileName -Source $script:MockSource
            
            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeLike "*win32*x64*TestTool*1.0.0*"
        }
        
        It "Should handle special characters in names" {
            $sourceWithSpecialChars = $script:MockSource.Clone()
            $sourceWithSpecialChars.name = "Test-Tool@2023"
            $sourceWithSpecialChars.version = "1.0-beta.1"
            
            $result = Get-CacheFileName -Source $sourceWithSpecialChars
            
            $result | Should -Not -BeNullOrEmpty
            $result | Should -Not -Match '[<>:"|?*]'  # Should not contain invalid path characters
        }
        
        It "Should extract filename from URL" {
            $sourceWithFilename = $script:MockSource.Clone()
            $sourceWithFilename.downloadUrl = "https://example.com/path/tool-1.0.0.msi"
            
            $result = Get-CacheFileName -Source $sourceWithFilename
            
            $result | Should -BeLike "*tool-1.0.0.msi"
        }
        
        It "Should generate filename when URL doesn't contain one" {
            $sourceWithoutFilename = $script:MockSource.Clone()
            $sourceWithoutFilename.downloadUrl = "https://example.com/download?id=123"
            
            $result = Get-CacheFileName -Source $sourceWithoutFilename
            
            $result | Should -BeLike "*TestTool-1.0.0.bin"
        }
    }
    
    Context "Start-SingleDownload" {
        BeforeEach {
            $script:TestCacheDir = Join-Path $TestDataPath "cache"
            if (Test-Path $script:TestCacheDir) {
                Remove-Item $script:TestCacheDir -Recurse -Force
            }
            New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
        }
        
        It "Should download file successfully" {
            # Mock successful download
            Mock -ModuleName CacheDownloader New-Object {
                param($TypeName)
                if ($TypeName -eq "System.Net.WebClient") {
                    return [PSCustomObject]@{
                        DownloadFile = { 
                            param($url, $path)
                            # Create empty file to simulate download
                            "" | Set-Content $path
                        }
                        Dispose = { }
                    }
                }
            }
            
            Mock Get-FileHash { 
                return @{ Hash = $script:MockSource.sha256 }
            }
            
            $result = Start-SingleDownload -Source $script:MockSource -CacheDirectory $script:TestCacheDir -VerifyChecksums
            
            $result.Status | Should -Be "Downloaded"
            $result.Name | Should -Be $script:MockSource.name
            $result.Version | Should -Be $script:MockSource.version
            $result.FilePath | Should -Not -BeNullOrEmpty
        }
        
        It "Should skip existing files when SkipExisting is specified" {
            # Create existing file
            $fileName = Get-CacheFileName -Source $script:MockSource
            $filePath = Join-Path $script:TestCacheDir $fileName
            $fileDir = Split-Path $filePath -Parent
            New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
            "" | Set-Content $filePath
            
            $result = Start-SingleDownload -Source $script:MockSource -CacheDirectory $script:TestCacheDir -SkipExisting
            
            $result.Status | Should -Be "Skipped"
            $result.Reason | Should -Be "Already exists"
        }
        
        It "Should retry on download failure" {
            $script:DownloadAttempts = 0
            
            Mock -ModuleName CacheDownloader New-Object {
                param($TypeName)
                if ($TypeName -eq "System.Net.WebClient") {
                    return [PSCustomObject]@{
                        DownloadFile = { 
                            $script:DownloadAttempts++
                            if ($script:DownloadAttempts -lt 3) {
                                throw "Network error"
                            }
                            # Succeed on third attempt
                            "" | Set-Content $args[1]
                        }
                        Dispose = { }
                    }
                }
            }
            
            Mock Get-FileHash { 
                return @{ Hash = $script:MockSource.sha256 }
            }
            
            $result = Start-SingleDownload -Source $script:MockSource -CacheDirectory $script:TestCacheDir -MaxRetries 3 -VerifyChecksums
            
            $result.Status | Should -Be "Downloaded"
            $script:DownloadAttempts | Should -Be 3
        }
        
        It "Should fail after max retries" {
            Mock -ModuleName CacheDownloader New-Object {
                param($TypeName)
                if ($TypeName -eq "System.Net.WebClient") {
                    return [PSCustomObject]@{
                        DownloadFile = { throw "Persistent network error" }
                        Dispose = { }
                    }
                }
            }
            
            $result = Start-SingleDownload -Source $script:MockSource -CacheDirectory $script:TestCacheDir -MaxRetries 2
            
            $result.Status | Should -Be "Error"
            $result.Error | Should -BeLike "*Persistent network error"
            $result.Attempts | Should -Be 2
        }
        
        It "Should fail checksum validation" {
            Mock -ModuleName CacheDownloader New-Object {
                param($TypeName)
                if ($TypeName -eq "System.Net.WebClient") {
                    return [PSCustomObject]@{
                        DownloadFile = { 
                            "different content" | Set-Content $args[1]
                        }
                        Dispose = { }
                    }
                }
            }
            
            Mock Get-FileHash { 
                return @{ Hash = "different_hash" }
            }
            
            $result = Start-SingleDownload -Source $script:MockSource -CacheDirectory $script:TestCacheDir -VerifyChecksums
            
            $result.Status | Should -Be "Error"
            $result.Error | Should -BeLike "*Checksum verification failed*"
        }
    }
    
    Context "Start-CacheDownload" {
        BeforeEach {
            $script:TestCacheDir = Join-Path $TestDataPath "cache"
            if (Test-Path $script:TestCacheDir) {
                Remove-Item $script:TestCacheDir -Recurse -Force
            }
            
            $script:TestSourceListPath = Join-Path $TestDataPath "sources.json"
            $script:MockSourceList | ConvertTo-Json -Depth 10 | Set-Content $script:TestSourceListPath
        }
        
        It "Should create cache directory if not exists" {
            Mock Start-SingleDownload {
                return @{
                    Name = $args[0].name
                    Version = $args[0].version
                    Status = "Downloaded"
                    FilePath = "test.zip"
                    FileSize = 1024
                }
            }
            
            $result = Start-CacheDownload -SourceListPath $script:TestSourceListPath -CacheDirectory $script:TestCacheDir
            
            $script:TestCacheDir | Should -Exist
            $result.Summary.Total | Should -Be 1
        }
        
        It "Should process all sources in list" {
            # Add more sources to test
            $multiSourceList = $script:MockSourceList.Clone()
            $multiSourceList.sources = @(
                $script:MockSource,
                @{
                    name = "AnotherTool"
                    version = "2.0.0"
                    platform = "win32"
                    arch = "x64"
                    downloadUrl = "https://example.com/another-tool.zip"
                    matchedFrom = @{ upstream = $true; toolset = "test.json" }
                }
            )
            
            $multiSourcePath = Join-Path $TestDataPath "multi-sources.json"
            $multiSourceList | ConvertTo-Json -Depth 10 | Set-Content $multiSourcePath
            
            Mock Start-SingleDownload {
                return @{
                    Name = $args[0].name
                    Version = $args[0].version
                    Status = "Downloaded"
                    FilePath = "test.zip"
                    FileSize = 1024
                }
            }
            
            $result = Start-CacheDownload -SourceListPath $multiSourcePath -CacheDirectory $script:TestCacheDir
            
            $result.Summary.Total | Should -Be 2
            $result.Summary.Downloaded | Should -Be 2
        }
        
        It "Should handle missing source list file" {
            { Start-CacheDownload -SourceListPath "missing.json" -CacheDirectory $script:TestCacheDir } | Should -Throw "Source list file not found*"
        }
        
        It "Should provide progress summary" {
            Mock Start-SingleDownload {
                param($Source)
                switch ($Source.name) {
                    "TestTool" { 
                        return @{ Name = $Source.name; Version = $Source.version; Status = "Downloaded" }
                    }
                    default { 
                        return @{ Name = $Source.name; Version = $Source.version; Status = "Error"; Error = "Failed" }
                    }
                }
            }
            
            # Create mixed result scenario
            $mixedSourceList = $script:MockSourceList.Clone()
            $mixedSourceList.sources = @(
                $script:MockSource,
                @{
                    name = "FailingTool"
                    version = "1.0.0"
                    platform = "win32"
                    arch = "x64"
                    downloadUrl = "https://example.com/failing-tool.zip"
                    matchedFrom = @{ upstream = $true; toolset = "test.json" }
                }
            )
            
            $mixedSourcePath = Join-Path $TestDataPath "mixed-sources.json"
            $mixedSourceList | ConvertTo-Json -Depth 10 | Set-Content $mixedSourcePath
            
            $result = Start-CacheDownload -SourceListPath $mixedSourcePath -CacheDirectory $script:TestCacheDir
            
            $result.Summary.Total | Should -Be 2
            $result.Summary.Downloaded | Should -Be 1
            $result.Summary.Errors | Should -Be 1
        }
    }
    
    Context "Test-CacheIntegrity" {
        BeforeEach {
            $script:TestCacheDir = Join-Path $TestDataPath "cache"
            if (Test-Path $script:TestCacheDir) {
                Remove-Item $script:TestCacheDir -Recurse -Force
            }
            New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
            
            $script:TestSourceListPath = Join-Path $TestDataPath "sources.json"
            $script:MockSourceList | ConvertTo-Json -Depth 10 | Set-Content $script:TestSourceListPath
        }
        
        It "Should verify file integrity with correct checksums" {
            # Create test file with correct hash
            $fileName = Get-CacheFileName -Source $script:MockSource
            $filePath = Join-Path $script:TestCacheDir $fileName
            $fileDir = Split-Path $filePath -Parent
            New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
            "" | Set-Content $filePath  # Empty file matches the hash in MockSource
            
            Mock Get-FileHash { 
                return @{ Hash = $script:MockSource.sha256 }
            }
            
            $result = Test-CacheIntegrity -SourceListPath $script:TestSourceListPath -CacheDirectory $script:TestCacheDir
            
            $result.Summary.Valid | Should -Be 1
            $result.Summary.Invalid | Should -Be 0
            $result.Summary.Missing | Should -Be 0
        }
        
        It "Should detect missing files" {
            $result = Test-CacheIntegrity -SourceListPath $script:TestSourceListPath -CacheDirectory $script:TestCacheDir
            
            $result.Summary.Missing | Should -Be 1
            $result.Summary.Valid | Should -Be 0
        }
        
        It "Should detect checksum mismatches" {
            # Create test file with wrong hash
            $fileName = Get-CacheFileName -Source $script:MockSource
            $filePath = Join-Path $script:TestCacheDir $fileName
            $fileDir = Split-Path $filePath -Parent
            New-Item -ItemType Directory -Path $fileDir -Force | Out-Null
            "different content" | Set-Content $filePath
            
            Mock Get-FileHash { 
                return @{ Hash = "wrong_hash" }
            }
            
            $result = Test-CacheIntegrity -SourceListPath $script:TestSourceListPath -CacheDirectory $script:TestCacheDir
            
            $result.Summary.Invalid | Should -Be 1
            $result.Summary.Valid | Should -Be 0
        }
    }
    
    Context "Get-CacheStatistics" {
        BeforeEach {
            $script:TestCacheDir = Join-Path $TestDataPath "cache"
            if (Test-Path $script:TestCacheDir) {
                Remove-Item $script:TestCacheDir -Recurse -Force
            }
        }
        
        It "Should return zero stats for empty/missing directory" {
            $result = Get-CacheStatistics -CacheDirectory $script:TestCacheDir
            
            $result.TotalFiles | Should -Be 0
            $result.TotalSize | Should -Be 0
            $result.TotalSizeFormatted | Should -Be "0 B"
        }
        
        It "Should calculate stats for populated directory" {
            New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
            
            # Create test files
            "file1" | Set-Content (Join-Path $script:TestCacheDir "file1.txt")
            "file2content" | Set-Content (Join-Path $script:TestCacheDir "file2.txt")
            
            $result = Get-CacheStatistics -CacheDirectory $script:TestCacheDir
            
            $result.TotalFiles | Should -Be 2
            $result.TotalSize | Should -BeGreaterThan 0
            $result.TotalSizeFormatted | Should -BeLike "* B"
            $result.Files | Should -HaveCount 2
        }
    }
    
    Context "Format-FileSize" {
        It "Should format bytes correctly" {
            Format-FileSize -Bytes 0 | Should -Be "0.00 B"
            Format-FileSize -Bytes 500 | Should -Be "500.00 B"
            Format-FileSize -Bytes 1024 | Should -Be "1.00 KB"
            Format-FileSize -Bytes 1048576 | Should -Be "1.00 MB"
            Format-FileSize -Bytes 1073741824 | Should -Be "1.00 GB"
        }
        
        It "Should handle large numbers" {
            Format-FileSize -Bytes 1099511627776 | Should -Be "1.00 TB"
        }
        
        It "Should format fractional units" {
            Format-FileSize -Bytes 1536 | Should -Be "1.50 KB"
            Format-FileSize -Bytes 2621440 | Should -Be "2.50 MB"
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
