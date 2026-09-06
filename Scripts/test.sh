#!/bin/bash
set -euo pipefail
HEXA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HEXA_ROOT"
# XCTest ships with Xcode. Prefer it for this command only, leaving xcode-select unchanged.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$HEXA_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$HEXA_ROOT/.build/clang-cache"
HEXA_TEST_ARGS=(--cache-path "$HEXA_ROOT/.build/cache" --config-path "$HEXA_ROOT/.build/config" --security-path "$HEXA_ROOT/.build/security")
if [[ "${HEXA_DISABLE_PACKAGE_SANDBOX:-0}" == 1 ]]; then HEXA_TEST_ARGS+=(--disable-sandbox); fi
swift test "${HEXA_TEST_ARGS[@]}" "$@"
