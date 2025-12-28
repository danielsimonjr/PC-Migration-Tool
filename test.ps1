# ============================================================================
# TEST SCRIPT - PC Migration Tool
# Runs unit tests for PC-Migration-Tool.ps1
# ============================================================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

# Configuration
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainScript = Join-Path $ScriptDir "PC-Migration-Tool.ps1"

# Test counters
$script:TestsPassed = 0
$script:TestsFailed = 0

# ============================================================================
# TEST FRAMEWORK
# ============================================================================

function Write-TestHeader {
    param([string]$Name)
    Write-Host "`n[$Name]" -ForegroundColor Cyan
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if ($Condition) {
        Write-Host "  PASS: $Message" -ForegroundColor Green
        $script:TestsPassed++
    }
    else {
        Write-Host "  FAIL: $Message" -ForegroundColor Red
        $script:TestsFailed++
    }
}

function Assert-False {
    param(
        [bool]$Condition,
        [string]$Message
    )
    Assert-True -Condition (-not $Condition) -Message $Message
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )
    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $Message" -ForegroundColor Green
        $script:TestsPassed++
    }
    else {
        Write-Host "  FAIL: $Message (Expected: $Expected, Got: $Actual)" -ForegroundColor Red
        $script:TestsFailed++
    }
}

function Assert-NotNull {
    param(
        $Value,
        [string]$Message
    )
    Assert-True -Condition ($null -ne $Value) -Message $Message
}

# ============================================================================
# LOAD FUNCTIONS FROM MAIN SCRIPT
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PC MIGRATION TOOL - TEST SUITE" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Extract and load functions from main script (without running it)
Write-Host "`nLoading functions from $MainScript..." -ForegroundColor Gray

# Read the script content
$scriptContent = Get-Content $MainScript -Raw

# Extract function definitions using regex
$functionPattern = '(?ms)^function\s+([\w-]+)\s*\{.*?^\}'
$matches = [regex]::Matches($scriptContent, $functionPattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)

# Load only the functions we need to test (non-interactive ones)
$functionsToLoad = @(
    'Test-ValidBackupPath',
    'Get-InstalledApplications'
)

foreach ($match in $matches) {
    $funcName = $match.Groups[1].Value
    if ($funcName -in $functionsToLoad) {
        try {
            Invoke-Expression $match.Value
            Write-Host "  Loaded: $funcName" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "  Failed to load: $funcName - $_" -ForegroundColor Yellow
        }
    }
}

# Also need to initialize the config
$Global:Config = @{
    BackupDrive = "D:\PCMigration"
    MaxFileSize = 1GB
}

# ============================================================================
# TEST: Test-ValidBackupPath
# ============================================================================

Write-TestHeader "Test-ValidBackupPath"

# Test: Empty path should fail
$result = Test-ValidBackupPath -Path ""
Assert-False -Condition $result.Valid -Message "Empty path should be invalid"

# Test: Null path should fail
$result = Test-ValidBackupPath -Path $null
Assert-False -Condition $result.Valid -Message "Null path should be invalid"

# Test: Relative path should fail
$result = Test-ValidBackupPath -Path ".\backup"
Assert-False -Condition $result.Valid -Message "Relative path should be invalid"

# Test: Windows directory should fail
$result = Test-ValidBackupPath -Path "$env:SystemRoot\backup"
Assert-False -Condition $result.Valid -Message "Windows directory should be invalid"

# Test: Program Files should fail
$result = Test-ValidBackupPath -Path "$env:ProgramFiles\backup"
Assert-False -Condition $result.Valid -Message "Program Files should be invalid"

# Test: User profile root should fail
$result = Test-ValidBackupPath -Path $env:USERPROFILE
Assert-False -Condition $result.Valid -Message "User profile root should be invalid"

# Test: Valid path should pass
$result = Test-ValidBackupPath -Path "D:\Backup"
Assert-True -Condition $result.Valid -Message "D:\Backup should be valid"

