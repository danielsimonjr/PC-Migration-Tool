# ============================================================================
# PC MIGRATION TOOLKIT v3.2
# Honest PC Migration: Package Managers + User Data
#
# Created for: Daniel Simon Jr. - Systems Engineer
#
# WHAT THIS DOES:
#   - Exports Winget and Chocolatey package lists for reinstallation
#   - Backs up user data (Documents, Desktop, Downloads, Pictures, etc.)
#   - Creates an inventory of installed applications (for reference only)
#
# WHAT THIS DOES NOT DO:
#   - "Migrate" applications by copying files (this doesn't work)
#   - Backup/restore registry keys (this is dangerous)
#   - Make apps magically work on a new PC without reinstalling
#
# HOW TO ACTUALLY MIGRATE:
#   1. Run backup on old PC (exports package lists + user data)
#   2. Fresh Windows install on new PC
#   3. Run restore (imports packages via winget/choco, copies user data)
#   4. Apps reinstall properly through their real installers
#
# ============================================================================

#Requires -RunAsAdministrator
#Requires -Version 5.1

# ============================================================================
# CONFIGURATION
# ============================================================================

$Global:Config = @{
    BackupDrive         = "D:\PCMigration"
    LogFile             = "migration.log"
    Version             = "3.2"

    # User data folders to backup (relative to user profile)
    UserDataFolders     = @(
        "Documents",
        "Desktop",
        "Downloads",
        "Pictures",
        "Videos",
        "Music",
        ".gitconfig"
    )

    # Sensitive folders - user will be prompted before backing these up
    SensitiveFolders    = @(
        ".ssh"          # Contains private keys - security risk if backup is compromised
    )

    # AppData folders to backup (common apps that store important data)
    AppDataFolders      = @(
        "Microsoft\Windows Terminal",
        "Code\User",                    # VS Code settings
        "JetBrains",
        "npm",
        "nuget"
    )

    # Maximum file size to backup (skip huge files)
    MaxFileSize         = 1GB

    # Exclude patterns
    ExcludePatterns     = @(
        "node_modules",
        ".git\objects",
        "__pycache__",
        "*.tmp",
        "*.log",
        "Thumbs.db"
    )
}

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    $colors = @{
        'INFO'    = 'Cyan'
        'WARNING' = 'Yellow'
        'ERROR'   = 'Red'
        'SUCCESS' = 'Green'
    }

    Write-Host $logMessage -ForegroundColor $colors[$Level]

    # Write to log file
    $logPath = Join-Path $Global:Config.BackupDrive $Global:Config.LogFile
    $logDir = Split-Path $logPath -Parent

    if (Test-Path $logDir) {
        try {
            Add-Content -Path $logPath -Value $logMessage -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

function Test-ValidBackupPath {
    param([string]$Path)

    # Check for empty/null
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{ Valid = $false; Reason = "Path cannot be empty" }
    }

    # Check for relative paths
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        return @{ Valid = $false; Reason = "Path must be absolute, not relative" }
    }

    # Normalize path for comparison
    try {
        $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    catch {
        return @{ Valid = $false; Reason = "Invalid path format" }
    }

    # Block system directories
    $blockedPaths = @(
        "$env:SystemRoot",                    # C:\Windows
        "$env:ProgramFiles",                  # C:\Program Files
        "${env:ProgramFiles(x86)}",           # C:\Program Files (x86)
        "$env:SystemDrive\Users\Default",     # Default user profile
        "$env:SystemDrive\Users\Public"       # Public profile
    )

    foreach ($blocked in $blockedPaths) {
        if ($blocked -and $normalizedPath -like "$blocked*") {
            return @{ Valid = $false; Reason = "Cannot backup to system directory: $blocked" }
        }
    }

    # Block current user profile root (but allow subdirectories)
    if ($normalizedPath -eq $env:USERPROFILE) {
        return @{ Valid = $false; Reason = "Cannot backup to user profile root" }
    }

    return @{ Valid = $true; Reason = "" }
}

function Initialize-BackupEnvironment {
    Write-Log "Initializing backup environment..." -Level INFO

    # Validate backup path
    $validation = Test-ValidBackupPath -Path $Global:Config.BackupDrive
    if (-not $validation.Valid) {
        Write-Log "Invalid backup path: $($validation.Reason)" -Level ERROR
        return $false
    }

    if (-not (Test-Path $Global:Config.BackupDrive)) {
        try {
            New-Item -Path $Global:Config.BackupDrive -ItemType Directory -Force | Out-Null
            Write-Log "Created backup directory: $($Global:Config.BackupDrive)" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to create backup directory: $_" -Level ERROR
            return $false
        }
    }

    # Create subdirectories
    $subdirs = @("PackageManagers", "UserData", "AppData")
    foreach ($dir in $subdirs) {
        $path = Join-Path $Global:Config.BackupDrive $dir
        if (-not (Test-Path $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    return $true
}

# ============================================================================
# PACKAGE MANAGER FUNCTIONS (The Actually Useful Part)
# ============================================================================

function Export-WingetPackages {
    Write-Log "Exporting Winget packages..." -Level INFO

    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Log "Winget not installed" -Level WARNING
        return $null
    }

    $exportPath = Join-Path $Global:Config.BackupDrive "PackageManagers\winget-packages.json"

    try {
        # Use winget's native export - this is the RIGHT way
        $result = winget export -o $exportPath --accept-source-agreements 2>&1

        if (Test-Path $exportPath) {
            $content = Get-Content $exportPath -Raw | ConvertFrom-Json
            $count = $content.Sources.Packages.Count
            Write-Log "Exported $count Winget packages to: $exportPath" -Level SUCCESS
            return $exportPath
        }
        else {
            Write-Log "Winget export failed: $result" -Level ERROR
            return $null
        }
    }
    catch {
        Write-Log "Winget export error: $_" -Level ERROR
        return $null
    }
}

function Export-ChocolateyPackages {
    Write-Log "Exporting Chocolatey packages..." -Level INFO

    $chocoPath = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoPath)) {
        Write-Log "Chocolatey not installed" -Level INFO
        return $null
    }

    $exportPath = Join-Path $Global:Config.BackupDrive "PackageManagers\chocolatey-packages.config"

    try {
        & $chocoPath export $exportPath -y 2>&1 | Out-Null

        if (Test-Path $exportPath) {
            [xml]$content = Get-Content $exportPath
            $count = $content.packages.package.Count
            Write-Log "Exported $count Chocolatey packages to: $exportPath" -Level SUCCESS
            return $exportPath
        }
        else {
            Write-Log "Chocolatey export failed" -Level ERROR
            return $null
        }
    }
    catch {
        Write-Log "Chocolatey export error: $_" -Level ERROR
        return $null
    }
}

function Export-ScoopPackages {
    Write-Log "Exporting Scoop packages..." -Level INFO

    $scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $scoopCmd) {
        Write-Log "Scoop not installed" -Level INFO
        return $null
    }

    $exportPath = Join-Path $Global:Config.BackupDrive "PackageManagers\scoop-packages.json"

    try {
        $packages = scoop list 2>&1 | Where-Object { $_ -match '^\s*\w' }
        $packageList = @()

        foreach ($line in $packages) {
            if ($line -match '^\s*(\S+)\s+(\S+)') {
                $packageList += @{
                    Name = $matches[1]
                    Version = $matches[2]
                }
            }
        }

        $packageList | ConvertTo-Json -Depth 5 | Out-File $exportPath -Encoding UTF8
        Write-Log "Exported $($packageList.Count) Scoop packages to: $exportPath" -Level SUCCESS
        return $exportPath
    }
    catch {
        Write-Log "Scoop export error: $_" -Level ERROR
        return $null
    }
}

