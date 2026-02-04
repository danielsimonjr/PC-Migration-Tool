# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PC Migration Toolkit v3.6 - A PowerShell script for simple PC migration:
- Exports Winget/Chocolatey/Scoop package lists for proper reinstallation
- Backs up ALL user profiles with full folder structure (`Users\username\...`)
- Creates an inventory of installed apps (reference only)
- Designed for non-technical users (wife-friendly)

**Does NOT** copy application files or registry keys (that approach doesn't work).

## Files

| File | Purpose |
|------|---------|
| `PC-Migration-Tool.ps1` | Main migration script (~2000 lines) |
| `PC-Migration-Tool.exe` | Compiled exe for non-technical users |
| `Setup-Users.ps1` | Helper to create user accounts on new PC |
| `build.ps1` | Build script for PS2EXE compilation |
| `README.md` | User documentation and quick start guide |
| `CHANGELOG.md` | Version history and release notes |
| `pc-migration.ico` | Application icon (used by build) |

## Running the Tool

```powershell
# Must run as Administrator (script or exe)
.\PC-Migration-Tool.ps1
.\PC-Migration-Tool.exe

# Create user accounts on new PC
.\Setup-Users.ps1 -BackupPath D:\Backup
```

## CLI Mode

```powershell
.\PC-Migration-Tool.ps1 backup -Path D:\Backup      # Run backup
.\PC-Migration-Tool.ps1 backup -Path D:\Backup -y   # Skip confirmation
.\PC-Migration-Tool.ps1 restore -Path D:\Backup     # Restore from backup
.\PC-Migration-Tool.ps1 verify -Path D:\Backup      # Verify checksums
.\PC-Migration-Tool.ps1 inventory -Path D:\Backup   # View app inventory
.\PC-Migration-Tool.ps1 -Help                       # Show help
```

## User Flow

Interactive mode: 3-option menu (Backup/Restore/Exit). Backup prompts for folder selection. Restore auto-detects `backup-manifest.json` in exe folder.

See README.md for detailed user walkthrough.

## Architecture

Single PowerShell file (~2000 lines) organized into sections. Requires PowerShell 5.1+ and Administrator privileges (`#Requires -RunAsAdministrator`).

### Configuration ($Global:Config hashtable)
- `BackupFullProfile` - Set to $true to scan all user folders
- `SensitiveFolders` - Empty (previously prompted for .ssh)
- `AppDataFolders` - Specific AppData folders to backup
- `ExcludeFolders` - Cloud sync, system junctions, caches
- `ExcludePatterns` - File patterns to skip

### Global Variables
- `$Global:ExeFolder` - Detected at startup, works with PS2EXE compiled exe
- `$Global:Progress` - Tracks operation progress for resume capability
- `$Global:ShellFolderMap` - Maps logical folder names to Shell API constants

### Folder Path Resolution
- `Get-ActualFolderPath` - Resolves folder paths via Windows Shell API
- Handles OneDrive folder redirection automatically

### Progress Tracking & Resume
- `Save-Progress` / `Get-SavedProgress` - Persist progress to `backup-progress.json`
- `Mark-StepComplete` / `Test-StepCompleted` - Track completed steps
- `Clear-Progress` - Remove progress file on successful completion

### Checksum Verification
- `Get-FileChecksum` - MD5 hash of files
- `Save-Checksums` / `Get-SavedChecksums` - Store in `checksums.json`
- `Test-BackupIntegrity` - Verify files match checksums

### Package Manager Functions
- `Export-WingetPackages` / `Import-WingetPackages` - Uses native `winget export/import`
- `Export-ChocolateyPackages` / `Import-ChocolateyPackages` - Uses `choco export/install`
- `Export-ScoopPackages` / `Import-ScoopPackages` - Parses `scoop list`
- `Install-Winget/Chocolatey/Scoop` - Auto-install missing package managers

### User Data Functions
- `Backup-SingleUserProfile` - Backs up one user profile
- `Backup-UserData` - Iterates all user profiles on PC
- `Restore-UserData` - Restores all users from backup
- Uses robocopy with multithreading

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
│   └── Users/
│       ├── camil/
│       │   ├── Documents/
│       │   ├── Downloads/
│       │   ├── .gitconfig
│       │   └── AppData/
│       └── danie/
│           ├── .vscode/
│           ├── .gitconfig
│           └── AppData/
├── backup-manifest.json    <- Identifies valid backup, shows source PC info
├── backup-progress.json    <- Progress tracking (deleted on completion)
├── checksums.json          <- File verification hashes
├── inventory.json
└── migration.log
```

## Key Design Decisions

1. **Multi-user support** - Backs up ALL user profiles, not just current user
2. **Full folder structure** - Preserves `Users\username\...` hierarchy
3. **Simple 3-option main menu** - Backup, Restore, Exit (wife-friendly)
4. **Auto-detect backup on restore** - Looks for `backup-manifest.json` in exe folder
5. **Resume capability** - Detects incomplete backups/restores and offers to continue
6. **Checksum verification** - Verifies files weren't corrupted during transfer
7. **No file copying for apps** - Apps need proper installation via package managers
8. **Uses native package manager exports** - `winget export` produces correct import format
9. **Robocopy for user data** - Reliable, multithreaded, handles long paths
10. **Setup-Users.ps1** - Separate script to create accounts on new PC

## Smart Exclusions

### Folders Excluded
- Cloud sync: Dropbox, OneDrive, Google Drive, iCloud, Box
- System junctions: Application Data, Local Settings, My Documents, etc.
- Caches: .cache, .local, .minikube, .android, scoop
- AppData (handled separately for specific apps)

### File Patterns Excluded
- node_modules, .git\objects, __pycache__
- *.tmp, *.log, Thumbs.db, desktop.ini

## Resume Feature

If backup/restore is interrupted:
- Progress saved to `backup-progress.json` after each step
- On restart, user sees: "INCOMPLETE BACKUP/RESTORE FOUND"
- Options: Resume, Start fresh, Cancel
- Shows "[SKIP]" for already completed steps

## PS2EXE Considerations

- `$PSScriptRoot` doesn't work reliably in compiled exe
- Use `[Environment]::GetCommandLineArgs()[0]` for exe path detection
- Split `Write-Host` calls with `-NoNewline` to avoid string interpolation issues
- Global variables set at startup work better than local variables in functions

## Gotchas

- **`$Global:Config.BackupDrive`** - Default `D:\PCMigration` is never used; user always selects location interactively or via `-Path`
- **Robocopy exit codes** - Exit codes 0-7 are success (files copied), only 8+ indicates error. The script handles this but logs may show non-zero exits.
- **Version sync** - Keep `$Global:Config.Version` in script and `$ExeVersion` in build.ps1 in sync when releasing

## Building the EXE

```powershell
.\build.ps1
```

Or manually:
```powershell
Import-Module ps2exe
Invoke-PS2EXE -inputFile '.\PC-Migration-Tool.ps1' -outputFile '.\PC-Migration-Tool.exe' -requireAdmin
```

**Note:** Update `$ExeVersion` in build.ps1 when releasing new versions.

## Testing

No automated test suite. Manual testing workflow:
1. Run backup on a test machine with multiple user profiles
2. Verify output structure: `PackageManagers/`, `UserData/Users/`, `backup-manifest.json`
3. Run `verify` command to check checksums
4. Test restore on clean Windows install
5. Verify package manager imports install apps correctly
