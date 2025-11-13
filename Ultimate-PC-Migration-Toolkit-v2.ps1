# ========================================================================================================
# ULTIMATE PC MIGRATION TOOLKIT v2.0
# Advanced PowerShell System for Complete Application Migration
#
# Created for: Daniel Simon Jr. - Systems Engineer
# Purpose: Migrate installed applications between Windows PCs with maximum intelligence
#
# WARNING: This script performs deep system analysis and file operations.
# Run with Administrator privileges. Use at your own risk.
# Test on non-production systems first.
#
# REVISION HISTORY:
# v1.0 - Initial release
# v2.0 - Triple-checked, bug fixes, improved error handling, validation
# v2.1 - Critical fixes: registry paths, file collisions, performance, security
# ========================================================================================================

#Requires -RunAsAdministrator
#Requires -Version 5.1

# ========================================================================================================
# CONFIGURATION
# ========================================================================================================

$Global:Config = @{
    BackupDrive        = "D:\PCMigration"  # Change this to your removable drive
    LogFile            = "migration.log"
    InventoryFile      = "inventory.json"
    RegistryExportPath = "RegistryExports"
    ApplicationsPath   = "Applications"
    DLLsPath           = "DLLs"
    ConfigsPath        = "Configurations"
    PackageManagersPath = "PackageManagers"
    MaxFileSize        = 2GB  # Skip files larger than this
    ExcludedPaths      = @(
        "C:\Windows\WinSxS",
        "C:\Windows\Installer",
        "C:\Windows\System32\DriverStore"
    )
    Version            = "2.1"
    EnableFileHashing  = $false  # Set to $true for integrity verification (slower)
    HashOnlyExecutables = $true   # Only hash .exe and .dll files
}

# Validate backup drive path format
if ([string]::IsNullOrWhiteSpace($Global:Config.BackupDrive)) {
    Write-Error "BackupDrive path cannot be empty!"
    exit 1
}

# ========================================================================================================
# UTILITY FUNCTIONS
# ========================================================================================================

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

    # Ensure log directory exists before writing
    $logPath = Join-Path $Global:Config.BackupDrive $Global:Config.LogFile
    $logDir = Split-Path $logPath -Parent

    if (-not (Test-Path $logDir)) {
        try {
            New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "WARNING: Cannot create log directory: $_" -ForegroundColor Yellow
            return
        }
    }

    try {
        Add-Content -Path $logPath -Value $logMessage -ErrorAction Stop
    }
    catch {
        Write-Host "WARNING: Cannot write to log file: $_" -ForegroundColor Yellow
    }
}

function Initialize-MigrationEnvironment {
    Write-Log "Initializing Migration Environment..." -Level INFO

    # Create directory structure
    $directories = @(
        $Global:Config.BackupDrive,
        (Join-Path $Global:Config.BackupDrive $Global:Config.RegistryExportPath),
        (Join-Path $Global:Config.BackupDrive $Global:Config.ApplicationsPath),
        (Join-Path $Global:Config.BackupDrive $Global:Config.DLLsPath),
        (Join-Path $Global:Config.BackupDrive $Global:Config.ConfigsPath),
        (Join-Path $Global:Config.BackupDrive $Global:Config.PackageManagersPath)
    )

    foreach ($dir in $directories) {
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Write-Log "Created directory: $dir" -Level INFO
        }
    }

    Write-Log "Environment initialized successfully" -Level SUCCESS
}

function Get-FileHashSafe {
    param([string]$FilePath)

    # Skip hashing if disabled
    if (-not $Global:Config.EnableFileHashing) {
        return $null
    }

    try {
        if (Test-Path $FilePath) {
            $file = Get-Item $FilePath

            # If HashOnlyExecutables is enabled, only hash specific file types
            if ($Global:Config.HashOnlyExecutables) {
                if ($file.Extension -notin @('.exe', '.dll', '.sys')) {
                    return $null
                }
            }

            $hash = Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction SilentlyContinue
            return $hash.Hash
        }
    }
    catch {
        return $null
    }
    return $null
}

function Get-SafeFolderName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [string]$Version = "",
        [int]$MaxLength = 80
    )

    # Remove invalid characters
    $safeName = $Name -replace '[<>:"/\\|?*]', '_'

    # Truncate if too long
    if ($safeName.Length -gt $MaxLength) {
        $safeName = $safeName.Substring(0, $MaxLength)
    }

    # Create unique identifier from name and version
    $uniqueId = ($Name + $Version).GetHashCode().ToString("X8")

    return "$safeName`_$uniqueId"
}

