#!/bin/bash
# wave-sync installer for Linux/macOS
# Installs wave-sync to /usr/local/bin (or ~/.local/bin if no sudo)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_SRC="$SCRIPT_DIR/wave_sync.py"

if [ ! -f "$SCRIPT_SRC" ]; then
    echo "[✗] wave_sync.py not found in $SCRIPT_DIR"
    exit 1
fi

# Determine install location
if [ -w /usr/local/bin ] 2>/dev/null; then
    INSTALL_DIR="/usr/local/bin"
elif [ -w "$HOME/.local/bin" ] 2>/dev/null; then
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
else
    mkdir -p "$HOME/.local/bin"
    INSTALL_DIR="$HOME/.local/bin"
    echo "[*] Installing to $INSTALL_DIR"
    echo "[!] Make sure $INSTALL_DIR is in your PATH"
    echo "    Add to ~/.bashrc or ~/.zshrc:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

cp "$SCRIPT_SRC" "$INSTALL_DIR/wave-sync"
chmod +x "$INSTALL_DIR/wave-sync"

echo "[✓] Installed: $INSTALL_DIR/wave-sync"
echo ""
echo "Next steps:"
echo "  1. Run: wave-sync init"
echo "  2. Edit config: ~/.config/wave-sync/config.yaml"
echo "  3. Run: wave-sync push"