function Import-WingetPackages {
    param([string]$BackupPath)

    $importFile = Join-Path $BackupPath "PackageManagers\winget-packages.json"

    if (-not (Test-Path $importFile)) {
        Write-Log "Winget package file not found: $importFile" -Level WARNING
        return
    }

    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Log "Winget not available - install it first" -Level ERROR
        return
    }

    Write-Log "Importing Winget packages (this may take a while)..." -Level INFO
    Write-Host ""
    Write-Host "NOTE: Some packages may fail if they're already installed or unavailable." -ForegroundColor Yellow
    Write-Host "This is normal. Failed packages will be listed at the end." -ForegroundColor Yellow
    Write-Host ""

    try {
        # --ignore-unavailable skips packages that can't be found
        # --ignore-versions allows newer versions to satisfy requirements
        winget import -i $importFile --ignore-unavailable --ignore-versions --accept-package-agreements --accept-source-agreements

        Write-Log "Winget import completed" -Level SUCCESS
    }
    catch {
        Write-Log "Winget import error: $_" -Level ERROR
    }
}

function Import-ChocolateyPackages {
    param([string]$BackupPath)

    $importFile = Join-Path $BackupPath "PackageManagers\chocolatey-packages.config"

    if (-not (Test-Path $importFile)) {
        Write-Log "Chocolatey package file not found" -Level INFO
        return
    }

    $chocoPath = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoPath)) {
        Write-Log "Chocolatey not installed. Install from https://chocolatey.org/install" -Level WARNING
        return
    }

    Write-Log "Importing Chocolatey packages..." -Level INFO

    try {
        & $chocoPath install $importFile -y
        Write-Log "Chocolatey import completed" -Level SUCCESS
    }
    catch {
        Write-Log "Chocolatey import error: $_" -Level ERROR
    }
}

