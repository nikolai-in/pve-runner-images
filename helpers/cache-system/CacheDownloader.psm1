<#
.SYNOPSIS
    Downloads tools from cache source lists with robust error handling and retry logic.

.DESCRIPTION
    This module provides functionality to:
    - Download tools from generated source lists
    - Handle various download sources and formats
    - Verify downloads with SHA256 checksums
    - Organize downloads in a structured cache directory

.EXAMPLE
    Import-Module .\CacheDownloader.psm1
    Start-CacheDownload -SourceListPath ".\cache-sources.json" -CacheDirectory ".\cache"
#>

using namespace System.Collections.Generic

# Import required modules
$ErrorActionPreference = 'Stop'

function Start-CacheDownload {
    <#
    .SYNOPSIS
        Downloads all tools from a cache source list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceListPath,
        
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300,
        
        [Parameter(Mandatory = $false)]
        [switch]$SkipExisting,
        
        [Parameter(Mandatory = $false)]
        [switch]$VerifyChecksums
    )
    
    if (-not (Test-Path $SourceListPath)) {
        throw "Source list file not found: $SourceListPath"
    }
    
    # Load source list
    $sourceList = Get-Content $SourceListPath -Raw | ConvertFrom-Json
    Write-Host "Cache Download Started" -ForegroundColor Green
    Write-Host "Source List: $SourceListPath" -ForegroundColor Gray
    Write-Host "Cache Directory: $CacheDirectory" -ForegroundColor Gray
    Write-Host "Total Sources: $($sourceList.sources.Count)" -ForegroundColor Gray
    Write-Host ""
    
    # Ensure cache directory exists
    if (-not (Test-Path $CacheDirectory)) {
        New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
        Write-Host "✓ Created cache directory: $CacheDirectory" -ForegroundColor Green
    }
    
    $results = [List[object]]::new()
    $downloadedCount = 0
    $skippedCount = 0
    $errorCount = 0
    
    foreach ($source in $sourceList.sources) {
        $result = Start-SingleDownload -Source $source -CacheDirectory $CacheDirectory -MaxRetries $MaxRetries -TimeoutSeconds $TimeoutSeconds -SkipExisting:$SkipExisting -VerifyChecksums:$VerifyChecksums.IsPresent
        $results.Add($result)
        
        switch ($result.Status) {
            'Downloaded' { $downloadedCount++ }
            'Skipped' { $skippedCount++ }
            'Error' { $errorCount++ }
        }
        
        # Progress indicator
        $completed = $downloadedCount + $skippedCount + $errorCount
        $percent = [math]::Round(($completed / $sourceList.sources.Count) * 100, 1)
        Write-Progress -Activity "Downloading Cache" -Status "$completed of $($sourceList.sources.Count) processed ($percent%)" -PercentComplete $percent
    }
    
    Write-Progress -Activity "Downloading Cache" -Completed
    
    # Summary
    Write-Host ""
    Write-Host "Download Summary:" -ForegroundColor Green
    Write-Host "  Downloaded: $downloadedCount" -ForegroundColor Green
    Write-Host "  Skipped: $skippedCount" -ForegroundColor Yellow
    Write-Host "  Errors: $errorCount" -ForegroundColor Red
    
    if ($errorCount -gt 0) {
        Write-Host ""
        Write-Host "Failed Downloads:" -ForegroundColor Red
        $results | Where-Object { $_.Status -eq 'Error' } | ForEach-Object {
            Write-Host "  $($_.Name) $($_.Version): $($_.Error)" -ForegroundColor Red
        }
    }
    
    return @{
        Results = $results.ToArray()
        Summary = @{
            Total = $sourceList.sources.Count
            Downloaded = $downloadedCount
            Skipped = $skippedCount
            Errors = $errorCount
        }
    }
}

function Start-SingleDownload {
    <#
    .SYNOPSIS
        Downloads a single tool with retry logic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,
        
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300,
        
        [Parameter(Mandatory = $false)]
        [switch]$SkipExisting,
        
        [Parameter(Mandatory = $false)]
        [switch]$VerifyChecksums
    )
    
    $fileName = Get-CacheFileName -Source $Source
    $targetPath = Join-Path $CacheDirectory $fileName
    $targetDir = Split-Path $targetPath -Parent
    
    # Ensure target directory exists
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    
    # Check if file already exists
    if ((Test-Path $targetPath) -and $SkipExisting) {
        Write-Host "⚬ Skipped: $($Source.name) $($Source.version) (already exists)" -ForegroundColor Yellow
        return @{
            Name = $Source.name
            Version = $Source.version
            Status = 'Skipped'
            FilePath = $targetPath
            Reason = 'Already exists'
        }
    }
    
    $attempt = 1
    $lastError = $null
    
    while ($attempt -le $MaxRetries) {
        try {
            Write-Host "⬇ Downloading: $($Source.name) $($Source.version) (attempt $attempt)" -ForegroundColor Cyan
            
            # Download with progress
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($Source.downloadUrl, $targetPath)
            $webClient.Dispose()
            
            # Verify checksum if provided
            if ($VerifyChecksums.IsPresent -and $Source.sha256) {
                $actualHash = Get-FileHash -Path $targetPath -Algorithm SHA256
                if ($actualHash.Hash -ne $Source.sha256) {
                    Remove-Item $targetPath -Force
                    throw "Checksum verification failed. Expected: $($Source.sha256), Actual: $($actualHash.Hash)"
                }
            }
            
            Write-Host "✓ Downloaded: $($Source.name) $($Source.version)" -ForegroundColor Green
            
            return @{
                Name = $Source.name
                Version = $Source.version
                Status = 'Downloaded'
                FilePath = $targetPath
                FileSize = (Get-Item $targetPath).Length
                DownloadedAt = (Get-Date).ToUniversalTime().ToString('o')
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Warning "Download attempt $attempt failed: $lastError"
            
            # Clean up partial download
            if (Test-Path $targetPath) {
                Remove-Item $targetPath -Force -ErrorAction SilentlyContinue
            }
            
            if ($attempt -lt $MaxRetries) {
                $waitTime = [math]::Pow(2, $attempt - 1) * 2  # Exponential backoff: 2, 4, 8 seconds
                Write-Host "  Retrying in $waitTime seconds..." -ForegroundColor Yellow
                Start-Sleep -Seconds $waitTime
            }
            
            $attempt++
        }
    }
    
    Write-Host "✗ Failed: $($Source.name) $($Source.version) - $lastError" -ForegroundColor Red
    
    return @{
        Name = $Source.name
        Version = $Source.version
        Status = 'Error'
        Error = $lastError
        Attempts = $MaxRetries
    }
}

