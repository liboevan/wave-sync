@echo off
setlocal
chcp 65001 >nul 2>&1

echo.
echo  ======================================
echo   wave-sync One-Click Setup
echo   Wave Terminal Config Sync Tool
echo  ======================================
echo.

:: Step 1: Check PowerShell
echo [1/4] Checking PowerShell...
powershell -Command "$PSVersionTable.PSVersion.Major" >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [!] PowerShell not found
    echo     Windows 10/11 includes PowerShell by default.
    echo.
    pause
    exit /b 1
)
echo       PowerShell is ready

:: Step 2: Install wave-sync
echo.
echo [2/4] Installing wave-sync...

set SCRIPT_DIR=%~dp0
set INSTALL_DIR=%LOCALAPPDATA%\wave-sync\bin

if not exist "%INSTALL_DIR%" (
    mkdir "%INSTALL_DIR%"
)

copy /Y "%SCRIPT_DIR%wave-sync.ps1" "%INSTALL_DIR%\wave-sync.ps1" >nul

echo @echo off> "%INSTALL_DIR%\wave-sync.bat"
echo powershell -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_DIR%\wave-sync.ps1" %%*>> "%INSTALL_DIR%\wave-sync.bat"

echo %PATH% | findstr /i /c:"%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    for /f "tokens=2*" %%a in ('reg query "HKCU\Environment" /v Path 2^>nul') do set OLD_PATH=%%b
    if defined OLD_PATH (
        reg add "HKCU\Environment" /v Path /t REG_EXPAND_SZ /d "%OLD_PATH%;%INSTALL_DIR%" /f >nul 2>&1
    ) else (
        reg add "HKCU\Environment" /v Path /t REG_EXPAND_SZ /d "%INSTALL_DIR%" /f >nul 2>&1
    )
    set "PATH=%PATH%;%INSTALL_DIR%"
    echo       Added to PATH (restart terminal to take effect)
) else (
    echo       Already in PATH
)

echo       Installed: %INSTALL_DIR%\wave-sync.bat

:: Step 3: Create config
echo.
echo [3/4] Creating config file...

set CONFIG_DIR=%APPDATA%\wave-sync
set CONFIG_FILE=%CONFIG_DIR%\config.yaml

if not exist "%CONFIG_DIR%" (
    mkdir "%CONFIG_DIR%"
)

if exist "%CONFIG_FILE%" (
    echo       Config already exists: %CONFIG_FILE%
) else (
    (
    echo # wave-sync configuration
    echo # https://github.com/liboevan/wave-sync
    echo.
    echo # WebDAV server config
    echo # Jianguo Cloud: Account - Security - Third-party App Management - Add App Password
    echo url: "https://dav.jianguoyun.com/dav/wave-sync"
    echo user: "your@email.com"
    echo password: ""
    ) > "%CONFIG_FILE%"
    echo       Created: %CONFIG_FILE%
)

:: Step 4: Open config
echo.
echo [4/4] Opening config file...
echo.
echo       Please fill in your WebDAV credentials:
echo         url: WebDAV server URL
echo         user: username
echo         password: app password
echo.

notepad "%CONFIG_FILE%" 2>nul

echo.
echo  ======================================
echo   Setup Complete!
echo  ======================================
echo.
echo   Next steps:
echo     1. Make sure config is filled in correctly
echo     2. Restart your terminal
echo     3. Run: wave-sync push
echo.
echo   Commands:
echo     wave-sync push       Upload config
echo     wave-sync pull       Download config
echo     wave-sync status     Show status
echo     wave-sync diff       Show changes
echo.
pause
