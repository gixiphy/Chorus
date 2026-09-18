#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/ChorusCore"
cd "$PKG"
FILTER="${1:-LayoutEngine|LayoutTemplate|RestoreStore|SnapResolver|WindowLayout}"
echo "==> swift build --build-tests"
set +e
swift build --build-tests
BUILD_STATUS=$?
set -e
echo "==> build status: $BUILD_STATUS"
BUNDLE=".build/out/Products/Debug/ChorusCoreTests.xctest"
if [[ ! -d "$BUNDLE" ]]; then echo "error: test bundle missing" >&2; exit 1; fi
echo "==> resign test bundle"
find "$BUNDLE" -exec xattr -c {} \; 2>/dev/null || true
codesign --force --sign=- --timestamp=none "$BUNDLE"
echo "==> swift test --skip-build"
swift test --skip-build --filter "$FILTER"
