# Ultimate PC Migration Toolkit v2.1

## Overview
Advanced PowerShell system for migrating installed applications between Windows PCs with maximum intelligence, security, and reliability.

---

## Quick Start

### Prerequisites
- Windows 10/11 or Windows Server
- PowerShell 5.1 or higher
- Administrator privileges
- External drive or network location for backups (recommended: 50GB+ free space)

### Basic Usage

1. **Configure Backup Location** (Line 25):
   ```powershell
   $Global:Config.BackupDrive = "D:\PCMigration"  # Change to your drive
   ```

2. **Run Script**:
   ```powershell
   # Right-click PowerShell → "Run as Administrator"
   .\Ultimate-PC-Migration-Toolkit-v2.ps1
   ```

3. **Select Operation**:
   - **Option 1**: Full Backup (recommended first)
   - **Option 2**: Restore from Backup
   - **Option 3**: View Inventory
   - **Option 4**: Export Package Managers Only

---

## Features

### Core Capabilities
- ✅ Backs up Win32 installed applications
- ✅ Captures application files, registry keys, and metadata
- ✅ Exports Winget and Chocolatey package lists
- ✅ Interactive restore with validation
- ✅ Comprehensive logging and progress tracking

### v2.1 Improvements
- ✅ **Performance**: 10-50x faster with optional file hashing
- ✅ **Security**: Registry validation, path traversal protection
- ✅ **Reliability**: Fixed critical bugs, improved error handling
- ✅ **Safety**: Prevents file name collisions, validates restorations

---

## Configuration Options

### Performance Tuning (Lines 40-41)
```powershell
EnableFileHashing   = $false  # Set to $true for integrity verification (slower)
HashOnlyExecutables = $true   # Only hash .exe/.dll files (balanced)
```

**Recommendations:**
- **Fast backup** (default): `EnableFileHashing = $false`
- **Balanced**: `EnableFileHashing = $false`, `HashOnlyExecutables = $true`
- **Maximum integrity**: `EnableFileHashing = $true`

### Other Settings
```powershell
MaxFileSize = 2GB              # Skip files larger than this
ExcludedPaths = @(             # Paths to skip during backup
    "C:\Windows\WinSxS",
    "C:\Windows\Installer",
    "C:\Windows\System32\DriverStore"
)
```

---

## Files in This Package

### Main Files
- **Ultimate-PC-Migration-Toolkit-v2.ps1** - Main script (run this)
- **README.md** - This file (quick start guide)

### Documentation
- **SCRIPT_ANALYSIS.md** - Comprehensive code review and issue documentation
- **CHANGELOG_v2.1.md** - Detailed changes in v2.1

---

## Typical Workflow

