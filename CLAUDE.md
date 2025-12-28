# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PC Migration Toolkit - A PowerShell script that does PC migration the right way:
- Exports Winget/Chocolatey/Scoop package lists for proper reinstallation
- Backs up user data (Documents, Desktop, Downloads, etc.)
- Creates an inventory of installed apps (reference only)

**Does NOT** copy application files or registry keys (that approach doesn't work).

## Running the Tool

```powershell
# Must run as Administrator (script or exe)
.\PC-Migration-Tool.ps1
.\PC-Migration-Tool.exe
```

On startup, user selects backup location via:
1. Browse for folder (Windows folder picker dialog)
2. Enter path manually
3. Exit

Then interactive menu: Backup, Restore, View Inventory, Configure Path, Exit.

## Architecture

Single PowerShell file (~1100 lines) organized into sections:

### Configuration (Lines 32-75)
- `BackupDrive` - Target path (set at startup)
- `UserDataFolders` - User profile folders to backup
- `SensitiveFolders` - Folders requiring explicit user consent (e.g., `.ssh`)
- `AppDataFolders` - AppData subfolders to backup (VS Code settings, etc.)
- `ExcludePatterns` - Skip node_modules, .git/objects, etc.

### Package Manager Functions
- `Export-WingetPackages` / `Import-WingetPackages` - Uses native `winget export/import`
- `Export-ChocolateyPackages` / `Import-ChocolateyPackages` - Uses `choco export/install`
- `Export-ScoopPackages` / `Import-ScoopPackages` - Parses `scoop list`

### User Data Functions
- `Backup-UserData` / `Restore-UserData` - Uses robocopy with multithreading
- Progress bar with size estimation
- Handles both user profile folders and AppData subfolders

### Startup
- `Select-FolderDialog` - Windows Forms folder browser dialog
- `Initialize-BackupDrivePrompt` - Startup menu for path selection

## Output Structure

```
BackupLocation/
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

## Security Features

- `Test-ValidBackupPath` - Blocks system directories, relative paths, user profile root
- `SensitiveFolders` - Prompts user with red warning before backing up `.ssh` (private keys)
- UNC path handling - Properly detects `\\server\share` paths
- Inventory includes `SecurityNote` warning not to share publicly

## UX Features

- `Select-FolderDialog` - Windows folder browser for visual path selection
- Progress bar with percentage during user data backup (`Write-Progress`)
- Size estimation before backup starts
- "Leave blank to go back" option for manual path entry

## Building the EXE

```powershell
Import-Module ps2exe
Invoke-PS2EXE -inputFile '.\PC-Migration-Tool.ps1' -outputFile '.\PC-Migration-Tool.exe' -iconFile '.\pc-migration.ico' -requireAdmin
```
