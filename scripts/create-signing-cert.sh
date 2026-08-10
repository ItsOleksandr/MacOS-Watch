#!/usr/bin/env bash
# Creates a STABLE self-signed code-signing certificate named "MacControl" in the
# login keychain, giving every build a consistent code identity.
#
# Why: MacControl injects input via CoreGraphics CGEvent, which needs Accessibility
# permission. macOS ties that grant (and the background-item / "Allow in the
# Background" approval) to the binary's code identity. Ad-hoc signing produces a
# NEW identity on every publish, so those grants reset each rebuild. A stable cert
# fixes that — you grant permissions once and they persist.
#
# Run this ONCE. Then use ./scripts/install.sh as usual.
set -euo pipefail

CERT_NAME="${MACCONTROL_SIGN_IDENTITY:-MacControl}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "✓ Code-signing identity '$CERT_NAME' already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Use the system LibreSSL (/usr/bin/openssl): it produces PKCS#12 output that
# macOS's `security import` accepts. Homebrew's OpenSSL 3.x defaults to a newer
# MAC algorithm that `security import` rejects ("MAC verification failed").
OPENSSL="/usr/bin/openssl"
[ -x "$OPENSSL" ] || OPENSSL="openssl"

echo "▶︎ Generating self-signed code-signing certificate '$CERT_NAME'… (using $OPENSSL)"

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# 1. Self-signed cert + private key with the codeSigning EKU.
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/openssl.cnf" >/dev/null 2>&1

# A non-empty passphrase is required: macOS `security import` fails MAC
# verification on empty-password PKCS#12 bundles. The bundle is temporary.
P12_PASS="maccontrol-temp"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/bundle.p12" -passout "pass:$P12_PASS" -name "$CERT_NAME" >/dev/null 2>&1

# 2. Import into the login keychain; allow /usr/bin/codesign to use the key.
security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

# 3. Trust it for code signing (user-level). macOS may prompt for your login
#    password here — that is expected; allow it.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null || \
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null || \
echo "  (note: could not auto-trust; if 'find-identity' below is empty, set it to 'Always Trust' in Keychain Access → My Certificates)"

echo ""
if security find-identity -p codesigning -v "$KEYCHAIN" | grep -q "\"$CERT_NAME\""; then
    echo "✓ Code-signing identity '$CERT_NAME' is ready."
    echo "  Next: ./scripts/install.sh"
    echo "  (On the first build, if macOS asks to use the key, click 'Always Allow'.)"
else
    echo "⚠️  '$CERT_NAME' not yet listed as a valid code-signing identity."
    echo "   Open Keychain Access → 'My Certificates', find '$CERT_NAME',"
    echo "   and set it to 'Always Trust' for Code Signing, then re-run install.sh."
fi