function Import-ScoopPackages {
    param([string]$BackupPath)

    $importFile = Join-Path $BackupPath "PackageManagers\scoop-packages.json"

    if (-not (Test-Path $importFile)) {
        Write-Log "Scoop package file not found" -Level INFO
        return
    }

    $scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
    if (-not $scoopCmd) {
        Write-Log "Scoop not installed. Install from https://scoop.sh" -Level WARNING
        return
    }

    Write-Log "Importing Scoop packages..." -Level INFO

    try {
        $packages = Get-Content $importFile | ConvertFrom-Json
        foreach ($pkg in $packages) {
            Write-Host "Installing: $($pkg.Name)" -ForegroundColor Cyan
            scoop install $pkg.Name 2>&1 | Out-Null
        }
        Write-Log "Scoop import completed" -Level SUCCESS
    }
    catch {
        Write-Log "Scoop import error: $_" -Level ERROR
    }
}

# ============================================================================
# USER DATA BACKUP (What Actually Matters)
# ============================================================================

function Backup-UserData {
    Write-Log "Backing up user data..." -Level INFO

    $userProfile = $env:USERPROFILE
    $backupBase = Join-Path $Global:Config.BackupDrive "UserData"

    # Build list of folders to backup, prompting for sensitive ones
    $foldersToBackup = @() + $Global:Config.UserDataFolders

    foreach ($sensitiveFolder in $Global:Config.SensitiveFolders) {
        $sensitivePath = Join-Path $userProfile $sensitiveFolder
        if (Test-Path $sensitivePath) {
            Write-Host ""
            Write-Host "SECURITY WARNING: $sensitiveFolder contains sensitive data (private keys, credentials)" -ForegroundColor Red
            Write-Host "If your backup drive is lost or stolen, this data could be compromised." -ForegroundColor Yellow
            $includeSensitive = Read-Host "Include $sensitiveFolder in backup? (Y/N)"
            if ($includeSensitive -eq 'Y') {
                $foldersToBackup += $sensitiveFolder
                Write-Log "User opted to include sensitive folder: $sensitiveFolder" -Level WARNING
            }
            else {
                Write-Log "User opted to skip sensitive folder: $sensitiveFolder" -Level INFO
            }
        }
    }

    # Build list of AppData folders that exist
    $appDataFoldersToBackup = @()
    foreach ($folder in $Global:Config.AppDataFolders) {
        $sourcePath = Join-Path $env:APPDATA $folder
        if (-not (Test-Path $sourcePath)) {
            $sourcePath = Join-Path $env:LOCALAPPDATA $folder
        }
        if (Test-Path $sourcePath) {
            $appDataFoldersToBackup += @{ Folder = $folder; Path = $sourcePath }
        }
    }

    # Calculate total size for progress estimation
    Write-Host ""
    Write-Host "Calculating backup size..." -ForegroundColor Cyan

    $folderSizes = @{}
    $totalEstimatedSize = 0
    $excludeDirs = $Global:Config.ExcludePatterns | Where-Object { $_ -notmatch '\.' }

    foreach ($folder in $foldersToBackup) {
        $sourcePath = Join-Path $userProfile $folder
        if (Test-Path $sourcePath) {
            try {
                $size = (Get-ChildItem $sourcePath -Recurse -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Length -lt $Global:Config.MaxFileSize } |
                         Measure-Object -Property Length -Sum).Sum
                if ($null -eq $size) { $size = 0 }
                $folderSizes[$folder] = $size
                $totalEstimatedSize += $size
            }
            catch {
                $folderSizes[$folder] = 0
            }
        }
    }

    foreach ($item in $appDataFoldersToBackup) {
        try {
            $size = (Get-ChildItem $item.Path -Recurse -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
            if ($null -eq $size) { $size = 0 }
            $folderSizes["AppData:$($item.Folder)"] = $size
            $totalEstimatedSize += $size
        }
        catch {
            $folderSizes["AppData:$($item.Folder)"] = 0
        }
    }

    $totalEstimatedMB = [math]::Round($totalEstimatedSize / 1MB, 2)
    Write-Host "Estimated total: $totalEstimatedMB MB" -ForegroundColor Gray
    Write-Host ""

    $completedSize = 0
    $totalFiles = 0
    $totalSize = 0

    # Backup user folders with progress
    foreach ($folder in $foldersToBackup) {
        $sourcePath = Join-Path $userProfile $folder

        if (-not (Test-Path $sourcePath)) {
            Write-Log "Skipping (not found): $folder" -Level INFO
            continue
        }

        $destPath = Join-Path $backupBase $folder

        # Calculate and display progress
        $percentComplete = if ($totalEstimatedSize -gt 0) {
            [math]::Round(($completedSize / $totalEstimatedSize) * 100, 1)
        } else { 0 }

        Write-Progress -Activity "Backing up user data" -Status "$folder ($percentComplete% complete)" -PercentComplete $percentComplete
        Write-Log "Backing up: $folder" -Level INFO

        try {
            # Use robocopy for reliable copying with exclusions
            $excludeFiles = $Global:Config.ExcludePatterns | Where-Object { $_ -match '\.' }

            $robocopyArgs = @(
                $sourcePath,
                $destPath,
                "/E",           # Copy subdirectories including empty
                "/R:1",         # Retry once
                "/W:1",         # Wait 1 second between retries
                "/MT:8",        # 8 threads
                "/NFL",         # No file list
                "/NDL",         # No directory list
                "/NJH",         # No job header
                "/NJS",         # No job summary
                "/MAX:$($Global:Config.MaxFileSize)"
            )

            if ($excludeDirs.Count -gt 0) {
                $robocopyArgs += "/XD"
                $robocopyArgs += $excludeDirs
            }
            if ($excludeFiles.Count -gt 0) {
                $robocopyArgs += "/XF"
                $robocopyArgs += $excludeFiles
            }

            $output = robocopy @robocopyArgs 2>&1

            # Robocopy exit codes 0-7 are success/partial success
            if ($LASTEXITCODE -le 7) {
                $stats = Get-ChildItem $destPath -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum
                $totalFiles += $stats.Count
                $totalSize += $stats.Sum
                Write-Log "Copied $folder ($($stats.Count) files)" -Level SUCCESS
            }
            else {
                Write-Log "Robocopy returned code $LASTEXITCODE for $folder" -Level WARNING
            }
        }
        catch {
            Write-Log "Error backing up $folder : $_" -Level ERROR
        }

        # Update completed size for progress
        $completedSize += $folderSizes[$folder]
    }

    # Backup AppData folders with progress
    $appDataBase = Join-Path $backupBase "AppData"
    foreach ($item in $appDataFoldersToBackup) {
        $destPath = Join-Path $appDataBase $item.Folder

        # Calculate and display progress
        $percentComplete = if ($totalEstimatedSize -gt 0) {
            [math]::Round(($completedSize / $totalEstimatedSize) * 100, 1)
        } else { 0 }

        Write-Progress -Activity "Backing up user data" -Status "AppData: $($item.Folder) ($percentComplete% complete)" -PercentComplete $percentComplete
        Write-Log "Backing up AppData: $($item.Folder)" -Level INFO

        try {
            robocopy $item.Path $destPath /E /R:1 /W:1 /MT:4 /NFL /NDL /NJH /NJS 2>&1 | Out-Null

            if ($LASTEXITCODE -le 7) {
                Write-Log "Copied AppData: $($item.Folder)" -Level SUCCESS
            }
        }
        catch {
            Write-Log "Error backing up AppData $($item.Folder) : $_" -Level WARNING
        }

        # Update completed size for progress
        $completedSize += $folderSizes["AppData:$($item.Folder)"]
    }

    Write-Progress -Activity "Backing up user data" -Completed

    $sizeMB = [math]::Round($totalSize / 1MB, 2)
    Write-Log "User data backup complete: $totalFiles files, $sizeMB MB" -Level SUCCESS
}

