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
if security find-identity -p codesigning -v | grep -q "$SIGN_IDENTITY"; then
    codesign --force --sign "$SIGN_IDENTITY" --identifier com.maccontrol "$OUT/MacControl"
    echo "  signed with: $SIGN_IDENTITY"
else
    codesign --force --sign - --identifier com.maccontrol "$OUT/MacControl"
    echo "  signed ad-hoc (Accessibility permission will need re-granting on each publish)"
    echo "  see scripts/publish.sh — create a self-signed cert named '$SIGN_IDENTITY' to fix"
fi
xattr -dr com.apple.quarantine "$OUT/MacControl" 2>/dev/null || true

echo "✓ Published: $OUT/MacControl"
