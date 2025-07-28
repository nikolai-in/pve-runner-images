# Copilot Instructions for PVE Runner Images

## Project Overview

This repository creates VM images for GitHub Actions self-hosted runners using Packer and Proxmox VE. The images include pre-installed development tools and software for Windows, Ubuntu, and macOS platforms.

## Current Focus: Simple Cache System Design

### Design Principles

1. **Simplicity First**: Minimal amount of scripts with clear, focused functionality
2. **Just Enough**: Only implement features that directly serve the main goal
3. **Maintainable**: Easy to understand, debug, and extend
4. **Reliable**: Robust error handling and retry logic
5. **Tested**: Ensure functionality through pester tests

### Architecture & Data Sources

**Data Sources:**

- **Upstream Software Reports**: JSON artifacts from [actions/runner-images releases](https://github.com/actions/runner-images/releases/download/win25%2F20250720.1/internal.windows-2025.json) containing node trees of installed software
- **Toolset Files**: Local image template toolset files defining required tools and versions

**Development Location**: All cache system code should be developed in a subfolder within the `helpers/` directory

### Core Features (4 Main Components)

1. **Source List Builder**

   - Parse upstream software report JSON node trees
   - Match with local toolset files
   - Generate source list JSON with matched tools
   - Support updating existing lists and manual editing

2. **Cache Downloader**

   - Download tools from generated source lists
   - Handle various download sources and formats

3. **Cache Reporter**

   - Generate reports on cache coverage
   - Show cache composition and statistics

4. **Pester Tests**
   - Comprehensive test coverage for all components
   - Validate JSON schemas and functionality

### Technical Requirements

- **Language**: PowerShell only (maintain consistency with existing codebase)
- **JSON Schema**: All JSON files must have defined schemas
- **Testing**: Complete Pester test coverage for all functionality
