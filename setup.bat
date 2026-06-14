@echo off
setlocal
chcp 65001 >nul 2>&1

echo.
echo  ======================================
echo   wave-sync 一键安装
echo   Wave Terminal 配置同步工具
echo  ======================================
echo.

:: ── Step 1: 检测 PowerShell ──────────────────────────────────
echo [1/4] 检测 PowerShell...
powershell -Command "$PSVersionTable.PSVersion.Major" >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [!] 未检测到 PowerShell
    echo     Windows 10/11 自带 PowerShell，请检查系统环境。
    echo.
    pause
    exit /b 1
)
echo       PowerShell 已就绪

:: ── Step 2: 安装 wave-sync ───────────────────────────────────
echo.
echo [2/4] 安装 wave-sync...

set SCRIPT_DIR=%~dp0
set INSTALL_DIR=%LOCALAPPDATA%\wave-sync\bin

if not exist "%INSTALL_DIR%" (
    mkdir "%INSTALL_DIR%"
)

:: 复制 PowerShell 脚本
copy /Y "%SCRIPT_DIR%wave-sync.ps1" "%INSTALL_DIR%\wave-sync.ps1" >nul

:: 创建 bat 包装器（让 wave-sync 命令可用）
(
echo @echo off
echo powershell -ExecutionPolicy Bypass -File "%%~dp0wave-sync.ps1" %%*
) > "%INSTALL_DIR%\wave-sync.bat"

:: 检查是否已在 PATH 中
echo %PATH% | findstr /i /c:"%INSTALL_DIR%" >nul 2>&1
if %errorlevel% neq 0 (
    :: 添加到用户 PATH
    for /f "tokens=2*" %%a in ('reg query "HKCU\Environment" /v Path 2^>nul') do set OLD_PATH=%%b
    if defined OLD_PATH (
        reg add "HKCU\Environment" /v Path /t REG_EXPAND_SZ /d "%OLD_PATH%;%INSTALL_DIR%" /f >nul 2>&1
    ) else (
        reg add "HKCU\Environment" /v Path /t REG_EXPAND_SZ /d "%INSTALL_DIR%" /f >nul 2>&1
    )
    set "PATH=%PATH%;%INSTALL_DIR%"
    echo       已添加到 PATH（重启终端后生效）
) else (
    echo       已在 PATH 中
)

echo       安装完成: %INSTALL_DIR%\wave-sync.bat

:: ── Step 3: 初始化配置 ───────────────────────────────────────
echo.
echo [3/4] 初始化配置文件...

set CONFIG_DIR=%APPDATA%\wave-sync
set CONFIG_FILE=%CONFIG_DIR%\config.yaml

if not exist "%CONFIG_DIR%" (
    mkdir "%CONFIG_DIR%"
)

if exist "%CONFIG_FILE%" (
    echo       配置文件已存在: %CONFIG_FILE%
) else (
    (
    echo # wave-sync 配置文件
    echo # https://github.com/liboevan/wave-sync
    echo.
    echo # WebDAV 服务器配置
    echo # 坚果云获取应用密码: 坚果云 - 账户信息 - 安全选项 - 第三方应用管理 - 添加应用密码
    echo url: "https://dav.jianguoyun.com/dav/wave-sync"
    echo user: "your@email.com"
    echo password: ""
    ) > "%CONFIG_FILE%"
    echo       已创建: %CONFIG_FILE%
)

:: ── Step 4: 打开配置文件 ─────────────────────────────────────
echo.
echo [4/4] 打开配置文件...
echo.
echo       请在配置文件中填写你的 WebDAV 信息:
echo         url: WebDAV 服务器地址
echo         user: 用户名
echo         password: 应用密码
echo.

notepad "%CONFIG_FILE%" 2>nul

echo.
echo  ======================================
echo   安装完成!
echo  ======================================
echo.
echo   下一步:
echo     1. 确保配置文件已填写正确
echo     2. 重启终端
echo     3. 运行: wave-sync push
echo.
echo   常用命令:
echo     wave-sync push       上传配置
echo     wave-sync pull       下载配置
echo     wave-sync status     查看状态
echo     wave-sync diff       查看差异
echo.
pause
