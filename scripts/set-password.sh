#!/usr/bin/env bash
# Replaces the random control token with a password you choose.
#
# The server reads its secret from the `token` file next to the binary, so
# setting a password is just writing that file and restarting the service.
# Run with no argument to be prompted (the password is not echoed):
#
#   ./scripts/set-password.sh
#   ./scripts/set-password.sh my-couch-remote
set -euo pipefail

INSTALL_DIR="$HOME/Applications/MacControl"
LABEL="com.maccontrol"
PORT=5050
RESTART=1
PASSWORD=""

usage() {
    cat <<'EOF'
Usage: set-password.sh [password] [--dir <install-dir>] [--no-restart]

  password       The new control password. Prompted for if omitted.
                 Allowed characters: letters, digits and . _ ~ -
                 (URL-safe, so it survives the pairing link and the QR code).
                 Minimum length: 8.

  --dir DIR      Where MacControl is installed. Default: ~/Applications/MacControl
  --no-restart   Only write the file; do not reload the LaunchAgent.
                 Used by install.sh, which starts the service itself.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)        INSTALL_DIR="$2"; shift 2 ;;
        --dir=*)      INSTALL_DIR="${1#*=}"; shift ;;
        --no-restart) RESTART=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "✗ unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)            PASSWORD="$1"; shift ;;
    esac
done

# Ask twice when nothing was passed on the command line. `read -s` keeps the
# password out of the terminal, and out of the shell history it would land in
# had it been typed as an argument.
if [ -z "$PASSWORD" ]; then
    if [ ! -t 0 ]; then
        echo "✗ No password given and no terminal to ask on." >&2
        exit 2
    fi
    read -r -s -p "New MacControl password: " PASSWORD; echo ""
    read -r -s -p "Repeat it: " CONFIRM; echo ""
    if [ "$PASSWORD" != "$CONFIRM" ]; then
        echo "✗ The two entries differ — nothing was changed." >&2
        exit 1
    fi
fi

# The password travels as a URL query parameter (?token=…) and inside the QR
# code, so restricting it to URL-safe characters avoids a password that works
# in curl but silently breaks the pairing link.
if [ "${#PASSWORD}" -lt 8 ]; then
    echo "✗ Too short — use at least 8 characters." >&2
    exit 1
fi
if ! printf '%s' "$PASSWORD" | grep -qE '^[A-Za-z0-9._~-]+$'; then
    echo "✗ Use only letters, digits and . _ ~ -  (the password goes into a URL)." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
# umask before the write, not chmod after: it never leaves a readable window.
( umask 077; printf '%s' "$PASSWORD" > "$INSTALL_DIR/token" )
echo "✓ Password written to $INSTALL_DIR/token"

if [ "$RESTART" = 1 ]; then
    SERVICE="gui/$UID/$LABEL"
    if launchctl print "$SERVICE" >/dev/null 2>&1; then
        # The token is read once at startup, so the running server keeps using
        # the old one until it is restarted.
        launchctl kickstart -k "$SERVICE" >/dev/null
        echo "✓ Service restarted — the old token no longer works."
    else
        echo "  ! The LaunchAgent is not loaded; run ./scripts/install.sh to start it."
    fi

    # Only when run on its own — install.sh prints the same link at the end.
    IP="$(ipconfig getifaddr en0 2>/dev/null || echo localhost)"
    echo ""
    echo "  URL:  http://$IP:$PORT/?token=$PASSWORD"
    echo "        ^ open this on the phone once; every device paired with the old"
    echo "          token has to open it again."
fi