function Test-PathTraversal {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    try {
        $baseResolved = [System.IO.Path]::GetFullPath($BasePath)
        $targetResolved = [System.IO.Path]::GetFullPath($TargetPath)

        return $targetResolved.StartsWith($baseResolved, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

# ========================================================================================================
# PACKAGE MANAGER DETECTION
# ========================================================================================================

function Get-WingetPackages {
    Write-Log "Detecting Winget packages..." -Level INFO

    try {
        # Check if winget is available
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $wingetCmd) {
            Write-Log "Winget not found on system" -Level WARNING
            return @()
        }

        $wingetList = winget list 2>&1 | Out-String

        if ([string]::IsNullOrWhiteSpace($wingetList)) {
            Write-Log "Winget returned empty output" -Level WARNING
            return @()
        }

        $packages = @()

        # Parse winget output - skip header lines
        $lines = $wingetList -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Skip 2

        foreach ($line in $lines) {
            # Winget format: Name  Id  Version
            # Use regex to handle variable spacing
            if ($line -match '^(.+?)\s{2,}(.+?)\s{2,}(.+?)\s*$') {
                $packages += @{
                    Name    = $matches[1].Trim()
                    Id      = $matches[2].Trim()
                    Version = $matches[3].Trim()
                    Source  = "Winget"
                }
            }
        }

        Write-Log "Found $($packages.Count) Winget packages" -Level SUCCESS
        return $packages
    }
    catch {
        Write-Log "Winget error: $_" -Level WARNING
        return @()
    }
}

function Get-ChocolateyPackages {
    Write-Log "Detecting Chocolatey packages..." -Level INFO

    try {
        $chocoPath = "$env:ProgramData\chocolatey\bin\choco.exe"

        if (-not (Test-Path $chocoPath)) {
            Write-Log "Chocolatey not installed" -Level INFO
            return @()
        }

        $chocoList = & $chocoPath list --local-only 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Log "Chocolatey command failed with exit code: $LASTEXITCODE" -Level WARNING
            return @()
        }

        $packages = @()

        foreach ($line in $chocoList) {
            # Chocolatey format: packagename version
            if ($line -match '^(.+?)\s+(.+?)$' -and $line -notmatch 'packages installed' -and $line -notmatch 'Chocolatey') {
                $packages += @{
                    Name    = $matches[1].Trim()
                    Version = $matches[2].Trim()
                    Source  = "Chocolatey"
                }
            }
        }

        Write-Log "Found $($packages.Count) Chocolatey packages" -Level SUCCESS
        return $packages
    }
    catch {
        Write-Log "Error detecting Chocolatey packages: $_" -Level WARNING
        return @()
    }
}

# ========================================================================================================
# APPLICATION INVENTORY
# ========================================================================================================

function Get-InstalledApplications {
    Write-Log "Scanning installed applications..." -Level INFO

    $applications = @()

    # Registry paths for installed applications
    $registryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $registryPaths) {
        try {
            $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation,
                              UninstallString, PSPath, InstallDate, EstimatedSize

            foreach ($app in $apps) {
                $applications += [PSCustomObject]@{
                    Name            = $app.DisplayName
                    Version         = $app.DisplayVersion
                    Publisher       = $app.Publisher
                    InstallLocation = $app.InstallLocation
                    UninstallString = $app.UninstallString
                    RegistryPath    = $app.PSPath
                    InstallDate     = $app.InstallDate
                    EstimatedSize   = $app.EstimatedSize
                    Files           = @()
                    DLLs            = @()
                    RegistryKeys    = @()
                }
            }
        }
        catch {
            Write-Log "Error reading registry path $path : $_" -Level WARNING
        }
    }

    Write-Log "Found $($applications.Count) installed applications" -Level SUCCESS
    return $applications
}

function Get-ApplicationFiles {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Application
    )

    $files = @()

    # Validate install location exists and is not empty
    if ([string]::IsNullOrWhiteSpace($Application.InstallLocation)) {
        Write-Log "No install location specified for: $($Application.Name)" -Level INFO
        return $Application
    }

    if (-not (Test-Path $Application.InstallLocation)) {
        Write-Log "Install location does not exist for: $($Application.Name)" -Level WARNING
        return $Application
    }

    # Check if path is in excluded list
    foreach ($excluded in $Global:Config.ExcludedPaths) {
        if ($Application.InstallLocation -like "$excluded*") {
            Write-Log "Skipping excluded path for: $($Application.Name)" -Level INFO
            return $Application
        }
    }

    try {
        Write-Log "Scanning files for: $($Application.Name)" -Level INFO

        # Get all files in install location with error handling
        $allFiles = Get-ChildItem -Path $Application.InstallLocation -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -lt $Global:Config.MaxFileSize -and
                $_.Length -gt 0  # Skip zero-byte files
            }

        $fileCount = 0
        $totalSize = 0

        foreach ($file in $allFiles) {
            try {
                $fileInfo = @{
                    FullPath     = $file.FullName
                    RelativePath = $file.FullName.Replace($Application.InstallLocation, "").TrimStart('\')
                    Size         = $file.Length
                    Extension    = $file.Extension
                    Hash         = Get-FileHashSafe -FilePath $file.FullName
                    LastModified = $file.LastWriteTime
                }

                $files += $fileInfo
                $fileCount++
                $totalSize += $file.Length

                # Track DLLs separately
                if ($file.Extension -eq ".dll") {
                    $Application.DLLs += $fileInfo
                }
            }
            catch {
                Write-Log "Error processing file $($file.FullName): $_" -Level WARNING
            }
        }

        $Application.Files = $files
        $sizeMB = [math]::Round($totalSize / 1MB, 2)
        Write-Log "Found $fileCount files ($sizeMB MB) for $($Application.Name)" -Level SUCCESS
    }
    catch {
        Write-Log "Error scanning files for $($Application.Name): $_" -Level ERROR
    }

    return $Application
}

