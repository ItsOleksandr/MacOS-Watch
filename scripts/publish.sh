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

echo "✓ Published: $OUT/MacControl"
