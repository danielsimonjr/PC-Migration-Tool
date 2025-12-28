# Changelog

All notable changes to PC Migration Toolkit.

## [3.6] - 2025-12-28

### Added
- Multi-user backup: backs up ALL user profiles on PC (not just current user)
- Full folder structure: preserves `Users\username\...` hierarchy
- `Setup-Users.ps1`: helper script to create user accounts on new PC before restore
- `.ssh` now included by default (no longer prompts for confirmation)

### Changed
- `Backup-SingleUserProfile`: new function to backup one user profile
- `Backup-UserData`: now iterates all users in `C:\Users`
- `Restore-UserData`: handles new multi-user structure
- Shell API folder resolution (handles OneDrive folder redirection)

## [3.5] - 2025-12-28

### Added
- Full user profile backup (scans entire user folder)
- Automatic detection and skip of system junction folders
- Cloud sync folder detection in actual paths

### Changed
- Backup structure now uses `UserData\Users\username\` format
- File vs directory detection for proper copy method

## [3.4] - 2025-12-28

### Fixed
- `.gitconfig` backup: now uses `Copy-Item` for files instead of robocopy
- Folder path resolution via Windows Shell API (handles OneDrive redirection)

### Changed
- Documents, Desktop, Pictures on OneDrive now properly detected and skipped

## [3.3] - 2025-12-28

### Added
- CLI mode for power users with command-line arguments
- Commands: `backup`, `restore`, `verify`, `inventory`
- Options: `-Path`, `-Yes`, `-Help`

## [3.2] - 2025-12-28

### Added
- Cloud sync folder exclusions (Dropbox, OneDrive, Google Drive, iCloud, Box)

## [3.1] - 2025-12-28

### Added
- Progress tracking with `backup-progress.json`
- Resume capability for interrupted backups/restores
- Checksum verification with `checksums.json`
- Graceful interruption handling

## [3.0] - 2025-12-28

### Added
- Complete rewrite with honest approach
- Package manager exports (Winget, Chocolatey, Scoop)
- User data backup via robocopy
- Application inventory (reference only)
- `backup-manifest.json` for backup identification
- Simple 3-option main menu (Backup/Restore/Exit)
- Auto-detect backup on restore
- Folder browser dialog

### Removed
- Application file copying (doesn't work for real migration)
- Registry backup/restore (dangerous, breaks systems)

## [2.1] - Previous

### Added
- Security improvements
- Critical fixes

## [2.0] - Previous

- Initial version with file-based migration approach
