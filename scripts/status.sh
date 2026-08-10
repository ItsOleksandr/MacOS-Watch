#!/usr/bin/env bash
# Diagnoses why MacControl is not reachable from the phone.
set -uo pipefail

LABEL="com.maccontrol"
SERVICE="gui/$UID/$LABEL"
INSTALL_DIR="$HOME/Applications/MacControl"
PORT=5050
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*"; }
warn() { echo "  ! $*"; }

echo "▶︎ LaunchAgent"
if launchctl print "$SERVICE" >/dev/null 2>&1; then
    PID=$(launchctl print "$SERVICE" | awk '/^\tpid = /{print $3}')
    STATE=$(launchctl print "$SERVICE" | awk '/^\tstate = /{print $3}')
    ok "loaded (state=$STATE pid=${PID:-none})"
else
    bad "not loaded — run ./scripts/install.sh"
fi

echo "▶︎ Old Login Item / terminal launch"
# Match only processes whose executable really is .../MacControl. A plain
# "contains MacControl" test also matches any shell command that mentions the
# name — including the greps in this script — and reports a stray copy that
# does not exist.
STRAY=$(pgrep -fl MacControl 2>/dev/null | awk -v dir="$INSTALL_DIR/MacControl" \
        '$2 ~ /\/MacControl$/ && $2 != dir {print}')
if [ -n "$STRAY" ]; then
    warn "another MacControl process is running outside $INSTALL_DIR:"
    echo "$STRAY" | sed 's/^/      /'
    warn "remove it from System Settings → General → Login Items"
else
    ok "no stray copies"
fi

echo "▶︎ Listening socket"
LISTEN=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | tail -n +2)
if [ -n "$LISTEN" ]; then
    echo "$LISTEN" | sed 's/^/      /'
    if echo "$LISTEN" | grep -qE '\*:'"$PORT"; then
        ok "bound to all interfaces (*:$PORT) — reachable from the LAN"
    else
        bad "bound to localhost only — the phone cannot connect."
        bad "set ASPNETCORE_URLS=http://0.0.0.0:$PORT (the LaunchAgent plist does this)"
    fi
else
    bad "nothing is listening on :$PORT"
fi

echo "▶︎ Local response"
# /api/* requires the control token, so a tokenless probe would report a false
# "no answer" (it gets a legitimate 401). Send the token and check for 200.
TOKEN="$(cat "$INSTALL_DIR/token" 2>/dev/null || true)"
CODE=$(curl -s -m 2 -o /dev/null -w '%{http_code}' \
       -H "X-MacControl-Token: $TOKEN" "http://localhost:$PORT/api/volume" 2>/dev/null)
case "$CODE" in
    200) ok "http://localhost:$PORT answers (token accepted)" ;;
    401) bad "token rejected — $INSTALL_DIR/token does not match the running server" ;;
    000) bad "no answer on localhost:$PORT" ;;
    *)   warn "unexpected HTTP $CODE from localhost:$PORT" ;;
esac

echo "▶︎ Firewall"
if [ -x "$FW" ]; then
    STATE=$("$FW" --getglobalstate 2>/dev/null)
    echo "      $STATE"
    if echo "$STATE" | grep -q enabled; then
        if "$FW" --getappblocked "$INSTALL_DIR/MacControl" 2>/dev/null | grep -qi "permitted\|allowed"; then
            ok "MacControl is allowed through the firewall"
        else
            warn "MacControl may be blocked. Allow it with:"
            echo "        sudo $FW --add \"$INSTALL_DIR/MacControl\""
            echo "        sudo $FW --unblockapp \"$INSTALL_DIR/MacControl\""
        fi
    else
        ok "firewall is off — nothing to allow"
    fi
fi

