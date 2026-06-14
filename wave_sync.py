#!/usr/bin/env python3
"""
wave-sync: Wave Terminal configuration sync via WebDAV.

Sync your Wave Terminal workspace, connections, and widgets across machines
using any WebDAV service (Jianguo Cloud / Nutstore, Nextcloud, etc.)

Usage:
    wave-sync push          Upload local config to WebDAV
    wave-sync pull          Download config from WebDAV
    wave-sync status        Show sync status
    wave-sync init          Create config file
    wave-sync -h            Show help

Config file: ~/.config/wave-sync/config.yaml (or %APPDATA%/wave-sync/config.yaml on Windows)
"""

import argparse
import hashlib
import json
import os
import platform
import sys
import time
import xml.etree.ElementTree as ET
from base64 import b64encode
from datetime import datetime, timezone
from getpass import getpass
from http.client import HTTPConnection, HTTPSConnection
from pathlib import Path
from urllib.parse import quote, urljoin, urlparse, unquote

# ── Constants ──────────────────────────────────────────────────────────────

VERSION = "0.2.0"
DAV_NS = "DAV:"
CONFIG_DIR_NAME = "wave-sync"
META_FILENAME = ".wave-sync-meta.json"
MANIFEST_FILENAME = ".wave-sync-manifest.json"

# Wave Terminal config directory patterns per platform
# Wave stores user config (connections.json, widgets.json, settings.json) in <WAVETERM_HOME>/config/
# We also accept the root WAVETERM_HOME for syncing everything
WAVE_DIR_PATTERNS = {
    "Windows": [
        Path(os.environ.get("APPDATA", "")) / "waveterm",
        Path(os.environ.get("LOCALAPPDATA", "")) / "waveterm",
        Path.home() / ".waveterm",
    ],
    "Darwin": [
        Path.home() / "Library" / "Application Support" / "waveterm",
        Path.home() / ".waveterm",
    ],
    "Linux": [
        Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "waveterm",
        Path.home() / ".waveterm",
        Path.home() / ".config" / "waveterm",
    ],
}

# Files/dirs to never sync
SYNC_EXCLUDE = {
    META_FILENAME,
    MANIFEST_FILENAME,
    "*.log",
    "*.log.*",
    "*.tmp",
    "*.bak",
    "*.sock",
    "*.pid",
    "__pycache__",
    "Cache",
    "Code Cache",
    "GPUCache",
    "DawnGraphiteCache",
    "DawnWebGPUCache",
    "blob_storage",
    "session_storage",
    "Local Storage",
    "IndexedDB",
    "WebStorage",
    "leveldb",
    # Wave runtime files (not user settings) - only exclude when syncing root dir
    "bin",
    "shell",
    "ssh",
}

# ── Colors (ANSI) ──────────────────────────────────────────────────────────

class C:
    RESET  = "\033[0m"
    RED    = "\033[31m"
    GREEN  = "\033[32m"
    YELLOW = "\033[33m"
    BLUE   = "\033[34m"
    CYAN   = "\033[36m"
    GRAY   = "\033[90m"
    BOLD   = "\033[1m"

    @staticmethod
    def disable():
        C.RED = C.GREEN = C.YELLOW = C.BLUE = C.CYAN = C.GRAY = C.BOLD = C.RESET = ""

if platform.system() == "Windows" and not os.environ.get("WT_SESSION"):
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        kernel32.SetConsoleMode(kernel32.GetStdHandle(-11), 7)
    except Exception:
        C.disable()

def info(msg):  print(f"{C.CYAN}[*]{C.RESET} {msg}")
def ok(msg):    print(f"{C.GREEN}[✓]{C.RESET} {msg}")
def warn(msg):  print(f"{C.YELLOW}[!]{C.RESET} {msg}")
def err(msg):   print(f"{C.RED}[✗]{C.RESET} {msg}")
def dim(msg):   print(f"{C.GRAY}  {msg}{C.RESET}")

# ── Platform Helpers ───────────────────────────────────────────────────────

def get_platform():
    return platform.system()

def get_config_dir() -> Path:
    system = get_platform()
    if system == "Windows":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / CONFIG_DIR_NAME

