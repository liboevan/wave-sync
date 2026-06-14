#Requires -Version 5.1
<#
.SYNOPSIS
    Wave Terminal 配置同步工具 (WebDAV)
.DESCRIPTION
    通过 WebDAV 在多台机器之间同步 Wave Terminal 的 workspace 布局、
    连接配置和自定义小部件。支持坚果云、Nextcloud 等主流 WebDAV 服务。
.EXAMPLE
    .\wave-sync.ps1 init
    .\wave-sync.ps1 push
    .\wave-sync.ps1 pull
    .\wave-sync.ps1 status
    .\wave-sync.ps1 diff
#>

param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [string]$Url = "",
    [string]$User = "",
    [string]$Password = "",
    [string]$WaveDir = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$Script:VERSION = "0.4.0"
$Script:CONFIG_DIR_NAME = "wave-sync"
$Script:META_FILENAME = ".wave-sync-meta.json"
$Script:MANIFEST_FILENAME = ".wave-sync-manifest.json"

# Wave Terminal config directory patterns per platform
$Script:WAVE_DIR_PATTERNS = @{
    "Windows" = @(
        "$env:APPDATA\waveterm"
        "$env:APPDATA\waveterm\config"
        "$env:LOCALAPPDATA\waveterm"
        "$env:LOCALAPPDATA\waveterm\config"
        "$env:USERPROFILE\.waveterm"
        "$env:USERPROFILE\.waveterm\config"
    )
    "Darwin" = @(
        "$env:HOME/Library/Application Support/waveterm"
        "$env:HOME/Library/Application Support/waveterm/config"
        "$env:HOME/.waveterm"
        "$env:HOME/.waveterm/config"
    )
    "Linux" = @(
        "$env:XDG_CONFIG_HOME/waveterm"
        "$env:XDG_CONFIG_HOME/waveterm/config"
        "$env:HOME/.waveterm"
        "$env:HOME/.waveterm/config"
        "$env:HOME/.config/waveterm"
        "$env:HOME/.config/waveterm/config"
    )
}

# Files/dirs to never sync
$Script:SYNC_EXCLUDE = @(
    ".wave-sync-meta.json"
    ".wave-sync-manifest.json"
    "*.log", "*.log.*", "*.tmp", "*.bak", "*.sock", "*.pid", "*.lock"
    "*.db", "*.db-journal", "*.db-wal", "*.db-shm"
    "filestore.db"
    "__pycache__"
    "Cache", "Code Cache", "GPUCache"
    "DawnGraphiteCache", "DawnWebGPUCache"
    "blob_storage", "session_storage"
    "Local Storage", "IndexedDB", "WebStorage", "leveldb"
    "bin", "shell", "ssh"
)

# ── Colors ──────────────────────────────────────────────────────────────────

function Write-Info  { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "[✓] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[✗] $Msg" -ForegroundColor Red }
function Write-Dim   { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor DarkGray }

# ── Platform Helpers ────────────────────────────────────────────────────────

function Get-ConfigDir {
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $base = $env:APPDATA
        if (-not $base) { $base = "$env:USERPROFILE\AppData\Roaming" }
    } else {
        $base = $env:XDG_CONFIG_HOME
        if (-not $base) { $base = "$env:HOME/.config" }
    }
    return Join-Path $base $Script:CONFIG_DIR_NAME
}

function Find-WaveDir {
    param([string]$OverrideDir = "")

    if ($OverrideDir -and (Test-Path $OverrideDir)) {
        $configDir = Join-Path $OverrideDir "config"
        if (Test-Path $configDir) { return $configDir }
        return $OverrideDir
    }

    $system = if ($IsWindows -or $env:OS -eq "Windows_NT") { "Windows" }
              elseif ($IsMacOS -or ($env:OS -eq "Darwin")) { "Darwin" }
              else { "Linux" }

    $patterns = $Script:WAVE_DIR_PATTERNS[$system]
    if (-not $patterns) { $patterns = $Script:WAVE_DIR_PATTERNS["Linux"] }

    foreach ($p in $patterns) {
        if ($p -and (Test-Path $p)) {
            # Check for config/ subdir first (old Wave)
            $configDir = Join-Path $p "config"
            if (Test-Path $configDir) { return $configDir }
            # Check if root has actual config files (new Wave)
            if ((Test-Path (Join-Path $p "settings.json")) -or
                (Test-Path (Join-Path $p "connections.json")) -or
                (Test-Path (Join-Path $p "widgets.json"))) {
                return $p
            }
            return $p
        }
    }
    return $null
}

function Get-MachineId {
    return $env:COMPUTERNAME
}

