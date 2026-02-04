# ============================================================================
# PC MIGRATION TOOLKIT v3.6.1
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
# CLI USAGE:
#   .\PC-Migration-Tool.ps1 backup -Path D:\Backup
#   .\PC-Migration-Tool.ps1 restore -Path D:\Backup
#   .\PC-Migration-Tool.ps1 verify -Path D:\Backup
#   .\PC-Migration-Tool.ps1 inventory -Path D:\Backup
#   .\PC-Migration-Tool.ps1 -Help
#
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("backup", "restore", "verify", "inventory", "")]
    [string]$Command = "",

    [Parameter()]
    [Alias("p")]
    [string]$Path = "",

    [Parameter()]
    [Alias("y")]
    [switch]$Yes,

    [Parameter()]
    [Alias("h", "?")]
    [switch]$Help
)

#Requires -RunAsAdministrator
#Requires -Version 5.1

# ============================================================================
# CONFIGURATION
# ============================================================================

$Global:Config = @{
    BackupDrive         = "D:\PCMigration"
    LogFile             = "migration.log"
    Version             = "3.6.1"

    # Backup entire user profile (set to $true to scan all folders)
    BackupFullProfile   = $true

    # Sensitive folders - user will be prompted before backing these up
    # (Empty - .ssh now included by default since it may contain important keys)
    SensitiveFolders    = @(
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

    # Folders to exclude (cloud sync, system junctions, temp data)
    ExcludeFolders      = @(
        # Cloud sync folders (already backed up to servers)
        "Dropbox",
        "OneDrive",
        "OneDrive - *",
        "Google Drive",
        "iCloudDrive",
        "iCloud Drive",
        "Box",
        "Box Sync",
        "Creative Cloud Files",
        # System junction folders (not real folders, just links)
        "Application Data",
        "Local Settings",
        "My Documents",
        "NetHood",
        "PrintHood",
        "Recent",
        "SendTo",
        "Start Menu",
        "Templates",
        "Cookies",
        # AppData handled separately
        "AppData",
        # Temp/cache folders
        "Tracing",
        ".cache",
        ".local",
        # Package manager caches (can be huge)
        "scoop",
        ".minikube",
        ".android"
    )

    # File patterns to exclude
    ExcludePatterns     = @(
        "node_modules",
        ".git\objects",
        "__pycache__",
        "*.tmp",
        "*.log",
        "Thumbs.db",
        "desktop.ini"
    )
}

# Get the folder where this exe/script is located (set at startup)
$Global:ExeFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([Environment]::GetCommandLineArgs()[0]) }
if (-not $Global:ExeFolder -or $Global:ExeFolder -eq "") { $Global:ExeFolder = (Get-Location).Path }

# ============================================================================
# FOLDER PATH RESOLUTION (handles OneDrive redirection)
# ============================================================================

# Map logical folder names to Windows Shell special folder enum values
$Global:ShellFolderMap = @{
    "Documents"  = "MyDocuments"
    "Desktop"    = "Desktop"
    "Downloads"  = $null  # No Shell constant, handled separately
    "Pictures"   = "MyPictures"
    "Videos"     = "MyVideos"
    "Music"      = "MyMusic"
}

function Get-ActualFolderPath {
    param([string]$FolderName)

    # For files like .gitconfig, just use user profile
    if ($FolderName -match '^\.' -or $FolderName -match '\.\w+$') {
        return Join-Path $env:USERPROFILE $FolderName
    }

    # Try Shell API first (handles OneDrive redirection)
    if ($Global:ShellFolderMap.ContainsKey($FolderName)) {
        $shellName = $Global:ShellFolderMap[$FolderName]
        if ($shellName) {
            $shellPath = [Environment]::GetFolderPath($shellName)
            if ($shellPath -and (Test-Path $shellPath)) {
                return $shellPath
            }
        }
    }

    # Special handling for Downloads (no Shell constant)
    if ($FolderName -eq "Downloads") {
        # Try Known Folder API via registry
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
        $downloads = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue)."{374DE290-123F-4565-9164-39C4925E467B}"
        if ($downloads -and (Test-Path $downloads)) {
            return $downloads
        }
        # Fallback to profile path
        $fallback = Join-Path $env:USERPROFILE "Downloads"
        if (Test-Path $fallback) {
            return $fallback
        }
    }

    # Fallback: try user profile path
    $profilePath = Join-Path $env:USERPROFILE $FolderName
    if (Test-Path $profilePath) {
        return $profilePath
    }

    return $null
}

# Progress tracking for resume capability
$Global:Progress = @{
    Operation = $null          # "backup" or "restore"
    StartTime = $null
    CompletedSteps = @()       # List of completed step names
    CurrentStep = $null        # Current step being processed
    Checksums = @{}            # File checksums for verification
    Interrupted = $false       # Flag for graceful interruption
}

# ============================================================================
# PROGRESS TRACKING & RESUME
# ============================================================================

function Save-Progress {
    param([string]$BackupPath)

    $progressFile = Join-Path $BackupPath "backup-progress.json"
    $progressData = @{
        Operation = $Global:Progress.Operation
        StartTime = $Global:Progress.StartTime
        LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        CompletedSteps = $Global:Progress.CompletedSteps
        CurrentStep = $Global:Progress.CurrentStep
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
    }

    try {
        $progressData | ConvertTo-Json -Depth 5 | Out-File -FilePath $progressFile -Encoding UTF8 -Force
    }
    catch {
        Write-Log "Could not save progress: $_" -Level WARNING
    }
}

function Get-SavedProgress {
    param([string]$BackupPath)

    $progressFile = Join-Path $BackupPath "backup-progress.json"

    if (Test-Path $progressFile) {
        try {
            $progress = Get-Content $progressFile -Raw | ConvertFrom-Json
            return $progress
        }
        catch {
            return $null
        }
    }
    return $null
}

function Clear-Progress {
    param([string]$BackupPath)

    $progressFile = Join-Path $BackupPath "backup-progress.json"
    if (Test-Path $progressFile) {
        Remove-Item $progressFile -Force -ErrorAction SilentlyContinue
    }

    $Global:Progress.CompletedSteps = @()
    $Global:Progress.CurrentStep = $null
}

function Mark-StepComplete {
    param(
        [string]$StepName,
        [string]$BackupPath
    )

    if ($StepName -notin $Global:Progress.CompletedSteps) {
        $Global:Progress.CompletedSteps += $StepName
    }
    $Global:Progress.CurrentStep = $null
    Save-Progress -BackupPath $BackupPath

    Write-Host "  [OK] $StepName complete - safe to close" -ForegroundColor DarkGreen
}

function Test-StepCompleted {
    param([string]$StepName)

    return $StepName -in $Global:Progress.CompletedSteps
}

function Set-CurrentStep {
    param(
        [string]$StepName,
        [string]$BackupPath
    )

    $Global:Progress.CurrentStep = $StepName
    Save-Progress -BackupPath $BackupPath
}

# ============================================================================
# CHECKSUM VERIFICATION
# ============================================================================

function Get-FileChecksum {
    param([string]$FilePath)

    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm MD5 -ErrorAction Stop
        return $hash.Hash
    }
    catch {
        return $null
    }
}

function Save-Checksums {
    param(
        [string]$BackupPath,
        [hashtable]$Checksums
    )

    $checksumFile = Join-Path $BackupPath "checksums.json"
    try {
        $Checksums | ConvertTo-Json -Depth 5 | Out-File -FilePath $checksumFile -Encoding UTF8 -Force
        Write-Log "Saved checksums for $($Checksums.Count) files" -Level INFO
    }
    catch {
        Write-Log "Could not save checksums: $_" -Level WARNING
    }
}

function Get-SavedChecksums {
    param([string]$BackupPath)

    $checksumFile = Join-Path $BackupPath "checksums.json"

    if (Test-Path $checksumFile) {
        try {
            $content = Get-Content $checksumFile -Raw | ConvertFrom-Json
            $checksums = @{}
            $content.PSObject.Properties | ForEach-Object {
                $checksums[$_.Name] = $_.Value
            }
            return $checksums
        }
        catch {
            return @{}
        }
    }
    return @{}
}

