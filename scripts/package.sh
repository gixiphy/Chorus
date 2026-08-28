#!/bin/zsh
# 打包腳本：自動遞增 build 號 → xcodegen → Release archive → dist zip → 安裝到 /Applications
# 用法：
#   scripts/package.sh                 # build 號 +1，打包並安裝
#   scripts/package.sh --version 1.2.0 # 同時改語意版本
#   scripts/package.sh --no-install    # 只打包不安裝
set -euo pipefail
cd "$(dirname "$0")/.."

NEW_VERSION=""
INSTALL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) NEW_VERSION="$2"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    *) echo "未知參數：$1" >&2; exit 1 ;;
  esac
done

# 讀取並遞增 project.yml 裡的版本欄位
VERSION=$(grep 'CFBundleShortVersionString:' project.yml | sed 's/.*"\(.*\)".*/\1/')
BUILD=$(grep 'CFBundleVersion:' project.yml | sed 's/.*"\(.*\)".*/\1/')
NEXT_BUILD=$((BUILD + 1))
if [[ -n "$NEW_VERSION" ]]; then VERSION="$NEW_VERSION"; fi

sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" project.yml
sed -i '' "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$NEXT_BUILD\"/" project.yml
echo "▸ 版本 $VERSION (build $NEXT_BUILD)"

xcodegen generate > /dev/null
rm -rf dist/Chorus.xcarchive
xcodebuild -project Chorus.xcodeproj -scheme Chorus -configuration Release \
  archive -archivePath dist/Chorus.xcarchive 2>&1 | grep -E "error:|ARCHIVE" || true

[[ -d dist/Chorus.xcarchive/Products/Applications/Chorus.app ]] || { echo "archive 失敗" >&2; exit 1; }

rm -rf dist/Chorus.app dist/Chorus-*.zip
ditto dist/Chorus.xcarchive/Products/Applications/Chorus.app dist/Chorus.app
# 建置產物的權限可能不是 world-readable；內嵌的 HAL driver 由 _coreaudiod 讀取，
# 少了 go+r 安裝後就載不進去。在打包前先正規化。
chmod -R go+rX dist/Chorus.app
ZIP="dist/Chorus-$VERSION-b$NEXT_BUILD.zip"
ditto -c -k --keepParent dist/Chorus.app "$ZIP"
echo "▸ 已打包 $ZIP"

if [[ $INSTALL -eq 1 ]]; then
  osascript -e 'quit app "Chorus"' 2>/dev/null || true
  sleep 2
  pkill -x Chorus 2>/dev/null || true
  rm -rf /Applications/Chorus.app
  ditto dist/Chorus.app /Applications/Chorus.app
  open /Applications/Chorus.app
  echo "▸ 已安裝並啟動 /Applications/Chorus.app"
fi
