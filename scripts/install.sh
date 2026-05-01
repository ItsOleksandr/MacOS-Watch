#!/usr/bin/env bash
# Publishes MacControl and installs a LaunchAgent so it auto-starts at login.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_DIR="$(pwd)"
INSTALL_DIR="$HOME/Applications/MacControl"
PLIST_LABEL="com.maccontrol"
PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

# 1. Publish
./scripts/publish.sh

# 2. Copy to install dir
echo "▶︎ Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rsync -a --delete "$PROJECT_DIR/publish/" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/MacControl"

# 3. Render plist with absolute paths
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__BIN__|$INSTALL_DIR/MacControl|g" \
    -e "s|__DIR__|$INSTALL_DIR|g" \
    "$PROJECT_DIR/scripts/com.maccontrol.plist" > "$PLIST_DST"

# 4. (Re)load LaunchAgent
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load   "$PLIST_DST"

echo ""
echo "✓ Installed and started."
echo "  Binary:  $INSTALL_DIR/MacControl"
echo "  Plist:   $PLIST_DST"
echo "  Logs:    $INSTALL_DIR/maccontrol.log"
echo "  URL:     http://$(ipconfig getifaddr en0 2>/dev/null || echo localhost):5050"
