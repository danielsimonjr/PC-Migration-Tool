# PC Migration Toolkit v3.2

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
# Run as Administrator
.\PC-Migration-Tool.ps1
```

### On Old PC
1. Choose **Option 1: Backup**
2. Wait for completion
3. Copy backup folder to external drive

### On New PC
1. Copy backup folder from external drive
2. Choose **Option 2: Restore**
3. Enter path to backup folder
4. Wait for packages to install
5. Restart

## Configuration

Edit the script header to customize:

```powershell
$Global:Config = @{
    BackupDrive = "D:\PCMigration"  # Where to save backups

    # User folders to backup
    UserDataFolders = @(
        "Documents", "Desktop", "Downloads",
        "Pictures", "Videos", "Music",
        ".ssh", ".gitconfig"
    )

    # App settings to backup (from AppData)
    AppDataFolders = @(
        "Microsoft\Windows Terminal",
        "Code\User",  # VS Code
        "JetBrains"
    )
}
```

## Output Structure

```
D:\PCMigration\
├── PackageManagers\
│   ├── winget-packages.json      # Winget export (reinstallable)
│   ├── chocolatey-packages.config # Choco export (reinstallable)
│   └── scoop-packages.json       # Scoop export (reinstallable)
├── UserData\
│   ├── Documents\
│   ├── Desktop\
│   ├── Downloads\
│   └── AppData\
│       └── Code\User\            # VS Code settings
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

## Why v3.0?

Previous versions tried to "migrate" apps by copying files and registry keys. This approach:
- Doesn't actually work for most apps
- Can break the target system
- Gives users false confidence their apps are backed up

v3.0 does what actually works: reinstall via package managers + backup user data.

## Security (v3.1)

- **Sensitive folders** (`.ssh`) require explicit confirmation before backup
- **Path validation** blocks system directories and relative paths
- **Inventory warnings** remind you the file contains system info

## UX Improvements (v3.2)

- **Startup prompt** asks for backup location on launch
- **Progress bar** shows percentage complete during user data backup
- **Size estimation** calculates total backup size before starting