function Find-WaveConfigFiles {
    # Search common locations for Wave config files
    $searchPaths = @(
        "$env:APPDATA\waveterm"
        "$env:LOCALAPPDATA\waveterm"
        "$env:USERPROFILE\.waveterm"
    )
    $configFiles = @("settings.json", "connections.json", "widgets.json")

    foreach ($base in $searchPaths) {
        if (-not (Test-Path $base)) { continue }
        foreach ($f in $configFiles) {
            $found = Get-ChildItem -Path $base -Recurse -Filter $f -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                return $found.DirectoryName
            }
        }
    }
    return $null
}

# ── Config ──────────────────────────────────────────────────────────────────

function Get-ConfigPath {
    return Join-Path (Get-ConfigDir) "config.yaml"
}

function Read-SimpleYaml {
    param([string]$Path)
    $config = @{}
    if (-not (Test-Path $Path)) { return $config }

    foreach ($line in (Get-Content $Path -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        if ($trimmed -match "^(\w[\w\s]*):\s*(.+)$") {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            $config[$key] = $value
        }
    }
    return $config
}

function Write-SimpleYaml {
    param(
        [string]$Path,
        [hashtable]$Data,
        [string[]]$Comments = @()
    )
    $lines = @()
    foreach ($c in $Comments) { $lines += "# $c" }
    foreach ($key in $Data.Keys) {
        $val = $Data[$key]
        if ($val -match "^\s*$") {
            $lines += "${key}: `"$val`""
        } else {
            $lines += "${key}: `"$val`""
        }
    }
    $lines | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Load-Config {
    $path = Get-ConfigPath
    if (-not (Test-Path $path)) { return @{} }
    return Read-SimpleYaml $path
}

function Get-WebDavConfig {
    param([hashtable]$Override = @{})

    $config = Load-Config

    # Flat key lookup (config.yaml uses webdav.url style but simple parser flattens)
    $url = if ($Override["url"]) { $Override["url"] }
           elseif ($env:WAVESYNC_WEBDAV_URL) { $env:WAVESYNC_WEBDAV_URL }
           elseif ($config["url"]) { $config["url"] }
           else { "" }

    $user = if ($Override["user"]) { $Override["user"] }
            elseif ($env:WAVESYNC_WEBDAV_USER) { $env:WAVESYNC_WEBDAV_USER }
            elseif ($config["user"]) { $config["user"] }
            else { "" }

    $pass = if ($Override["password"]) { $Override["password"] }
            elseif ($env:WAVESYNC_WEBDAV_PASS) { $env:WAVESYNC_WEBDAV_PASS }
            elseif ($config["password"]) { $config["password"] }
            else { "" }

    if (-not $url -or -not $user) {
        Write-Err "请先配置 WebDAV 信息"
        Write-Dim "编辑配置文件: $(Get-ConfigPath)"
        Write-Dim "或使用参数: -Url, -User, -Password"
        Write-Dim "或设置环境变量: WAVESYNC_WEBDAV_URL, WAVESYNC_WEBDAV_USER, WAVESYNC_WEBDAV_PASS"
        exit 1
    }

    if (-not $pass) {
        $pass = Read-Host "WebDAV 密码"
    }

    return @{ url = $url; user = $user; password = $pass }
}

# ── WebDAV Client ───────────────────────────────────────────────────────────

function New-WebDavAuth {
    param([string]$User, [string]$Password)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("${User}:${Password}")
    return "Basic $([System.Convert]::ToBase64String($bytes))"
}

function Invoke-WebDavRequest {
    param(
        [string]$Method,
        [string]$BaseUrl,
        [string]$Path,
        [string]$Auth,
        [string]$Body = $null,
        [byte[]]$BodyBytes = $null,
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 30
    )

    $urlPath = $Path.TrimStart("/")
    $fullUrl = $BaseUrl.TrimEnd("/") + "/" + $urlPath

    try {
        $request = [System.Net.WebRequest]::Create($fullUrl)
        $request.Method = $Method
        $request.Timeout = $TimeoutSec * 1000
        $request.ContentType = "application/xml; charset=utf-8"
        $request.Headers.Add("Authorization", $Auth)

        foreach ($k in $Headers.Keys) {
            if ($k -eq "Content-Type") {
                $request.ContentType = $Headers[$k]
            } elseif ($k -ne "Content-Length") {
                $request.Headers.Add($k, $Headers[$k])
            }
        }

        if ($BodyBytes) {
            $request.ContentLength = $BodyBytes.Length
            $stream = $request.GetRequestStream()
            try { $stream.Write($BodyBytes, 0, $BodyBytes.Length) } finally { $stream.Close() }
        } elseif ($Body) {
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentLength = $bodyBytes.Length
            $stream = $request.GetRequestStream()
            try { $stream.Write($bodyBytes, 0, $bodyBytes.Length) } finally { $stream.Close() }
        } else {
            $request.ContentLength = 0
        }

        $response = $request.GetResponse()
        $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
        $content = $reader.ReadToEnd()
        $reader.Close()
        $statusCode = [int]$response.StatusCode
        $response.Close()

        return @{ Status = $statusCode; Content = $content }
    } catch {
        $statusCode = 0
        $content = ""
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $content = $reader.ReadToEnd()
                $reader.Close()
            } catch { $content = $_.Exception.Message }
        } else {
            $content = $_.Exception.Message
        }
        return @{ Status = $statusCode; Content = $content; Error = $true }
    }
}