function Get-ApplicationRegistryKeys {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Application
    )

    Write-Log "Scanning registry for: $($Application.Name)" -Level INFO

    $registryKeys = @()

    # Build search paths dynamically, only if values are not null
    $searchPaths = @()

    # Add paths based on what information we have
    if (-not [string]::IsNullOrWhiteSpace($Application.Name)) {
        $searchPaths += "HKLM:\Software\$($Application.Name)"
        $searchPaths += "HKCU:\Software\$($Application.Name)"
    }

    if (-not [string]::IsNullOrWhiteSpace($Application.Publisher) -and
        -not [string]::IsNullOrWhiteSpace($Application.Name)) {
        $searchPaths += "HKLM:\Software\$($Application.Publisher)\$($Application.Name)"
        $searchPaths += "HKCU:\Software\$($Application.Publisher)\$($Application.Name)"
    }

    # Also check the uninstall registry key itself
    if (-not [string]::IsNullOrWhiteSpace($Application.RegistryPath)) {
        $searchPaths += $Application.RegistryPath
    }

    foreach ($path in $searchPaths) {
        try {
            # Skip if path construction failed (contains null-like strings)
            if ($path -match '\$\(.*\)' -or $path -match '\\\\') {
                continue
            }

            $cleanPath = $path -replace 'HKLM:', 'HKEY_LOCAL_MACHINE' `
                              -replace 'HKCU:', 'HKEY_CURRENT_USER' `
                              -replace 'HKCR:', 'HKEY_CLASSES_ROOT'

            if (Test-Path $path -ErrorAction SilentlyContinue) {
                $registryKeys += @{
                    Path           = $cleanPath
                    PowerShellPath = $path
                    Exists         = $true
                }
            }
        }
        catch {
            # Path doesn't exist or is invalid, continue
            Write-Log "Invalid or inaccessible registry path: $path" -Level INFO
        }
    }

    $Application.RegistryKeys = $registryKeys
    Write-Log "Found $($registryKeys.Count) registry keys for $($Application.Name)" -Level SUCCESS

    return $Application
}

# ========================================================================================================
# BACKUP FUNCTIONS
# ========================================================================================================

function Backup-ApplicationFiles {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Application
    )

    if (-not $Application.Files -or $Application.Files.Count -eq 0) {
        Write-Log "No files to backup for $($Application.Name)" -Level INFO
        return
    }

    $appBackupPath = Join-Path $Global:Config.BackupDrive $Global:Config.ApplicationsPath

    # Use safe folder name with unique identifier to prevent collisions
    $safeName = Get-SafeFolderName -Name $Application.Name -Version $Application.Version

    $appFolder = Join-Path $appBackupPath $safeName

    if (-not (Test-Path $appFolder)) {
        try {
            New-Item -Path $appFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log "Failed to create backup folder for $($Application.Name): $_" -Level ERROR
            return
        }
    }

    Write-Log "Backing up files for: $($Application.Name)" -Level INFO
    $copiedCount = 0
    $errorCount = 0
    $skippedCount = 0

    foreach ($file in $Application.Files) {
        try {
            # Validate source file still exists
            if (-not (Test-Path $file.FullPath)) {
                $skippedCount++
                continue
            }

            # Build destination path
            $destPath = Join-Path $appFolder $file.RelativePath

            # Security check: Prevent path traversal attacks
            if (-not (Test-PathTraversal -BasePath $appFolder -TargetPath $destPath)) {
                $errorCount++
                Write-Log "Path traversal attempt detected: $($file.RelativePath)" -Level ERROR
                continue
            }

            $destDir = Split-Path $destPath -Parent

            # Create destination directory if needed
            if (-not (Test-Path $destDir)) {
                New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            # Copy file with verification
            Copy-Item -Path $file.FullPath -Destination $destPath -Force -ErrorAction Stop

            # Verify copy succeeded
            if (Test-Path $destPath) {
                $copiedCount++
            }
            else {
                $errorCount++
                Write-Log "Copy verification failed for: $($file.FullPath)" -Level WARNING
            }
        }
        catch [System.IO.PathTooLongException] {
            $errorCount++
            Write-Log "Path too long, skipped: $($file.RelativePath)" -Level WARNING
        }
        catch [System.UnauthorizedAccessException] {
            $errorCount++
            Write-Log "Access denied: $($file.FullPath)" -Level WARNING
        }
        catch {
            $errorCount++
            Write-Log "Failed to copy: $($file.FullPath) - $_" -Level WARNING
        }
    }

    $totalProcessed = $copiedCount + $errorCount + $skippedCount
    Write-Log "Backup complete for $($Application.Name): $copiedCount copied, $errorCount errors, $skippedCount skipped" -Level SUCCESS
}

