# PC Migration Toolkit

## What This Tool Actually Does

1. **Exports package manager lists** (Winget, Chocolatey, Scoop) so apps can be properly reinstalled
2. **Backs up user data** (Documents, Desktop, Downloads, Pictures, Videos, Music, SSH keys, select AppData)
3. **Creates an inventory** of installed apps (for reference - not for restore)

## What This Tool Does NOT Do

- Copy application files (this doesn't work for real app migration)
- Backup/restore registry keys (this is dangerous and breaks things)
- Magically make apps work without reinstalling them

## How PC Migration Actually Works

1. Run backup on old PC → exports package lists + copies user files
2. Fresh Windows install on new PC
3. Run restore on new PC → `winget import` reinstalls apps properly + copies user files back
4. Apps install correctly through their real installers

## Quick Start

```powershell
# Run as Administrator (script or exe)
.\PC-Migration-Tool.ps1
.\PC-Migration-Tool.exe
```

On launch, you'll be prompted to select a backup location:
- **Browse for folder** - Opens Windows folder picker
- **Enter path manually** - Type a path (e.g., `D:\Backup`, `\\server\share`)
- **Exit** - Close the application

### On Old PC
1. Select backup destination
2. Choose **Option 1: Backup**
3. Wait for completion
4. Copy backup folder to external drive

### On New PC
1. Copy backup folder from external drive
2. Run the tool and select the backup location
3. Choose **Option 2: Restore**
4. Wait for packages to install
5. Restart

## Output Structure

```
BackupLocation\
├── PackageManagers\
│   ├── winget-packages.json       # Winget export (reinstallable)
│   ├── chocolatey-packages.config # Choco export (reinstallable)
│   └── scoop-packages.json        # Scoop export (reinstallable)
├── UserData\
│   ├── Documents\
│   ├── Desktop\
│   ├── Downloads\
│   └── AppData\
│       └── Code\User\             # VS Code settings
├── inventory.json                 # App list (reference only)
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

### Security
- **Sensitive folders** (`.ssh`) require explicit confirmation before backup
- **Path validation** blocks system directories and relative paths
- **Inventory warnings** remind you the file contains system info

### User Experience
- **Folder browser** - Visual folder picker to select backup location
- **Progress bar** - Shows percentage complete during user data backup
- **Size estimation** - Calculates total backup size before starting

## Building the EXE

The tool can be compiled to a standalone exe using ps2exe:

```powershell
Import-Module ps2exe
Invoke-PS2EXE -inputFile '.\PC-Migration-Tool.ps1' -outputFile '.\PC-Migration-Tool.exe' -iconFile '.\pc-migration.ico' -requireAdmin
```
