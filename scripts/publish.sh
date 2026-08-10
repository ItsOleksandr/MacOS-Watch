#!/usr/bin/env bash
# Publish MacControl as a self-contained osx-arm64 single-file binary.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(pwd)/publish"
echo "▶︎ Publishing to $OUT"
rm -rf "$OUT"
dotnet publish MacControl.csproj -c Release -r osx-arm64 --self-contained true \
    -p:PublishSingleFile=true \
    -o "$OUT" \
    -nologo

SIGN_IDENTITY="${MACCONTROL_SIGN_IDENTITY:-MacControl}"
# Resolve to the identity's unique SHA-1 hash: the common name alone is ambiguous
# if more than one certificate shares it (codesign errors out on "ambiguous").
SIGN_HASH="$(security find-identity -p codesigning -v | awk -v n="\"$SIGN_IDENTITY\"" 'index($0, n) {print $2; exit}')"
if [ -n "$SIGN_HASH" ]; then
    codesign --force --sign "$SIGN_HASH" --identifier com.maccontrol "$OUT/MacControl"
    echo "  signed with: $SIGN_IDENTITY ($SIGN_HASH)"
else
    codesign --force --sign - --identifier com.maccontrol "$OUT/MacControl"
    echo "  signed ad-hoc (Accessibility permission will need re-granting on each publish)"
    echo "  run ./scripts/create-signing-cert.sh once to create a stable '$SIGN_IDENTITY' identity and fix this"
fi
xattr -dr com.apple.quarantine "$OUT/MacControl" 2>/dev/null || true

echo "✓ Published: $OUT/MacControl"