function Backup-ApplicationRegistry {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Application
    )

    if ($Application.RegistryKeys.Count -eq 0) {
        Write-Log "No registry keys to backup for $($Application.Name)" -Level INFO
        return
    }

    $regBackupPath = Join-Path $Global:Config.BackupDrive $Global:Config.RegistryExportPath
    $safeName = Get-SafeFolderName -Name $Application.Name -Version $Application.Version

    Write-Log "Backing up registry for: $($Application.Name)" -Level INFO

    foreach ($regKey in $Application.RegistryKeys) {
        if ($regKey.Exists) {
            try {
                $fileName = ($regKey.Path -replace '\\', '_') + ".reg"
                $exportPath = Join-Path $regBackupPath "$safeName`_$fileName"

                # Ensure path is not too long
                if ($exportPath.Length -gt 240) {
                    $fileName = $fileName.Substring(0, [Math]::Min($fileName.Length, 100)) + ".reg"
                    $exportPath = Join-Path $regBackupPath "$safeName`_$fileName"
                }

                # Export registry key using reg.exe
                $regPath = $regKey.Path
                $regOutput = & reg export $regPath $exportPath /y 2>&1

                # Check exit code and file existence
                if ($LASTEXITCODE -eq 0 -and (Test-Path $exportPath)) {
                    Write-Log "Exported registry: $($regKey.Path)" -Level SUCCESS
                }
                else {
                    Write-Log "Registry export failed (Exit: $LASTEXITCODE): $($regKey.Path)" -Level WARNING
                    if ($regOutput) {
                        Write-Log "Output: $regOutput" -Level INFO
                    }
                }
            }
            catch {
                Write-Log "Failed to export registry: $($regKey.Path) - $_" -Level WARNING
            }
        }
    }
}

function Backup-SharedDLLs {
    Write-Log "Backing up shared system DLLs..." -Level INFO

    $dllBackupPath = Join-Path $Global:Config.BackupDrive $Global:Config.DLLsPath
    $systemDLLs = @(
        "C:\Windows\System32\*.dll",
        "C:\Windows\SysWOW64\*.dll"
    )

    # Only backup DLLs referenced by applications
    $referencedDLLs = @{}

    # This is a simplified approach - in reality, you'd want to track which DLLs
    # are actually used by your applications
    Write-Log "Shared DLL backup is complex - consider using dependency walker for production use" -Level WARNING
}

function Backup-ApplicationConfigurations {
    Write-Log "Backing up application configurations..." -Level INFO

    $configBackupPath = Join-Path $Global:Config.BackupDrive $Global:Config.ConfigsPath

    # Common configuration locations
    $configPaths = @(
        "$env:APPDATA",
        "$env:LOCALAPPDATA",
        "$env:ProgramData"
    )

    # This is a complex task - backing up ALL AppData can be huge
    # Better to do this selectively for known important apps
    Write-Log "Configuration backup requires selective approach - see script for details" -Level WARNING
}

function Export-PackageManagerLists {
    Write-Log "Exporting package manager lists..." -Level INFO

    $pmPath = Join-Path $Global:Config.BackupDrive $Global:Config.PackageManagersPath

    if (-not (Test-Path $pmPath)) {
        New-Item -Path $pmPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    # Export Winget
    try {
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetCmd) {
            $wingetExport = Join-Path $pmPath "winget_packages.json"
            $output = winget export -o $wingetExport 2>&1

            if ($LASTEXITCODE -eq 0 -and (Test-Path $wingetExport)) {
                Write-Log "Winget packages exported to: $wingetExport" -Level SUCCESS
            }
            else {
                Write-Log "Winget export failed with exit code: $LASTEXITCODE" -Level WARNING
            }
        }
        else {
            Write-Log "Winget not available for export" -Level INFO
        }
    }
    catch {
        Write-Log "Failed to export Winget packages: $_" -Level WARNING
    }

    # Export Chocolatey
    try {
        $chocoPath = "$env:ProgramData\chocolatey\bin\choco.exe"
        if (Test-Path $chocoPath) {
            $chocoExport = Join-Path $pmPath "chocolatey_packages.config"
            $output = & $chocoPath export $chocoExport 2>&1

            if ($LASTEXITCODE -eq 0 -and (Test-Path $chocoExport)) {
                Write-Log "Chocolatey packages exported to: $chocoExport" -Level SUCCESS
            }
            else {
                Write-Log "Chocolatey export failed with exit code: $LASTEXITCODE" -Level WARNING
            }
        }
        else {
            Write-Log "Chocolatey not available for export" -Level INFO
        }
    }
    catch {
        Write-Log "Failed to export Chocolatey packages: $_" -Level WARNING
    }
}