function Test-BackupIntegrity {
    param([string]$BackupPath)

    $savedChecksums = Get-SavedChecksums -BackupPath $BackupPath

    if ($savedChecksums.Count -eq 0) {
        return @{ Verified = $false; FilesChecked = 0; Errors = @("No checksums found") }
    }

    $errors = @()
    $filesChecked = 0

    foreach ($relativePath in $savedChecksums.Keys) {
        $fullPath = Join-Path $BackupPath $relativePath

        if (-not (Test-Path $fullPath)) {
            $errors += "Missing: $relativePath"
            continue
        }

        $currentHash = Get-FileChecksum -FilePath $fullPath
        if ($currentHash -ne $savedChecksums[$relativePath]) {
            $errors += "Corrupted: $relativePath"
        }
        $filesChecked++
    }

    return @{
        Verified = ($errors.Count -eq 0)
        FilesChecked = $filesChecked
        Errors = $errors
    }
}

# ============================================================================
# GRACEFUL INTERRUPTION
# ============================================================================

function Register-InterruptHandler {
    param([string]$BackupPath)

    # Register Ctrl+C handler
    [Console]::TreatControlCAsInput = $false

    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        if ($Global:Progress.CurrentStep) {
            Write-Host "`n`nInterrupted during: $($Global:Progress.CurrentStep)" -ForegroundColor Yellow
            Write-Host "Progress saved. You can resume next time." -ForegroundColor Yellow
        }
    } -SupportEvent
}

function Show-InterruptMessage {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host "  OPERATION INTERRUPTED" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Your progress has been saved." -ForegroundColor White
    Write-Host "Run the tool again to resume where you left off." -ForegroundColor White
    Write-Host ""
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

function Install-Winget {
    Write-Log "Installing Winget..." -Level INFO

    try {
        # Winget is part of App Installer from Microsoft Store
        # Try to install via Add-AppxPackage from GitHub releases
        $progressPreference = 'SilentlyContinue'
        $latestWinget = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
        $wingetUrl = $latestWinget.assets | Where-Object { $_.name -match '\.msixbundle$' } | Select-Object -First 1 -ExpandProperty browser_download_url

        if ($wingetUrl) {
            $wingetPath = Join-Path $env:TEMP "winget.msixbundle"
            Invoke-WebRequest -Uri $wingetUrl -OutFile $wingetPath
            Add-AppxPackage -Path $wingetPath -ErrorAction Stop
            Remove-Item $wingetPath -Force -ErrorAction SilentlyContinue
            Write-Log "Winget installed successfully" -Level SUCCESS
            return $true
        }
    }
    catch {
        Write-Log "Failed to install Winget: $_" -Level ERROR
        Write-Host "Please install Winget manually from the Microsoft Store (App Installer)" -ForegroundColor Yellow
    }
    return $false
}

function Install-Chocolatey {
    Write-Log "Installing Chocolatey..." -Level INFO

    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

        # Refresh environment
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        Write-Log "Chocolatey installed successfully" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Failed to install Chocolatey: $_" -Level ERROR
    }
    return $false
}

function Install-Scoop {
    Write-Log "Installing Scoop..." -Level INFO

    try {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Invoke-RestMethod get.scoop.sh | Invoke-Expression

        # Refresh environment
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        Write-Log "Scoop installed successfully" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Failed to install Scoop: $_" -Level ERROR
    }
    return $false
}

function Install-RequiredPackageManagers {
    param([string]$BackupPath)

    $pmPath = Join-Path $BackupPath "PackageManagers"
    $installed = @()

    # Check what package manager exports exist in backup
    $hasWinget = Test-Path (Join-Path $pmPath "winget-packages.json")
    $hasChoco = Test-Path (Join-Path $pmPath "chocolatey-packages.config")
    $hasScoop = Test-Path (Join-Path $pmPath "scoop-packages.json")

    Write-Host ""
    Write-Host "Checking package managers..." -ForegroundColor Cyan

    # Check and install Winget
    if ($hasWinget) {
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $wingetCmd) {
            Write-Host "Winget packages found in backup but Winget is not installed." -ForegroundColor Yellow
            $install = Read-Host "Install Winget? (Y/N)"
            if ($install -eq 'Y') {
                if (Install-Winget) {
                    $installed += "Winget"
                }
            }
        }
        else {
            Write-Host "  Winget: Installed" -ForegroundColor Green
        }
    }

    # Check and install Chocolatey
    if ($hasChoco) {
        $chocoPath = "$env:ProgramData\chocolatey\bin\choco.exe"
        if (-not (Test-Path $chocoPath)) {
            Write-Host "Chocolatey packages found in backup but Chocolatey is not installed." -ForegroundColor Yellow
            $install = Read-Host "Install Chocolatey? (Y/N)"
            if ($install -eq 'Y') {
                if (Install-Chocolatey) {
                    $installed += "Chocolatey"
                }
            }
        }
        else {
            Write-Host "  Chocolatey: Installed" -ForegroundColor Green
        }
    }

    # Check and install Scoop
    if ($hasScoop) {
        $scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
        if (-not $scoopCmd) {
            Write-Host "Scoop packages found in backup but Scoop is not installed." -ForegroundColor Yellow
            $install = Read-Host "Install Scoop? (Y/N)"
            if ($install -eq 'Y') {
                if (Install-Scoop) {
                    $installed += "Scoop"
                }
            }
        }
        else {
            Write-Host "  Scoop: Installed" -ForegroundColor Green
        }
    }

    if ($installed.Count -gt 0) {
        Write-Log "Installed package managers: $($installed -join ', ')" -Level SUCCESS
        Write-Host ""
        Write-Host "Package managers installed. You may need to restart PowerShell for changes to take effect." -ForegroundColor Yellow
        $restart = Read-Host "Restart restore process? (Y/N)"
        if ($restart -eq 'Y') {
            return $false  # Signal to restart
        }
    }

    return $true  # Continue with restore
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
        Write-Log "Winget not available - skipping" -Level WARNING
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

