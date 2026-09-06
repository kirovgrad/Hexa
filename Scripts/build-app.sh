#!/bin/bash
set -euo pipefail

HEXA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HEXA_ROOT"
HEXA_CONFIGURATION=release
HEXA_UNIVERSAL=0
for argument in "$@"; do
    case "$argument" in
        --debug) HEXA_CONFIGURATION=debug ;;
        --universal) HEXA_UNIVERSAL=1 ;;
        --help) echo 'Usage: ./Scripts/build-app.sh [--debug] [--universal]'; exit 0 ;;
        *) echo "Unknown option: $argument" >&2; exit 1 ;;
    esac
done

export CLANG_MODULE_CACHE_PATH="$HEXA_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$HEXA_ROOT/.build/clang-cache"
HEXA_SWIFT_ARGS=(--configuration "$HEXA_CONFIGURATION" --cache-path "$HEXA_ROOT/.build/cache" --config-path "$HEXA_ROOT/.build/config" --security-path "$HEXA_ROOT/.build/security")
if [[ "${HEXA_DISABLE_PACKAGE_SANDBOX:-0}" == 1 ]]; then HEXA_SWIFT_ARGS+=(--disable-sandbox); fi
if [[ "$HEXA_UNIVERSAL" == 1 ]]; then HEXA_SWIFT_ARGS+=(--arch arm64 --arch x86_64); fi

swift build "${HEXA_SWIFT_ARGS[@]}" --product Hexa
HEXA_BIN_DIR="$(swift build "${HEXA_SWIFT_ARGS[@]}" --show-bin-path)"
HEXA_APP="$HEXA_ROOT/build/Hexa.app"
mkdir -p "$HEXA_APP/Contents/MacOS" "$HEXA_APP/Contents/Resources"
cp "$HEXA_BIN_DIR/Hexa" "$HEXA_APP/Contents/MacOS/.Hexa-new"
mv -f "$HEXA_APP/Contents/MacOS/.Hexa-new" "$HEXA_APP/Contents/MacOS/Hexa"
cp "$HEXA_ROOT/Scripts/Info.plist" "$HEXA_APP/Contents/Info.plist"
cp "$HEXA_ROOT/Sources/Hexa/Resources/Welcome.bin" "$HEXA_APP/Contents/Resources/Welcome.bin"
cp "$HEXA_ROOT/docs/UserGuide.html" "$HEXA_APP/Contents/Resources/UserGuide.html"
swift "$HEXA_ROOT/Scripts/make-icon.swift" "$HEXA_ROOT/build/Hexa.iconset" "$HEXA_APP/Contents/Resources/Hexa.icns"
printf 'APPL????' > "$HEXA_APP/Contents/PkgInfo"

# Ad-hoc signing is sufficient for a local build. Set HEXA_SIGN_IDENTITY to a
# Developer ID Application identity for distribution, then notarize separately.
if [[ -n "${HEXA_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$HEXA_SIGN_IDENTITY" "$HEXA_APP"
else
    codesign --force --sign - "$HEXA_APP"
fi
codesign --verify --strict "$HEXA_APP"
echo "Built: $HEXA_APP"
echo 'Launch with: open build/Hexa.app'
