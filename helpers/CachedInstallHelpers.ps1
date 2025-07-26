################################################################################
##  File:  CachedInstallHelpers.ps1
##  Desc:  Modified installation helpers that use pre-downloaded cache
##  Usage: Replace Install-Binary and Invoke-DownloadWithRetry calls with cached versions
################################################################################

$ErrorActionPreference = "Stop"

# Global cache configuration
$Script:CacheConfig = @{
    Location = $null
    Manifest = $null
    Enabled  = $false
}

#region Cache Management Functions

function Initialize-BuildCache {
    <#
    .SYNOPSIS
    Initialize the build cache for use during image provisioning
    
    .PARAMETER CacheLocation
    Path to the pre-built cache directory
    
    .PARAMETER Platform
    Platform identifier (windows, ubuntu, macos)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheLocation,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet("windows", "ubuntu", "macos")]
        [string]$Platform
    )
    
    if (-not (Test-Path $CacheLocation)) {
        throw "Cache location does not exist: $CacheLocation"
    }
    
    $manifestPath = Join-Path $CacheLocation "cache-manifest.json"
    if (-not (Test-Path $manifestPath)) {
        throw "Cache manifest not found: $manifestPath"
    }
    
    $Script:CacheConfig.Location = $CacheLocation
    $Script:CacheConfig.Manifest = Get-Content $manifestPath | ConvertFrom-Json
    $Script:CacheConfig.Enabled = $true
    
    # Validate platform matches
    if ($Script:CacheConfig.Manifest.Platform -ne $Platform) {
        Write-Warning "Cache platform mismatch. Expected: $Platform, Found: $($Script:CacheConfig.Manifest.Platform)"
    }
    
    Write-Host "Build cache initialized successfully" -ForegroundColor Green
    Write-Host "  Location: $CacheLocation"
    Write-Host "  Platform: $($Script:CacheConfig.Manifest.Platform)"
    Write-Host "  Generated: $($Script:CacheConfig.Manifest.GeneratedAt)"
    Write-Host "  Total cached files: $($Script:CacheConfig.Manifest.Downloads.Count)"
}

function Find-CachedFile {
    <#
    .SYNOPSIS
    Find a cached file by URL
    
    .PARAMETER Url
    The original download URL
    
    .OUTPUTS
    Hashtable with cache entry information or $null if not found
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )
    
    if (-not $Script:CacheConfig.Enabled) {
        return $null
    }
    
    $cacheEntry = $Script:CacheConfig.Manifest.Downloads | Where-Object { $_.Url -eq $Url }
    if ($cacheEntry) {
        $fullPath = Join-Path $Script:CacheConfig.Location $cacheEntry.CachePath
        if (Test-Path $fullPath) {
            return @{
                Entry    = $cacheEntry
                FullPath = $fullPath
            }
        } else {
            Write-Warning "Cached file not found: $fullPath"
        }
    }
    
    return $null
}

function Test-CacheEnabled {
    <#
    .SYNOPSIS
    Check if cache is enabled and available
    #>
    return $Script:CacheConfig.Enabled
}

function Get-CacheStatistics {
    <#
    .SYNOPSIS
    Get cache usage statistics
    #>
    if (-not $Script:CacheConfig.Enabled) {
        return @{ CacheEnabled = $false }
    }
    
    return @{
        CacheEnabled = $true
        Location     = $Script:CacheConfig.Location
        Platform     = $Script:CacheConfig.Manifest.Platform
        TotalFiles   = $Script:CacheConfig.Manifest.Downloads.Count
        Statistics   = $Script:CacheConfig.Manifest.Statistics
    }
}

#endregion

#region Enhanced Installation Functions