# Test: Valid path with subfolder should pass
$result = Test-ValidBackupPath -Path "E:\MyBackups\PCMigration"
Assert-True -Condition $result.Valid -Message "E:\MyBackups\PCMigration should be valid"

# Test: UNC path should pass
$result = Test-ValidBackupPath -Path "\\server\share\backup"
Assert-True -Condition $result.Valid -Message "UNC path should be valid"

# Test: User profile subfolder should pass
$result = Test-ValidBackupPath -Path "$env:USERPROFILE\Backups"
Assert-True -Condition $result.Valid -Message "User profile subfolder should be valid"

# ============================================================================
# TEST: Get-InstalledApplications
# ============================================================================

Write-TestHeader "Get-InstalledApplications"

# Suppress the Write-Log output for this test
function Write-Log { param($Message, $Level) }

$apps = Get-InstalledApplications

Assert-NotNull -Value $apps -Message "Should return applications list"
Assert-True -Condition ($apps.Count -gt 0) -Message "Should find at least one application"

# Check that returned objects have expected properties
if ($apps.Count -gt 0) {
    $firstApp = $apps[0]
    Assert-NotNull -Value $firstApp.Name -Message "Application should have Name property"
    Assert-True -Condition ($firstApp.PSObject.Properties.Name -contains 'Version') -Message "Application should have Version property"
    Assert-True -Condition ($firstApp.PSObject.Properties.Name -contains 'Publisher') -Message "Application should have Publisher property"
}

# ============================================================================
# TEST: Configuration Defaults
# ============================================================================

Write-TestHeader "Configuration Defaults"

# Re-read config from script
$configMatch = [regex]::Match($scriptContent, '\$Global:Config\s*=\s*@\{[\s\S]*?\n\}')
if ($configMatch.Success) {
    # Check that expected config keys exist in script
    Assert-True -Condition ($scriptContent -match 'BackupDrive') -Message "Config should have BackupDrive"
    Assert-True -Condition ($scriptContent -match 'UserDataFolders') -Message "Config should have UserDataFolders"
    Assert-True -Condition ($scriptContent -match 'SensitiveFolders') -Message "Config should have SensitiveFolders"
    Assert-True -Condition ($scriptContent -match 'AppDataFolders') -Message "Config should have AppDataFolders"
    Assert-True -Condition ($scriptContent -match 'ExcludePatterns') -Message "Config should have ExcludePatterns"
    Assert-True -Condition ($scriptContent -match 'MaxFileSize') -Message "Config should have MaxFileSize"
}

# ============================================================================
# TEST: Script Structure
# ============================================================================

Write-TestHeader "Script Structure"

# Check that required functions exist
$requiredFunctions = @(
    'Write-Log',
    'Initialize-BackupEnvironment',
    'Export-WingetPackages',
    'Export-ChocolateyPackages',
    'Export-ScoopPackages',
    'Import-WingetPackages',
    'Import-ChocolateyPackages',
    'Import-ScoopPackages',
    'Backup-UserData',
    'Restore-UserData',
    'Get-InstalledApplications',
    'Export-Inventory',
    'Start-Backup',
    'Start-Restore',
    'Show-MainMenu',
    'Start-InteractiveMode',
    'Test-ValidBackupPath',
    'Select-FolderDialog',
    'Initialize-BackupDrivePrompt'
)

foreach ($func in $requiredFunctions) {
    Assert-True -Condition ($scriptContent -match "function\s+$func") -Message "Function $func should exist"
}

# Check for admin requirement
Assert-True -Condition ($scriptContent -match '#Requires -RunAsAdministrator') -Message "Script should require admin"

# Check for PowerShell version requirement
Assert-True -Condition ($scriptContent -match '#Requires -Version 5\.1') -Message "Script should require PowerShell 5.1"

# ============================================================================
# TEST SUMMARY
# ============================================================================

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  TEST RESULTS" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Gray" })
Write-Host ""

if ($script:TestsFailed -gt 0) {
    Write-Host "TESTS FAILED" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}