# ========================================================================================================
# MAIN BACKUP ORCHESTRATION
# ========================================================================================================

function Start-FullSystemBackup {
    Write-Log "========================================" -Level INFO
    Write-Log "STARTING FULL SYSTEM BACKUP v$($Global:Config.Version)" -Level INFO
    Write-Log "========================================" -Level INFO

    $startTime = Get-Date

    # CRITICAL: Validate backup drive is accessible FIRST
    if (-not (Test-Path $Global:Config.BackupDrive)) {
        Write-Log "Backup drive not accessible: $($Global:Config.BackupDrive)" -Level ERROR
        Write-Host "`nERROR: Backup drive '$($Global:Config.BackupDrive)' is not accessible!" -ForegroundColor Red
        Write-Host "Please verify the drive is connected and the path is correct." -ForegroundColor Yellow
        return
    }

    # CRITICAL: Check available disk space BEFORE starting backup
    try {
        $drive = Get-PSDrive -Name $Global:Config.BackupDrive.Substring(0,1) -ErrorAction SilentlyContinue
        if ($drive) {
            $freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
            Write-Log "Available space on backup drive: $freeSpaceGB GB" -Level INFO

            if ($freeSpaceGB -lt 10) {
                Write-Log "WARNING: Low disk space on backup drive ($freeSpaceGB GB)" -Level WARNING
                Write-Host "`nWARNING: Only $freeSpaceGB GB available on backup drive!" -ForegroundColor Yellow
                Write-Host "This may not be enough space for a complete backup." -ForegroundColor Yellow
                $continue = Read-Host "Continue anyway? (Y/N)"
                if ($continue -ne 'Y') {
                    Write-Log "Backup cancelled by user due to low disk space" -Level INFO
                    return
                }
            }
        }
    }
    catch {
        Write-Log "Could not check disk space: $_" -Level WARNING
    }

    # Initialize environment (only after validations pass)
    Initialize-MigrationEnvironment

    # Get package manager information
    $wingetPackages = Get-WingetPackages
    $chocoPackages = Get-ChocolateyPackages

    # Export package manager lists
    Export-PackageManagerLists

    # Get all installed applications
    $applications = Get-InstalledApplications

    if ($applications.Count -eq 0) {
        Write-Log "No applications found to backup!" -Level WARNING
        return
    }

    Write-Log "Processing $($applications.Count) applications..." -Level INFO

    $inventory = @{
        BackupDate         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ComputerName       = $env:COMPUTERNAME
        UserName           = $env:USERNAME
        WindowsVersion     = (Get-CimInstance Win32_OperatingSystem).Caption
        WindowsBuild       = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        WingetPackages     = $wingetPackages
        ChocolateyPackages = $chocoPackages
        Applications       = @()
        Statistics         = @{
            TotalApplications  = 0
            SuccessfulBackups  = 0
            FailedBackups      = 0
            TotalFiles         = 0
            TotalSizeMB        = 0
        }
    }

    $progressCount = 0
    $successCount = 0
    $failCount = 0

    foreach ($app in $applications) {
        $progressCount++
        $percentComplete = [math]::Round(($progressCount / $applications.Count) * 100, 2)

        Write-Progress -Activity "Processing Applications" `
                       -Status "Processing: $($app.Name) ($progressCount of $($applications.Count))" `
                       -PercentComplete $percentComplete

        Write-Log "[$progressCount/$($applications.Count)] Processing: $($app.Name)" -Level INFO

        try {
            # Get files and registry keys
            $app = Get-ApplicationFiles -Application $app
            $app = Get-ApplicationRegistryKeys -Application $app

            # Backup files and registry
            Backup-ApplicationFiles -Application $app
            Backup-ApplicationRegistry -Application $app

            $inventory.Applications += $app
            $successCount++
        }
        catch {
            Write-Log "Failed to process application $($app.Name): $_" -Level ERROR
            $failCount++
        }
    }

    Write-Progress -Activity "Processing Applications" -Completed

    # Calculate statistics
    $inventory.Statistics.TotalApplications = $applications.Count
    $inventory.Statistics.SuccessfulBackups = $successCount
    $inventory.Statistics.FailedBackups = $failCount
    $inventory.Statistics.TotalFiles = ($inventory.Applications | ForEach-Object { $_.Files.Count } | Measure-Object -Sum).Sum
    $inventory.Statistics.TotalSizeMB = [math]::Round(($inventory.Applications |
        ForEach-Object { ($_.Files | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum } |
        Measure-Object -Sum).Sum / 1MB, 2)

    # Save inventory with increased depth to prevent truncation
    $inventoryPath = Join-Path $Global:Config.BackupDrive $Global:Config.InventoryFile
    try {
        # Use Depth 20 and Compress to handle deeply nested structures
        $inventory | ConvertTo-Json -Depth 20 -Compress | Out-File $inventoryPath -Encoding UTF8 -ErrorAction Stop
        Write-Log "Inventory saved to: $inventoryPath" -Level SUCCESS

        # Verify inventory file was created
        if (Test-Path $inventoryPath) {
            $fileSize = (Get-Item $inventoryPath).Length / 1KB
            Write-Log "Inventory file size: $([math]::Round($fileSize, 2)) KB" -Level INFO
        }
    }
    catch {
        Write-Log "Failed to save inventory: $_" -Level ERROR
        Write-Host "`nWARNING: Failed to save inventory file!" -ForegroundColor Red
        Write-Host "Backup data exists but inventory may be incomplete." -ForegroundColor Yellow
    }

    $endTime = Get-Date
    $duration = $endTime - $startTime

    Write-Log "========================================" -Level SUCCESS
    Write-Log "BACKUP COMPLETED" -Level SUCCESS
    Write-Log "Duration: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s" -Level SUCCESS
    Write-Log "Applications: $successCount successful, $failCount failed" -Level SUCCESS
    Write-Log "Total Files: $($inventory.Statistics.TotalFiles)" -Level SUCCESS
    Write-Log "Total Size: $($inventory.Statistics.TotalSizeMB) MB" -Level SUCCESS
    Write-Log "========================================" -Level SUCCESS
}

# ========================================================================================================
# RESTORATION FUNCTIONS
# ========================================================================================================

function Start-ApplicationRestoration {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BackupPath
    )

    Write-Log "========================================" -Level INFO
    Write-Log "STARTING APPLICATION RESTORATION" -Level INFO
    Write-Log "========================================" -Level INFO

    # Load inventory
    $inventoryPath = Join-Path $BackupPath "inventory.json"

    if (-not (Test-Path $inventoryPath)) {
        Write-Log "Inventory file not found: $inventoryPath" -Level ERROR
        return
    }

    Write-Log "Loading inventory from: $inventoryPath" -Level INFO
    $inventory = Get-Content $inventoryPath | ConvertFrom-Json

    Write-Log "Backup created on: $($inventory.BackupDate)" -Level INFO
    Write-Log "Source computer: $($inventory.ComputerName)" -Level INFO
    Write-Log "Applications to restore: $($inventory.Applications.Count)" -Level INFO

    # First, restore package managers
    Restore-PackageManagers -BackupPath $BackupPath -Inventory $inventory

    # Then restore applications
    foreach ($app in $inventory.Applications) {
        Write-Log "Restoring: $($app.Name)" -Level INFO
        Restore-ApplicationFiles -Application $app -BackupPath $BackupPath
        Restore-ApplicationRegistry -Application $app -BackupPath $BackupPath
    }

    Write-Log "========================================" -Level SUCCESS
    Write-Log "RESTORATION COMPLETED" -Level SUCCESS
    Write-Log "========================================" -Level SUCCESS
    Write-Log "IMPORTANT: Some applications may require reactivation or reinstallation" -Level WARNING
}