def find_wave_dir() -> Path | None:
    system = get_platform()
    patterns = WAVE_DIR_PATTERNS.get(system, WAVE_DIR_PATTERNS["Linux"])
    for p in patterns:
        if p.exists():
            # Prefer <wavehome>/config/ if it exists (stores user settings)
            config_dir = p / "config"
            if config_dir.exists():
                return config_dir
            # Fall back to root dir, but we'll exclude Wave runtime files
            return p
    return None

def is_wave_runtime_dir(wave_dir: Path) -> bool:
    """Check if we're syncing the root Wave dir (not config/ subdir)."""
    return not wave_dir.name == "config" and (wave_dir / "bin").exists()

def get_machine_id() -> str:
    return platform.node()

# ── Config ─────────────────────────────────────────────────────────────────

def get_config_path() -> Path:
    return get_config_dir() / "config.yaml"

def load_config() -> dict:
    config_path = get_config_path()
    if not config_path.exists():
        return {}
    try:
        import yaml
        with open(config_path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except ImportError:
        # Fallback: simple key: value parsing
        return _parse_simple_config(config_path)

def _parse_simple_config(path: Path) -> dict:
    config = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if ":" in line:
                key, _, value = line.partition(":")
                config[key.strip()] = value.strip().strip('"').strip("'")
    return config

def save_config_example():
    config_dir = get_config_dir()
    config_dir.mkdir(parents=True, exist_ok=True)
    config_path = config_dir / "config.yaml"

    if config_path.exists():
        warn(f"Config already exists: {config_path}")
        return

    example = f"""# wave-sync configuration
# See: https://github.com/evan/wave-sync

webdav:
  # Jianguo Cloud (Nutstore) - 国内首选
  # 获取应用密码: 坚果云 → 账户信息 → 安全选项 → 第三方应用管理 → 添加应用密码
  url: "https://dav.jianguoyun.com/dav/wave-sync"
  user: "your@email.com"
  password: ""  # 应用密码，非登录密码。也可留空，运行时交互输入

# 同步范围（可选，默认全部同步）
# sync:
#   include:
#     - "settings/"
#     - "connections/"
#   exclude:
#     - "*.log"
#     - "Cache/"
"""
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(example)
    ok(f"Config created: {config_path}")
    dim("请编辑配置文件，填入你的 WebDAV 信息")

# ── WebDAV Client ──────────────────────────────────────────────────────────

class WebDAVClient:
    def __init__(self, url: str, user: str, password: str):
        parsed = urlparse(url)
        self.base_url = url.rstrip("/")
        self.scheme = parsed.scheme
        self.host = parsed.hostname
        self.port = parsed.port or (443 if self.scheme == "https" else 80)
        self.path = parsed.path.rstrip("/")
        self.user = user
        self.password = password
        self.auth_header = "Basic " + b64encode(f"{user}:{password}".encode()).decode()

    def _connect(self):
        if self.scheme == "https":
            return HTTPSConnection(self.host, self.port, timeout=30)
        return HTTPConnection(self.host, self.port, timeout=30)

    def _request(self, method: str, path: str, body=None, headers=None, depth=None):
        conn = self._connect()
        url_path = self.path + "/" + path.strip("/") if path.strip("/") else self.path

        req_headers = {
            "Authorization": self.auth_header,
            "Content-Type": "application/xml; charset=utf-8",
        }
        if headers:
            req_headers.update(headers)
        if depth is not None:
            req_headers["Depth"] = str(depth)

        try:
            conn.request(method, url_path, body=body, headers=req_headers)
            resp = conn.getresponse()
            data = resp.read()
            return resp.status, resp.reason, data
        finally:
            conn.close()

    def propfind(self, path: str = "", depth: int = 1):
        body = f"""<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:getlastmodified/>
    <D:getcontentlength/>
    <D:etag/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>"""
        status, reason, data = self._request("PROPFIND", path, body=body, depth=depth)
        if status not in (200, 207):
            raise Exception(f"PROPFIND failed: {status} {reason}")
        return self._parse_propfind(data)

    def _parse_propfind(self, xml_data: bytes) -> list[dict]:
        results = []
        try:
            root = ET.fromstring(xml_data)
        except ET.ParseError:
            return results

        for resp in root.findall(f"{{{DAV_NS}}}response"):
            href_el = resp.find(f"{{{DAV_NS}}}href")
            if href_el is None or href_el.text is None:
                continue
            href = unquote(href_el.text.rstrip("/"))

            props_el = resp.find(f"{{{DAV_NS}}}propstat/{{{DAV_NS}}}prop")
            if props_el is None:
                continue

            is_dir = props_el.find(f"{{{DAV_NS}}}resourcetype/{{{DAV_NS}}}collection") is not None
            mtime_el = props_el.find(f"{{{DAV_NS}}}getlastmodified")
            size_el = props_el.find(f"{{{DAV_NS}}}getcontentlength")
            etag_el = props_el.find(f"{{{DAV_NS}}}etag")

            # Extract relative path from base path
            rel_path = href
            if self.path and href.startswith(self.path):
                rel_path = href[len(self.path):].lstrip("/")
            elif href.startswith("/"):
                rel_path = href.lstrip("/")

            results.append({
                "href": href,
                "path": rel_path,
                "is_dir": is_dir,
                "mtime": mtime_el.text if mtime_el is not None else None,
                "size": int(size_el.text) if size_el is not None else None,
                "etag": etag_el.text.strip('"') if etag_el is not None else None,
            })

        return results

    def upload(self, local_path: str, remote_path: str):
        with open(local_path, "rb") as f:
            data = f.read()

        status, reason, _ = self._request("PUT", remote_path, body=data, headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(len(data)),
        })
        if status not in (200, 201, 204, 207):
            raise Exception(f"PUT failed: {status} {reason}")
        return True

    def download(self, remote_path: str, local_path: str):
        status, reason, data = self._request("GET", remote_path)
        if status != 200:
            raise Exception(f"GET failed: {status} {reason}")

        local_path = Path(local_path)
        local_path.parent.mkdir(parents=True, exist_ok=True)
        with open(local_path, "wb") as f:
            f.write(data)
        return True

    def mkdir(self, path: str):
        status, reason, _ = self._request("MKCOL", path)
        if status not in (201, 405):  # 405 = already exists
            raise Exception(f"MKCOL failed: {status} {reason}")

    def delete(self, path: str):
        status, reason, _ = self._request("DELETE", path)
        if status not in (200, 204, 404):
            raise Exception(f"DELETE failed: {status} {reason}")

    def check_connection(self):
        try:
            status, reason, _ = self._request("PROPFIND", "", depth=0)
            return status in (200, 207)
        except Exception:
            return False