function Backup-SingleUserProfile {
    param(
        [string]$UserProfilePath,
        [string]$Username,
        [string]$BackupBase
    )

    $usersBackupBase = Join-Path $BackupBase "Users\$Username"
    if (-not (Test-Path $usersBackupBase)) {
        New-Item -ItemType Directory -Path $usersBackupBase -Force | Out-Null
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Backing up user: $Username" -ForegroundColor Cyan
    Write-Host "Profile: $UserProfilePath" -ForegroundColor Gray
    Write-Host "========================================" -ForegroundColor Cyan

    $allItems = Get-ChildItem $UserProfilePath -Force -ErrorAction SilentlyContinue
    $foldersToBackup = @()
    $filesToBackup = @()

    foreach ($item in $allItems) {
        $itemName = $item.Name

        # Check if this is an excluded folder
        $isExcluded = $false
        foreach ($excludePattern in $Global:Config.ExcludeFolders) {
            if ($itemName -like $excludePattern) {
                $isExcluded = $true
                break
            }
        }

        if ($isExcluded) {
            Write-Log "[$Username] Skipping (excluded): $itemName" -Level INFO
            continue
        }

        # Check if it's a system junction/reparse point
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Log "[$Username] Skipping (junction): $itemName" -Level INFO
            continue
        }

        # Check for sensitive folders
        if ($Global:Config.SensitiveFolders -contains $itemName) {
            Write-Host ""
            Write-Host "SECURITY WARNING: $Username\$itemName contains sensitive data (private keys, credentials)" -ForegroundColor Red
            Write-Host "If your backup drive is lost or stolen, this data could be compromised." -ForegroundColor Yellow
            $includeSensitive = Read-Host "Include $itemName in backup? (Y/N)"
            if ($includeSensitive -ne 'Y') {
                Write-Log "User opted to skip sensitive folder: $itemName" -Level INFO
                continue
            }
            Write-Log "User opted to include sensitive folder: $itemName" -Level WARNING
        }

        if ($item.PSIsContainer) {
            $foldersToBackup += $item
        } else {
            $filesToBackup += $item
        }
    }

    Write-Host "Found $($foldersToBackup.Count) folders and $($filesToBackup.Count) files to backup" -ForegroundColor Gray

    # Build list of AppData folders that exist for this user (track Roaming vs Local)
    $appDataFoldersToBackup = @()
    $userAppDataRoaming = Join-Path $UserProfilePath "AppData\Roaming"
    $userAppDataLocal = Join-Path $UserProfilePath "AppData\Local"

    foreach ($folder in $Global:Config.AppDataFolders) {
        # Check Roaming first
        $roamingPath = Join-Path $userAppDataRoaming $folder
        if (Test-Path $roamingPath) {
            $appDataFoldersToBackup += @{ Folder = $folder; Path = $roamingPath; Location = "Roaming" }
        }
        # Check Local
        $localPath = Join-Path $userAppDataLocal $folder
        if (Test-Path $localPath) {
            $appDataFoldersToBackup += @{ Folder = $folder; Path = $localPath; Location = "Local" }
        }
    }

    # Calculate total size for progress estimation
    Write-Host "Calculating backup size..." -ForegroundColor Cyan

    $folderSizes = @{}
    $totalEstimatedSize = 0
    $excludeDirs = $Global:Config.ExcludePatterns | Where-Object { $_ -notmatch '\.' }

    foreach ($folder in $foldersToBackup) {
        try {
            $size = (Get-ChildItem $folder.FullName -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Length -lt $Global:Config.MaxFileSize } |
                     Measure-Object -Property Length -Sum).Sum
            if ($null -eq $size) { $size = 0 }
            $folderSizes[$folder.Name] = $size
            $totalEstimatedSize += $size
        }
        catch {
            $folderSizes[$folder.Name] = 0
        }
    }

    foreach ($file in $filesToBackup) {
        if ($file.Length -lt $Global:Config.MaxFileSize) {
            $folderSizes[$file.Name] = $file.Length
            $totalEstimatedSize += $file.Length
        }
    }

    foreach ($item in $appDataFoldersToBackup) {
        try {
            $size = (Get-ChildItem $item.Path -Recurse -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
            if ($null -eq $size) { $size = 0 }
            $folderSizes["AppData:$($item.Location):$($item.Folder)"] = $size
            $totalEstimatedSize += $size
        }
        catch {
            $folderSizes["AppData:$($item.Location):$($item.Folder)"] = 0
        }
    }

    $totalEstimatedMB = [math]::Round($totalEstimatedSize / 1MB, 2)
    Write-Host "Estimated total: $totalEstimatedMB MB" -ForegroundColor Gray
    Write-Host ""

    $completedSize = 0
    $totalFiles = 0
    $totalSize = 0

    # Backup root files first (like .gitconfig)
    foreach ($file in $filesToBackup) {
        if ($file.Length -ge $Global:Config.MaxFileSize) {
            Write-Log "Skipping (too large): $($file.Name)" -Level INFO
            continue
        }

        try {
            Copy-Item -Path $file.FullName -Destination $usersBackupBase -Force
            $totalFiles += 1
            $totalSize += $file.Length
            Write-Log "Copied file: $($file.Name)" -Level SUCCESS
        }
        catch {
            Write-Log "Error copying file $($file.Name): $_" -Level ERROR
        }
        $completedSize += $file.Length
    }

    # Backup user folders with progress
    foreach ($folder in $foldersToBackup) {
        $sourcePath = $folder.FullName
        $folderName = $folder.Name

        # Calculate and display progress
        $percentComplete = if ($totalEstimatedSize -gt 0) {
            [math]::Round(($completedSize / $totalEstimatedSize) * 100, 1)
        } else { 0 }

        Write-Progress -Activity "Backing up user data" -Status "$folderName ($percentComplete% complete)" -PercentComplete $percentComplete
        Write-Log "Backing up: $folderName" -Level INFO

        $destPath = Join-Path $usersBackupBase $folderName

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
                Write-Log "Copied $folderName ($($stats.Count) files)" -Level SUCCESS
            }
            else {
                Write-Log "Robocopy returned code $LASTEXITCODE for $folderName" -Level WARNING
            }
        }
        catch {
            Write-Log "Error backing up $folderName : $_" -Level ERROR
        }

        # Update completed size for progress
        $completedSize += $folderSizes[$folderName]
    }

    # Backup AppData folders with progress (preserving Roaming/Local structure)
    $appDataBase = Join-Path $usersBackupBase "AppData"
    foreach ($item in $appDataFoldersToBackup) {
        # Preserve Roaming/Local structure: AppData/Roaming/folder or AppData/Local/folder
        $destPath = Join-Path $appDataBase "$($item.Location)\$($item.Folder)"

        # Calculate and display progress
        $percentComplete = if ($totalEstimatedSize -gt 0) {
            [math]::Round(($completedSize / $totalEstimatedSize) * 100, 1)
        } else { 0 }

        Write-Progress -Activity "Backing up user data" -Status "AppData\$($item.Location): $($item.Folder) ($percentComplete% complete)" -PercentComplete $percentComplete
        Write-Log "Backing up AppData\$($item.Location): $($item.Folder)" -Level INFO

        try {
            robocopy $item.Path $destPath /E /R:1 /W:1 /MT:4 /NFL /NDL /NJH /NJS 2>&1 | Out-Null

            if ($LASTEXITCODE -le 7) {
                Write-Log "Copied AppData\$($item.Location): $($item.Folder)" -Level SUCCESS
            }
        }
        catch {
            Write-Log "Error backing up AppData $($item.Folder) : $_" -Level WARNING
        }

        # Update completed size for progress
        $completedSize += $folderSizes["AppData:$($item.Location):$($item.Folder)"]
    }

    Write-Progress -Activity "Backing up user data" -Completed

    $sizeMB = [math]::Round($totalSize / 1MB, 2)
    Write-Log "[$Username] Backup complete: $totalFiles files, $sizeMB MB" -Level SUCCESS

    return @{
        Files = $totalFiles
        SizeMB = $sizeMB
    }
}

