#!/usr/bin/env bash
# Publishes MacControl and installs a LaunchAgent so it auto-starts at login.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_DIR="$(pwd)"
INSTALL_DIR="$HOME/Applications/MacControl"
PLIST_LABEL="com.maccontrol"
PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
DOMAIN="gui/$UID"
SERVICE="$DOMAIN/$PLIST_LABEL"
PORT=5050

# 0a. Optional own password instead of the random token generated on first run.
#     MACCONTROL_TOKEN is accepted too, but it is written to the token file
#     rather than exported: the LaunchAgent does not inherit this shell's
#     environment, so an exported variable alone would never reach the server.
CUSTOM_PASSWORD="${MACCONTROL_TOKEN:-}"
ASK_PASSWORD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --password|--token)     CUSTOM_PASSWORD="$2"; shift 2 ;;
        --password=*|--token=*) CUSTOM_PASSWORD="${1#*=}"; shift ;;
        --ask-password)         ASK_PASSWORD=1; shift ;;
        -h|--help)
            echo "Usage: install.sh [--password <own-password> | --ask-password]"
            echo "  no option        keep the existing token, or generate a random one"
            echo "  --password P     use P as the control password"
            echo "  --ask-password   prompt for it (not echoed, not in shell history)"
            exit 0 ;;
        *) echo "✗ unknown argument: $1" >&2; exit 2 ;;
    esac
done

# 0b. Set that password now, before the build: asking for it after a two-minute
#     publish would leave the prompt waiting on an unattended install. The file
#     survives step 2 — rsync excludes `token` from --delete.
if [ "$ASK_PASSWORD" = 1 ] || [ -n "$CUSTOM_PASSWORD" ]; then
    ./scripts/set-password.sh --no-restart --dir "$INSTALL_DIR" ${CUSTOM_PASSWORD:+"$CUSTOM_PASSWORD"}
    echo ""
fi

# 0. Warn if there is no stable signing identity — without it, macOS resets the
#    Accessibility grant and background-item approval on every publish.
SIGN_IDENTITY="${MACCONTROL_SIGN_IDENTITY:-MacControl}"
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
    echo "⚠️  No stable code-signing identity '$SIGN_IDENTITY' found."
    echo "   The build will be ad-hoc signed, so macOS will reset Accessibility and"
    echo "   the 'Allow in the Background' approval on each rebuild."
    echo "   Run ./scripts/create-signing-cert.sh once to fix this permanently."
    echo ""
fi

# 1. Publish
./scripts/publish.sh

# 2. Copy to install dir
echo "▶︎ Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# Keep runtime-generated files that live in the install dir but not in publish/:
# the logs and the `token` secret must survive a reinstall.
rsync -a --delete --exclude 'maccontrol*.log' --exclude 'token' "$PROJECT_DIR/publish/" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/MacControl"

# 3. Render plist with absolute paths
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__BIN__|$INSTALL_DIR/MacControl|g" \
    -e "s|__DIR__|$INSTALL_DIR|g" \
    "$PROJECT_DIR/scripts/com.maccontrol.plist" > "$PLIST_DST"

# 4. Reload the LaunchAgent cleanly so it re-registers with the new binary.
#    bootout any stale instance, then bootstrap + enable (survives logout/reboot)
#    + kickstart to start it right now.
echo "▶︎ (Re)loading LaunchAgent"
launchctl bootout "$SERVICE" 2>/dev/null || true
# Wait for the old instance to fully unload — bootstrapping too soon races the
# teardown and fails with "Bootstrap failed: 5: Input/output error".
for _ in $(seq 1 15); do
    launchctl print "$SERVICE" >/dev/null 2>&1 || break
    sleep 1
done
# Bootstrap, retrying briefly while launchd settles.
for attempt in 1 2 3; do
    launchctl bootstrap "$DOMAIN" "$PLIST_DST" 2>/dev/null && break
    if [ "$attempt" = 3 ]; then
        echo "✗ launchctl bootstrap failed; error detail:"
        launchctl bootstrap "$DOMAIN" "$PLIST_DST" || true
        exit 1
    fi
    sleep 2
done
launchctl enable "$SERVICE"
launchctl kickstart -k "$SERVICE"

# 4b. Allow the binary through the macOS application firewall, if it is on.
#     Without this the LAN handshake is dropped and the phone just times out.
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
if [ -x "$FW" ] && "$FW" --getglobalstate 2>/dev/null | grep -q enabled; then
    if ! "$FW" --getappblocked "$INSTALL_DIR/MacControl" 2>/dev/null | grep -qi "permitted\|allowed"; then
        echo "▶︎ Firewall is on — allowing MacControl (needs sudo)"
        sudo "$FW" --add "$INSTALL_DIR/MacControl" >/dev/null 2>&1 || \
            echo "  ! could not add automatically; run: sudo $FW --add \"$INSTALL_DIR/MacControl\""
        sudo "$FW" --unblockapp "$INSTALL_DIR/MacControl" >/dev/null 2>&1 || true
    fi
fi

# 5. Verify it is actually listening (self-contained single-file needs a few
#    seconds to extract on the very first run).
echo -n "▶︎ Waiting for the service to listen on :$PORT "
for _ in $(seq 1 20); do
    # /api/* now requires the token, so read it (written on first run) and send it.
    HC_TOKEN="$(cat "$INSTALL_DIR/token" 2>/dev/null || true)"
    if curl -fsS -m 1 -H "X-MacControl-Token: $HC_TOKEN" "http://localhost:$PORT/api/volume" >/dev/null 2>&1; then
        echo ""
        echo "✓ Installed and running."
        echo "  Binary:  $INSTALL_DIR/MacControl"
        echo "  Plist:   $PLIST_DST"
        echo "  Logs:    $INSTALL_DIR/maccontrol.log  (errors: maccontrol.err.log)"
        # The control token: your own password if you set one, otherwise the
        # random one generated on first run. Both live next to the binary.
        TOKEN="$(cat "$INSTALL_DIR/token" 2>/dev/null || true)"
        IP="$(ipconfig getifaddr en0 2>/dev/null || echo localhost)"
        if [ -n "$TOKEN" ]; then
            echo "  URL:     http://$IP:$PORT/?token=$TOKEN"
            echo "           ^ open this on your phone. The token is remembered after the first visit."
        else
            echo "  URL:     http://$IP:$PORT"
        fi
        echo ""
        # Ask the running server whether macOS actually lets it post input events,
        # rather than telling everyone to check a setting most people already have.
        TRUSTED=$(curl -s -m 2 -H "X-MacControl-Token: $HC_TOKEN" \
                  "http://localhost:$PORT/api/accessibility" 2>/dev/null)
        if [ "${TRUSTED#*\"trusted\":true}" != "$TRUSTED" ]; then
            echo "  ✓ Accessibility granted — mouse and keyboard work."
        else
            echo "  ⚠️  Accessibility is NOT granted yet."
            echo "     Volume works; the trackpad and keys will do nothing until you fix this."
            echo ""
            echo "     Opening both windows you need now:"
            echo "       1. drag  MacControl  from the Finder window into the list"
            echo "       2. switch it on"
            open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' 2>/dev/null || true
            sleep 1
            open -R "$INSTALL_DIR/MacControl" 2>/dev/null || true
        fi
        exit 0
    fi
    echo -n "."
    sleep 1
done

echo ""
echo "✗ Service did not start in time. Recent errors:"
tail -20 "$INSTALL_DIR/maccontrol.err.log" 2>/dev/null || echo "  (no error log)"
echo "  Status: launchctl print $SERVICE"
exit 1
