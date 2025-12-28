# PC Migration Toolkit

A simple tool for migrating to a new PC. Features both a menu-driven interface for non-technical users and CLI mode for power users.

## What This Tool Does

1. **Exports package manager lists** (Winget, Chocolatey, Scoop) so apps can be properly reinstalled
2. **Backs up ALL user profiles** with full folder structure (`Users\username\...`)
3. **Creates an inventory** of installed apps (for reference)
4. **Tracks progress** so you can resume if interrupted
5. **Verifies backup integrity** with checksums

## What This Tool Does NOT Do

- Copy application files (this doesn't work for real app migration)
- Backup/restore registry keys (this breaks things)
- Magically make apps work without reinstalling them

## Quick Start (USB Drive Workflow)

### On Old PC
1. Copy `PC-Migration-Tool.exe` and `Setup-Users.ps1` to USB drive
2. Run the exe (right-click → Run as Administrator)
3. Select **1. BACKUP**
4. Select **1. Use this folder** (saves backup to USB)
5. Wait for completion (safe to close after each step completes)

### On New PC
1. Plug in USB drive with backup
2. Run `Setup-Users.ps1` as Administrator (creates user accounts)
3. Log in as each new user once (creates profile folders)
4. Log back in as Administrator
5. Run `PC-Migration-Tool.exe` → Select **2. RESTORE**
6. Wait for apps to install and files to copy
7. Restart computer

## Setup-Users.ps1

Helper script to create user accounts on the new PC before restore:

```powershell
# Run as Administrator
.\Setup-Users.ps1                      # Auto-detect backup in current folder
.\Setup-Users.ps1 -BackupPath D:\Backup
```

This script will:
- Read user profiles from backup (e.g., `camil`, `danie`)
- Create matching local accounts
- Optionally add users to Administrators group

## Resume Feature

If backup or restore is interrupted (power loss, closed window, etc.):
- Progress is automatically saved after each step
- Run the tool again and it will ask: **Resume or Start Fresh?**
- Already completed steps are skipped

## CLI Mode (Power Users)

```powershell
# Backup to a specific path
.\PC-Migration-Tool.ps1 backup -Path D:\Backup

# Backup without confirmation prompt
.\PC-Migration-Tool.ps1 backup -Path D:\Backup -y

# Restore from backup
.\PC-Migration-Tool.ps1 restore -Path D:\Backup

# Verify backup integrity
.\PC-Migration-Tool.ps1 verify -Path D:\Backup

# View inventory of backed-up apps
.\PC-Migration-Tool.ps1 inventory -Path D:\Backup

# Show help
.\PC-Migration-Tool.ps1 -Help
```

### CLI Options
| Option | Alias | Description |
|--------|-------|-------------|
| `-Path` | `-p` | Backup/restore path (required) |
| `-Yes` | `-y` | Skip confirmation prompts |
| `-Help` | `-h` | Show help message |

## Interactive Mode (Menu-Driven)

Run without arguments for the menu interface:

### Main Menu
```
1. BACKUP - Save everything from this PC
2. RESTORE - Put everything on this PC
3. Exit
```

### Backup Flow
After selecting Backup, choose where to save:
```
1. Use this folder: [exe location]  <- Recommended for USB
2. Browse for folder
3. Enter path manually
4. Go back
```

### Restore Flow
Restore auto-detects backups in the exe folder:
```
Found backup in this folder:
  Computer:  OLD-PC-NAME
  User:      Username
  Date:      2025-12-28 10:30:00
  Windows:   Windows 11 Home

1. Run Restore
2. Go back
```

If no backup found, shows error with instructions.

## Output Structure

```
BackupLocation\
├── PackageManagers\
│   ├── winget-packages.json
│   ├── chocolatey-packages.config
│   └── scoop-packages.json
├── UserData\
│   └── Users\
│       ├── camil\
│       │   ├── Documents\
│       │   ├── Downloads\
│       │   ├── .gitconfig
│       │   └── AppData\
│       └── danie\
│           ├── Documents\
│           ├── Downloads\
│           ├── .vscode\
│           ├── .gitconfig
│           └── AppData\
├── backup-manifest.json          # Identifies valid backup
├── checksums.json                # File verification hashes
├── inventory.json                # App list (reference only)
└── migration.log
```

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Administrator privileges
- Winget (comes with Windows 11, install App Installer on Windows 10)

## What About Apps Not in Package Managers?

Check `inventory.json` after restore. It lists all apps that were installed. For apps not available via Winget/Chocolatey:
- Download installer from vendor website
- Some apps may need license reactivation

## Features

### Multi-User Support
- Backs up ALL user profiles on the PC
- Preserves full folder structure (`Users\username\...`)
- Restore maps to matching usernames on new PC

### Resume Capability
- Progress saved after each step
- Detect incomplete backup/restore on startup
- Option to resume or start fresh

### Integrity Verification
- Checksums generated during backup
- Verified before restore begins
- Warns if files are corrupted

### Smart Exclusions
- **Cloud sync folders** automatically skipped (Dropbox, OneDrive, Google Drive, iCloud, Box)
- **System junctions** skipped (Application Data, Local Settings, etc.)
- **Dev folders** excluded (node_modules, .git/objects, __pycache__)
- **Cache folders** excluded (.cache, .local, .minikube, .android)
- **Large files** over 1GB skipped

### What Gets Backed Up
- All user profile folders (Documents, Downloads, Desktop, etc.)
- Hidden config files (.gitconfig, .claude, .vscode, etc.)
- SSH keys (.ssh folder)
- Specific AppData folders (VS Code settings, Windows Terminal, npm, etc.)

## Building the EXE

```powershell
.\build.ps1
```

Or manually:
```powershell
Import-Module ps2exe
Invoke-PS2EXE -inputFile '.\PC-Migration-Tool.ps1' -outputFile '.\PC-Migration-Tool.exe' -requireAdmin
```