function Restore-UserData {
    param([string]$BackupPath)

    $backupBase = Join-Path $BackupPath "UserData"

    if (-not (Test-Path $backupBase)) {
        Write-Log "User data backup not found" -Level WARNING
        return
    }

    Write-Log "Restoring user data..." -Level INFO
    Write-Host ""
    Write-Host "WARNING: This will copy files to your user profile." -ForegroundColor Yellow
    Write-Host "Existing files with the same name will be overwritten." -ForegroundColor Yellow
    $confirm = Read-Host "Continue? (Y/N)"

    if ($confirm -ne 'Y') {
        Write-Log "User data restore cancelled" -Level INFO
        return
    }

    $userProfile = $env:USERPROFILE

    foreach ($folder in $Global:Config.UserDataFolders) {
        $sourcePath = Join-Path $backupBase $folder

        if (-not (Test-Path $sourcePath)) {
            continue
        }

        $destPath = Join-Path $userProfile $folder
        Write-Log "Restoring: $folder" -Level INFO

        try {
            robocopy $sourcePath $destPath /E /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS 2>&1 | Out-Null

            if ($LASTEXITCODE -le 7) {
                Write-Log "Restored: $folder" -Level SUCCESS
            }
        }
        catch {
            Write-Log "Error restoring $folder : $_" -Level ERROR
        }
    }

    # Restore AppData
    $appDataBackup = Join-Path $backupBase "AppData"
    if (Test-Path $appDataBackup) {
        foreach ($folder in $Global:Config.AppDataFolders) {
            $sourcePath = Join-Path $appDataBackup $folder

            if (-not (Test-Path $sourcePath)) {
                continue
            }

            # Try APPDATA first, then LOCALAPPDATA
            $destPath = Join-Path $env:APPDATA $folder
            if (-not (Test-Path (Split-Path $destPath -Parent))) {
                $destPath = Join-Path $env:LOCALAPPDATA $folder
            }

            Write-Log "Restoring AppData: $folder" -Level INFO

            try {
                robocopy $sourcePath $destPath /E /R:1 /W:1 /MT:4 /NFL /NDL /NJH /NJS 2>&1 | Out-Null

                if ($LASTEXITCODE -le 7) {
                    Write-Log "Restored AppData: $folder" -Level SUCCESS
                }
            }
            catch {
                Write-Log "Error restoring AppData $folder : $_" -Level WARNING
            }
        }
    }

    Write-Log "User data restore complete" -Level SUCCESS
}

