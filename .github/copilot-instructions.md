# GitHub Actions Runner Images - AI Agent Instructions (Updated)

## AI Agent Personality

**Communication Style**: Adopt a professional, technically-focused approach with dry humor when appropriate. Maintain technical accuracy while delivering straightforward solutions. Avoid excessive personality, marketing language, or GLaDOS/Portal references. Use emojis sparingly as visual accents, not as excessive decoration.

**Code Quality Standards**: Prioritize functional, reliable code over flashy presentation. Write clear, descriptive comments without corporate marketing speak. Focus on technical precision rather than feature advertising.

## Code Style Guidelines

**Comments and Documentation**: Use straightforward, technical descriptions without marketing language. Avoid terms like "intelligent", "enhanced", "advanced", or "powerful" when describing functionality. Focus on what the code does, not how impressive it is.

**Emoji Usage**: Use emojis sparingly as visual accents in output formatting. Acceptable uses:

- 📊 for analysis results headers
- 📈 for metrics and coverage displays
- ✓/✗ for status indicators
- • for bullet points
  Avoid excessive emoji decoration in code comments or console output.

**Personality**: Maintain professional tone without GLaDOS references, Portal jokes, or sarcastic commentary. Provide dry, functional explanations focused on technical accuracy.

## Project Architecture

This repository builds virtual machine images for GitHub Actions hosted runners using **Packer templates** and **PowerShell provisioning scripts**. The codebase is organized by platform (`images/windows/`, `images/ubuntu/`, `images/macos/`) with shared utilities in `helpers/`.

### Key Components

- **Packer Templates** (`images/{platform}/templates/*.pkr.hcl`): HCL2 configurations defining VM builds, sources, and provisioning steps
- **Installation Scripts** (`images/{platform}/scripts/build/Install-*.ps1`): Individual software installation scripts following naming convention `Install-{ToolName}.ps1`
- **Toolsets** (`images/{platform}/toolsets/toolset-*.json`): JSON definitions of software versions and toolcache configurations
- **Helpers** (`helpers/`): PowerShell utilities for cache management, URL discovery, and software inventory

## Critical Workflows

### Building Images

```bash
# Build Windows 2025 image
packer build -only="windows-2025.runner" images/windows/templates/

# Debug build with WinRM access
packer build -only="windows-2025.winrm" -var="winrm_host=IP" images/windows/templates/
```

### Cache System (Current Development Status)

**IMPORTANT**: The cache system has undergone significant development on the `feature/download-cache-system` branch. Key developments include:

```powershell
# Current working cache operations
.\CacheManager-Simple.ps1 -Action Status -Platform windows      # Status checking
.\Build-DownloadCache.ps1 -Platform windows                     # Cache building
.\Compare-CacheStatus.ps1 -OutputFormat Table                   # Status reporting
```

**Architecture Evolution**:

1. **Initial State**: Broken Build-SoftwareInventory.ps1 with regex parsing failures
2. **Phase 1**: Implemented authoritative upstream data parsing from GitHub Actions JSON reports
3. **Phase 2**: Created unified CacheManager system with modular architecture
4. **Current Status**: Working CacheManager-Simple.ps1 with 13.5% coverage (10/74 URLs cached)

**VS Code Tasks**: Use `Ctrl+Shift+P` → "Tasks: Run Task" for: Build Cache, Discover URLs, Cache Report

## Software Installation Patterns

### Standard Installation Script Structure

```powershell
# Get version from toolset
$version = (Get-ToolsetContent).{toolname}.version

# Download with retry
$downloadUrl = "https://example.com/tool-${version}.msi"
$installerPath = Invoke-DownloadWithRetry $downloadUrl

# Install with error handling
Start-Process $installerPath -ArgumentList "/quiet" -Wait
if ($LastExitCode -ne 0) { exit $LastExitCode }
```

### Toolset Integration

- **toolcache**: Tools managed by GitHub Actions setup-\* actions (Node.js, Python, Go, Ruby)
- **docker.images**: Container images to pre-pull
- **{tool}.version**: Version pinning for reproducible builds

## Project-Specific Conventions

### File Organization

- Scripts named `Install-{ExactToolName}.ps1` (case-sensitive, matches tool branding)
- Platform-specific toolsets: `toolset-2025.json`, `toolset-2022.json`
- Shared utilities use verb-noun PowerShell naming: `Get-CacheUrls.ps1`, `Build-DownloadCache.ps1`

### Error Handling

```powershell
# Standard pattern in installation scripts
if ($LastExitCode -ne 0) {
    Write-Host "Installation failed with exit code $LastExitCode"
    exit $LastExitCode
}
```

### Helper Functions