### On Source PC
1. Run script as Administrator
2. Choose "1. Start Full Backup"
3. Wait for completion (time varies by # of apps)
4. Verify backup completed successfully
5. Safely eject/disconnect backup drive

### On Target PC
1. Connect backup drive
2. Run script as Administrator
3. Choose "2. Restore from Backup"
4. Enter backup path (or press Enter for default)
5. Review prompts for:
   - System directory warnings
   - Registry autostart key warnings
6. Wait for restoration to complete

---

## What Gets Backed Up?

### Included
- ✅ Win32 applications from registry (Uninstall keys)
- ✅ Application files from InstallLocation
- ✅ Application-specific registry keys
- ✅ Winget package list
- ✅ Chocolatey package list
- ✅ Application metadata (version, publisher, etc.)

### Not Included
- ❌ UWP/Microsoft Store apps
- ❌ System drivers
- ❌ User profiles and documents
- ❌ Application data from %APPDATA%
- ❌ Database contents
- ❌ License keys (some apps may need reactivation)

---

## Security Features

### Backup Protection
- Path traversal attack prevention
- File size limits
- Excluded system paths
- Comprehensive validation

### Restore Protection
- Registry content scanning
- System directory warnings
- User confirmation for sensitive operations
- Restoration verification

### Monitored Registry Keys
The script warns before importing registry entries that modify:
- Autostart locations (Run keys)
- Image File Execution Options
- Other sensitive system settings

---

## Troubleshooting

### Common Issues

**"Backup drive not accessible"**
- Verify drive is connected
- Check drive letter in config (Line 25)
- Ensure sufficient permissions

**"Low disk space warning"**
- Free up space on backup drive
- Adjust `MaxFileSize` setting to skip large files
- Add more paths to `ExcludedPaths`

**"Application files not found"**
- Some apps don't store InstallLocation in registry
- Script logs which apps were skipped
- Consider manual backup for these apps

**"Registry import failed"**
- Requires Administrator privileges
- Some registry keys may be locked by running processes
- Try closing the application before restore

**Slow Performance**
- Disable file hashing: `EnableFileHashing = $false`
- Reduce number of apps to backup
- Use SSD for backup drive
- Close other applications during backup

---

## Performance Expectations

### Typical Backup Times
| Apps | Files | Size | Time (Hash Off) | Time (Hash On) |
|------|-------|------|-----------------|----------------|
| 50   | 5,000 | 10GB | 5-10 min       | 15-25 min      |
| 100  | 10,000| 25GB | 10-20 min      | 30-50 min      |
| 200  | 25,000| 50GB | 25-40 min      | 60-120 min     |

*Times vary based on drive speed, CPU, and application complexity*

---

## Advanced Usage

### Command-Line Mode (Future)
Currently interactive-only. For automation, consider modifying the script to accept parameters.

### Selective Backup
To backup specific applications only:
1. Run full backup first
2. Edit `inventory.json` to remove unwanted apps
3. Delete corresponding folders from `Applications/`

### Custom Package Managers
To add support for additional package managers:
1. Create function similar to `Get-WingetPackages`
2. Add to `Export-PackageManagerLists`
3. Create restore function in `Restore-PackageManagers`

---

## Best Practices

### Before Backup
1. ✅ Close all applications
2. ✅ Verify backup drive has sufficient space
3. ✅ Run Windows Update
4. ✅ Test with non-production system first

### During Backup
1. ✅ Don't modify applications
2. ✅ Keep PC powered on
3. ✅ Monitor for errors in console

### After Backup
1. ✅ Verify inventory.json exists
2. ✅ Check log file for errors
3. ✅ Keep backup in safe location
4. ✅ Test restore on VM if possible

### Before Restore
1. ✅ Fresh Windows installation recommended
2. ✅ Install same Windows version as source
3. ✅ Create system restore point
4. ✅ Backup target PC if it has data

### After Restore
1. ✅ Reboot system
2. ✅ Test each application
3. ✅ Reactivate licenses if needed
4. ✅ Update applications to latest versions

---

## Limitations

### Known Limitations (v2.1)
- No incremental backup support
- Sequential processing (no parallelization)
- Win32 apps only (no UWP)
- No application data backup (%APPDATA%)
- Some apps may need reinstallation/reactivation

See SCRIPT_ANALYSIS.md for full list and workarounds.

---

## Version Information

- **Current Version**: 2.1
- **Release Date**: 2025-11-13
- **PowerShell Required**: 5.1+
- **Platform**: Windows 10/11, Server 2016+

---

## Support & Contribution

### Getting Help
1. Read SCRIPT_ANALYSIS.md for detailed documentation
2. Check CHANGELOG_v2.1.md for recent changes
3. Review log file: `[BackupDrive]\migration.log`

### Reporting Issues
When reporting issues, include:
- PowerShell version: `$PSVersionTable.PSVersion`
- Windows version: `winver`
- Log file excerpt
- Steps to reproduce

---

## License & Disclaimer

**WARNING**: This script performs deep system analysis and file operations.
- Use at your own risk
- Test on non-production systems first
- Always maintain separate backups
- Some applications may require reactivation

**Created for**: Daniel Simon Jr. - Systems Engineer

---

## Quick Reference Card

```
BACKUP WORKFLOW           RESTORE WORKFLOW
================          =================
1. Run as Admin          1. Run as Admin
2. Option 1              2. Option 2
3. Wait...               3. Enter path
4. Verify log            4. Review prompts
5. Eject drive           5. Wait...
                         6. Reboot & test

CONFIGURATION PRESETS
====================
Fast:      EnableFileHashing = $false
Balanced:  HashOnlyExecutables = $true
Thorough:  EnableFileHashing = $true

IMPORTANT PATHS
==============
Log:       [BackupDrive]\migration.log
Inventory: [BackupDrive]\inventory.json
Apps:      [BackupDrive]\Applications\
Registry:  [BackupDrive]\RegistryExports\
Packages:  [BackupDrive]\PackageManagers\
```

---

## What's Next?

After successful backup/restore:
1. Review `migration.log` for any warnings
2. Test all critical applications
3. Update applications to latest versions
4. Consider scheduling regular backups
5. Keep backup in safe, separate location

For advanced usage and troubleshooting, see **SCRIPT_ANALYSIS.md**.

---

**Happy Migrating!** 🚀
