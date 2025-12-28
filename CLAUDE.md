# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PC Migration Toolkit - A PowerShell script for simple PC migration:
- Exports Winget/Chocolatey/Scoop package lists for proper reinstallation
- Backs up user data (Documents, Desktop, Downloads, etc.)
- Creates an inventory of installed apps (reference only)
- Designed for non-technical users (wife-friendly)

**Does NOT** copy application files or registry keys (that approach doesn't work).

## Running the Tool

```powershell
# Must run as Administrator (script or exe)
.\PC-Migration-Tool.ps1
.\PC-Migration-Tool.exe
```

## User Flow

### Main Menu (First Screen)
```
1. BACKUP - Save everything from this PC
2. RESTORE - Put everything on this PC
3. Exit
```

### Backup Flow
User selects where to save backup:
```
1. Use this folder: [exe location]  ← Best for USB workflow
2. Browse for folder
3. Enter path manually
4. Go back
```

### Restore Flow
Auto-detects `backup-manifest.json` in exe folder:
- If found: Shows backup info (PC name, user, date) → Confirm to restore
- If not found: Shows error with instructions

## Architecture

Single PowerShell file (~1400 lines) organized into sections:

### Configuration (Lines 32-74)
- `BackupDrive` - Target path (set during backup)
- `UserDataFolders` - User profile folders to backup
- `SensitiveFolders` - Folders requiring explicit user consent (e.g., `.ssh`)
- `AppDataFolders` - AppData subfolders to backup (VS Code settings, etc.)
- `ExcludePatterns` - Skip node_modules, .git/objects, etc.

### Global Variables (Lines 76-78)
- `$Global:ExeFolder` - Detected at startup, works with PS2EXE compiled exe

### Package Manager Functions
- `Export-WingetPackages` / `Import-WingetPackages` - Uses native `winget export/import`
- `Export-ChocolateyPackages` / `Import-ChocolateyPackages` - Uses `choco export/install`
- `Export-ScoopPackages` / `Import-ScoopPackages` - Parses `scoop list`
- `Install-Winget/Chocolatey/Scoop` - Auto-install missing package managers

### User Data Functions
- `Backup-UserData` / `Restore-UserData` - Uses robocopy with multithreading
- Progress bar with size estimation

### Main Menu Functions
- `Show-MainMenu` - Main 3-option menu (Backup/Restore/Exit)
- `Select-FolderLocation` - Folder picker for backup destination
- `Select-FolderDialog` - Windows Forms folder browser

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
├── backup-manifest.json    ← Identifies valid backup, shows source PC info
├── inventory.json
└── migration.log
```

## Key Design Decisions

1. **Simple 3-option main menu** - Backup, Restore, Exit (wife-friendly)
2. **Auto-detect backup on restore** - Looks for `backup-manifest.json` in exe folder
3. **No file copying for apps** - Apps need proper installation via package managers
4. **Uses native package manager exports** - `winget export` produces correct import format
5. **Robocopy for user data** - Reliable, multithreaded, handles long paths

## Security Features

- `Test-ValidBackupPath` - Blocks system directories, relative paths, user profile root
- `SensitiveFolders` - Prompts user with red warning before backing up `.ssh`
- `backup-manifest.json` - Identifies valid backups and shows source PC info

## PS2EXE Considerations

- `$PSScriptRoot` doesn't work reliably in compiled exe
- Use `[Environment]::GetCommandLineArgs()[0]` for exe path detection
- Split `Write-Host` calls with `-NoNewline` to avoid string interpolation issues
- Global variables set at startup work better than local variables in functions

## Building the EXE

```powershell
.\build.ps1
```

Or manually:
```powershell
Import-Module ps2exe
Invoke-PS2EXE -inputFile '.\PC-Migration-Tool.ps1' -outputFile '.\PC-Migration-Tool.exe' -iconFile '.\pc-migration.ico' -requireAdmin
```