# ── Manifest (checksum tracking) ──────────────────────────────────────────

def compute_file_hash(filepath: str) -> str:
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()

def build_manifest(wave_dir: Path) -> dict:
    manifest = {"files": {}, "generated_at": datetime.now(timezone.utc).isoformat()}
    for f in get_sync_files(wave_dir):
        rel = str(f.relative_to(wave_dir))
        manifest["files"][rel] = {
            "hash": compute_file_hash(str(f)),
            "size": f.stat().st_size,
            "mtime": f.stat().st_mtime,
        }
    return manifest

def load_manifest(wave_dir: Path) -> dict:
    meta_path = wave_dir / MANIFEST_FILENAME
    if meta_path.exists():
        try:
            return json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"files": {}}

def save_manifest(wave_dir: Path, manifest: dict):
    meta_path = wave_dir / MANIFEST_FILENAME
    meta_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")

# ── Sync Logic ─────────────────────────────────────────────────────────────

def get_sync_files(wave_dir: Path) -> list[Path]:
    """Get all files in wave_dir that should be synced."""
    files = []
    for f in wave_dir.rglob("*"):
        if not f.is_file():
            continue
        rel = str(f.relative_to(wave_dir))
        if _should_exclude(rel):
            continue
        files.append(f)
    return sorted(files)