function Restore-PackageManagers {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BackupPath,
        [Parameter(Mandatory=$true)]
        [object]$Inventory
    )

    Write-Log "Restoring package manager installations..." -Level INFO

    $pmPath = Join-Path $BackupPath "PackageManagers"

    if (-not (Test-Path $pmPath)) {
        Write-Log "Package manager backup folder not found" -Level WARNING
        return
    }

    # Restore Winget packages
    $wingetFile = Join-Path $pmPath "winget_packages.json"
    if (Test-Path $wingetFile) {
        Write-Log "Restoring Winget packages..." -Level INFO
        try {
            $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
            if (-not $wingetCmd) {
                Write-Log "Winget not available on this system" -Level WARNING
            }
            else {
                $output = winget import -i $wingetFile --ignore-versions --accept-package-agreements --accept-source-agreements 2>&1

                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Winget packages restored successfully" -Level SUCCESS
                }
                else {
                    Write-Log "Winget restore completed with exit code: $LASTEXITCODE" -Level WARNING
                }
            }
        }
        catch {
            Write-Log "Error restoring Winget packages: $_" -Level ERROR
        }
    }
    else {
        Write-Log "Winget package file not found" -Level INFO
    }

    # Restore Chocolatey packages
    $chocoFile = Join-Path $pmPath "chocolatey_packages.config"
    if (Test-Path $chocoFile) {
        $chocoPath = "$env:ProgramData\chocolatey\bin\choco.exe"
        if (Test-Path $chocoPath) {
            Write-Log "Restoring Chocolatey packages..." -Level INFO
            try {
                $output = & $chocoPath install $chocoFile -y 2>&1

                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Chocolatey packages restored successfully" -Level SUCCESS
                }
                else {
                    Write-Log "Chocolatey restore completed with exit code: $LASTEXITCODE" -Level WARNING
                }
            }
            catch {
                Write-Log "Error restoring Chocolatey packages: $_" -Level ERROR
            }
        }
        else {
            Write-Log "Chocolatey not installed - skipping package restoration" -Level WARNING
            Write-Log "Install Chocolatey first, then re-run restoration" -Level INFO
        }
    }
    else {
        Write-Log "Chocolatey package file not found" -Level INFO
    }
}

