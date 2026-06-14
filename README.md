# wave-sync

Wave Terminal 配置跨机器同步工具。通过 WebDAV 在多台机器之间同步 workspace 布局、连接配置和自定义小部件。

## 为什么需要这个？

Wave Terminal 目前不支持原生的配置同步功能。当你在多台机器上使用 Wave 时，每次都要手动重新配置 workspace、连接和小部件。本工具通过 WebDAV 协议解决这个问题。

## 功能

- **一键部署**: Windows 双击 `setup.bat` 即可完成安装，无需安装任何依赖
- **零依赖**: 仅使用 PowerShell（Windows 自带）
- **增量同步**: 仅上传/下载变更文件
- **冲突检测**: 文件级校验 + 跨机器状态追踪
- **交互式冲突处理**: 冲突时提示你选择处理方式
- **支持主流 WebDAV 服务**: 坚果云、Nextcloud、Synology 等

## 同步范围

| 同步 | 不同步 |
|------|--------|
| Workspace 布局 | 终端历史记录 |
| 标签页配置 | 日志文件 |
| 连接配置 (connections.json) | AI 对话记录 |
| 自定义小部件 (widgets.json) | 本地密钥文件 |
| 主题和外观设置 | 缓存/临时文件 |

## 快速开始

### 一键安装（推荐）

1. 下载本仓库（Clone or Download ZIP）
2. 双击 `setup.bat`
3. 按提示填写 WebDAV 配置
4. 重启终端，运行 `wave-sync push`

### 手动安装

```powershell
# 复制脚本到 PATH 目录
copy wave-sync.ps1 "$env:LOCALAPPDATA\wave-sync\bin\wave-sync.ps1"

# 创建 bat 包装器
@"
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0wave-sync.ps1" %*
"@ | Out-File "$env:LOCALAPPDATA\wave-sync\bin\wave-sync.bat" -Encoding ASCII

# 加入 PATH（需重启终端生效）
$env:Path += ";$env:LOCALAPPDATA\wave-sync\bin"
```

### 初始化配置

```powershell
wave-sync init
```

配置文件路径: `%APPDATA%\wave-sync\config.yaml`

### 编辑配置

```yaml
url: "https://dav.jianguoyun.com/dav/wave-sync"
user: "your@email.com"
password: "your-app-password"
```

### 开始同步

```powershell
# 上传本地配置
wave-sync push

# 下载云端配置
wave-sync pull

# 查看同步状态
wave-sync status

# 查看未同步的更改
wave-sync diff
```

## 坚果云 (Jianguo Cloud) 配置

坚果云是国内首选的 WebDAV 服务，免费用户每月 1GB 上传流量。

1. 登录 [坚果云](https://www.jianguoyun.com/)
2. 进入 **账户信息** → **安全选项** → **第三方应用管理**
3. 点击 **添加应用密码**，输入应用名称（如 "wave-sync"）
4. 复制生成的密码到配置文件

```yaml
url: "https://dav.jianguoyun.com/dav/wave-sync"
user: "your@email.com"
password: "应用密码（非登录密码）"
```

> 注意：坚果云的 WebDAV 目录需要手动创建。先在坚果云客户端创建一个 "wave-sync" 文件夹。

## 使用流程

```
机器A（主力机）              机器B / 机器C
     │                            │
     │  修改 workspace            │
     │                            │
     ▼                            │
  wave-sync push                  │
     │                            │
     └──────────► WebDAV ◄────────┘
                     │
                     ▼
               wave-sync pull
                     │
                     ▼
               重启 Wave 生效
```

## 冲突处理

### 冲突检测机制

工具通过两层机制检测冲突：

1. **跨机器状态追踪**: 记录每次同步的方向、时间和机器名
2. **文件级校验**: 使用 SHA-256 校验和检测文件变更

### 冲突场景

| 场景 | 检测结果 | 处理方式 |
|------|----------|----------|
| Pull 时本地有未同步的 Push | ⚠️ 警告 | 提示确认，可强制覆盖 |
| Push 时上次是其他机器 Pull 的 | ⚠️ 警告 | 提示确认，可强制覆盖 |
| 同一文件在两端都被修改 | ⚠️ 警告 | 列出冲突文件，提示选择 |
| 无冲突 | ✅ 正常 | 直接执行 |

### 强制覆盖

```powershell
# 以本地为准（覆盖云端）
wave-sync push -Force

# 以云端为准（覆盖本地）
wave-sync pull -Force
```

### 推荐工作流

1. 在一台机器上完成修改
2. 立即 `wave-sync push`
3. 到下一台机器 `wave-sync pull`
4. 重启 Wave

**不要同时在多台机器上修改配置**，否则会产生冲突。

## 命令行用法

```powershell
wave-sync init                    # 初始化配置文件
wave-sync push                    # 上传配置
wave-sync push -Force             # 强制上传（忽略冲突）
wave-sync pull                    # 下载配置
wave-sync pull -Force             # 强制下载（忽略冲突）
wave-sync status                  # 查看同步状态
wave-sync diff                    # 查看未同步的更改
wave-sync help                    # 显示帮助

# 通过参数覆盖配置
wave-sync push -Url "https://..." -User "user" -Password "pass"

# 通过环境变量覆盖配置
$env:WAVESYNC_WEBDAV_URL = "https://..."
$env:WAVESYNC_WEBDAV_USER = "user"
$env:WAVESYNC_WEBDAV_PASS = "pass"
wave-sync push
```

## Wave Terminal 集成

Wave Terminal 不支持传统插件系统，但你可以通过以下方式集成：

### 自定义 Widget

在 Wave 的 `widgets.json` 中添加 sync widget：

```json
{
  "wave-sync": {
    "icon": "cloud-arrow-up",
    "label": "sync",
    "color": "#4fc3f7",
    "blockdef": {
      "meta": {
        "view": "term",
        "controller": "cmd",
        "cmd": "wave-sync pull && echo 'Sync complete. Restart Wave to apply.'",
        "cmd:clearonstart": true
      }
    }
  }
}
```

## WebDAV 服务推荐

| 服务 | 免费额度 | 说明 |
|------|----------|------|
| [坚果云](https://www.jianguoyun.com/) | 1GB/月上传 | 国内首选，WebDAV 支持好 |
| [Nextcloud](https://nextcloud.com/) | 自建 | 功能全，可自托管 |
| [Synology Drive](https://www.synology.com/) | 自建 | NAS 用户推荐 |
| [InfiniCLOUD](https://infini-cloud.net/) | 20GB | 日本服务，速度不错 |

## 文件结构

```
wave-sync/
├── README.md              # 本文档
├── wave-sync.ps1          # 主脚本（PowerShell）
├── setup.bat              # Windows 一键安装（双击即用）
├── config.example.yaml    # 配置示例
└── .gitignore             # Git 忽略规则
```

## 常见问题

### Q: 同步后配置没生效？

A: 需要重启 Wave Terminal。配置文件在启动时加载。

### Q: 不同机器的 SSH 连接能用吗？

A: 连接配置会同步，但 SSH 密钥不会。你需要在每台机器上单独配置密钥。

### Q: 密码安全吗？

A: 配置文件中的密码是明文存储，建议：
- 仅限个人机器使用
- 或使用环境变量传入密码
- 或在交互模式下输入密码（不写入配置文件）

### Q: 坚果云连接失败？

A: 常见原因：
1. 使用了登录密码而非应用密码
2. WebDAV 目录不存在（需先在坚果云客户端创建）
3. 网络问题

### Q: 执行策略报错？

A: 运行以下命令解除限制：
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

## License

MIT
