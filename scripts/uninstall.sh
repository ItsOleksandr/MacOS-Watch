#!/usr/bin/env bash
# Stops the LaunchAgent and removes installed files.
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.maccontrol.plist"
INSTALL_DIR="$HOME/Applications/MacControl"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$INSTALL_DIR"
echo "✓ Uninstalled."