# ============================================================================
# INVENTORY (Reference Only - Not for Restore)
# ============================================================================

function Get-InstalledApplications {
    Write-Log "Scanning installed applications (for reference)..." -Level INFO

    $applications = @()

    $registryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $registryPaths) {
        try {
            $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne "" } |
                Select-Object DisplayName, DisplayVersion, Publisher, InstallDate

            foreach ($app in $apps) {
                $applications += [PSCustomObject]@{
                    Name      = $app.DisplayName
                    Version   = $app.DisplayVersion
                    Publisher = $app.Publisher
                    InstallDate = $app.InstallDate
                }
            }
        }
        catch { }
    }

    # Remove duplicates
    $applications = $applications | Sort-Object Name -Unique

    Write-Log "Found $($applications.Count) installed applications" -Level SUCCESS
    return $applications
}

function Export-Inventory {
    Write-Log "Creating system inventory..." -Level INFO

    $applications = Get-InstalledApplications

    Write-Host ""
    Write-Host "NOTE: Inventory will include computer name and username for reference." -ForegroundColor Yellow
    Write-Host "This information will be stored in plaintext in inventory.json" -ForegroundColor Yellow

    $inventory = @{
        ExportDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ComputerName    = $env:COMPUTERNAME
        UserName        = $env:USERNAME
        WindowsVersion  = (Get-CimInstance Win32_OperatingSystem).Caption
        WindowsBuild    = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Applications    = $applications
        TotalApps       = $applications.Count
        Note            = "This inventory is for REFERENCE ONLY. Use package manager imports to reinstall apps."
        SecurityNote    = "This file contains system information. Do not share publicly."
    }

    $inventoryPath = Join-Path $Global:Config.BackupDrive "inventory.json"
    $inventory | ConvertTo-Json -Depth 10 | Out-File $inventoryPath -Encoding UTF8

    Write-Log "Inventory saved to: $inventoryPath" -Level SUCCESS
    return $inventoryPath
}

