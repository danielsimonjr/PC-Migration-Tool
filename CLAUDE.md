# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Ultimate PC Migration Toolkit v2.1 - a PowerShell script for migrating installed Win32 applications between Windows PCs. It backs up application files, registry keys, and package manager lists (Winget/Chocolatey), then restores them on a target system.

## Running the Script

```powershell
# Must run as Administrator
.\Ultimate-PC-Migration-Toolkit-v2.ps1
```

The script launches an interactive menu with options:
1. Full Backup - Scans registry for installed apps, copies files, exports registry keys
2. Restore from Backup - Restores files and imports registry from backup
3. View Inventory - Shows backup statistics
4. Export Package Managers Only - Exports Winget/Chocolatey package lists

## Architecture

The script is a single PowerShell file (~1200 lines) organized into sections:

### Configuration (Lines 25-43)
Global `$Global:Config` hashtable controls:
- `BackupDrive` - Target path for backups
- `EnableFileHashing` / `HashOnlyExecutables` - Performance vs integrity tradeoff
- `MaxFileSize` - Skip files larger than 2GB
- `ExcludedPaths` - System paths to skip (WinSxS, Installer, DriverStore)

### Key Functions

**Utility Functions (55-186)**
- `Write-Log` - Colored console + file logging
- `Get-SafeFolderName` - Creates collision-resistant folder names using hash suffix
- `Test-PathTraversal` - Security check for path traversal attacks

**Package Manager Detection (192-275)**
- `Get-WingetPackages` / `Get-ChocolateyPackages` - Parse package lists

**Application Inventory (281-460)**
- `Get-InstalledApplications` - Reads from HKLM/HKCU Uninstall registry keys
- `Get-ApplicationFiles` - Scans InstallLocation directories
- `Get-ApplicationRegistryKeys` - Finds app-specific registry keys

**Backup Functions (466-690)**
- `Backup-ApplicationFiles` - Copies files with path traversal protection
- `Backup-ApplicationRegistry` - Exports registry keys to .reg files
- `Export-PackageManagerLists` - Uses `winget export` and `choco export`

**Restore Functions (850-1104)**
- `Restore-PackageManagers` - Uses `winget import` and `choco install`
- `Restore-ApplicationFiles` - Copies from backup with system directory warnings
- `Restore-ApplicationRegistry` - Imports .reg files with autostart key detection

**Orchestration (696-844, 1110-1190)**
- `Start-FullSystemBackup` - Main backup workflow with disk space checks
- `Start-ApplicationRestoration` - Main restore workflow
- `Start-InteractiveMode` - Menu loop

### Output Structure
Backups create this folder structure at `BackupDrive`:
```
migration.log           # Timestamped log file
inventory.json          # Full backup metadata (JSON, Depth 20)
Applications/           # Copied application files per-app
RegistryExports/        # .reg files for each app
PackageManagers/        # winget_packages.json, chocolatey_packages.config
```

## Security Considerations

The script includes several security features:
- Path traversal protection via `Test-PathTraversal`
- Warnings before restoring to `C:\Windows` or `WindowsApps`
- Detection of autostart registry keys (Run, Image File Execution Options) with user confirmation
- Registry export validation checking `$LASTEXITCODE`

## Known Limitations

Documented in SCRIPT_ANALYSIS.md:
- No incremental backups (always full)
- Sequential processing (no parallelization)
- Win32 apps only (no UWP/Store apps)
- No compression
- Winget/Chocolatey parsing may break with tool updates