def _should_exclude(rel_path: str) -> bool:
    name = Path(rel_path).name
    parts = Path(rel_path).parts

    for pattern in SYNC_EXCLUDE:
        if pattern.startswith("*."):
            if name.endswith(pattern[1:]):
                return True
        elif pattern in SYNC_EXCLUDE:
            # Check if pattern matches a directory component
            if pattern in parts:
                return True
            # Also check full path match for backward compat
            if pattern in rel_path:
                return True
    return False

def get_sync_meta_path(wave_dir: Path) -> Path:
    return wave_dir / META_FILENAME

def load_sync_meta(wave_dir: Path) -> dict:
    meta_path = get_sync_meta_path(wave_dir)
    if meta_path.exists():
        try:
            return json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"lastSync": None, "direction": None, "machineId": get_machine_id(), "checksums": {}}

def save_sync_meta(wave_dir: Path, meta: dict):
    meta_path = get_sync_meta_path(wave_dir)
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")

def detect_conflict(wave_dir: Path, direction: str) -> dict | None:
    """
    Detect potential conflicts before sync.
    Returns conflict info dict or None if no conflict.
    """
    meta = load_sync_meta(wave_dir)
    machine_id = get_machine_id()

    if not meta.get("lastSync"):
        return None

    last_dir = meta.get("direction")
    last_machine = meta.get("machineId")
    last_time = meta.get("lastSync")

    if last_machine == machine_id:
        return None

    # Conflict: last sync was from a different machine in opposite direction
    if (direction == "push" and last_dir == "pull") or \
       (direction == "pull" and last_dir == "push"):
        return {
            "type": "cross_machine",
            "last_direction": last_dir,
            "last_machine": last_machine,
            "last_time": last_time,
            "message": (
                f"上次同步是从 {last_machine} 机器{'拉取' if last_dir == 'pull' else '上传'}的 "
                f"({last_time})，当前要{'上传' if direction == 'push' else '拉取'}"
            ),
        }

    return None

def check_file_conflicts(wave_dir: Path, remote_files: list[dict]) -> list[dict]:
    """Compare local checksums with remote to find files changed on both sides."""
    local_manifest = load_manifest(wave_dir)
    conflicts = []

    local_files = {str(f.relative_to(wave_dir)): f for f in get_sync_files(wave_dir)}
    remote_map = {rf["path"]: rf for rf in remote_files if not rf["is_dir"]}

    for rel_path, local_file in local_files.items():
        if rel_path in remote_map:
            local_hash = compute_file_hash(str(local_file))
            remote_info = remote_map[rel_path]
            local_meta = local_manifest.get("files", {}).get(rel_path, {})

            # File changed locally since last sync
            local_changed = local_meta.get("hash") != local_hash if local_meta else True
            # File exists on remote (was uploaded by another machine)
            remote_exists = remote_info is not None

            if local_changed and remote_exists:
                conflicts.append({
                    "path": rel_path,
                    "local_hash": local_hash[:12],
                    "type": "both_changed",
                })

    return conflicts

# ── Commands ───────────────────────────────────────────────────────────────

def cmd_init(args):
    save_config_example()

