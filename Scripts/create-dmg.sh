#!/bin/bash
set -euo pipefail

HEXA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEXA_BUILD=1
HEXA_UNIVERSAL=0
HEXA_OUTPUT=""

usage() {
    cat <<'EOF'
Usage: ./Scripts/create-dmg.sh [--skip-build] [--universal] [--output PATH]

Builds Hexa.app and creates a compressed installer disk image containing Hexa
and an Applications shortcut. The default output is dist/Hexa-VERSION.dmg.

Environment variables:
  HEXA_SIGN_IDENTITY   Developer ID Application identity used to sign the app
                      and disk image. Omit for an ad-hoc local test build.
  HEXA_NOTARY_PROFILE  notarytool Keychain profile. When set, submits the DMG,
                      waits for approval, and staples the ticket.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) HEXA_BUILD=0 ;;
        --universal) HEXA_UNIVERSAL=1 ;;
        --output)
            [[ $# -ge 2 ]] || { echo "--output requires a path" >&2; exit 2; }
            HEXA_OUTPUT="$2"; shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

cd "$HEXA_ROOT"
HEXA_BUILD_ARGS=()
if [[ "$HEXA_UNIVERSAL" == 1 ]]; then HEXA_BUILD_ARGS+=(--universal); fi
if [[ "$HEXA_BUILD" == 1 ]]; then "$HEXA_ROOT/Scripts/build-app.sh" "${HEXA_BUILD_ARGS[@]}"; fi

HEXA_APP="$HEXA_ROOT/build/Hexa.app"
[[ -d "$HEXA_APP" ]] || { echo "Missing $HEXA_APP. Build the app first or omit --skip-build." >&2; exit 1; }
codesign --verify --strict "$HEXA_APP"

HEXA_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HEXA_APP/Contents/Info.plist")"
if [[ -z "$HEXA_OUTPUT" ]]; then HEXA_OUTPUT="$HEXA_ROOT/dist/Hexa-$HEXA_VERSION.dmg"; fi
if [[ "$HEXA_OUTPUT" != /* ]]; then HEXA_OUTPUT="$HEXA_ROOT/$HEXA_OUTPUT"; fi
[[ ! -e "$HEXA_OUTPUT" ]] || { echo "Refusing to overwrite existing file: $HEXA_OUTPUT" >&2; exit 1; }
mkdir -p "$(dirname "$HEXA_OUTPUT")"

HEXA_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hexa-dmg.XXXXXX")"
cleanup() { rm -rf "$HEXA_STAGE"; }
trap cleanup EXIT

# ditto preserves the complete bundle. The symlink gives users the familiar
# drag-to-Applications installation flow without scripting Finder.
ditto "$HEXA_APP" "$HEXA_STAGE/Hexa.app"
ln -s /Applications "$HEXA_STAGE/Applications"
hdiutil create -quiet -srcfolder "$HEXA_STAGE" -volname "Hexa $HEXA_VERSION" -fs HFS+ -format UDZO "$HEXA_OUTPUT"

if [[ -n "${HEXA_SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$HEXA_SIGN_IDENTITY" "$HEXA_OUTPUT"
    codesign --verify --verbose=2 "$HEXA_OUTPUT"
fi

hdiutil verify "$HEXA_OUTPUT" >/dev/null

if [[ -n "${HEXA_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$HEXA_OUTPUT" --keychain-profile "$HEXA_NOTARY_PROFILE" --wait
    xcrun stapler staple "$HEXA_OUTPUT"
    xcrun stapler validate "$HEXA_OUTPUT"
fi

HEXA_SHA256="$(shasum -a 256 "$HEXA_OUTPUT" | awk '{print $1}')"
printf 'Created: %s\nSHA-256: %s\n' "$HEXA_OUTPUT" "$HEXA_SHA256"
