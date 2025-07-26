# Download Cache System

A download caching system for GitHub runner image builds that pre-downloads packages and installers to improve build performance and reliability.

**Current Status**: Windows platform only. Ubuntu/macOS support planned for future releases.

## Overview

The system works in two simple steps:

1. **Generate Cache**: Extract URLs from Windows scripts/toolsets and download files locally
2. **Use Cache**: Run build scripts with cache-aware functions that check cache first

## Quick Start

### 1. Generate Cache

```powershell
# Generate cache for Windows platform
.\helpers\Build-DownloadCache.ps1 -CacheLocation "D:\BuildCache" -Platform "windows"

# Preview what would be downloaded (dry run)
.\helpers\Build-DownloadCache.ps1 -CacheLocation "D:\BuildCache" -Platform "windows" -WhatIf
```

### 2. Use Cache During Build

```powershell
# Initialize cache environment (makes cache-aware functions available)
.\helpers\Initialize-CacheEnvironment.ps1 -CacheLocation "D:\BuildCache" -Platform "windows"

# Run existing build scripts - they automatically check cache first
& .\scripts\build\Install-PowershellCore.ps1
& .\scripts\build\Install-Docker.ps1
```

## Architecture

### Cache Structure

```text
BuildCache/
├── cache-manifest.json           # Metadata and URL mappings
├── packages/                     # Downloaded installers, binaries
│   ├── <hash>_<filename>
│   └── ...
└── manifests/                    # Version manifests from GitHub
    ├── <hash>_versions-manifest.json
    └── ...
```

### URL Extraction

- **Toolsets**: Parses `toolset-*.json` files for manifest URLs
- **Scripts**: Uses regex patterns to find download URLs in PowerShell scripts
- **Patterns**: `Install-Binary -Url`, `Invoke-DownloadWithRetry -Url`, variable assignments

## Benefits

- **Performance**: Eliminates repeated downloads
- **Reliability**: Reduces network dependencies during builds
- **Security**: Pre-validated checksums and controlled environment
- **Compatibility**: Zero changes required to existing scripts
- **Offline**: Builds can work without internet after cache generation

## Files

- `helpers/Build-DownloadCache.ps1` - Cache generation script
- `helpers/CachedInstallHelpers.ps1` - Enhanced installation functions
- `helpers/Initialize-CacheEnvironment.ps1` - Environment setup
- `docs/download-cache.md` - This documentation