# ============================================================================
# MAIN WORKFLOWS
# ============================================================================

function Start-Backup {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  PC MIGRATION BACKUP" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This will:" -ForegroundColor White
    Write-Host "  1. Export Winget/Chocolatey/Scoop package lists" -ForegroundColor Gray
    Write-Host "  2. Backup user data (Documents, Desktop, etc.)" -ForegroundColor Gray
    Write-Host "  3. Create an inventory of installed apps (reference only)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Backup location: $($Global:Config.BackupDrive)" -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "Start backup? (Y/N)"
    if ($confirm -ne 'Y') {
        Write-Log "Backup cancelled" -Level INFO
        return
    }

    $startTime = Get-Date

    # Initialize
    if (-not (Initialize-BackupEnvironment)) {
        return
    }

    # Check disk space (handle both local and UNC paths)
    try {
        $backupPath = $Global:Config.BackupDrive
        if ($backupPath -match '^\\\\') {
            # UNC path - use Get-WmiObject for network shares
            $freeSpace = $null
            Write-Log "UNC path detected - skipping disk space check" -Level INFO
        }
        elseif ($backupPath -match '^([A-Za-z]):') {
            $driveLetter = $matches[1]
            $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
            if ($drive -and $drive.Free -lt 5GB) {
                Write-Log "Warning: Less than 5GB free on backup drive" -Level WARNING
            }
        }
    }
    catch { }

    # Export package managers
    Write-Host ""
    Write-Host "--- Package Managers ---" -ForegroundColor Cyan
    Export-WingetPackages
    Export-ChocolateyPackages
    Export-ScoopPackages

    # Backup user data
    Write-Host ""
    Write-Host "--- User Data ---" -ForegroundColor Cyan
    Backup-UserData

    # Create inventory
    Write-Host ""
    Write-Host "--- Inventory ---" -ForegroundColor Cyan
    Export-Inventory

    $duration = (Get-Date) - $startTime

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  BACKUP COMPLETE" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "Duration: $($duration.Minutes)m $($duration.Seconds)s" -ForegroundColor Gray
    Write-Host "Location: $($Global:Config.BackupDrive)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Copy backup folder to new PC" -ForegroundColor White
    Write-Host "  2. Run this script on new PC" -ForegroundColor White
    Write-Host "  3. Choose 'Restore' option" -ForegroundColor White
    Write-Host ""
}

