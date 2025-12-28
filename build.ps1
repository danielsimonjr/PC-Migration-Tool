# ============================================================================
# BUILD SCRIPT - PC Migration Tool
# Converts PC-Migration-Tool.ps1 to PC-Migration-Tool.exe
# ============================================================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

# Configuration
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InputFile = Join-Path $ScriptDir "PC-Migration-Tool.ps1"
$OutputFile = Join-Path $ScriptDir "PC-Migration-Tool.exe"
$IconFile = Join-Path $ScriptDir "pc-migration.ico"

$ExeTitle = "PC Migration Tool"
$ExeDescription = "Migrate apps via package managers + user data"
$ExeCompany = "Daniel Simon Jr."
$ExeVersion = "3.2.0.0"

# Check if input file exists
if (-not (Test-Path $InputFile)) {
    Write-Host "ERROR: $InputFile not found" -ForegroundColor Red
    exit 1
}

# Check for ps2exe module
$ps2exeModule = Get-Module -ListAvailable -Name ps2exe
if (-not $ps2exeModule) {
    Write-Host "ps2exe module not found. Attempting to install..." -ForegroundColor Yellow

    try {
        Install-Module -Name ps2exe -Scope CurrentUser -Force
        Write-Host "ps2exe installed successfully" -ForegroundColor Green
    }
    catch {
        # Try downloading directly from GitHub
        Write-Host "Module install failed. Downloading from GitHub..." -ForegroundColor Yellow

        $ps2exeZip = Join-Path $env:TEMP "ps2exe.zip"
        $ps2exePath = Join-Path $env:TEMP "PS2EXE-master"

        Invoke-WebRequest -Uri "https://github.com/MScholtes/PS2EXE/archive/refs/heads/master.zip" -OutFile $ps2exeZip
        Expand-Archive -Path $ps2exeZip -DestinationPath $env:TEMP -Force

        Import-Module (Join-Path $ps2exePath "Module\ps2exe.psm1") -Force
        Write-Host "ps2exe loaded from GitHub" -ForegroundColor Green
    }
}

# Import module
Import-Module ps2exe -ErrorAction SilentlyContinue
if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    # Try loading from temp if module import failed
    $ps2exePath = Join-Path $env:TEMP "PS2EXE-master"
    if (Test-Path $ps2exePath) {
        Import-Module (Join-Path $ps2exePath "Module\ps2exe.psm1") -Force
    }
}

# Build parameters
$buildParams = @{
    inputFile    = $InputFile
    outputFile   = $OutputFile
    requireAdmin = $true
    title        = $ExeTitle
    description  = $ExeDescription
    company      = $ExeCompany
    version      = $ExeVersion
}

# Add icon if exists
if (Test-Path $IconFile) {
    $buildParams.iconFile = $IconFile
    Write-Host "Using icon: $IconFile" -ForegroundColor Cyan
}
else {
    Write-Host "Warning: Icon file not found, building without icon" -ForegroundColor Yellow
}

# Build
Write-Host ""
Write-Host "Building PC Migration Tool..." -ForegroundColor Cyan
Write-Host "  Input:  $InputFile" -ForegroundColor Gray
Write-Host "  Output: $OutputFile" -ForegroundColor Gray
Write-Host ""

try {
    Invoke-PS2EXE @buildParams

    if (Test-Path $OutputFile) {
        $fileInfo = Get-Item $OutputFile
        Write-Host ""
        Write-Host "BUILD SUCCESSFUL" -ForegroundColor Green
        Write-Host "  Output: $OutputFile" -ForegroundColor Gray
        Write-Host "  Size:   $([math]::Round($fileInfo.Length / 1KB, 2)) KB" -ForegroundColor Gray
    }
    else {
        Write-Host "BUILD FAILED - Output file not created" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "BUILD FAILED: $_" -ForegroundColor Red
    exit 1
}