function Backup-UserData {
    Write-Log "Backing up user data..." -Level INFO

    $backupBase = Join-Path $Global:Config.BackupDrive "UserData"

    # Get all user profiles (excluding system accounts)
    $excludeUsers = @("Public", "Default", "Default User", "All Users")
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $excludeUsers -notcontains $_.Name }

    Write-Host ""
    Write-Host "Found $($userProfiles.Count) user profile(s) to backup:" -ForegroundColor Cyan
    foreach ($profile in $userProfiles) {
        Write-Host "  - $($profile.Name)" -ForegroundColor Gray
    }

    $grandTotalFiles = 0
    $grandTotalSizeMB = 0

    foreach ($profile in $userProfiles) {
        $result = Backup-SingleUserProfile -UserProfilePath $profile.FullName -Username $profile.Name -BackupBase $backupBase
        if ($result) {
            $grandTotalFiles += $result.Files
            $grandTotalSizeMB += $result.SizeMB
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "ALL USERS BACKUP COMPLETE" -ForegroundColor Green
    Write-Host "Total: $grandTotalFiles files, $grandTotalSizeMB MB" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Log "All users backup complete: $grandTotalFiles files, $grandTotalSizeMB MB" -Level SUCCESS
}

function Restore-SingleUserProfile {
    param(
        [string]$SourceUserPath,
        [string]$DestUserPath,
        [string]$Username
    )

    Write-Host ""
    Write-Host "[$Username] Restoring to $DestUserPath" -ForegroundColor Cyan

    # Get all items from backup source
    $allItems = Get-ChildItem $SourceUserPath -Force -ErrorAction SilentlyContinue

    foreach ($item in $allItems) {
        $itemName = $item.Name

        # Skip AppData - handled separately
        if ($itemName -eq "AppData") { continue }

        Write-Log "[$Username] Restoring: $itemName" -Level INFO

        if ($item.PSIsContainer) {
            # Directory
            $destPath = Join-Path $DestUserPath $itemName
            try {
                robocopy $item.FullName $destPath /E /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS 2>&1 | Out-Null
                if ($LASTEXITCODE -le 7) {
                    Write-Log "[$Username] Restored: $itemName" -Level SUCCESS
                }
            }
            catch {
                Write-Log "[$Username] Error restoring $itemName : $_" -Level ERROR
            }
        }
        else {
            # File
            try {
                Copy-Item -Path $item.FullName -Destination $DestUserPath -Force
                Write-Log "[$Username] Restored file: $itemName" -Level SUCCESS
            }
            catch {
                Write-Log "[$Username] Error restoring file $itemName : $_" -Level ERROR
            }
        }
    }

    # Restore AppData - check for Roaming/Local structure first
    $appDataBackup = Join-Path $SourceUserPath "AppData"
    if (Test-Path $appDataBackup) {
        $destAppDataRoaming = Join-Path $DestUserPath "AppData\Roaming"
        $destAppDataLocal = Join-Path $DestUserPath "AppData\Local"

        # Check for new structure (AppData/Roaming, AppData/Local)
        $roamingBackup = Join-Path $appDataBackup "Roaming"
        $localBackup = Join-Path $appDataBackup "Local"

        if ((Test-Path $roamingBackup) -or (Test-Path $localBackup)) {
            # New structure - restore to correct locations
            if (Test-Path $roamingBackup) {
                foreach ($folder in (Get-ChildItem $roamingBackup -Directory -ErrorAction SilentlyContinue)) {
                    $destPath = Join-Path $destAppDataRoaming $folder.Name
                    Write-Log "[$Username] Restoring AppData\Roaming\$($folder.Name)" -Level INFO
                    try {
                        robocopy $folder.FullName $destPath /E /R:1 /W:1 /MT:4 /NFL /NDL /NJH /NJS 2>&1 | Out-Null
                        if ($LASTEXITCODE -le 7) {
                            Write-Log "[$Username] Restored AppData\Roaming\$($folder.Name)" -Level SUCCESS
                        }
                    }
                    catch {
                        Write-Log "[$Username] Error restoring AppData $($folder.Name): $_" -Level WARNING
                    }
                }
            }
            if (Test-Path $localBackup) {
                foreach ($folder in (Get-ChildItem $localBackup -Directory -ErrorAction SilentlyContinue)) {
                    $destPath = Join-Path $destAppDataLocal $folder.Name
                    Write-Log "[$Username] Restoring AppData\Local\$($folder.Name)" -Level INFO
                    try {
                        robocopy $folder.FullName $destPath /E /R:1 /W:1 /MT:4 /NFL /NDL /NJH /NJS 2>&1 | Out-Null
                        if ($LASTEXITCODE -le 7) {
                            Write-Log "[$Username] Restored AppData\Local\$($folder.Name)" -Level SUCCESS
                        }
                    }
                    catch {
                        Write-Log "[$Username] Error restoring AppData $($folder.Name): $_" -Level WARNING
                    }
                }
            }
        }
        else {
            # Old structure - folders directly in AppData, guess location
            foreach ($folder in $Global:Config.AppDataFolders) {
                $sourcePath = Join-Path $appDataBackup $folder

                if (-not (Test-Path $sourcePath)) {
                    continue
                }

                # Try Roaming first, then Local
                $destPath = Join-Path $destAppDataRoaming $folder
                if (-not (Test-Path (Split-Path $destPath -Parent))) {
                    $destPath = Join-Path $destAppDataLocal $folder
                }

                Write-Log "[$Username] Restoring AppData: $folder" -Level INFO

                try {
                    robocopy $sourcePath $destPath /E /R:1 /W:1 /MT:4 /NFL /NDL /NJH /NJS 2>&1 | Out-Null
                    if ($LASTEXITCODE -le 7) {
                        Write-Log "[$Username] Restored AppData: $folder" -Level SUCCESS
                    }
                }
                catch {
                    Write-Log "[$Username] Error restoring AppData $folder : $_" -Level WARNING
                }
            }
        }
    }

    Write-Log "[$Username] Profile restore complete" -Level SUCCESS
}

function Restore-UserData {
    param(
        [string]$BackupPath,
        [switch]$SkipConfirm
    )

    $backupBase = Join-Path $BackupPath "UserData"

    if (-not (Test-Path $backupBase)) {
        Write-Log "User data backup not found" -Level WARNING
        return
    }

    # Check for new structure (Users\username) or old structure
    $usersFolder = Join-Path $backupBase "Users"

    Write-Log "Restoring user data..." -Level INFO

    if (Test-Path $usersFolder) {
        # New multi-user structure
        $backupUsers = Get-ChildItem $usersFolder -Directory

        Write-Host ""
        Write-Host "Found $($backupUsers.Count) user profile(s) in backup:" -ForegroundColor Cyan
        foreach ($user in $backupUsers) {
            $localProfile = "C:\Users\$($user.Name)"
            $exists = Test-Path $localProfile
            $status = if ($exists) { "[OK]" } else { "[MISSING]" }
            $color = if ($exists) { "Green" } else { "Yellow" }
            Write-Host "  $status $($user.Name)" -ForegroundColor $color
        }

        Write-Host ""
        Write-Host "WARNING: This will copy files to user profiles." -ForegroundColor Yellow
        Write-Host "Existing files with the same name will be overwritten." -ForegroundColor Yellow

        if (-not $SkipConfirm) {
            $confirm = Read-Host "Continue? (Y/N)"
            if ($confirm -ne 'Y') {
                Write-Log "User data restore cancelled" -Level INFO
                return
            }
        }

        # Restore each user
        foreach ($user in $backupUsers) {
            $localProfile = "C:\Users\$($user.Name)"

            if (-not (Test-Path $localProfile)) {
                Write-Host ""
                Write-Host "[$($user.Name)] SKIPPED - Profile not found at $localProfile" -ForegroundColor Yellow
                Write-Host "  Run Setup-Users.ps1 first to create the account," -ForegroundColor Gray
                Write-Host "  then log in as that user once to create the profile." -ForegroundColor Gray
                Write-Log "[$($user.Name)] Skipped - profile not found" -Level WARNING
                continue
            }

            Restore-SingleUserProfile -SourceUserPath $user.FullName -DestUserPath $localProfile -Username $user.Name
        }

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "ALL USERS RESTORE COMPLETE" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
    }
    else {
        # Old single-user structure - restore to current user
        Write-Host ""
        Write-Host "WARNING: This will copy files to your user profile." -ForegroundColor Yellow
        Write-Host "Existing files with the same name will be overwritten." -ForegroundColor Yellow

        if (-not $SkipConfirm) {
            $confirm = Read-Host "Continue? (Y/N)"
            if ($confirm -ne 'Y') {
                Write-Log "User data restore cancelled" -Level INFO
                return
            }
        }

        Restore-SingleUserProfile -SourceUserPath $backupBase -DestUserPath $env:USERPROFILE -Username $env:USERNAME
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
    param([switch]$Resume)

    $backupPath = $Global:Config.BackupDrive

    # Register interrupt handler for graceful cancellation
    Register-InterruptHandler -BackupPath $backupPath

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  PC MIGRATION BACKUP" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    # Check for existing progress
    $savedProgress = Get-SavedProgress -BackupPath $backupPath
    if ($savedProgress -and $savedProgress.Operation -eq "backup" -and -not $Resume) {
        Write-Host "INCOMPLETE BACKUP FOUND" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Started:   $($savedProgress.StartTime)" -ForegroundColor Gray
        Write-Host "  Last save: $($savedProgress.LastUpdate)" -ForegroundColor Gray
        Write-Host "  Completed: $($savedProgress.CompletedSteps.Count) steps" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  1. Resume where you left off" -ForegroundColor Green
        Write-Host "  2. Start fresh (delete previous progress)" -ForegroundColor Yellow
        Write-Host "  3. Cancel" -ForegroundColor Red
        Write-Host ""

        $resumeChoice = Read-Host "Select option (1-3)"

        switch ($resumeChoice) {
            "1" {
                $Global:Progress.Operation = "backup"
                $Global:Progress.StartTime = $savedProgress.StartTime
                $Global:Progress.CompletedSteps = @($savedProgress.CompletedSteps)
                Write-Host ""
                Write-Host "Resuming backup..." -ForegroundColor Green
            }
            "2" {
                Clear-Progress -BackupPath $backupPath
                Write-Host ""
                Write-Host "Starting fresh backup..." -ForegroundColor Green
            }
            default {
                Write-Log "Backup cancelled" -Level INFO
                return
            }
        }
    }
    else {
        Write-Host "This will:" -ForegroundColor White
        Write-Host "  1. Export Winget/Chocolatey/Scoop package lists" -ForegroundColor Gray
        Write-Host "  2. Backup user data (Documents, Desktop, etc.)" -ForegroundColor Gray
        Write-Host "  3. Create an inventory of installed apps (reference only)" -ForegroundColor Gray
        Write-Host "  4. Create checksums for verification" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Backup location: $backupPath" -ForegroundColor Yellow
        Write-Host ""

        $confirm = Read-Host "Start backup? (Y/N)"
        if ($confirm -ne 'Y') {
            Write-Log "Backup cancelled" -Level INFO
            return
        }

        # Initialize progress
        $Global:Progress.Operation = "backup"
        $Global:Progress.StartTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $Global:Progress.CompletedSteps = @()
    }

    $startTime = Get-Date

    # Initialize
    if (-not (Initialize-BackupEnvironment)) {
        return
    }

    # Check disk space (handle both local and UNC paths)
    try {
        if ($backupPath -match '^\\\\') {
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

    # Initialize checksums hashtable
    $checksums = @{}

    # Export package managers (with progress tracking)
    Write-Host ""
    Write-Host "--- Package Managers ---" -ForegroundColor Cyan

    if (-not (Test-StepCompleted -StepName "Winget")) {
        Set-CurrentStep -StepName "Winget" -BackupPath $backupPath
        Export-WingetPackages
        Mark-StepComplete -StepName "Winget" -BackupPath $backupPath
    } else {
        Write-Host "  [SKIP] Winget - already completed" -ForegroundColor DarkGray
    }

    if (-not (Test-StepCompleted -StepName "Chocolatey")) {
        Set-CurrentStep -StepName "Chocolatey" -BackupPath $backupPath
        Export-ChocolateyPackages
        Mark-StepComplete -StepName "Chocolatey" -BackupPath $backupPath
    } else {
        Write-Host "  [SKIP] Chocolatey - already completed" -ForegroundColor DarkGray
    }

    if (-not (Test-StepCompleted -StepName "Scoop")) {
        Set-CurrentStep -StepName "Scoop" -BackupPath $backupPath
        Export-ScoopPackages
        Mark-StepComplete -StepName "Scoop" -BackupPath $backupPath
    } else {
        Write-Host "  [SKIP] Scoop - already completed" -ForegroundColor DarkGray
    }

    # Backup user data (with progress tracking)
    Write-Host ""
    Write-Host "--- User Data ---" -ForegroundColor Cyan

    if (-not (Test-StepCompleted -StepName "UserData")) {
        Set-CurrentStep -StepName "UserData" -BackupPath $backupPath
        Backup-UserData
        Mark-StepComplete -StepName "UserData" -BackupPath $backupPath
    } else {
        Write-Host "  [SKIP] UserData - already completed" -ForegroundColor DarkGray
    }

    # Create inventory
    Write-Host ""
    Write-Host "--- Inventory ---" -ForegroundColor Cyan

    if (-not (Test-StepCompleted -StepName "Inventory")) {
        Set-CurrentStep -StepName "Inventory" -BackupPath $backupPath
        Export-Inventory
        Mark-StepComplete -StepName "Inventory" -BackupPath $backupPath
    } else {
        Write-Host "  [SKIP] Inventory - already completed" -ForegroundColor DarkGray
    }

    # Generate checksums for key files
    Write-Host ""
    Write-Host "--- Verification ---" -ForegroundColor Cyan

    if (-not (Test-StepCompleted -StepName "Checksums")) {
        Set-CurrentStep -StepName "Checksums" -BackupPath $backupPath
        Write-Host "Generating checksums for verification..." -ForegroundColor Gray

        # Checksum package manager exports
        $pmPath = Join-Path $backupPath "PackageManagers"
        if (Test-Path $pmPath) {
            Get-ChildItem $pmPath -File | ForEach-Object {
                $relativePath = "PackageManagers\$($_.Name)"
                $hash = Get-FileChecksum -FilePath $_.FullName
                if ($hash) { $checksums[$relativePath] = $hash }
            }
        }

        # Checksum inventory
        $inventoryPath = Join-Path $backupPath "inventory.json"
        if (Test-Path $inventoryPath) {
            $hash = Get-FileChecksum -FilePath $inventoryPath
            if ($hash) { $checksums["inventory.json"] = $hash }
        }

        Save-Checksums -BackupPath $backupPath -Checksums $checksums
        Mark-StepComplete -StepName "Checksums" -BackupPath $backupPath
    } else {
        Write-Host "  [SKIP] Checksums - already completed" -ForegroundColor DarkGray
    }

    # Create backup manifest (so restore can identify this as a valid backup)
    $manifest = @{
        Version = $Global:Config.Version
        BackupDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        WindowsVersion = (Get-CimInstance Win32_OperatingSystem).Caption
        CompletedSteps = $Global:Progress.CompletedSteps
    }
    $manifestPath = Join-Path $backupPath "backup-manifest.json"
    $manifest | ConvertTo-Json | Out-File -FilePath $manifestPath -Encoding UTF8
    Write-Log "Created backup manifest" -Level INFO

    # Clear progress file on successful completion
    Clear-Progress -BackupPath $backupPath

    $duration = (Get-Date) - $startTime

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  BACKUP COMPLETE" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "Duration: $($duration.Minutes)m $($duration.Seconds)s" -ForegroundColor Gray
    Write-Host "Location: $backupPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Copy backup folder to new PC" -ForegroundColor White
    Write-Host "  2. Run this tool on new PC" -ForegroundColor White
    Write-Host "  3. Choose 'Restore' option" -ForegroundColor White
    Write-Host ""
}

function Start-Restore {
    param(
        [string]$BackupPath,
        [switch]$SkipConfirm
    )

    # Register interrupt handler for graceful cancellation
    Register-InterruptHandler -BackupPath $BackupPath

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host "  PC MIGRATION RESTORE" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host ""

    # Verify backup exists
    if (-not (Test-Path $BackupPath)) {
        Write-Host "ERROR: Folder not found: $BackupPath" -ForegroundColor Red
        return
    }

    # Check for backup manifest
    $manifestPath = Join-Path $BackupPath "backup-manifest.json"
    if (-not (Test-Path $manifestPath)) {
        Write-Host "ERROR: This doesn't look like a backup folder." -ForegroundColor Red
        Write-Host ""
        Write-Host "No backup-manifest.json found." -ForegroundColor Gray
        Write-Host "Make sure you selected the folder containing your backup." -ForegroundColor Gray
        return
    }

    # Load and display backup info
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        Write-Host "Found backup from:" -ForegroundColor Green
        Write-Host "  Computer:  $($manifest.ComputerName)" -ForegroundColor White
        Write-Host "  User:      $($manifest.UserName)" -ForegroundColor White
        Write-Host "  Date:      $($manifest.BackupDate)" -ForegroundColor White
        Write-Host "  Windows:   $($manifest.WindowsVersion)" -ForegroundColor White
        Write-Host ""
    }
    catch {
        Write-Host "WARNING: Could not read backup info" -ForegroundColor Yellow
    }

    # Check for existing restore progress
    $savedProgress = Get-SavedProgress -BackupPath $BackupPath
    if ($savedProgress -and $savedProgress.Operation -eq "restore") {
        Write-Host "INCOMPLETE RESTORE FOUND" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Started:   $($savedProgress.StartTime)" -ForegroundColor Gray
        Write-Host "  Last save: $($savedProgress.LastUpdate)" -ForegroundColor Gray
        Write-Host "  Completed: $($savedProgress.CompletedSteps.Count) steps" -ForegroundColor Gray
        Write-Host ""

        if ($SkipConfirm) {
            # CLI mode: auto-resume
            $Global:Progress.Operation = "restore"
            $Global:Progress.StartTime = $savedProgress.StartTime
            $Global:Progress.CompletedSteps = @($savedProgress.CompletedSteps)
            Write-Host "Auto-resuming restore (CLI mode)..." -ForegroundColor Green
        }
        else {
            Write-Host "  1. Resume where you left off" -ForegroundColor Green
            Write-Host "  2. Start fresh (redo everything)" -ForegroundColor Yellow
            Write-Host "  3. Cancel" -ForegroundColor Red
            Write-Host ""

            $resumeChoice = Read-Host "Select option (1-3)"

            switch ($resumeChoice) {
                "1" {
                    $Global:Progress.Operation = "restore"
                    $Global:Progress.StartTime = $savedProgress.StartTime
                    $Global:Progress.CompletedSteps = @($savedProgress.CompletedSteps)
                    Write-Host ""
                    Write-Host "Resuming restore..." -ForegroundColor Green
                }
                "2" {
                    Clear-Progress -BackupPath $BackupPath
                    $Global:Progress.Operation = "restore"
                    $Global:Progress.StartTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    $Global:Progress.CompletedSteps = @()
                    Write-Host ""
                    Write-Host "Starting fresh restore..." -ForegroundColor Green
                }
                default {
                    Write-Log "Restore cancelled" -Level INFO
                    return
                }
            }
        }
    }
    else {
        Write-Host "This will:" -ForegroundColor White
        Write-Host "  - Reinstall your apps (fresh installs)" -ForegroundColor Gray
        Write-Host "  - Copy your files back (Documents, Desktop, etc.)" -ForegroundColor Gray
        Write-Host "  - Verify backup integrity" -ForegroundColor Gray
        Write-Host ""

        # Show what will be restored
        $pmPath = Join-Path $BackupPath "PackageManagers"
        $wingetFile = Join-Path $pmPath "winget-packages.json"
        $chocoFile = Join-Path $pmPath "chocolatey-packages.config"
        $scoopFile = Join-Path $pmPath "scoop-packages.json"

        if (Test-Path $wingetFile) {
            try {
                $content = Get-Content $wingetFile -Raw | ConvertFrom-Json
                Write-Host "  Winget packages: $($content.Sources.Packages.Count)" -ForegroundColor Gray
            } catch { }
        }
        if (Test-Path $chocoFile) {
            try {
                [xml]$content = Get-Content $chocoFile
                Write-Host "  Chocolatey packages: $($content.packages.package.Count)" -ForegroundColor Gray
            } catch { }
        }
        if (Test-Path $scoopFile) {
            try {
                $content = Get-Content $scoopFile | ConvertFrom-Json
                Write-Host "  Scoop packages: $($content.Count)" -ForegroundColor Gray
            } catch { }
        }

        if (-not $SkipConfirm) {
            Write-Host ""
            $confirm = Read-Host "Start restore? (Y/N)"
            if ($confirm -ne 'Y') {
                Write-Log "Restore cancelled" -Level INFO
                return
            }
        }

        # Initialize progress
        $Global:Progress.Operation = "restore"
        $Global:Progress.StartTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $Global:Progress.CompletedSteps = @()
    }

    $startTime = Get-Date

    # Verify backup integrity first
    Write-Host ""
    Write-Host "--- Verifying Backup ---" -ForegroundColor Cyan

    if (-not (Test-StepCompleted -StepName "Verification")) {
        Set-CurrentStep -StepName "Verification" -BackupPath $BackupPath
        $integrity = Test-BackupIntegrity -BackupPath $BackupPath

        if ($integrity.FilesChecked -gt 0) {
            if ($integrity.Verified) {
                Write-Host "  Backup verified: $($integrity.FilesChecked) files OK" -ForegroundColor Green
            }
            else {
                Write-Host "  WARNING: Some files may be corrupted" -ForegroundColor Yellow
                foreach ($err in $integrity.Errors | Select-Object -First 5) {
                    Write-Host "    - $err" -ForegroundColor Yellow
                }
                if (-not $SkipConfirm) {
                    $continueAnyway = Read-Host "Continue anyway? (Y/N)"
                    if ($continueAnyway -ne 'Y') {
                        Write-Log "Restore cancelled due to verification errors" -Level WARNING
                        return
                    }
                }
                else {
                    Write-Host "  Continuing despite errors (CLI mode with -y flag)" -ForegroundColor Yellow
                }
            }
        }
        else {
            Write-Host "  No checksums found (older backup) - skipping verification" -ForegroundColor Gray
        }
        Mark-StepComplete -StepName "Verification" -BackupPath $BackupPath
    } else {
        Write-Host "  [SKIP] Verification - already completed" -ForegroundColor DarkGray
    }

    # Check and install missing package managers
    if (-not (Test-StepCompleted -StepName "PackageManagers")) {
        Set-CurrentStep -StepName "PackageManagers" -BackupPath $BackupPath
        $continueRestore = Install-RequiredPackageManagers -BackupPath $BackupPath
        if (-not $continueRestore) {
            Write-Log "Restore paused - please restart after package managers are installed" -Level INFO
            return
        }
        Mark-StepComplete -StepName "PackageManagers" -BackupPath $BackupPath
    }

    # Restore packages
    Write-Host ""
    Write-Host "--- Installing Packages ---" -ForegroundColor Cyan
    Write-Host "(This may take a while...)" -ForegroundColor Gray
    Write-Host ""

    if (-not (Test-StepCompleted -StepName "RestoreWinget")) {
        Set-CurrentStep -StepName "RestoreWinget" -BackupPath $BackupPath
        Import-WingetPackages -BackupPath $BackupPath
        Mark-StepComplete -StepName "RestoreWinget" -BackupPath $BackupPath
    } else {
        Write-Host "  [SKIP] Winget - already completed" -ForegroundColor DarkGray
    }

    if (-not (Test-StepCompleted -StepName "RestoreChocolatey")) {
        Set-CurrentStep -StepName "RestoreChocolatey" -BackupPath $BackupPath
        Import-ChocolateyPackages -BackupPath $BackupPath
        Mark-StepComplete -StepName "RestoreChocolatey" -BackupPath $BackupPath
    } else {
        Write-Host "  [SKIP] Chocolatey - already completed" -ForegroundColor DarkGray
    }

    if (-not (Test-StepCompleted -StepName "RestoreScoop")) {
        Set-CurrentStep -StepName "RestoreScoop" -BackupPath $BackupPath
        Import-ScoopPackages -BackupPath $BackupPath
        Mark-StepComplete -StepName "RestoreScoop" -BackupPath $BackupPath
    } else {
        Write-Host "  [SKIP] Scoop - already completed" -ForegroundColor DarkGray
    }

    # Restore user data
    Write-Host ""
    Write-Host "--- User Data ---" -ForegroundColor Cyan

    if (-not (Test-StepCompleted -StepName "RestoreUserData")) {
        Set-CurrentStep -StepName "RestoreUserData" -BackupPath $BackupPath
        Restore-UserData -BackupPath $BackupPath -SkipConfirm:$SkipConfirm
        Mark-StepComplete -StepName "RestoreUserData" -BackupPath $BackupPath
    } else {
        Write-Host "  [SKIP] UserData - already completed" -ForegroundColor DarkGray
    }

    # Clear progress on successful completion
    Clear-Progress -BackupPath $BackupPath

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
# ENTRY POINT
# ============================================================================

function Select-FolderDialog {
    param([string]$Description = "Select backup folder")

    Add-Type -AssemblyName System.Windows.Forms
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = $Description
    $folderBrowser.ShowNewFolderButton = $true

    $result = $folderBrowser.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    }
    return $null
}

function Select-FolderLocation {
    param(
        [string]$Title = "Select Folder",
        [string]$Prompt = "Where would you like to store backups?"
    )

    do {
        Clear-Host
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  $Title" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host $Prompt -ForegroundColor White
        Write-Host ""
        Write-Host "  1. Use this folder: " -ForegroundColor Green -NoNewline
        Write-Host $Global:ExeFolder -ForegroundColor Green
        Write-Host "  2. Browse for folder" -ForegroundColor Yellow
        Write-Host "  3. Enter path manually" -ForegroundColor White
        Write-Host "  4. Go back" -ForegroundColor Red
        Write-Host ""

        $choice = Read-Host "Select option (1-4)"

        switch ($choice) {
            "1" {
                $validation = Test-ValidBackupPath -Path $Global:ExeFolder
                if ($validation.Valid) {
                    return $Global:ExeFolder
                }
                else {
                    Write-Host "Can't use this folder: $($validation.Reason)" -ForegroundColor Red
                    Read-Host "`nPress Enter to try again"
                }
            }
            "2" {
                Write-Host "Opening folder browser..." -ForegroundColor Cyan
                $selectedPath = Select-FolderDialog -Description $Prompt

                if ($selectedPath) {
                    $validation = Test-ValidBackupPath -Path $selectedPath
                    if ($validation.Valid) {
                        return $selectedPath
                    }
                    else {
                        Write-Host "Invalid path: $($validation.Reason)" -ForegroundColor Red
                        Read-Host "`nPress Enter to try again"
                    }
                }
                else {
                    Write-Host "No folder selected" -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
            "3" {
                Write-Host ""
                Write-Host "Examples:" -ForegroundColor Gray
                Write-Host "  D:\PCMigration" -ForegroundColor Gray
                Write-Host "  E:\Backup" -ForegroundColor Gray
                Write-Host "  \\server\share\backup" -ForegroundColor Gray
                Write-Host ""
                Write-Host "Leave blank to go back" -ForegroundColor DarkGray
                Write-Host ""
                $newPath = Read-Host "Enter path"

                if ([string]::IsNullOrWhiteSpace($newPath)) {
                    continue
                }

                $validation = Test-ValidBackupPath -Path $newPath
                if ($validation.Valid) {
                    return $newPath
                }
                else {
                    Write-Host "Invalid path: $($validation.Reason)" -ForegroundColor Red
                    Read-Host "`nPress Enter to try again"
                }
            }
            "4" {
                return $null
            }
            default {
                Write-Host "Invalid option" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

function Show-MainMenu {
    do {
        Clear-Host
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "  PC MIGRATION TOOLKIT" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  1. BACKUP - Save everything from this PC" -ForegroundColor Green
        Write-Host "  2. RESTORE - Put everything on this PC" -ForegroundColor Yellow
        Write-Host "  3. Exit" -ForegroundColor Red
        Write-Host ""

        $choice = Read-Host "Select option (1-3)"

        switch ($choice) {
            "1" {
                $backupPath = Select-FolderLocation -Title "BACKUP" -Prompt "Where would you like to save the backup?"
                if ($backupPath) {
                    $Global:Config.BackupDrive = $backupPath
                    Start-Backup
                    Read-Host "`nPress Enter to continue"
                }
            }
            "2" {
                # Check if backup exists in exe folder
                $manifestPath = Join-Path $Global:ExeFolder "backup-manifest.json"

                if (Test-Path $manifestPath) {
                    # Found backup - show info and confirm
                    Clear-Host
                    Write-Host ""
                    Write-Host "============================================" -ForegroundColor Yellow
                    Write-Host "  RESTORE" -ForegroundColor Yellow
                    Write-Host "============================================" -ForegroundColor Yellow
                    Write-Host ""

                    try {
                        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
                        Write-Host "Found backup in this folder:" -ForegroundColor Green
                        Write-Host ""
                        Write-Host "  Computer:  $($manifest.ComputerName)" -ForegroundColor White
                        Write-Host "  User:      $($manifest.UserName)" -ForegroundColor White
                        Write-Host "  Date:      $($manifest.BackupDate)" -ForegroundColor White
                        Write-Host "  Windows:   $($manifest.WindowsVersion)" -ForegroundColor White
                        Write-Host ""
                    }
                    catch {
                        Write-Host "Found backup in this folder" -ForegroundColor Green
                        Write-Host ""
                    }

                    Write-Host "  1. Run Restore" -ForegroundColor Green
                    Write-Host "  2. Go back" -ForegroundColor Red
                    Write-Host ""

                    $confirmChoice = Read-Host "Select option (1-2)"

                    if ($confirmChoice -eq "1") {
                        $Global:Config.BackupDrive = $Global:ExeFolder
                        Start-Restore -BackupPath $Global:ExeFolder
                        Read-Host "`nPress Enter to continue"
                    }
                }
                else {
                    # No backup found - show error
                    Clear-Host
                    Write-Host ""
                    Write-Host "============================================" -ForegroundColor Red
                    Write-Host "  NO BACKUP FOUND" -ForegroundColor Red
                    Write-Host "============================================" -ForegroundColor Red
                    Write-Host ""
                    Write-Host "No backup was found in this folder:" -ForegroundColor White
                    Write-Host "  $Global:ExeFolder" -ForegroundColor Gray
                    Write-Host ""
                    Write-Host "Make sure the backup files are in the same" -ForegroundColor White
                    Write-Host "folder as this program." -ForegroundColor White
                    Write-Host ""
                    Read-Host "Press Enter to go back"
                }
            }
            "3" {
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
# CLI MODE
# ============================================================================

function Show-Help {
    Write-Host ""
    Write-Host "PC MIGRATION TOOLKIT v$($Global:Config.Version)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "USAGE:" -ForegroundColor Yellow
    Write-Host "  .\PC-Migration-Tool.ps1 [command] [options]"
    Write-Host ""
    Write-Host "COMMANDS:" -ForegroundColor Yellow
    Write-Host "  backup      Export packages and backup user data"
    Write-Host "  restore     Import packages and restore user data"
    Write-Host "  verify      Verify backup integrity (checksums)"
    Write-Host "  inventory   Show installed applications from backup"
    Write-Host ""
    Write-Host "OPTIONS:" -ForegroundColor Yellow
    Write-Host "  -Path, -p   Backup/restore path (required for CLI mode)"
    Write-Host "  -Yes, -y    Skip confirmation prompts"
    Write-Host "  -Help, -h   Show this help message"
    Write-Host ""
    Write-Host "EXAMPLES:" -ForegroundColor Yellow
    Write-Host "  .\PC-Migration-Tool.ps1 backup -Path D:\Backup"
    Write-Host "  .\PC-Migration-Tool.ps1 backup -p D:\Backup -y"
    Write-Host "  .\PC-Migration-Tool.ps1 restore -Path D:\Backup"
    Write-Host "  .\PC-Migration-Tool.ps1 verify -Path D:\Backup"
    Write-Host ""
    Write-Host "INTERACTIVE MODE:" -ForegroundColor Yellow
    Write-Host "  Run without arguments for menu-driven interface"
    Write-Host ""
}

function Start-CLIBackup {
    param(
        [string]$BackupPath,
        [switch]$SkipConfirm
    )

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        Write-Host "ERROR: -Path is required for CLI backup" -ForegroundColor Red
        Write-Host "Example: .\PC-Migration-Tool.ps1 backup -Path D:\Backup" -ForegroundColor Yellow
        exit 1
    }

    $validation = Test-ValidBackupPath -Path $BackupPath
    if (-not $validation.Valid) {
        Write-Host "ERROR: Invalid path - $($validation.Reason)" -ForegroundColor Red
        exit 1
    }

    $Global:Config.BackupDrive = $BackupPath

    Write-Host ""
    Write-Host "PC MIGRATION BACKUP (CLI Mode)" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Backup path: $BackupPath" -ForegroundColor White
    Write-Host ""

    if (-not $SkipConfirm) {
        $confirm = Read-Host "Start backup? (Y/N)"
        if ($confirm -ne 'Y') {
            Write-Host "Backup cancelled" -ForegroundColor Yellow
            exit 0
        }
    }

    # Run backup (skip the internal confirmation since we already confirmed)
    $Global:Progress.Operation = "backup"
    $Global:Progress.StartTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $Global:Progress.CompletedSteps = @()

    $startTime = Get-Date

    if (-not (Initialize-BackupEnvironment)) {
        exit 1
    }

    # Initialize checksums hashtable
    $checksums = @{}

    Write-Host ""
    Write-Host "--- Package Managers ---" -ForegroundColor Cyan
    Set-CurrentStep -StepName "Winget" -BackupPath $BackupPath
    Export-WingetPackages
    Mark-StepComplete -StepName "Winget" -BackupPath $BackupPath

    Set-CurrentStep -StepName "Chocolatey" -BackupPath $BackupPath
    Export-ChocolateyPackages
    Mark-StepComplete -StepName "Chocolatey" -BackupPath $BackupPath

    Set-CurrentStep -StepName "Scoop" -BackupPath $BackupPath
    Export-ScoopPackages
    Mark-StepComplete -StepName "Scoop" -BackupPath $BackupPath

    Write-Host ""
    Write-Host "--- User Data ---" -ForegroundColor Cyan
    Set-CurrentStep -StepName "UserData" -BackupPath $BackupPath
    Backup-UserData
    Mark-StepComplete -StepName "UserData" -BackupPath $BackupPath

    Write-Host ""
    Write-Host "--- Inventory ---" -ForegroundColor Cyan
    Set-CurrentStep -StepName "Inventory" -BackupPath $BackupPath
    Export-Inventory
    Mark-StepComplete -StepName "Inventory" -BackupPath $BackupPath

    Write-Host ""
    Write-Host "--- Verification ---" -ForegroundColor Cyan
    Set-CurrentStep -StepName "Checksums" -BackupPath $BackupPath
    Write-Host "Generating checksums..." -ForegroundColor Gray

    $pmPath = Join-Path $BackupPath "PackageManagers"
    if (Test-Path $pmPath) {
        Get-ChildItem $pmPath -File | ForEach-Object {
            $relativePath = "PackageManagers\$($_.Name)"
            $hash = Get-FileChecksum -FilePath $_.FullName
            if ($hash) { $checksums[$relativePath] = $hash }
        }
    }

    $inventoryPath = Join-Path $BackupPath "inventory.json"
    if (Test-Path $inventoryPath) {
        $hash = Get-FileChecksum -FilePath $inventoryPath
        if ($hash) { $checksums["inventory.json"] = $hash }
    }

    Save-Checksums -BackupPath $BackupPath -Checksums $checksums
    Mark-StepComplete -StepName "Checksums" -BackupPath $BackupPath

    # Create manifest
    $manifest = @{
        Version = $Global:Config.Version
        BackupDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        WindowsVersion = (Get-CimInstance Win32_OperatingSystem).Caption
        CompletedSteps = $Global:Progress.CompletedSteps
    }
    $manifestPath = Join-Path $BackupPath "backup-manifest.json"
    $manifest | ConvertTo-Json | Out-File -FilePath $manifestPath -Encoding UTF8

    Clear-Progress -BackupPath $BackupPath

    $duration = (Get-Date) - $startTime

    Write-Host ""
    Write-Host "BACKUP COMPLETE" -ForegroundColor Green
    Write-Host "Duration: $($duration.Minutes)m $($duration.Seconds)s" -ForegroundColor Gray
    Write-Host "Location: $BackupPath" -ForegroundColor Gray
}

function Start-CLIRestore {
    param(
        [string]$BackupPath,
        [switch]$SkipConfirm
    )

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        Write-Host "ERROR: -Path is required for CLI restore" -ForegroundColor Red
        Write-Host "Example: .\PC-Migration-Tool.ps1 restore -Path D:\Backup" -ForegroundColor Yellow
        exit 1
    }

    if (-not (Test-Path $BackupPath)) {
        Write-Host "ERROR: Path not found: $BackupPath" -ForegroundColor Red
        exit 1
    }

    $manifestPath = Join-Path $BackupPath "backup-manifest.json"
    if (-not (Test-Path $manifestPath)) {
        Write-Host "ERROR: No backup found at $BackupPath" -ForegroundColor Red
        Write-Host "Missing backup-manifest.json" -ForegroundColor Gray
        exit 1
    }

    $Global:Config.BackupDrive = $BackupPath

    Write-Host ""
    Write-Host "PC MIGRATION RESTORE (CLI Mode)" -ForegroundColor Yellow
    Write-Host "================================" -ForegroundColor Yellow
    Write-Host ""

    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        Write-Host "Backup info:" -ForegroundColor White
        Write-Host "  Computer:  $($manifest.ComputerName)" -ForegroundColor Gray
        Write-Host "  User:      $($manifest.UserName)" -ForegroundColor Gray
        Write-Host "  Date:      $($manifest.BackupDate)" -ForegroundColor Gray
        Write-Host "  Windows:   $($manifest.WindowsVersion)" -ForegroundColor Gray
        Write-Host ""
    }
    catch {
        Write-Host "WARNING: Could not read backup manifest" -ForegroundColor Yellow
    }

    if (-not $SkipConfirm) {
        $confirm = Read-Host "Start restore? (Y/N)"
        if ($confirm -ne 'Y') {
            Write-Host "Restore cancelled" -ForegroundColor Yellow
            exit 0
        }
    }

    # Run restore (pass through SkipConfirm for fully non-interactive CLI mode)
    Start-Restore -BackupPath $BackupPath -SkipConfirm:$SkipConfirm
}

function Start-CLIVerify {
    param([string]$BackupPath)

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        Write-Host "ERROR: -Path is required" -ForegroundColor Red
        exit 1
    }

    if (-not (Test-Path $BackupPath)) {
        Write-Host "ERROR: Path not found: $BackupPath" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "VERIFYING BACKUP INTEGRITY" -ForegroundColor Magenta
    Write-Host "==========================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Path: $BackupPath" -ForegroundColor Gray
    Write-Host ""

    $result = Test-BackupIntegrity -BackupPath $BackupPath

    if ($result.FilesChecked -eq 0) {
        Write-Host "No checksums found - backup may be from older version" -ForegroundColor Yellow
        exit 0
    }

    if ($result.Verified) {
        Write-Host "VERIFIED: $($result.FilesChecked) files OK" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "ERRORS FOUND:" -ForegroundColor Red
        foreach ($err in $result.Errors) {
            Write-Host "  - $err" -ForegroundColor Red
        }
        exit 1
    }
}

function Start-CLIInventory {
    param([string]$BackupPath)

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        Write-Host "ERROR: -Path is required" -ForegroundColor Red
        exit 1
    }

    $inventoryPath = Join-Path $BackupPath "inventory.json"

    if (-not (Test-Path $inventoryPath)) {
        Write-Host "ERROR: No inventory found at $BackupPath" -ForegroundColor Red
        exit 1
    }

    $inventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json

    Write-Host ""
    Write-Host "BACKUP INVENTORY" -ForegroundColor Cyan
    Write-Host "================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Backup Date:  $($inventory.ExportDate)" -ForegroundColor Gray
    Write-Host "Computer:     $($inventory.ComputerName)" -ForegroundColor Gray
    Write-Host "User:         $($inventory.UserName)" -ForegroundColor Gray
    Write-Host "Windows:      $($inventory.WindowsVersion)" -ForegroundColor Gray
    Write-Host "Total Apps:   $($inventory.TotalApps)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Applications:" -ForegroundColor Yellow
    Write-Host ""

    $inventory.Applications | Sort-Object Name | ForEach-Object {
        Write-Host "  $($_.Name)" -ForegroundColor White -NoNewline
        if ($_.Version) {
            Write-Host " v$($_.Version)" -ForegroundColor DarkGray
        }
        else {
            Write-Host ""
        }
    }
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# Verify admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script requires Administrator privileges!" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

# Check for CLI mode
if ($Help) {
    Show-Help
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($Command)) {
    # CLI mode
    switch ($Command.ToLower()) {
        "backup" {
            Start-CLIBackup -BackupPath $Path -SkipConfirm:$Yes
        }
        "restore" {
            Start-CLIRestore -BackupPath $Path -SkipConfirm:$Yes
        }
        "verify" {
            Start-CLIVerify -BackupPath $Path
        }
        "inventory" {
            Start-CLIInventory -BackupPath $Path
        }
        default {
            Write-Host "Unknown command: $Command" -ForegroundColor Red
            Show-Help
            exit 1
        }
    }
}
else {
    # Interactive mode (for exe / non-technical users)
    Show-MainMenu
}