function Restore-ApplicationFiles {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Application,
        [Parameter(Mandatory=$true)]
        [string]$BackupPath
    )

    if (-not $Application.InstallLocation) {
        Write-Log "No install location for $($Application.Name) - skipping" -Level WARNING
        return
    }

    $appBackupPath = Join-Path $BackupPath "Applications"

    # Use the same safe folder name generation for consistency
    $safeName = Get-SafeFolderName -Name $Application.Name -Version $Application.Version
    $appFolder = Join-Path $appBackupPath $safeName

    if (-not (Test-Path $appFolder)) {
        Write-Log "Backup folder not found for $($Application.Name)" -Level WARNING
        return
    }

    Write-Log "Restoring files for: $($Application.Name)" -Level INFO

    try {
        # Validate install location to prevent path traversal
        $installLocationResolved = [System.IO.Path]::GetFullPath($Application.InstallLocation)

        # Ensure we're not writing to sensitive system directories
        $systemPaths = @('C:\Windows', 'C:\Program Files\WindowsApps')
        foreach ($sysPath in $systemPaths) {
            if ($installLocationResolved.StartsWith($sysPath, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "WARNING: Attempt to restore to system directory: $installLocationResolved" -Level WARNING
                Write-Host "`nWARNING: Application wants to restore to system directory!" -ForegroundColor Yellow
                Write-Host "Path: $installLocationResolved" -ForegroundColor Yellow
                $confirm = Read-Host "Continue? (Y/N)"
                if ($confirm -ne 'Y') {
                    Write-Log "Skipped restoration to system directory" -Level INFO
                    return
                }
                break
            }
        }

        # Create install directory if it doesn't exist
        if (-not (Test-Path $Application.InstallLocation)) {
            New-Item -Path $Application.InstallLocation -ItemType Directory -Force | Out-Null
        }

        # Copy all files with verification
        $filesBeforeRestore = @(Get-ChildItem -Path $appFolder -Recurse -File).Count
        Copy-Item -Path "$appFolder\*" -Destination $Application.InstallLocation -Recurse -Force

        # Verify restoration
        $filesAfterRestore = @(Get-ChildItem -Path $Application.InstallLocation -Recurse -File).Count

        if ($filesAfterRestore -gt 0) {
            Write-Log "Files restored for: $($Application.Name) ($filesAfterRestore files)" -Level SUCCESS
        }
        else {
            Write-Log "WARNING: No files found after restoration for: $($Application.Name)" -Level WARNING
        }
    }
    catch {
        Write-Log "Error restoring files for $($Application.Name): $_" -Level ERROR
    }
}