def cmd_push(args):
    config = _load_config(args)
    wave_dir = _get_wave_dir(args)

    info(f"Wave config: {wave_dir}")
    info(f"Machine: {get_machine_id()}")

    # Conflict detection
    conflict = detect_conflict(wave_dir, "push")
    if conflict:
        warn(conflict["message"])
        if not args.force:
            ans = input(f"{C.YELLOW}继续上传? (y/N): {C.RESET}").strip().lower()
            if ans != "y":
                info("已取消")
                return

    client = WebDAVClient(config["webdav"]["url"], config["webdav"]["user"], config["webdav"]["password"])

    # Test connection
    info("连接 WebDAV 服务器...")
    if not client.check_connection():
        err("无法连接 WebDAV 服务器，请检查配置")
        sys.exit(1)
    ok("连接成功")

    # Get local files
    files = get_sync_files(wave_dir)
    info(f"找到 {len(files)} 个文件")

    # Build current manifest for comparison
    current_manifest = build_manifest(wave_dir)
    old_manifest = load_manifest(wave_dir)

    # Find changed files
    changed = []
    new_files = []
    for f in files:
        rel = str(f.relative_to(wave_dir))
        current_hash = current_manifest["files"][rel]["hash"]
        old_hash = old_manifest.get("files", {}).get(rel, {}).get("hash")
        if old_hash is None:
            new_files.append(rel)
        elif old_hash != current_hash:
            changed.append(rel)

    # Find deleted files
    deleted = [rel for rel in old_manifest.get("files", {}) if rel not in current_manifest["files"]]

    total_ops = len(new_files) + len(changed) + len(deleted)
    if total_ops == 0 and not args.force:
        ok("所有文件已是最新状态，无需同步")
        return

    if new_files:
        info(f"新增: {len(new_files)} 个文件")
    if changed:
        info(f"修改: {len(changed)} 个文件")
    if deleted:
        info(f"删除: {len(deleted)} 个文件")

    # Upload
    success = 0
    fail = 0
    for f in files:
        rel = str(f.relative_to(wave_dir))
        status = "新" if rel in new_files else ("改" if rel in changed else "=")
        dim(f"  [{status}] {rel}")
        try:
            client.upload(str(f), rel)
            success += 1
        except Exception as e:
            err(f"    失败: {e}")
            fail += 1

    # Delete remote files that were deleted locally
    for rel in deleted:
        dim(f"  [删] {rel}")
        try:
            client.delete(rel)
        except Exception:
            pass

    # Save manifest
    save_manifest(wave_dir, current_manifest)

    # Save sync meta
    meta = load_sync_meta(wave_dir)
    meta["lastSync"] = datetime.now(timezone.utc).isoformat()
    meta["direction"] = "push"
    meta["machineId"] = get_machine_id()
    save_sync_meta(wave_dir, meta)

    print()
    if fail == 0:
        ok(f"上传完成: {success} 个文件")
    else:
        warn(f"上传完成: {success} 成功, {fail} 失败")

def cmd_pull(args):
    config = _load_config(args)
    wave_dir = _get_wave_dir(args)

    info(f"Wave config: {wave_dir}")
    info(f"Machine: {get_machine_id()}")

    # Conflict detection
    conflict = detect_conflict(wave_dir, "pull")
    if conflict:
        warn(conflict["message"])
        if not args.force:
            ans = input(f"{C.YELLOW}继续拉取? (y/N): {C.RESET}").strip().lower()
            if ans != "y":
                info("已取消")
                return

    client = WebDAVClient(config["webdav"]["url"], config["webdav"]["user"], config["webdav"]["password"])

    # Test connection
    info("连接 WebDAV 服务器...")
    if not client.check_connection():
        err("无法连接 WebDAV 服务器，请检查配置")
        sys.exit(1)
    ok("连接成功")

    # List remote files
    info("获取远程文件列表...")
    try:
        remote_files = client.propfind("", depth=2)
    except Exception as e:
        err(f"获取文件列表失败: {e}")
        sys.exit(1)

    remote_files = [f for f in remote_files if not f["is_dir"] and f["path"]]
    info(f"远程找到 {len(remote_files)} 个文件")

    if not remote_files:
        warn("远程没有同步文件，请先在其他机器上执行 push")
        return

    # Check for conflicts
    file_conflicts = check_file_conflicts(wave_dir, remote_files)
    if file_conflicts:
        warn(f"发现 {len(file_conflicts)} 个文件可能有冲突:")
        for c in file_conflicts:
            dim(f"  ⚠ {c['path']}")
        if not args.force:
            ans = input(f"{C.YELLOW}这些文件在本地和云端都有修改，拉取将覆盖本地版本。继续? (y/N): {C.RESET}").strip().lower()
            if ans != "y":
                info("已取消")
                return

    # Download
    local_files = {str(f.relative_to(wave_dir)): f for f in get_sync_files(wave_dir)}
    success = 0
    fail = 0
    new = 0
    updated = 0

    for rf in remote_files:
        rel = rf["path"]
        local_path = wave_dir / rel
        is_new = not local_path.exists()
        dim(f"  [{'新' if is_new else '更'}] {rel}")
        try:
            client.download(rel, str(local_path))
            success += 1
            if is_new:
                new += 1
            else:
                updated += 1
        except Exception as e:
            err(f"    失败: {e}")
            fail += 1

    # Build and save manifest
    manifest = build_manifest(wave_dir)
    save_manifest(wave_dir, manifest)

    # Save sync meta
    meta = load_sync_meta(wave_dir)
    meta["lastSync"] = datetime.now(timezone.utc).isoformat()
    meta["direction"] = "pull"
    meta["machineId"] = get_machine_id()
    save_sync_meta(wave_dir, meta)

    print()
    if fail == 0:
        ok(f"下载完成: {success} 个文件 ({new} 新增, {updated} 更新)")
    else:
        warn(f"下载完成: {success} 成功, {fail} 失败")

    warn("请重启 Wave Terminal 以加载新配置")

