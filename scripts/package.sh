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

# P5：driver 源碼變了但 CFBundleVersion 沒 +1 → 擋下打包。
# 忘了 +1 的話設定頁不會跳「更新驅動」，改動就靜靜地沒生效。
DRIVER_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' AudioDriver/Info.plist)
DRIVER_HASH=$(find AudioDriver/Source -type f | sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
DRIVER_STAMP_FILE=AudioDriver/.source-version
if [[ -f "$DRIVER_STAMP_FILE" ]]; then
  read -r STAMP_VER STAMP_HASH < "$DRIVER_STAMP_FILE"
  if [[ "$DRIVER_HASH" != "$STAMP_HASH" && "$DRIVER_VER" == "$STAMP_VER" ]]; then
    echo "✗ driver 源碼變了，但 AudioDriver/Info.plist 的 CFBundleVersion 還是 $DRIVER_VER" >&2
    echo "  請 +1 後再打包（否則設定頁不會出現「更新驅動」）" >&2
    exit 1
  fi
fi
echo "$DRIVER_VER $DRIVER_HASH" > "$DRIVER_STAMP_FILE"

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

rm -rf dist/Chorus.app
rm -f dist/Chorus-*.zip(N)   # (N) = 沒有符合的檔案就當空的（zsh 預設會報錯中止）

# 簽章與打包全部在**同步資料夾之外**進行。這個 repo 在 iCloud Drive 裡，
# file provider 會在兩秒內把 com.apple.FinderInfo 掛回 bundle 目錄上，
# codesign 就判「resource fork, Finder information, or similar detritus
# not allowed」——清掉也沒用，它會再長回來。所以搬到 /tmp 底下處理，
# 完成後才把成品複製回 dist/。
WORK=$(mktemp -d /tmp/chorus-pkg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Chorus.app"
ditto dist/Chorus.xcarchive/Products/Applications/Chorus.app "$APP"
# 建置產物的權限可能不是 world-readable；內嵌的 HAL driver 由 _coreaudiod 讀取，
# 少了 go+r 安裝後就載不進去。在打包前先正規化。
chmod -R go+rX "$APP"
xattr -cr "$APP"

# Developer ID 重簽：archive 出來的是開發簽章（Apple Development），別台 Mac 打不開。
# 巢狀先簽、app 本體最後——順序反了外層簽章會被內層改動作廢。
DEVID="Developer ID Application"
if security find-identity -v -p codesigning | grep -q "$DEVID"; then
  codesign --force --options runtime --timestamp --sign "$DEVID" \
    "$APP/Contents/PlugIns/ChorusAudioDevice.driver"
  codesign --force --options runtime --timestamp --sign "$DEVID" \
    "$APP/Contents/SharedSupport/chorus"
  codesign --force --options runtime --timestamp \
    --entitlements Chorus/Support/Chorus.entitlements --sign "$DEVID" "$APP"
  echo "▸ 已用 Developer ID 重簽"
else
  echo "⚠︎ 找不到 Developer ID Application 憑證——這包是開發簽章，只能自己機器跑" >&2
fi

# 硬性驗證：巢狀 code（HAL driver、chorus CLI）都要簽得過才算打包成功。
if ! codesign --verify --deep --strict "$APP"; then
  echo "簽章驗證失敗，不產出 zip" >&2
  exit 1
fi
echo "▸ 簽章驗證通過（含巢狀 driver 與 CLI）"

ZIP="dist/Chorus-$VERSION-b$NEXT_BUILD.zip"
WORK_ZIP="$WORK/Chorus-$VERSION-b$NEXT_BUILD.zip"
ditto -c -k --keepParent "$APP" "$WORK_ZIP"
echo "▸ 已打包 $ZIP"

# 公證：有 notarytool 憑證才跑（建立方式見 README）。公證過的 ticket 要 staple
# 進 app，再重新打包一次 zip——不然下載端拿到的還是沒有 ticket 的版本。
NOTARY_PROFILE="${CHORUS_NOTARY_PROFILE:-chorus}"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
  echo "▸ 送公證（profile: $NOTARY_PROFILE）…"
  xcrun notarytool submit "$WORK_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$WORK_ZIP"
  ditto -c -k --keepParent "$APP" "$WORK_ZIP"
  spctl -a -vvv -t exec "$APP" || true
  echo "▸ 已公證並重新打包"
else
  echo "⚠︎ 沒有 notarytool 憑證（profile: $NOTARY_PROFILE）——這包未公證，別台 Mac 會被 Gatekeeper 擋" >&2
fi

# 成品搬回 dist/（同步資料夾會在 bundle 上掛 FinderInfo，但簽章已經完成，
# 只有「簽的當下」會被擋，所以這一步是安全的）
cp "$WORK_ZIP" "$ZIP"
ditto "$APP" dist/Chorus.app

if [[ $INSTALL -eq 1 ]]; then
  osascript -e 'quit app "Chorus"' 2>/dev/null || true
  sleep 2
  pkill -x Chorus 2>/dev/null || true
  rm -rf /Applications/Chorus.app
  ditto "$APP" /Applications/Chorus.app
  open /Applications/Chorus.app
  echo "▸ 已安裝並啟動 /Applications/Chorus.app"
fi