function Restore-ApplicationRegistry {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Application,
        [Parameter(Mandatory=$true)]
        [string]$BackupPath
    )

    $regBackupPath = Join-Path $BackupPath "RegistryExports"

    # Use the same safe folder name generation for consistency
    $safeName = Get-SafeFolderName -Name $Application.Name -Version $Application.Version

    # Find all .reg files for this application
    $regFiles = Get-ChildItem -Path $regBackupPath -Filter "$safeName*.reg" -ErrorAction SilentlyContinue

    if ($regFiles.Count -eq 0) {
        Write-Log "No registry files found for $($Application.Name)" -Level INFO
        return
    }

    Write-Log "Restoring registry for: $($Application.Name)" -Level INFO

    foreach ($regFile in $regFiles) {
        try {
            # Security: Validate registry file content
            $content = Get-Content $regFile.FullName -Raw -ErrorAction Stop

            # Check for suspicious registry modifications
            $suspiciousKeys = @(
                'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run',
                'HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run',
                'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options'
            )

            $foundSuspicious = $false
            foreach ($suspKey in $suspiciousKeys) {
                if ($content -match [regex]::Escape($suspKey)) {
                    $foundSuspicious = $true
                    Write-Log "WARNING: Registry file modifies autostart/sensitive keys: $($regFile.Name)" -Level WARNING
                    Write-Host "`nWARNING: Registry file $($regFile.Name) modifies system autostart keys!" -ForegroundColor Yellow
                    $confirm = Read-Host "This could be a security risk. Import anyway? (Y/N)"
                    if ($confirm -ne 'Y') {
                        Write-Log "Skipped registry import: $($regFile.Name)" -Level INFO
                        continue
                    }
                    break
                }
            }

            # Import registry file using reg.exe
            $regOutput = & reg import $regFile.FullName 2>&1

            # Check exit code
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Imported registry: $($regFile.Name)" -Level SUCCESS
            }
            else {
                Write-Log "Failed to import registry (Exit: $LASTEXITCODE): $($regFile.Name)" -Level ERROR
                if ($regOutput) {
                    Write-Log "Output: $regOutput" -Level INFO
                }
            }
        }
        catch {
            Write-Log "Failed to import registry: $($regFile.Name) - $_" -Level ERROR
        }
    }
}

# ========================================================================================================
# MAIN MENU INTERFACE
# ========================================================================================================

function Show-MainMenu {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  ULTIMATE PC MIGRATION TOOLKIT" -ForegroundColor Cyan
    Write-Host "  Advanced Application Migration System" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Start Full Backup (Inventory & Copy)" -ForegroundColor Green
    Write-Host "2. Restore from Backup" -ForegroundColor Yellow
    Write-Host "3. View Inventory" -ForegroundColor Cyan
    Write-Host "4. Export Package Manager Lists Only" -ForegroundColor Magenta
    Write-Host "5. Configure Backup Drive" -ForegroundColor White
    Write-Host "6. Exit" -ForegroundColor Red
    Write-Host ""
    Write-Host "Current Backup Drive: $($Global:Config.BackupDrive)" -ForegroundColor Gray
    Write-Host ""
}

function Start-InteractiveMode {
    do {
        Show-MainMenu
        $choice = Read-Host "Select an option (1-6)"

        switch ($choice) {
            "1" {
                Write-Host "`nStarting Full Backup..." -ForegroundColor Green
                Start-FullSystemBackup
                Read-Host "`nPress Enter to continue"
            }
            "2" {
                Write-Host "`nStarting Restoration..." -ForegroundColor Yellow
                $backupPath = Read-Host "Enter backup path (or press Enter for default: $($Global:Config.BackupDrive))"
                if ([string]::IsNullOrWhiteSpace($backupPath)) {
                    $backupPath = $Global:Config.BackupDrive
                }
                Start-ApplicationRestoration -BackupPath $backupPath
                Read-Host "`nPress Enter to continue"
            }
            "3" {
                $inventoryPath = Join-Path $Global:Config.BackupDrive $Global:Config.InventoryFile
                if (Test-Path $inventoryPath) {
                    $inventory = Get-Content $inventoryPath | ConvertFrom-Json
                    Write-Host "`nInventory Summary:" -ForegroundColor Cyan
                    Write-Host "Backup Date: $($inventory.BackupDate)"
                    Write-Host "Computer: $($inventory.ComputerName)"
                    Write-Host "Applications: $($inventory.Applications.Count)"
                    Write-Host "Winget Packages: $($inventory.WingetPackages.Count)"
                    Write-Host "Chocolatey Packages: $($inventory.ChocolateyPackages.Count)"
                }
                else {
                    Write-Host "`nNo inventory found at: $inventoryPath" -ForegroundColor Red
                }
                Read-Host "`nPress Enter to continue"
            }
            "4" {
                Export-PackageManagerLists
                Write-Host "`nPackage manager lists exported" -ForegroundColor Green
                Read-Host "`nPress Enter to continue"
            }
            "5" {
                $newPath = Read-Host "Enter new backup drive path"
                if (Test-Path $newPath) {
                    $Global:Config.BackupDrive = $newPath
                    Write-Host "Backup drive updated to: $newPath" -ForegroundColor Green
                }
                else {
                    Write-Host "Path does not exist!" -ForegroundColor Red
                }
                Read-Host "`nPress Enter to continue"
            }
            "6" {
                Write-Host "`nExiting... Thank you for using the Ultimate PC Migration Toolkit!" -ForegroundColor Cyan
                return
            }
            default {
                Write-Host "`nInvalid option. Please select 1-6." -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    } while ($true)
}

# ========================================================================================================
# SCRIPT ENTRY POINT
# ========================================================================================================

# Check for Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script requires Administrator privileges!" -ForegroundColor Red
    Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
    exit
}

# Start interactive mode
Start-InteractiveMode