echo "▶︎ Devices that have actually reached this server"
# The log outlives both restarts and network changes, so it accumulates addresses
# from networks we are no longer on. Two filters keep this honest:
#   1. drop this Mac's own addresses — reaching the server through its own LAN IP
#      is logged as a client and would falsely prove the phone got through;
#   2. drop anything outside the subnets we are currently attached to — e.g. a
#      192.168.0.x entry left over from the home Wi-Fi while we are on a hotspot.
# The /24 prefix match covers home networks and hotspots; this is a diagnostic
# hint, not an access decision, so the approximation is fine.
SELF_IPS=$(ifconfig 2>/dev/null | awk '/inet6? /{print $2}' | sed 's/%.*//' | sort -u)
LOCAL_PREFIXES=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' \
                 | grep -v '^127\.' | awk -F. '{print "^"$1"\\."$2"\\."$3"\\."}')
# Each line is "<address> via <host>", so filtering works on the first field while
# the host is kept for display — it shows which name the device actually resolved.
CLIENTS=$(grep "New client connected" "$INSTALL_DIR/maccontrol.log" 2>/dev/null \
          | sed -e 's/.*connected: //' -e 's/^::ffff://' | sort -u \
          | while read -r line; do
                addr=${line%% *}
                echo "$SELF_IPS" | grep -qxF "$addr" && continue
                if [ -n "$LOCAL_PREFIXES" ]; then
                    echo "$addr" | grep -qE "$(echo "$LOCAL_PREFIXES" | paste -sd'|' -)" || continue
                fi
                echo "$line"
            done)
if [ -n "$CLIENTS" ]; then
    echo "$CLIENTS" | sed 's/^/      /'
    ok "the network path works for the addresses above"
else
    warn "no device other than this Mac has ever connected."
    echo "      If the phone shows 'cannot connect', its packets are not arriving:"
    echo "        · phone on mobile data or a different/guest Wi-Fi → join the same network"
    echo "        · router has AP/client isolation on → turn it off in the router settings"
    echo "        · VPN or iCloud Private Relay active on the phone → disable it for the LAN"
fi

echo "▶︎ Addresses to open on the phone (same Wi-Fi!)"
# Include ?token=… : opening the bare address only shows the "missing token" notice.
# The phone stores the token on the first visit, so this link is needed just once.
Q=""
[ -n "${TOKEN:-}" ] && Q="/?token=$TOKEN"
# The IP link goes first because it is the one that works on every phone. The
# .local name is listed after it, since Android does not resolve .local at all.
for iface in en0 en1 en2; do
    IP=$(ipconfig getifaddr "$iface" 2>/dev/null) || true
    [ -n "${IP:-}" ] && echo "      http://$IP:$PORT$Q"
done
echo "        ↑ works on any phone — use this one"
HOSTN=$(scutil --get LocalHostName 2>/dev/null) || true
if [ -n "${HOSTN:-}" ]; then
    # Bonjour names are case-insensitive; lowercase reads better in a browser.
    LOWER=$(echo "$HOSTN" | tr '[:upper:]' '[:lower:]')
    echo "      http://$LOWER.local:$PORT$Q"
    echo "        ↑ iPhone/iPad only — Android cannot resolve .local"
fi

echo "▶︎ Accessibility (mouse/keyboard control)"
# Ask the running server, which asks macOS — no guessing from log messages.
TRUSTED=$(curl -s -m 2 -H "X-MacControl-Token: $TOKEN" \
          "http://localhost:$PORT/api/accessibility" 2>/dev/null)
case "$TRUSTED" in
    *'"trusted":true'*)
        ok "granted — mouse and keyboard work" ;;
    *'"trusted":false'*)
        bad "NOT granted — volume works, mouse and keyboard do nothing."
        echo "      Fix it by re-running ./scripts/install.sh, which opens both windows,"
        echo "      or by hand: drag this binary into the Accessibility list and switch it on"
        echo "        $INSTALL_DIR/MacControl"
        echo "        open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'" ;;
    *)
        warn "could not query the server for Accessibility state" ;;
esac

echo "▶︎ Recent errors"
tail -15 "$INSTALL_DIR/maccontrol.err.log" 2>/dev/null | sed 's/^/      /' || echo "      (no error log)"