function Test-WebDavConnection {
    param([string]$BaseUrl, [string]$Auth)
    $result = Invoke-WebDavRequest -Method "PROPFIND" -BaseUrl $BaseUrl -Path "" -Auth $Auth -Headers @{ "Depth" = "0" }
    return ($result.Status -in @(200, 207))
}

function Get-WebDavFileList {
    param(
        [string]$BaseUrl,
        [string]$BasePath,
        [string]$Auth
    )

    $body = @"
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:getlastmodified/>
    <D:getcontentlength/>
    <D:etag/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>
"@

    $result = Invoke-WebDavRequest -Method "PROPFIND" -BaseUrl $BaseUrl -Path $BasePath -Auth $Auth -Body $body -Headers @{ "Depth" = "1" }
    if ($result.Status -notin @(200, 207)) {
        throw "PROPFIND failed: $($result.Status)"
    }

    $files = @()
    try {
        [xml]$xml = $result.Content
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace("D", "DAV:")

        $responses = $xml.SelectNodes("//D:response", $ns)
        foreach ($resp in $responses) {
            $href = $resp.SelectSingleNode("D:href", $ns).'#text'
            if (-not $href) { continue }
            $href = $href.TrimEnd("/")
            $isDir = $null -ne $resp.SelectSingleNode("D:propstat/D:prop/D:resourcetype/D:collection", $ns)

            $relPath = $href
            $basePathNorm = $BasePath.TrimEnd("/")
            if ($relPath.StartsWith($basePathNorm)) {
                $relPath = $relPath.Substring($basePathNorm.Length).TrimStart("/")
            } elseif ($relPath.StartsWith("/")) {
                $relPath = $relPath.TrimStart("/")
            }

            $sizeEl = $resp.SelectSingleNode("D:propstat/D:prop/D:getcontentlength", $ns)
            $size = if ($sizeEl) { [long]$sizeEl.'#text' } else { 0 }

            $files += @{
                href  = $href
                path  = $relPath
                isDir = $isDir
                size  = $size
            }
        }
    } catch {
        Write-Dim "XML parse warning: $_"
    }

    return $files
}

function Ensure-WebDavDirectories {
    param(
        [string]$BaseUrl,
        [string]$RemotePath,
        [string]$Auth
    )
    $parts = $RemotePath.TrimStart("/").Split("/")
    $current = ""
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $current = if ($current) { "$current/$($parts[$i])" } else { $parts[$i] }
        Invoke-WebDavRequest -Method "MKCOL" -BaseUrl $BaseUrl -Path $current -Auth $Auth | Out-Null
    }
}

function Upload-WebDavFile {
    param(
        [string]$BaseUrl,
        [string]$RemotePath,
        [string]$LocalPath,
        [string]$Auth
    )
    Ensure-WebDavDirectories -BaseUrl $BaseUrl -RemotePath $RemotePath -Auth $Auth
    $stream = [System.IO.File]::Open($LocalPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $data = New-Object byte[] $stream.Length
        $stream.Read($data, 0, $stream.Length) | Out-Null
    } finally {
        $stream.Close()
    }
    $result = Invoke-WebDavRequest -Method "PUT" -BaseUrl $BaseUrl -Path $RemotePath -Auth $Auth -BodyBytes $data -Headers @{
        "Content-Type" = "application/octet-stream"
    }
    return ($result.Status -in @(200, 201, 204, 207))
}

function Download-WebDavFile {
    param(
        [string]$BaseUrl,
        [string]$RemotePath,
        [string]$LocalPath,
        [string]$Auth
    )

    $urlPath = $RemotePath.TrimStart("/")
    $fullUrl = $BaseUrl.TrimEnd("/") + "/" + $urlPath

    try {
        $request = [System.Net.WebRequest]::Create($fullUrl)
        $request.Method = "GET"
        $request.Timeout = 30000
        $request.Headers.Add("Authorization", $Auth)

        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $dir = Split-Path $LocalPath -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $fileStream = [System.IO.File]::Create($LocalPath)
        try {
            $stream.CopyTo($fileStream)
        } finally {
            $fileStream.Close()
            $stream.Close()
            $response.Close()
        }
        return $true
    } catch {
        throw "GET failed: $($_.Exception.Message)"
    }
}