function Get-CacheFileName {
    <#
    .SYNOPSIS
        Generates a structured file name for cache storage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source
    )
    
    # Create a structured path: platform/arch/name/version/filename
    $platform = $Source.platform -replace '[^\w]', '_'
    $arch = $Source.arch -replace '[^\w]', '_'
    $name = $Source.name -replace '[^\w]', '_'
    $version = $Source.version -replace '[^\w\.]', '_'
    
    # Extract filename from URL
    $uri = [Uri]$Source.downloadUrl
    $originalFileName = [System.IO.Path]::GetFileName($uri.LocalPath)
    
    if ([string]::IsNullOrEmpty($originalFileName)) {
        # Generate filename if not available from URL
        $extension = if ($Source.downloadUrl -match '\.(zip|tar\.gz|tar\.bz2|exe|msi|dmg|pkg)(\?|$)') { $Matches[1] } else { 'bin' }
        $originalFileName = "$name-$version.$extension"
    }
    
    return Join-Path $platform (Join-Path $arch (Join-Path $name (Join-Path $version $originalFileName)))
}

function Test-CacheIntegrity {
    <#
    .SYNOPSIS
        Verifies the integrity of cached files using checksums.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceListPath,
        
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory
    )
    
    if (-not (Test-Path $SourceListPath)) {
        throw "Source list file not found: $SourceListPath"
    }
    
    $sourceList = Get-Content $SourceListPath -Raw | ConvertFrom-Json
    $results = [List[object]]::new()
    
    Write-Host "Verifying cache integrity..." -ForegroundColor Green
    
    foreach ($source in $sourceList.sources) {
        if (-not $source.sha256) {
            continue  # Skip sources without checksums
        }
        
        $fileName = Get-CacheFileName -Source $source
        $filePath = Join-Path $CacheDirectory $fileName
        
        if (-not (Test-Path $filePath)) {
            $results.Add(@{
                Name = $source.name
                Version = $source.version
                Status = 'Missing'
                FilePath = $filePath
            })
            continue
        }
        
        try {
            $actualHash = Get-FileHash -Path $filePath -Algorithm SHA256
            $isValid = $actualHash.Hash -eq $source.sha256
            
            $results.Add(@{
                Name = $source.name
                Version = $source.version
                Status = if ($isValid) { 'Valid' } else { 'Invalid' }
                FilePath = $filePath
                ExpectedHash = $source.sha256
                ActualHash = $actualHash.Hash
            })
            
            if (-not $isValid) {
                Write-Warning "Checksum mismatch: $($source.name) $($source.version)"
            }
        }
        catch {
            $results.Add(@{
                Name = $source.name
                Version = $source.version
                Status = 'Error'
                FilePath = $filePath
                Error = $_.Exception.Message
            })
        }
    }
    
    $summary = @{
        Total = $results.Count
        Valid = ($results | Where-Object { $_.Status -eq 'Valid' }).Count
        Invalid = ($results | Where-Object { $_.Status -eq 'Invalid' }).Count
        Missing = ($results | Where-Object { $_.Status -eq 'Missing' }).Count
        Errors = ($results | Where-Object { $_.Status -eq 'Error' }).Count
    }
    
    Write-Host "Integrity Check Summary:" -ForegroundColor Green
    Write-Host "  Valid: $($summary.Valid)" -ForegroundColor Green
    Write-Host "  Invalid: $($summary.Invalid)" -ForegroundColor Red
    Write-Host "  Missing: $($summary.Missing)" -ForegroundColor Yellow
    Write-Host "  Errors: $($summary.Errors)" -ForegroundColor Red
    
    return @{
        Results = $results.ToArray()
        Summary = $summary
    }
}

function Get-CacheStatistics {
    <#
    .SYNOPSIS
        Gets statistics about the cache directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory
    )
    
    if (-not (Test-Path $CacheDirectory)) {
        return @{
            TotalFiles = 0
            TotalSize = 0
            TotalSizeFormatted = "0 B"
        }
    }
    
    $files = Get-ChildItem -Path $CacheDirectory -Recurse -File
    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
    
    return @{
        TotalFiles = $files.Count
        TotalSize = $totalSize
        TotalSizeFormatted = Format-FileSize -Bytes $totalSize
        Files = $files
    }
}

function Format-FileSize {
    <#
    .SYNOPSIS
        Formats file size in human-readable format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )
    
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    $size = [double]$Bytes
    
    while ($size -ge 1024 -and $index -lt ($units.Length - 1)) {
        $size /= 1024
        $index++
    }
    
    return "{0:N2} {1}" -f $size, $units[$index]
}

# Export functions
Export-ModuleMember -Function @(
    'Start-CacheDownload',
    'Test-CacheIntegrity',
    'Get-CacheStatistics',
    'Get-CacheFileName'
)
