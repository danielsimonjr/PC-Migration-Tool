# ============================================================================
# SETUP USERS - Create user accounts on new PC before restore
# Run as Administrator
# ============================================================================

#Requires -RunAsAdministrator
#Requires -Version 5.1

param(
    [Parameter()]
    [string]$BackupPath = "",

    [Parameter()]
    [switch]$Help
)

function Show-Help {
    Write-Host ""
    Write-Host "SETUP USERS - Create user accounts from backup" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Setup-Users.ps1                    # Auto-detect backup in current folder"
    Write-Host "  .\Setup-Users.ps1 -BackupPath D:\Backup"
    Write-Host ""
    Write-Host "This script will:"
    Write-Host "  1. Read user profiles from backup"
    Write-Host "  2. Create matching local accounts on this PC"
    Write-Host "  3. Optionally add users to Administrators group"
    Write-Host ""
}

function Get-BackupUsers {
    param([string]$BackupPath)

    $usersPath = Join-Path $BackupPath "UserData\Users"

    if (-not (Test-Path $usersPath)) {
        Write-Host "ERROR: No user backup found at $usersPath" -ForegroundColor Red
        return $null
    }

    $users = Get-ChildItem $usersPath -Directory | Select-Object -ExpandProperty Name
    return $users
}

function Test-UserExists {
    param([string]$Username)

    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    return $null -ne $user
}

function New-LocalUserAccount {
    param(
        [string]$Username,
        [securestring]$Password,
        [bool]$IsAdmin = $false
    )

    try {
        # Create the user
        New-LocalUser -Name $Username -Password $Password -FullName $Username -Description "Migrated from backup" -ErrorAction Stop
        Write-Host "  [OK] Created user: $Username" -ForegroundColor Green

        # Add to Users group
        Add-LocalGroupMember -Group "Users" -Member $Username -ErrorAction SilentlyContinue

        # Add to Administrators if requested
        if ($IsAdmin) {
            Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction Stop
            Write-Host "  [OK] Added to Administrators group" -ForegroundColor Green
        }

        # Set password to never expire
        Set-LocalUser -Name $Username -PasswordNeverExpires $true -ErrorAction SilentlyContinue

        return $true
    }
    catch {
        Write-Host "  [ERROR] Failed to create user: $_" -ForegroundColor Red
        return $false
    }
}

# ============================================================================
# MAIN
# ============================================================================

if ($Help) {
    Show-Help
    exit 0
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SETUP USER ACCOUNTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Find backup path
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    # Try current folder
    $scriptFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([Environment]::GetCommandLineArgs()[0]) }
    if (-not $scriptFolder) { $scriptFolder = (Get-Location).Path }

    # Check for Backup subfolder or direct UserData
    if (Test-Path (Join-Path $scriptFolder "Backup\UserData\Users")) {
        $BackupPath = Join-Path $scriptFolder "Backup"
    }
    elseif (Test-Path (Join-Path $scriptFolder "UserData\Users")) {
        $BackupPath = $scriptFolder
    }
    else {
        Write-Host "ERROR: No backup found. Use -BackupPath to specify location." -ForegroundColor Red
        Write-Host ""
        Show-Help
        exit 1
    }
}

Write-Host "Backup path: $BackupPath" -ForegroundColor Gray
Write-Host ""

# Get users from backup
$backupUsers = Get-BackupUsers -BackupPath $BackupPath

if (-not $backupUsers -or $backupUsers.Count -eq 0) {
    Write-Host "No users found in backup." -ForegroundColor Red
    exit 1
}

Write-Host "Users found in backup:" -ForegroundColor Yellow
foreach ($user in $backupUsers) {
    $exists = Test-UserExists -Username $user
    $status = if ($exists) { "[EXISTS]" } else { "[NEW]" }
    $color = if ($exists) { "Gray" } else { "White" }
    Write-Host "  $status $user" -ForegroundColor $color
}
Write-Host ""

# Process each user
foreach ($user in $backupUsers) {
    Write-Host "----------------------------------------" -ForegroundColor DarkGray
    Write-Host "User: $user" -ForegroundColor Cyan

    if (Test-UserExists -Username $user) {
        Write-Host "  [SKIP] User already exists" -ForegroundColor Yellow
        continue
    }

    # Ask for password
    Write-Host ""
    Write-Host "  Create account for: $user" -ForegroundColor White
    $password = Read-Host "  Enter password for $user" -AsSecureString
    $confirmPassword = Read-Host "  Confirm password" -AsSecureString

    # Convert to plain text for comparison
    $pwd1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
    $pwd2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPassword))

    if ($pwd1 -ne $pwd2) {
        Write-Host "  [ERROR] Passwords do not match!" -ForegroundColor Red
        continue
    }

    if ($pwd1.Length -lt 1) {
        Write-Host "  [ERROR] Password cannot be empty!" -ForegroundColor Red
        continue
    }

    # Clear plain text passwords from memory
    $pwd1 = $null
    $pwd2 = $null

    # Ask about admin rights
    $makeAdmin = Read-Host "  Make $user an Administrator? (Y/N)"
    $isAdmin = $makeAdmin -eq 'Y'

    # Create the account
    $success = New-LocalUserAccount -Username $user -Password $password -IsAdmin $isAdmin
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  SETUP COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Log in as each new user once (creates profile folder)"
Write-Host "  2. Log back in as Administrator"
Write-Host "  3. Run PC-Migration-Tool.exe -> Restore"
Write-Host ""
Write-Host "NOTE: Users must log in once before restore to create" -ForegroundColor Gray
Write-Host "      their profile folders (C:\Users\username)" -ForegroundColor Gray
Write-Host ""