function Start-Restore {
    param([string]$BackupPath)

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host "  PC MIGRATION RESTORE" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This will:" -ForegroundColor White
    Write-Host "  1. Install packages via Winget/Chocolatey/Scoop" -ForegroundColor Gray
    Write-Host "  2. Restore user data (Documents, Desktop, etc.)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "NOTE: Apps will be REINSTALLED properly, not copied." -ForegroundColor Cyan
    Write-Host "This is the correct way to migrate applications." -ForegroundColor Cyan
    Write-Host ""

    # Verify backup exists
    if (-not (Test-Path $BackupPath)) {
        Write-Log "Backup path not found: $BackupPath" -Level ERROR
        return
    }

    $pmPath = Join-Path $BackupPath "PackageManagers"
    if (-not (Test-Path $pmPath)) {
        Write-Log "Package manager exports not found in backup" -Level ERROR
        return
    }

    Write-Host "Backup location: $BackupPath" -ForegroundColor Yellow
    Write-Host ""

    # Show what will be restored
    $wingetFile = Join-Path $pmPath "winget-packages.json"
    $chocoFile = Join-Path $pmPath "chocolatey-packages.config"
    $scoopFile = Join-Path $pmPath "scoop-packages.json"

    if (Test-Path $wingetFile) {
        $content = Get-Content $wingetFile -Raw | ConvertFrom-Json
        Write-Host "  Winget packages: $($content.Sources.Packages.Count)" -ForegroundColor Gray
    }
    if (Test-Path $chocoFile) {
        [xml]$content = Get-Content $chocoFile
        Write-Host "  Chocolatey packages: $($content.packages.package.Count)" -ForegroundColor Gray
    }
    if (Test-Path $scoopFile) {
        $content = Get-Content $scoopFile | ConvertFrom-Json
        Write-Host "  Scoop packages: $($content.Count)" -ForegroundColor Gray
    }

    Write-Host ""
    $confirm = Read-Host "Start restore? (Y/N)"
    if ($confirm -ne 'Y') {
        Write-Log "Restore cancelled" -Level INFO
        return
    }

    $startTime = Get-Date

    # Restore packages
    Write-Host ""
    Write-Host "--- Installing Packages ---" -ForegroundColor Cyan
    Write-Host "(This may take a while...)" -ForegroundColor Gray
    Write-Host ""

    Import-WingetPackages -BackupPath $BackupPath
    Import-ChocolateyPackages -BackupPath $BackupPath
    Import-ScoopPackages -BackupPath $BackupPath

    # Restore user data
    Write-Host ""
    Write-Host "--- User Data ---" -ForegroundColor Cyan
    Restore-UserData -BackupPath $BackupPath

    $duration = (Get-Date) - $startTime

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  RESTORE COMPLETE" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "Duration: $($duration.Minutes)m $($duration.Seconds)s" -ForegroundColor Gray
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Restart your computer" -ForegroundColor White
    Write-Host "  2. Some apps may need re-authentication" -ForegroundColor White
    Write-Host "  3. Check inventory.json for apps that weren't in package managers" -ForegroundColor White
    Write-Host ""
}

