# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PC Migration Toolkit v3.1 - A PowerShell script that does PC migration the right way:
- Exports Winget/Chocolatey/Scoop package lists for proper reinstallation
- Backs up user data (Documents, Desktop, Downloads, etc.)
- Creates an inventory of installed apps (reference only)

**Does NOT** copy application files or registry keys (that approach doesn't work).

## Running the Script

```powershell
# Must run as Administrator
.\Ultimate-PC-Migration-Toolkit-v2.ps1
```

Interactive menu with 5 options: Backup, Restore, View Inventory, Configure Path, Exit.

## Architecture

Single PowerShell file (~920 lines) organized into sections:

### Configuration (Lines 32-75)
- `BackupDrive` - Target path
- `UserDataFolders` - User profile folders to backup
- `SensitiveFolders` - Folders requiring explicit user consent (e.g., `.ssh`)
- `AppDataFolders` - AppData subfolders to backup (VS Code settings, etc.)
- `ExcludePatterns` - Skip node_modules, .git/objects, etc.

### Package Manager Functions (Lines 138-325)
- `Export-WingetPackages` / `Import-WingetPackages` - Uses native `winget export/import`
- `Export-ChocolateyPackages` / `Import-ChocolateyPackages` - Uses `choco export/install`
- `Export-ScoopPackages` / `Import-ScoopPackages` - Parses `scoop list`

### User Data Functions (Lines 331-507)
- `Backup-UserData` / `Restore-UserData` - Uses robocopy with multithreading
- Handles both user profile folders and AppData subfolders

### Inventory (Lines 513-571)
- `Get-InstalledApplications` - Reads registry Uninstall keys
- `Export-Inventory` - Saves to JSON (reference only, not for restore)

### Workflows (Lines 577-763)
- `Start-Backup` - Orchestrates full backup
- `Start-Restore` - Orchestrates full restore
- `Show-Inventory` - Displays backup summary

## Output Structure

```
BackupDrive/
├── PackageManagers/
│   ├── winget-packages.json
│   ├── chocolatey-packages.config
│   └── scoop-packages.json
├── UserData/
│   ├── Documents/
│   ├── Desktop/
│   └── AppData/
├── inventory.json
└── migration.log
```

## Design Decisions

1. **No file copying for apps** - Apps need proper installation (MSI, registry, services, etc.)
2. **Uses native package manager exports** - `winget export` produces correct import format
3. **Robocopy for user data** - Reliable, multithreaded, handles long paths
4. **Inventory is reference only** - Shows what was installed, not used for restore

## Security Features (v3.1)

- `Test-ValidBackupPath` - Blocks system directories, relative paths, user profile root
- `SensitiveFolders` - Prompts user with red warning before backing up `.ssh` (private keys)
- UNC path handling - Properly detects `\\server\share` paths
- Inventory includes `SecurityNote` warning not to share publicly