def cmd_status(args):
    wave_dir = _get_wave_dir(args)

    print(f"\n{C.BOLD}=== Wave Terminal Sync Status ==={C.RESET}")
    print(f"  Machine:      {get_machine_id()}")
    print(f"  Config Dir:   {wave_dir}")

    if not wave_dir.exists():
        err("Wave 配置目录不存在")
        return

    meta = load_sync_meta(wave_dir)
    if meta.get("lastSync"):
        sync_time = meta["lastSync"]
        direction_cn = {"push": "上传", "pull": "下载"}.get(meta["direction"], meta["direction"])
        print(f"  Last Sync:    {sync_time} ({direction_cn})")
        print(f"  Sync Machine: {meta.get('machineId', 'unknown')}")
    else:
        print(f"  Last Sync:    {C.YELLOW}从未同步{C.RESET}")

    files = get_sync_files(wave_dir)
    total_size = sum(f.stat().st_size for f in files)
    print(f"  Local Files:  {len(files)} ({_human_size(total_size)})")

    # Show changed files since last sync
    if meta.get("lastSync") and files:
        manifest = load_manifest(wave_dir)
        changed = []
        for f in files:
            rel = str(f.relative_to(wave_dir))
            current_hash = compute_file_hash(str(f))
            old_hash = manifest.get("files", {}).get(rel, {}).get("hash")
            if old_hash is None:
                changed.append(("new", rel))
            elif old_hash != current_hash:
                changed.append(("changed", rel))

        local_rels = {str(f.relative_to(wave_dir)) for f in files}
        for rel in manifest.get("files", {}):
            if rel not in local_rels:
                changed.append(("deleted", rel))

        if changed:
            print(f"\n  {C.YELLOW}Unsynced Changes:{C.RESET}")
            for status, path in changed[:20]:
                label = {"new": "+", "changed": "~", "deleted": "-"}[status]
                dim(f"    [{label}] {path}")
            if len(changed) > 20:
                dim(f"    ... and {len(changed) - 20} more")
        else:
            print(f"\n  {C.GREEN}All files in sync{C.RESET}")

    # Config
    config = load_config()
    if config.get("webdav", {}).get("url"):
        url = config["webdav"]["url"]
        # Mask password in URL
        print(f"\n  WebDAV:       {url}")
    else:
        print(f"\n  {C.YELLOW}WebDAV: not configured{C.RESET} (run: wave-sync init)")

    print()

def cmd_diff(args):
    wave_dir = _get_wave_dir(args)
    manifest = load_manifest(wave_dir)
    files = get_sync_files(wave_dir)

    changed = []
    for f in files:
        rel = str(f.relative_to(wave_dir))
        current_hash = compute_file_hash(str(f))
        old_hash = manifest.get("files", {}).get(rel, {}).get("hash")
        if old_hash is None:
            changed.append(("new", rel))
        elif old_hash != current_hash:
            changed.append(("changed", rel))

    deleted = [r for r in manifest.get("files", {}) if not (wave_dir / r).exists()]

    if not changed and not deleted:
        ok("没有未同步的更改")
        return

    print(f"\n{C.BOLD}=== Unsynced Changes ==={C.RESET}")
    for status, path in changed:
        label = "+" if status == "new" else "~"
        color = C.GREEN if status == "new" else C.YELLOW
        print(f"  {color}[{label}]{C.RESET} {path}")
    for path in deleted:
        print(f"  {C.RED}[-]{C.RESET} {path}")
    print()