function Install-BinaryFromCache {
    <#
    .SYNOPSIS
    Enhanced Install-Binary that uses cache when available, falls back to download
    
    .PARAMETER Url
    Download URL
    
    .PARAMETER Type
    Installation type (MSI, EXE, ZIP)
    
    .PARAMETER InstallArgs
    Installation arguments
    
    .PARAMETER ExpectedSHA256Sum
    Expected SHA256 checksum
    
    .PARAMETER ExpectedSHA512Sum  
    Expected SHA512 checksum
    
    .PARAMETER ExpectedSignature
    Expected code signature
    
    .PARAMETER ExpectedSubject
    Expected certificate subject
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("MSI", "EXE", "ZIP")]
        [string]$Type = "EXE",
        
        [Parameter(Mandatory = $false)]
        [string[]]$InstallArgs = @(),
        
        [Parameter(Mandatory = $false)]
        [string]$ExpectedSHA256Sum = $null,
        
        [Parameter(Mandatory = $false)]
        [string]$ExpectedSHA512Sum = $null,
        
        [Parameter(Mandatory = $false)]
        [string]$ExpectedSignature = $null,
        
        [Parameter(Mandatory = $false)]
        [string]$ExpectedSubject = $null
    )
    
    Write-Host "Installing binary from: $Url" -ForegroundColor Yellow
    
    # Try to use cache first
    $cachedFile = Find-CachedFile -Url $Url
    if ($cachedFile) {
        Write-Host "  [CACHE HIT] Using cached file: $($cachedFile.Entry.FileName)" -ForegroundColor Green
        $filePath = $cachedFile.FullPath
        
        # Use cached checksum if not provided
        if (-not $ExpectedSHA256Sum -and $cachedFile.Entry.ExpectedSHA256) {
            $ExpectedSHA256Sum = $cachedFile.Entry.ExpectedSHA256
        }
        if (-not $ExpectedSHA512Sum -and $cachedFile.Entry.ExpectedSHA512) {
            $ExpectedSHA512Sum = $cachedFile.Entry.ExpectedSHA512
        }
    } else {
        Write-Host "  [CACHE MISS] Downloading file..." -ForegroundColor Yellow
        # Fall back to original download logic
        $fileName = Split-Path $Url -Leaf
        $filePath = Join-Path $env:TEMP $fileName
        
        # Download with retry logic (simplified version)
        try {
            Invoke-WebRequest -Uri $Url -OutFile $filePath -UseBasicParsing
        } catch {
            throw "Failed to download $Url : $_"
        }
    }
    
    # Validate checksums
    if ($ExpectedSHA256Sum) {
        $actualHash = (Get-FileHash $filePath -Algorithm SHA256).Hash
        if ($actualHash -ne $ExpectedSHA256Sum) {
            throw "SHA256 checksum validation failed for $Url"
        }
        Write-Host "  ✓ SHA256 checksum validated" -ForegroundColor Green
    }
    
    if ($ExpectedSHA512Sum) {
        $actualHash = (Get-FileHash $filePath -Algorithm SHA512).Hash
        if ($actualHash -ne $ExpectedSHA512Sum) {
            throw "SHA512 checksum validation failed for $Url"
        }
        Write-Host "  ✓ SHA512 checksum validated" -ForegroundColor Green
    }
    
    # Validate signature if specified
    if ($ExpectedSignature -or $ExpectedSubject) {
        $signature = Get-AuthenticodeSignature $filePath
        if ($ExpectedSignature -and $signature.SignerCertificate.Thumbprint -ne $ExpectedSignature) {
            throw "Code signature validation failed for $Url"
        }
        if ($ExpectedSubject -and $signature.SignerCertificate.Subject -ne $ExpectedSubject) {
            throw "Certificate subject validation failed for $Url"
        }
        Write-Host "  ✓ Code signature validated" -ForegroundColor Green
    }
    
    # Install based on type
    switch ($Type) {
        "MSI" {
            $installCmd = "msiexec.exe"
            $installArgs = @("/i", $filePath, "/quiet") + $InstallArgs
        }
        "EXE" {
            $installCmd = $filePath
        }
        "ZIP" {
            # Handle ZIP extraction
            throw "ZIP installation not implemented in this example"
        }
    }
    
    Write-Host "  Installing: $installCmd $($InstallArgs -join ' ')" -ForegroundColor Cyan
    if ($Type -ne "ZIP") {
        $process = Start-Process -FilePath $installCmd -ArgumentList $InstallArgs -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Installation failed with exit code: $($process.ExitCode)"
        }
    }
    
    Write-Host "  Installation completed successfully" -ForegroundColor Green
    
    # Cleanup temp file if it was downloaded (not from cache)
    if (-not $cachedFile -and (Test-Path $filePath) -and $filePath.StartsWith($env:TEMP)) {
        Remove-Item $filePath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DownloadWithCacheRetry {
    <#
    .SYNOPSIS
    Enhanced Invoke-DownloadWithRetry that uses cache when available
    
    .PARAMETER Url
    Download URL
    
    .PARAMETER Path
    Destination path (if not specified, returns path to cached/downloaded file)
    
    .PARAMETER ExpectedSHA256Sum
    Expected SHA256 checksum
    
    .PARAMETER ExpectedSHA512Sum
    Expected SHA512 checksum
    
    .PARAMETER MaxRetries
    Maximum retry attempts for downloads
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [Parameter(Mandatory = $false)]
        [string]$Path = $null,
        
        [Parameter(Mandatory = $false)]
        [string]$ExpectedSHA256Sum = $null,
        
        [Parameter(Mandatory = $false)]
        [string]$ExpectedSHA512Sum = $null,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3
    )
    
    Write-Host "Downloading: $Url" -ForegroundColor Yellow
    
    # Try cache first
    $cachedFile = Find-CachedFile -Url $Url
    if ($cachedFile) {
        Write-Host "  [CACHE HIT] Using cached file: $($cachedFile.Entry.FileName)" -ForegroundColor Green
        $sourcePath = $cachedFile.FullPath
        
        # Use cached checksums if not provided
        if (-not $ExpectedSHA256Sum -and $cachedFile.Entry.ExpectedSHA256) {
            $ExpectedSHA256Sum = $cachedFile.Entry.ExpectedSHA256
        }
        if (-not $ExpectedSHA512Sum -and $cachedFile.Entry.ExpectedSHA512) {
            $ExpectedSHA512Sum = $cachedFile.Entry.ExpectedSHA512
        }
    } else {
        Write-Host "  [CACHE MISS] Downloading with retry..." -ForegroundColor Yellow
        $fileName = Split-Path $Url -Leaf
        $sourcePath = Join-Path $env:TEMP $fileName
        
        # Download with retry logic
        $retryCount = 0
        while ($retryCount -lt $MaxRetries) {
            try {
                Invoke-WebRequest -Uri $Url -OutFile $sourcePath -UseBasicParsing
                break
            } catch {
                $retryCount++
                if ($retryCount -ge $MaxRetries) {
                    throw "Failed to download $Url after $MaxRetries attempts: $_"
                }
                Write-Warning "Download attempt $retryCount failed, retrying... $_"
                Start-Sleep -Seconds (2 * $retryCount)
            }
        }
    }
    
    # Validate checksums
    if ($ExpectedSHA256Sum) {
        $actualHash = (Get-FileHash $sourcePath -Algorithm SHA256).Hash
        if ($actualHash -ne $ExpectedSHA256Sum) {
            throw "SHA256 checksum validation failed for $Url"
        }
        Write-Host "  ✓ SHA256 checksum validated" -ForegroundColor Green
    }
    
    if ($ExpectedSHA512Sum) {
        $actualHash = (Get-FileHash $sourcePath -Algorithm SHA512).Hash
        if ($actualHash -ne $ExpectedSHA512Sum) {
            throw "SHA512 checksum validation failed for $Url"
        }
        Write-Host "  ✓ SHA512 checksum validated" -ForegroundColor Green
    }
    
    # Copy to destination if specified
    if ($Path) {
        $destinationDir = Split-Path $Path -Parent
        if ($destinationDir -and -not (Test-Path $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }
        
        if ($cachedFile) {
            # Copy from cache
            Copy-Item $sourcePath $Path -Force
            Write-Host "  Copied from cache to: $Path" -ForegroundColor Green
        } else {
            # Move downloaded file
            Move-Item $sourcePath $Path -Force
            Write-Host "  Downloaded to: $Path" -ForegroundColor Green
        }
        
        return $Path
    } else {
        # Return path to file (cache or temp)
        return $sourcePath
    }
}

#endregion

#region Backward Compatibility Aliases

# Create aliases to replace original functions seamlessly
Set-Alias -Name "Install-Binary" -Value "Install-BinaryFromCache" -Force
Set-Alias -Name "Invoke-DownloadWithRetry" -Value "Invoke-DownloadWithCacheRetry" -Force

#endregion

# Only export if running as a module
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
    # Running as script - functions are available in calling scope
    Write-Host "Cache functions loaded directly" -ForegroundColor Green
} else {
    # Running as module - export functions
    Export-ModuleMember -Function Initialize-BuildCache, Find-CachedFile, Test-CacheEnabled, Get-CacheStatistics, Install-BinaryFromCache, Invoke-DownloadWithCacheRetry
    Export-ModuleMember -Alias Install-Binary, Invoke-DownloadWithRetry
}