function Remove-WebDavFile {
    param(
        [string]$BaseUrl,
        [string]$RemotePath,
        [string]$Auth
    )
    $result = Invoke-WebDavRequest -Method "DELETE" -BaseUrl $BaseUrl -Path $RemotePath -Auth $Auth
    return ($result.Status -in @(200, 204, 404))
}

# ── Manifest (checksum tracking) ───────────────────────────────────────────

function Compute-FileHash256 {
    param([string]$FilePath)
    try {
        $hash = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = $hash.ComputeHash($stream)
            return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
        } finally {
            $stream.Close()
            $hash.Dispose()
        }
    } catch {
        return "locked"
    }
}

function Get-SyncFiles {
    param([string]$BaseDir)
    $files = @()
    Get-ChildItem -Path $BaseDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($BaseDir.Length + 1).Replace("\", "/")
        if (-not (Test-SyncExclude $rel)) {
            $files += $_
        }
    }
    return $files | Sort-Object FullName
}

function Test-SyncExclude {
    param([string]$RelPath)
    $name = Split-Path $RelPath -Leaf
    $parts = $RelPath.Replace("\", "/").Split("/")

    foreach ($pattern in $Script:SYNC_EXCLUDE) {
        if ($pattern.StartsWith("*.")) {
            if ($name -like $pattern) { return $true }
        } else {
            if ($parts -contains $pattern) { return $true }
            if ($RelPath -like "*$pattern*") { return $true }
        }
    }
    return $false
}

function Build-Manifest {
    param([string]$BaseDir)
    $manifest = @{ files = @{}; generated_at = (Get-Date -Format "o") }
    Get-SyncFiles $BaseDir | ForEach-Object {
        $rel = $_.FullName.Substring($BaseDir.Length + 1).Replace("\", "/")
        $hash = Compute-FileHash256 $_.FullName
        if ($hash -ne "locked") {
            $manifest["files"][$rel] = @{
                hash  = $hash
                size  = $_.Length
                mtime = $_.LastWriteTimeUtc.ToString("o")
            }
        } else {
            Write-Dim "  [skip] $rel (locked)"
        }
    }
    return $manifest
}

function Load-Manifest {
    param([string]$BaseDir)
    $path = Join-Path $BaseDir $Script:MANIFEST_FILENAME
    if (Test-Path $path) {
        try {
            $obj = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            # Convert PSCustomObject to hashtable for reliable iteration
            $files = @{}
            if ($obj.files) {
                foreach ($prop in $obj.files.PSObject.Properties) {
                    if ($prop.Value.hash) {
                        $files[$prop.Name] = @{
                            hash  = $prop.Value.hash
                            size  = $prop.Value.size
                            mtime = $prop.Value.mtime
                        }
                    }
                }
            }
            return @{ files = $files; generated_at = $obj.generated_at }
        } catch { }
    }
    return @{ files = @{} }
}

function Save-Manifest {
    param([string]$BaseDir, $Manifest)
    $path = Join-Path $BaseDir $Script:MANIFEST_FILENAME
    $Manifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $path -Encoding UTF8 -Force
}

# ── Sync Meta ───────────────────────────────────────────────────────────────

function Load-SyncMeta {
    param([string]$BaseDir)
    $path = Join-Path $BaseDir $Script:META_FILENAME
    if (Test-Path $path) {
        try {
            $obj = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            return @{
                lastSync  = $obj.lastSync
                direction = $obj.direction
                machineId = $obj.machineId
            }
        } catch { }
    }
    return @{
        lastSync  = $null
        direction = $null
        machineId = Get-MachineId
    }
}

function Save-SyncMeta {
    param([string]$BaseDir, $Meta)
    $path = Join-Path $BaseDir $Script:META_FILENAME
    $Meta | ConvertTo-Json -Depth 5 | Out-File -FilePath $path -Encoding UTF8 -Force
}

# ── Conflict Detection ──────────────────────────────────────────────────────

function Detect-Conflict {
    param([string]$BaseDir, [string]$Direction)
    $meta = Load-SyncMeta $BaseDir
    $machineId = Get-MachineId

    if (-not $meta.lastSync) { return $null }
    if ($meta.machineId -eq $machineId) { return $null }

    $lastDir = $meta.direction
    $lastMachine = $meta.machineId
    $lastTime = $meta.lastSync

    if (($Direction -eq "push" -and $lastDir -eq "pull") -or
        ($Direction -eq "pull" -and $lastDir -eq "push")) {
        $dirCn = if ($lastDir -eq "pull") { "拉取" } else { "上传" }
        $curDirCn = if ($Direction -eq "push") { "上传" } else { "拉取" }
        return "上次同步是从 $lastMachine 机器${dirCn}的 ($lastTime)，当前要${curDirCn}"
    }

    return $null
}

function Find-FileConflicts {
    param([string]$BaseDir, [array]$RemoteFiles)
    $localManifest = Load-Manifest $BaseDir
    $conflicts = @()

    $localFiles = @{}
    Get-SyncFiles $BaseDir | ForEach-Object {
        $rel = $_.FullName.Substring($BaseDir.Length + 1).Replace("\", "/")
        $localFiles[$rel] = $_
    }

    $remoteMap = @{}
    $RemoteFiles | Where-Object { -not $_.isDir -and $_.path } | ForEach-Object {
        $remoteMap[$_.path] = $_
    }

    foreach ($rel in $localFiles.Keys) {
        if ($remoteMap.ContainsKey($rel)) {
            $localHash = Compute-FileHash256 $localFiles[$rel].FullName
            $oldHash = if ($localManifest.files.$rel) { $localManifest.files.$rel.hash } else { $null }
            $localChanged = ($oldHash -ne $localHash)
            $remoteExists = $null -ne $remoteMap[$rel]

            if ($localChanged -and $remoteExists) {
                $conflicts += @{
                    path      = $rel
                    localHash = $localHash.Substring(0, 12)
                    type      = "both_changed"
                }
            }
        }
    }

    return $conflicts
}

# ── Commands ────────────────────────────────────────────────────────────────

function Invoke-Init {
    $configDir = Get-ConfigDir
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $configPath = Join-Path $configDir "config.yaml"
    if (Test-Path $configPath) {
        Write-Warn "配置文件已存在: $configPath"
        return
    }

    $content = @"
# wave-sync configuration
# https://github.com/liboevan/wave-sync

webdav:
  # 坚果云 (Jianguo Cloud / Nutstore) - 国内首选
  # 获取应用密码: 坚果云 → 账户信息 → 安全选项 → 第三方应用管理 → 添加应用密码
  url: "https://dav.jianguoyun.com/dav/wave-sync"
  user: "your@email.com"
  password: ""  # 应用密码（非登录密码），留空则运行时交互输入
"@
    $content | Out-File -FilePath $configPath -Encoding UTF8
    Write-Ok "配置已创建: $configPath"
    Write-Dim "请编辑配置文件，填入你的 WebDAV 信息"
}

function Invoke-Push {
    $waveDir = Find-WaveDir -OverrideDir $WaveDir
    if (-not $waveDir) {
        Write-Err "Wave Terminal config directory not found"
        Write-Dim "Use -WaveDir to specify path"
        exit 1
    }

    # If no sync files found, try searching for Wave config files
    if ((Get-SyncFiles $waveDir).Count -eq 0) {
        Write-Warn "No syncable files in $waveDir"
        $found = Find-WaveConfigFiles
        if ($found) {
            Write-Info "Found Wave config at: $found"
            $waveDir = $found
        } else {
            Write-Err "Could not find Wave config files"
            Write-Dim "Use -WaveDir to specify the path to your Wave config"
            exit 1
        }
    }

    $webdav = Get-WebDavConfig -Override @{ url = $Url; user = $User; password = $Password }
    $auth = New-WebDavAuth -User $webdav.user -Password $webdav.password
    $baseUrl = $webdav.url

    Write-Info "Wave config: $waveDir"
    Write-Info "Machine: $(Get-MachineId)"

    # Debug: show directory contents
    Write-Dim "Contents:"
    Get-ChildItem $waveDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object {
        $rel = $_.FullName.Substring($waveDir.Length + 1)
        $excluded = Test-SyncExclude ($rel.Replace("\", "/"))
        $mark = if ($excluded) { "[skip]" } else { "[sync]" }
        Write-Dim "  $mark $rel"
    }
    $syncCount = (Get-SyncFiles $waveDir).Count
    Write-Dim "  Total syncable files: $syncCount"

    # Conflict detection
    $conflict = Detect-Conflict -BaseDir $waveDir -Direction "push"
    if ($conflict) {
        Write-Warn $conflict
        if (-not $Force) {
            $ans = Read-Host "Continue upload? (y/N)"
            if ($ans -ne "y") {
                Write-Info "Cancelled"
                return
            }
        }
    }

    # Test connection
    Write-Info "Connecting to WebDAV..."
    Write-Dim "URL: $baseUrl"
    $testResult = Invoke-WebDavRequest -Method "PROPFIND" -BaseUrl $baseUrl -Path "" -Auth $auth -Headers @{ "Depth" = "0" }
    if ($testResult.Status -in @(200, 207)) {
        Write-Ok "Connected"
    } else {
        Write-Err "Connection failed (HTTP $($testResult.Status))"
        if ($testResult.Content) { Write-Dim "$($testResult.Content.Substring(0, [Math]::Min(200, $testResult.Content.Length)))" }
        exit 1
    }

    # Get local files
    $files = Get-SyncFiles $waveDir
    Write-Info "找到 $($files.Count) 个文件"

    # Build current manifest
    $currentManifest = Build-Manifest $waveDir
    $oldManifest = Load-Manifest $waveDir

    # Find changes
    $newFiles = @()
    $changed = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($waveDir.Length + 1).Replace("\", "/")
        $currentHash = $currentManifest.files.$rel.hash
        $oldHash = if ($oldManifest.files.$rel) { $oldManifest.files.$rel.hash } else { $null }
        if (-not $oldHash) {
            $newFiles += $rel
        } elseif ($oldHash -ne $currentHash) {
            $changed += $rel
        }
    }

    $deleted = @()
    foreach ($rel in $oldManifest.files.Keys) {
        if (-not $currentManifest.files[$rel]) {
            $deleted += $rel
        }
    }

    $totalOps = $newFiles.Count + $changed.Count + $deleted.Count
    if ($totalOps -eq 0 -and -not $Force) {
        Write-Ok "所有文件已是最新状态，无需同步"
        return
    }

    if ($newFiles.Count -gt 0) { Write-Info "新增: $($newFiles.Count) 个文件" }
    if ($changed.Count -gt 0) { Write-Info "修改: $($changed.Count) 个文件" }
    if ($deleted.Count -gt 0) { Write-Info "删除: $($deleted.Count) 个文件" }

    # Upload
    $success = 0; $fail = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($waveDir.Length + 1).Replace("\", "/")
        $status = if ($rel -in $newFiles) { "新" } elseif ($rel -in $changed) { "改" } else { "=" }
        Write-Dim "  [$status] $rel"
        try {
            Upload-WebDavFile -BaseUrl $baseUrl -RemotePath $rel -LocalPath $f.FullName -Auth $auth | Out-Null
            $success++
        } catch {
            Write-Err "    失败: $_"
            $fail++
        }
    }

    # Delete remote files
    foreach ($rel in $deleted) {
        Write-Dim "  [删] $rel"
        try {
            Remove-WebDavFile -BaseUrl $baseUrl -RemotePath $rel -Auth $auth | Out-Null
        } catch { }
    }

    # Save manifest
    Save-Manifest $waveDir $currentManifest

    # Save sync meta
    $meta = Load-SyncMeta $waveDir
    $meta.lastSync = (Get-Date -Format "o")
    $meta.direction = "push"
    $meta.machineId = Get-MachineId
    Save-SyncMeta $waveDir $meta

    Write-Host ""
    if ($fail -eq 0) {
        Write-Ok "上传完成: $success 个文件"
    } else {
        Write-Warn "上传完成: $success 成功, $fail 失败"
    }
}

function Invoke-Pull {
    $waveDir = Find-WaveDir -OverrideDir $WaveDir
    if (-not $waveDir) {
        Write-Err "未找到 Wave Terminal 配置目录"
        Write-Dim "请使用 -WaveDir 参数指定路径"
        exit 1
    }

    $webdav = Get-WebDavConfig -Override @{ url = $Url; user = $User; password = $Password }
    $auth = New-WebDavAuth -User $webdav.user -Password $webdav.password
    $baseUrl = $webdav.url

    Write-Info "Wave config: $waveDir"
    Write-Info "Machine: $(Get-MachineId)"

    # Conflict detection
    $conflict = Detect-Conflict -BaseDir $waveDir -Direction "pull"
    if ($conflict) {
        Write-Warn $conflict
        if (-not $Force) {
            $ans = Read-Host "Continue pull? (y/N)"
            if ($ans -ne "y") {
                Write-Info "Cancelled"
                return
            }
        }
    }

    # Test connection
    Write-Info "Connecting to WebDAV..."
    Write-Dim "URL: $baseUrl"
    $testResult = Invoke-WebDavRequest -Method "PROPFIND" -BaseUrl $baseUrl -Path "" -Auth $auth -Headers @{ "Depth" = "0" }
    if ($testResult.Status -in @(200, 207)) {
        Write-Ok "Connected"
    } else {
        Write-Err "Connection failed (HTTP $($testResult.Status))"
        if ($testResult.Content) { Write-Dim "$($testResult.Content.Substring(0, [Math]::Min(200, $testResult.Content.Length)))" }
        exit 1
    }

    # List remote files
    Write-Info "获取远程文件列表..."
    try {
        $remoteFiles = Get-WebDavFileList -BaseUrl $baseUrl -BasePath "" -Auth $auth
    } catch {
        Write-Err "获取文件列表失败: $_"
        exit 1
    }

    $remoteFiles = $remoteFiles | Where-Object { -not $_.isDir -and $_.path }
    Write-Info "远程找到 $($remoteFiles.Count) 个文件"

    if ($remoteFiles.Count -eq 0) {
        Write-Warn "远程没有同步文件，请先在其他机器上执行 push"
        return
    }

    # Check file conflicts
    $conflicts = Find-FileConflicts -BaseDir $waveDir -RemoteFiles $remoteFiles
    if ($conflicts.Count -gt 0) {
        Write-Warn "发现 $($conflicts.Count) 个文件可能有冲突:"
        foreach ($c in $conflicts) {
            Write-Dim "  ⚠ $($c.path)"
        }
        if (-not $Force) {
            $ans = Read-Host "这些文件在本地和云端都有修改，拉取将覆盖本地版本。继续? (y/N)"
            if ($ans -ne "y") {
                Write-Info "已取消"
                return
            }
        }
    }

    # Download
    $success = 0; $fail = 0; $new = 0; $updated = 0
    foreach ($rf in $remoteFiles) {
        $rel = $rf.path
        $localPath = Join-Path $waveDir $rel
        $isNew = -not (Test-Path $localPath)
        Write-Dim "  [$(if ($isNew) {'新'} else {'更'})] $rel"
        try {
            Download-WebDavFile -BaseUrl $baseUrl -RemotePath $rel -LocalPath $localPath -Auth $auth | Out-Null
            $success++
            if ($isNew) { $new++ } else { $updated++ }
        } catch {
            Write-Err "    失败: $_"
            $fail++
        }
    }

    # Save manifest
    $manifest = Build-Manifest $waveDir
    Save-Manifest $waveDir $manifest

    # Save sync meta
    $meta = Load-SyncMeta $waveDir
    $meta.lastSync = (Get-Date -Format "o")
    $meta.direction = "pull"
    $meta.machineId = Get-MachineId
    Save-SyncMeta $waveDir $meta

    Write-Host ""
    if ($fail -eq 0) {
        Write-Ok "下载完成: $success 个文件 ($new 新增, $updated 更新)"
    } else {
        Write-Warn "下载完成: $success 成功, $fail 失败"
    }

    Write-Warn "请重启 Wave Terminal 以加载新配置"
}

function Invoke-Status {
    $waveDir = Find-WaveDir -OverrideDir $WaveDir

    Write-Host ""
    Write-Host "=== Wave Terminal Sync Status ===" -ForegroundColor Cyan
    Write-Host "  Machine:      $(Get-MachineId)"

    if ($waveDir) {
        Write-Host "  Config Dir:   $waveDir"
    } else {
        Write-Err "Wave 配置目录不存在"
        return
    }

    $meta = Load-SyncMeta $waveDir
    if ($meta.lastSync) {
        $dirCn = switch ($meta.direction) { "push" { "上传" } "pull" { "下载" } default { $meta.direction } }
        Write-Host "  Last Sync:    $($meta.lastSync) ($dirCn)"
        Write-Host "  Sync Machine: $($meta.machineId)"
    } else {
        Write-Host "  Last Sync:    Never" -ForegroundColor Yellow
    }

    $files = Get-SyncFiles $waveDir
    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
    Write-Host "  Local Files:  $($files.Count) ($(Format-Size $totalSize))"

    # Show unsynced changes
    if ($meta.lastSync -and $files.Count -gt 0) {
        $manifest = Load-Manifest $waveDir
        $changes = @()

        foreach ($f in $files) {
            $rel = $f.FullName.Substring($waveDir.Length + 1).Replace("\", "/")
            $currentHash = Compute-FileHash256 $f.FullName
            $oldHash = if ($manifest.files.$rel) { $manifest.files.$rel.hash } else { $null }
            if (-not $oldHash) {
                $changes += @{ status = "new"; path = $rel }
            } elseif ($oldHash -ne $currentHash) {
                $changes += @{ status = "changed"; path = $rel }
            }
        }

        $localRels = @{}
        $files | ForEach-Object {
            $rel = $_.FullName.Substring($waveDir.Length + 1).Replace("\", "/")
            $localRels[$rel] = $true
        }
        foreach ($rel in $manifest.files.Keys) {
            if (-not $localRels.ContainsKey($rel)) {
                $changes += @{ status = "deleted"; path = $rel }
            }
        }

        if ($changes.Count -gt 0) {
            Write-Host ""
            Write-Host "  Unsynced Changes:" -ForegroundColor Yellow
            $shown = [Math]::Min($changes.Count, 20)
            for ($i = 0; $i -lt $shown; $i++) {
                $c = $changes[$i]
                $label = switch ($c.status) { "new" { "+" } "changed" { "~" } "deleted" { "-" } }
                $color = switch ($c.status) { "new" { "Green" } "changed" { "Yellow" } "deleted" { "Red" } }
                Write-Host "    [$label] $($c.path)" -ForegroundColor $color
            }
            if ($changes.Count -gt 20) {
                Write-Dim "    ... and $($changes.Count - 20) more"
            }
        } else {
            Write-Host ""
            Write-Host "  All files in sync" -ForegroundColor Green
        }
    }

    # Config
    $config = Load-Config
    if ($config["url"]) {
        Write-Host ""
        Write-Host "  WebDAV:       $($config['url'])"
    } else {
        Write-Host ""
        Write-Host "  WebDAV:       not configured" -ForegroundColor Yellow
        Write-Dim "  (run: wave-sync init)"
    }

    Write-Host ""
}

function Invoke-Diff {
    $waveDir = Find-WaveDir -OverrideDir $WaveDir
    if (-not $waveDir) {
        Write-Err "未找到 Wave Terminal 配置目录"
        exit 1
    }

    $manifest = Load-Manifest $waveDir
    $files = Get-SyncFiles $waveDir

    $changes = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($waveDir.Length + 1).Replace("\", "/")
        $currentHash = Compute-FileHash256 $f.FullName
        $oldHash = if ($manifest.files.$rel) { $manifest.files.$rel.hash } else { $null }
        if (-not $oldHash) {
            $changes += @{ status = "new"; path = $rel }
        } elseif ($oldHash -ne $currentHash) {
            $changes += @{ status = "changed"; path = $rel }
        }
    }

    $deleted = @()
    foreach ($rel in $manifest.files.Keys) {
        $localPath = Join-Path $waveDir $rel
        if (-not (Test-Path $localPath)) {
            $deleted += $rel
        }
    }

    if ($changes.Count -eq 0 -and $deleted.Count -eq 0) {
        Write-Ok "没有未同步的更改"
        return
    }

    Write-Host ""
    Write-Host "=== Unsynced Changes ===" -ForegroundColor Cyan
    foreach ($c in $changes) {
        $label = if ($c.status -eq "new") { "+" } else { "~" }
        $color = if ($c.status -eq "new") { "Green" } else { "Yellow" }
        Write-Host "  [$label] $($c.path)" -ForegroundColor $color
    }
    foreach ($d in $deleted) {
        Write-Host "  [-] $d" -ForegroundColor Red
    }
    Write-Host ""
}

function Format-Size {
    param([long]$Size)
    foreach ($unit in @("B", "KB", "MB", "GB")) {
        if ($Size -lt 1024) { return "$([math]::Round($Size, 1)) $unit" }
        $Size /= 1024
    }
    return "$([math]::Round($Size, 1)) TB"
}

function Show-Help {
    $help = @"

  wave-sync v$($Script:VERSION)  - Wave Terminal 配置同步工具 (WebDAV)

  Usage:
    wave-sync <command> [options]

  Commands:
    init              创建配置文件
    push              上传本地配置到 WebDAV
    pull              从 WebDAV 下载配置到本地
    status            查看同步状态
    diff              查看未同步的更改

  Options:
    -Url <url>        WebDAV 服务器地址
    -User <user>      WebDAV 用户名
    -Password <pass>  WebDAV 密码
    -WaveDir <path>   Wave 配置目录路径
    -Force             强制执行（忽略冲突）

  Environment Variables:
    WAVESYNC_WEBDAV_URL     WebDAV URL
    WAVESYNC_WEBDAV_USER    WebDAV 用户名
    WAVESYNC_WEBDAV_PASS    WebDAV 密码

  Examples:
    wave-sync init
    wave-sync push
    wave-sync pull --force
    wave-sync status
    wave-sync push -Url "https://dav.jianguoyun.com/dav/wave" -User "user" -Password "pass"

  Config: $(Get-ConfigPath)

"@
    Write-Host $help
}

# ── Main ────────────────────────────────────────────────────────────────────

# Enable ANSI colors on Windows
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    try {
        $sig = '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int mode);'
        $type = Add-Type -MemberDefinition $sig -Name "Kernel32" -Namespace "Win32" -PassThru
        $handle = [Win32.Kernel32]::GetStdHandle(-11)
        $type::SetConsoleMode($handle, 7)
    } catch { }
}

Add-Type -AssemblyName System.Web

switch ($Command) {
    "init"  { Invoke-Init }
    "push"  { Invoke-Push }
    "pull"  { Invoke-Pull }
    "status" { Invoke-Status }
    "diff"  { Invoke-Diff }
    "help"  { Show-Help }
    "-h"    { Show-Help }
    "--help" { Show-Help }
    default {
        Write-Err "未知命令: $Command"
        Show-Help
        exit 1
    }
}
