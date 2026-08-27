#!/bin/zsh
# Mac mini（無 Xcode，只有 CLT）上的驗證替代（Xcode 在 MBP 那台）：
#   1. ChorusCore swift test（需手動指到 CLT 的 Testing.framework）
#   2. App 目標 swiftc -typecheck（無法 link/打包，型別檢查可抓 99% 編譯錯）
# 用法：check.sh [core|app|all]
set -euo pipefail
REPO=/Users/wuxianyou/Documents/Code/Chorus
CLT=/Library/Developer/CommandLineTools
FWK=$CLT/Library/Developer/Frameworks
MODE=${1:-all}

if [[ $MODE == core || $MODE == all ]]; then
  cd $REPO/Packages/ChorusCore
  export DYLD_FALLBACK_LIBRARY_PATH=$CLT/Library/Developer/usr/lib
  swift test \
    -Xswiftc -F$FWK \
    -Xlinker -F$FWK \
    -Xlinker -rpath -Xlinker $FWK \
    -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib \
    2>&1 | tail -3
fi

if [[ $MODE == app || $MODE == all ]]; then
  cd $REPO/Packages/ChorusCore
  swift build 2>&1 | tail -1
  MODDIR=$REPO/Packages/ChorusCore/.build/arm64-apple-macosx/debug/Modules
  cd $REPO
  # CLT 沒有 PreviewsMacros（Xcode 專屬）：typecheck 前把 #Preview 區塊剝掉
  STAGE=$(mktemp -d)
  trap "rm -rf $STAGE" EXIT
  for f in Chorus/**/*.swift; do
    mkdir -p "$STAGE/$(dirname $f)"
    perl -0pe 's/#Preview\s*(\([^)]*\))?\s*\{([^{}]|\{([^{}]|\{[^{}]*\})*\})*\}//gs' "$f" > "$STAGE/$f"
  done
  swiftc -typecheck \
    -target arm64-apple-macos26.0 \
    -swift-version 6 \
    -sdk "$(xcrun --show-sdk-path)" \
    -I "$MODDIR" \
    -import-objc-header Chorus/Support/Chorus-Bridging-Header.h \
    $STAGE/Chorus/**/*.swift \
    && echo "app typecheck ✅"
fi