function Show-Inventory {
    $inventoryPath = Join-Path $Global:Config.BackupDrive "inventory.json"

    if (-not (Test-Path $inventoryPath)) {
        Write-Host "No inventory found. Run a backup first." -ForegroundColor Red
        return
    }

    $inventory = Get-Content $inventoryPath | ConvertFrom-Json

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  BACKUP INVENTORY" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Backup Date:    $($inventory.ExportDate)" -ForegroundColor Gray
    Write-Host "Computer:       $($inventory.ComputerName)" -ForegroundColor Gray
    Write-Host "User:           $($inventory.UserName)" -ForegroundColor Gray
    Write-Host "Windows:        $($inventory.WindowsVersion)" -ForegroundColor Gray
    Write-Host "Total Apps:     $($inventory.TotalApps)" -ForegroundColor Gray
    Write-Host ""

    $showApps = Read-Host "Show application list? (Y/N)"
    if ($showApps -eq 'Y') {
        Write-Host ""
        $inventory.Applications |
            Sort-Object Name |
            Format-Table Name, Version, Publisher -AutoSize
    }
}

# ============================================================================
# MAIN MENU
# ============================================================================

function Show-MainMenu {
    Clear-Host
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  PC MIGRATION TOOLKIT v$($Global:Config.Version)" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Backup (export packages + user data)" -ForegroundColor Green
    Write-Host "  2. Restore (install packages + user data)" -ForegroundColor Yellow
    Write-Host "  3. View Inventory" -ForegroundColor Cyan
    Write-Host "  4. Configure Backup Path" -ForegroundColor White
    Write-Host "  5. Exit" -ForegroundColor Red
    Write-Host ""
    Write-Host "Current backup path: $($Global:Config.BackupDrive)" -ForegroundColor Gray
    Write-Host ""
}

function Start-InteractiveMode {
    do {
        Show-MainMenu
        $choice = Read-Host "Select option (1-5)"

        switch ($choice) {
            "1" {
                Start-Backup
                Read-Host "`nPress Enter to continue"
            }
            "2" {
                $backupPath = Read-Host "Backup path (Enter for default: $($Global:Config.BackupDrive))"
                if ([string]::IsNullOrWhiteSpace($backupPath)) {
                    $backupPath = $Global:Config.BackupDrive
                }
                Start-Restore -BackupPath $backupPath
                Read-Host "`nPress Enter to continue"
            }
            "3" {
                Show-Inventory
                Read-Host "`nPress Enter to continue"
            }
            "4" {
                $newPath = Read-Host "Enter new backup path (absolute path required)"
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $validation = Test-ValidBackupPath -Path $newPath
                    if ($validation.Valid) {
                        $Global:Config.BackupDrive = $newPath
                        Write-Host "Backup path updated to: $newPath" -ForegroundColor Green
                    }
                    else {
                        Write-Host "Invalid path: $($validation.Reason)" -ForegroundColor Red
                    }
                }
                Read-Host "`nPress Enter to continue"
            }
            "5" {
                Write-Host "`nGoodbye!" -ForegroundColor Cyan
                return
            }
            default {
                Write-Host "Invalid option" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

# ============================================================================
# ENTRY POINT
# ============================================================================

function Initialize-BackupDrivePrompt {
    Clear-Host
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  PC MIGRATION TOOLKIT v$($Global:Config.Version)" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Where would you like to store backups?" -ForegroundColor White
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Gray
    Write-Host "  D:\PCMigration" -ForegroundColor Gray
    Write-Host "  E:\Backup" -ForegroundColor Gray
    Write-Host "  \\server\share\backup" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Current default: $($Global:Config.BackupDrive)" -ForegroundColor Yellow
    Write-Host ""

    $newPath = Read-Host "Enter backup path (or press Enter for default)"

    if (-not [string]::IsNullOrWhiteSpace($newPath)) {
        $validation = Test-ValidBackupPath -Path $newPath
        if ($validation.Valid) {
            $Global:Config.BackupDrive = $newPath
            Write-Host "Backup path set to: $newPath" -ForegroundColor Green
        }
        else {
            Write-Host "Invalid path: $($validation.Reason)" -ForegroundColor Red
            Write-Host "Using default: $($Global:Config.BackupDrive)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Using default: $($Global:Config.BackupDrive)" -ForegroundColor Green
    }

    Start-Sleep -Seconds 1
}

# Verify admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script requires Administrator privileges!" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

# Prompt for backup drive on startup
Initialize-BackupDrivePrompt

Start-InteractiveMode