# ── Helpers ────────────────────────────────────────────────────────────────

def _load_config(args) -> dict:
    config = load_config()

    # Override from args/env
    webdav = config.setdefault("webdav", {})

    if hasattr(args, "url") and args.url:
        webdav["url"] = args.url
    elif os.environ.get("WAVESYNC_WEBDAV_URL"):
        webdav["url"] = os.environ["WAVESYNC_WEBDAV_URL"]

    if hasattr(args, "user") and args.user:
        webdav["user"] = args.user
    elif os.environ.get("WAVESYNC_WEBDAV_USER"):
        webdav["user"] = os.environ["WAVESYNC_WEBDAV_USER"]

    if hasattr(args, "password") and args.password:
        webdav["password"] = args.password
    elif os.environ.get("WAVESYNC_WEBDAV_PASS"):
        webdav["password"] = os.environ["WAVESYNC_WEBDAV_PASS"]

    if not webdav.get("url") or not webdav.get("user"):
        err("请先配置 WebDAV 信息")
        dim(f"编辑配置文件: {get_config_path()}")
        dim("或使用参数: --url, --user, --password")
        dim("或设置环境变量: WAVESYNC_WEBDAV_URL, WAVESYNC_WEBDAV_USER, WAVESYNC_WEBDAV_PASS")
        sys.exit(1)

    if not webdav.get("password"):
        webdav["password"] = getpass(f"{C.CYAN}WebDAV 密码: {C.RESET}")

    return config

def _get_wave_dir(args) -> Path:
    if hasattr(args, "wave_dir") and args.wave_dir:
        return Path(args.wave_dir)

    wave_dir = find_wave_dir()
    if wave_dir is None:
        err("未找到 Wave Terminal 配置目录")
        dim("请使用 --wave-dir 参数指定路径")
        sys.exit(1)
    return wave_dir

def _human_size(size: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"

# ── CLI ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        prog="wave-sync",
        description="Wave Terminal 配置同步工具 (WebDAV)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  wave-sync init                    初始化配置文件
  wave-sync push                    上传本地配置
  wave-sync pull                    下载云端配置
  wave-sync pull --force            强制下载（忽略冲突）
  wave-sync status                  查看同步状态
  wave-sync diff                    查看未同步的更改

坚果云配置:
  url: https://dav.jianguoyun.com/dav/wave-sync
  user: your@email.com
  password: 应用密码（账号设置 → 安全选项 → 第三方应用管理）
        """
    )
    parser.add_argument("--version", action="version", version=f"wave-sync {VERSION}")

    sub = parser.add_subparsers(dest="command")

    # init
    sub.add_parser("init", help="创建配置文件")

    # push
    p_push = sub.add_parser("push", help="上传配置到 WebDAV")
    p_push.add_argument("--url", help="WebDAV URL")
    p_push.add_argument("--user", help="WebDAV 用户名")
    p_push.add_argument("--password", "--pass", help="WebDAV 密码")
    p_push.add_argument("--wave-dir", help="Wave 配置目录")
    p_push.add_argument("-f", "--force", action="store_true", help="强制上传（忽略冲突）")

    # pull
    p_pull = sub.add_parser("pull", help="从 WebDAV 下载配置")
    p_pull.add_argument("--url", help="WebDAV URL")
    p_pull.add_argument("--user", help="WebDAV 用户名")
    p_pull.add_argument("--password", "--pass", help="WebDAV 密码")
    p_pull.add_argument("--wave-dir", help="Wave 配置目录")
    p_pull.add_argument("-f", "--force", action="store_true", help="强制下载（忽略冲突）")

    # status
    p_status = sub.add_parser("status", help="查看同步状态")
    p_status.add_argument("--wave-dir", help="Wave 配置目录")

    # diff
    p_diff = sub.add_parser("diff", help="查看未同步的更改")
    p_diff.add_argument("--wave-dir", help="Wave 配置目录")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(0)

    commands = {
        "init": cmd_init,
        "push": cmd_push,
        "pull": cmd_pull,
        "status": cmd_status,
        "diff": cmd_diff,
    }
    commands[args.command](args)

if __name__ == "__main__":
    main()
