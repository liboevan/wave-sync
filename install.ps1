# wave-sync installer for Windows
# Installs wave-sync to a directory in PATH

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptSrc = Join-Path $ScriptDir "wave_sync.py"

if (-not (Test-Path $ScriptSrc)) {
    Write-Host "[✗] wave_sync.py not found in $ScriptDir" -ForegroundColor Red
    exit 1
}

# Choose install location
$InstallDir = Join-Path $env:LOCALAPPDATA "wave-sync\bin"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# Copy script
Copy-Item $ScriptSrc (Join-Path $InstallDir "wave-sync.py") -Force

# Create batch wrapper
$BatContent = @"
@echo off
python "%~dp0wave-sync.py" %*
"@
Set-Content -Path (Join-Path $InstallDir "wave-sync.bat") -Value $BatContent -Encoding ASCII

# Add to PATH if not already there
$CurrentPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($CurrentPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$CurrentPath;$InstallDir", "User")
    $env:Path = "$env:Path;$InstallDir"
    Write-Host "[✓] Added $InstallDir to PATH" -ForegroundColor Green
}

Write-Host "[✓] Installed: $InstallDir\wave-sync.bat" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Restart your terminal"
Write-Host "  2. Run: wave-sync init"
Write-Host "  3. Edit config: $env:APPDATA\wave-sync\config.yaml"
Write-Host "  4. Run: wave-sync push"