- `Get-ToolsetContent`: Reads current platform's toolset.json
- `Invoke-DownloadWithRetry`: Downloads with automatic retry logic
- `Get-GithubReleasesByVersion`: Fetches GitHub release metadata

## Cache System Development Log

### Current Branch Status: `feature/download-cache-system`

**Achievements**:

- ✅ Fixed Build-SoftwareInventory.ps1 to parse upstream JSON hierarchically (90 upstream + 5 toolset items)
- ✅ Updated Compare-CacheStatus.ps1 to integrate software inventory + enhanced cache manifest
- ✅ Resolved data inconsistencies (unified reporting of 74 URLs with 13.5% coverage)
- ✅ Created comprehensive CacheManager architecture with 4 specialized modules
- ✅ Implemented working CacheManager-Simple.ps1 as functional fallback

**Key Files Created/Modified**:

- `CacheManager.ps1` - Main orchestrator (modular version with PowerShell class issues)
- `CacheManager-Simple.ps1` - Working functional version
- `UrlResolver.psm1` - URL resolution with variables/redirects
- `DownloadEngine.psm1` - Parallel downloading with retry logic
- `CacheValidator.psm1` - File integrity validation and health checking
- `ReportGenerator.psm1` - Reporting (Table/JSON/Markdown)
- `cache-config.json` - Configuration file for system settings
- `software-inventory.json` - Record of 95 software items

**Current System Status**:

- Coverage: 13.5% (10 of 74 URLs successfully cached)
- Cache Size: 191.74 MB across 16 files
- Data Sources: Software inventory + cache manifest
- Integration: Works with existing Compare-CacheStatus.ps1

**Known Issues**:

- PowerShell class instantiation issues in modular CacheManager.ps1
- Some URL resolution patterns need refinement
- Build functionality partially implemented

### Recommended Next Steps

1. **Branch Strategy**: Create new branch `feature/cache-system-v2` for clean implementation
2. **Architecture Decision**: Focus on functional approach over PowerShell classes
3. **Priority**: Complete the Build-Cache functionality with proper URL resolution
4. **Testing**: Implement comprehensive test coverage for cache operations

## External Dependencies

### Build Requirements

- **Packer 1.8.2+**: Image generation engine
- **Azure CLI**: Authentication for Azure resource creation
- **PowerShell Core**: Cross-platform script execution

### Package Managers by Platform

- **Windows**: Chocolatey (no third-party repos)
- **Ubuntu**: APT with 15+ third-party repositories (Docker, MongoDB, etc.)
- **macOS**: Homebrew with AWS CLI, Azure Bicep, MongoDB taps

## Software Support Policies

### Version Strategy

- **LTS Tools**: Java (all LTS), .NET Core (2 latest LTS + 1 latest)
- **Multiple Versions**: Node.js (3 latest LTS), Python/Ruby (5 popular major.minor)
- **Single Version**: Xcode (one major per macOS), Chrome (latest only)

### Update Cadence

- **Weekly**: Software updates deployed to images
- **2 weeks notice**: Default version changes (1 month for dangerous updates)
- **6 months**: Tool removal after deprecation/EOL

## Development Workflow Recommendations

When continuing cache system development:

1. **Start Fresh**: Create new branch to avoid accumulated technical debt
2. **Functional First**: Prioritize working functionality over elegant architecture
3. **Incremental Testing**: Test each component thoroughly before integration
4. **Documentation**: Maintain clear development log of decisions and outcomes
5. **Integration Points**: Leverage existing working components where possible

The previous cache system rewrite provided valuable lessons about PowerShell module architecture and the importance of pragmatic over theoretical approaches to system design.

## Cache System Architecture (Lessons Learned)

The cache system development revealed important architectural insights:

### Data Sources Integration

1. **Upstream JSON Reports**: `https://github.com/actions/runner-images/releases/download/win25%2F20250720.1/internal.windows-2025.json`
2. **Software Inventory**: Generated from upstream data + local toolsets (95 items total)
3. **Enhanced Cache Manifest**: URL discovery with 74 URLs from various sources
4. **Toolset Definitions**: Local `toolset-*.json` files for version pinning

### URL Resolution

- **Variable Resolution**: Resolves `${version}` placeholders from toolsets
- **GitHub Latest Mapping**: Converts to `/releases/latest/download/` patterns
- **Redirect Following**: Handles `aka.ms` and `go.microsoft.com` redirects
- **Package Manager Integration**: Includes Chocolatey/NuGet package URLs

### PowerShell Implementation Notes

- **Class-based Architecture**: Encountered instantiation issues with complex module imports
- **Functional Approach**: CacheManager-Simple.ps1 proves more reliable for PowerShell execution
- **Module System**: PowerShell's module system requires careful handling of class definitions
- **Integration Strategy**: Calling existing scripts (Compare-CacheStatus.ps1) more reliable than reimplementation
