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
# -name '.*' 排除 .DS_Store 那類：Finder 逛過一次目錄就會多出一個檔，
# 雜湊跟著變、擋板就誤判「driver 源碼變了」（2026-09-02 真的擋過一次）。
# LC_ALL=C：排序受 locale 影響，同一份源碼在不同 shell 會算出不同雜湊，
# 擋板照樣誤判（2026-09-04 又擋過一次）。釘死 C collation 才穩定。
DRIVER_HASH=$(find AudioDriver/Source -type f -not -name '.*' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
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

# 讀取並遞增版本。PKG-11 / W1-2：單一來源——只取 Chorus info.properties，
# 絕不 grep 全檔（helper INFOPLIST_KEY / CURRENT_PROJECT_VERSION 會污染算術）。
# shellcheck source=lib/chorus-version.sh
source "$(dirname "$0")/lib/chorus-version.sh"
chorus_read_app_version project.yml || { echo "✗ 無法從 project.yml 的 Chorus info 讀取版本" >&2; exit 1; }
VERSION="$CHORUS_APP_VERSION"
BUILD="$CHORUS_APP_BUILD"
NEXT_BUILD=$((BUILD + 1))
if [[ -n "$NEW_VERSION" ]]; then VERSION="$NEW_VERSION"; fi

# 同步 App info.properties 與 helper 的 CURRENT_PROJECT_VERSION / MARKETING_VERSION。
# 只改引號內數字／語意版本；INFOPLIST_KEY_*=$(CURRENT_PROJECT_VERSION) 維持單一來源參照。
sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" project.yml
sed -i '' "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$NEXT_BUILD\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$NEXT_BUILD\"/" project.yml
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
echo "▸ 版本 $VERSION (build $NEXT_BUILD)"

xcodegen generate > /dev/null
BUILD_CACHE="$HOME/Library/Caches/DevBuild"
ARCHIVE="$BUILD_CACHE/Chorus_Archive/Chorus.xcarchive"
mkdir -p "$BUILD_CACHE/Chorus_Archive" "$BUILD_CACHE/Chorus_DerivedData"
rm -rf "$ARCHIVE"
xcodebuild -project Chorus.xcodeproj -scheme Chorus -configuration Release \
  -derivedDataPath "$BUILD_CACHE/Chorus_DerivedData" \
  archive -archivePath "$ARCHIVE" 2>&1 | xcsift -f toon -w -E

[[ -d "$ARCHIVE/Products/Applications/Chorus.app" ]] || { echo "archive 失敗" >&2; exit 1; }

# 保留 dSYM：archive 每次都會被砍掉、dist/ 又不進版控，之前發出去的版本一份符號都沒留，
# 使用者送來的 crash 報告完全對不回原始碼。zip 檔名帶版本與 build，發 GitHub Release 時一起附上。
mkdir -p dist/dsyms
DSYM_ZIP="dist/dsyms/Chorus-$VERSION-b$NEXT_BUILD.dSYMs.zip"
if [[ -d "$ARCHIVE/dSYMs" ]]; then
  rm -f "$DSYM_ZIP"
  ditto -c -k --keepParent "$ARCHIVE/dSYMs" "$DSYM_ZIP"
  echo "▸ 已保存 dSYM：$DSYM_ZIP（發 Release 時請一起附上）"
else
  echo "⚠︎ archive 裡沒有 dSYMs 目錄，這版無法事後符號化" >&2
fi

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
ditto "$ARCHIVE/Products/Applications/Chorus.app" "$APP"
# 建置產物的權限可能不是 world-readable；內嵌的 HAL driver 由 _coreaudiod 讀取，
# 少了 go+r 安裝後就載不進去。在打包前先正規化。
chmod -R go+rX "$APP"
xattr -cr "$APP"

# Developer ID 重簽：archive 出來的是開發簽章（Apple Development），別台 Mac 打不開。
# 巢狀先簽、app 本體最後——順序反了外層簽章會被內層改動作廢。
#
# 憑證用 40 字元 SHA-1 指紋指定，不用名稱。Keychain 裡常同時躺著過期的舊憑證和剛
# 續期的新憑證，名稱一模一樣，codesign 拿名稱做子字串比對會報 ambiguous 直接中止。
# 要指定特定一張：CHORUS_SIGN_IDENTITY=<40 字元指紋> scripts/package.sh
DEVID="${CHORUS_SIGN_IDENTITY:-}"
if [[ -z "$DEVID" ]]; then
  CERT_LINES=$(security find-identity -v -p codesigning | grep '"Developer ID Application' || true)
  CERT_COUNT=$(printf '%s\n' "$CERT_LINES" | grep -c . || true)
  if [[ "$CERT_COUNT" -eq 1 ]]; then
    DEVID=$(printf '%s\n' "$CERT_LINES" | awk '{print $2}')
  elif [[ "$CERT_COUNT" -gt 1 ]]; then
    echo "✗ Keychain 裡有 $CERT_COUNT 張 Developer ID Application 憑證，無法判斷該用哪張：" >&2
    printf '%s\n' "$CERT_LINES" >&2
    echo "  請指定：CHORUS_SIGN_IDENTITY=<40 字元指紋> scripts/package.sh" >&2
    exit 1
  fi
fi

HELPER_BIN="$APP/Contents/MacOS/ChorusPowerHelper"
HELPER_PLIST="$APP/Contents/Library/LaunchDaemons/com.hermes.Chorus.PowerHelper.plist"
[[ -f "$HELPER_BIN" ]] || { echo "✗ 缺少 helper：$HELPER_BIN" >&2; exit 1; }
[[ -f "$HELPER_PLIST" ]] || { echo "✗ 缺少 LaunchDaemon plist：$HELPER_PLIST" >&2; exit 1; }
plutil -lint "$HELPER_PLIST" >/dev/null || { echo "✗ helper plist 無法 lint" >&2; exit 1; }

if [[ -n "$DEVID" ]]; then
  # 巢狀先簽、app 本體最後。Helper 必須在 App 之前（C05 / PKG-3）。
  codesign --force --options runtime --timestamp \
    --entitlements PowerHelper/ChorusPowerHelper.entitlements --sign "$DEVID" \
    "$HELPER_BIN"
  codesign --force --options runtime --timestamp --sign "$DEVID" \
    "$APP/Contents/PlugIns/ChorusAudioDevice.driver"
  codesign --force --options runtime --timestamp --sign "$DEVID" \
    "$APP/Contents/SharedSupport/chorus"
  codesign --force --options runtime --timestamp \
    --entitlements Chorus/Support/Chorus.entitlements --sign "$DEVID" "$APP"
  echo "▸ 已用 Developer ID 重簽（$DEVID）"
else
  echo "⚠︎ 找不到 Developer ID Application 憑證——這包是開發簽章，只能自己機器跑" >&2
fi

# 硬性驗證：巢狀 code（HAL driver、chorus CLI、helper）都要簽得過才算打包成功。
if ! codesign --verify --deep --strict "$APP"; then
  echo "簽章驗證失敗，不產出 zip" >&2
  exit 1
fi

# PKG-4：helper designated requirement 必須含 Team ID。
HELPER_REQ=$(codesign -d -r- "$HELPER_BIN" 2>&1 || true)
if ! grep -q '2ENEDJHX95' <<< "$HELPER_REQ"; then
  echo "✗ helper designated requirement 未含 Team ID 2ENEDJHX95：" >&2
  echo "$HELPER_REQ" >&2
  exit 1
fi

# --verify --deep --strict 對開發簽章一樣會過，所以還要逐個巢狀 binary 確認
# Developer ID、Hardened Runtime、timestamp（PKG-11）。無正式憑證不得標公證 PASS。
verify_nested_devid() {
  local path="$1"
  local label="$2"
  local info
  info=$(codesign -dv --verbose=4 "$path" 2>&1)
  if ! grep -q '^Authority=Developer ID Application' <<< "$info"; then
    echo "✗ $label 不是 Developer ID 憑證：" >&2
    grep '^Authority=' <<< "$info" >&2 || true
    return 1
  fi
  if ! grep -qE '^CodeDirectory .*flags=[^ ]*runtime' <<< "$info"; then
    echo "✗ $label 未啟用 Hardened Runtime" >&2
    return 1
  fi
  if ! grep -q '^Timestamp=' <<< "$info"; then
    echo "✗ $label 缺少 timestamp" >&2
    return 1
  fi
  if ! grep -q '^TeamIdentifier=2ENEDJHX95' <<< "$info"; then
    echo "✗ $label TeamIdentifier 不是 2ENEDJHX95" >&2
    return 1
  fi
  return 0
}

if [[ -n "$DEVID" ]]; then
  verify_nested_devid "$APP" "Chorus.app" || exit 1
  verify_nested_devid "$HELPER_BIN" "ChorusPowerHelper" || exit 1
  verify_nested_devid "$APP/Contents/SharedSupport/chorus" "chorus CLI" || exit 1
  verify_nested_devid "$APP/Contents/PlugIns/ChorusAudioDevice.driver" "ChorusAudioDevice" || exit 1
  # PKG-8/9/11 / W1-3：實際嵌入的 helper version＋identifier；失敗一律 fail closed（不可用 NEXT_BUILD 頂替）。
  chorus_verify_helper_metadata \
    "$APP/Contents/Info.plist" \
    "$HELPER_BIN" \
    "com.hermes.Chorus.PowerHelper" || exit 1
  echo "▸ 簽章驗證通過（Developer ID＋Hardened Runtime＋timestamp；含 helper／driver／CLI）"
else
  echo "▸ 簽章驗證通過（開發簽章，含巢狀 helper／driver／CLI；未標公證 PASS）"
fi

ZIP="dist/Chorus-$VERSION-b$NEXT_BUILD.zip"
WORK_ZIP="$WORK/Chorus-$VERSION-b$NEXT_BUILD.zip"
ditto -c -k --keepParent "$APP" "$WORK_ZIP"
echo "▸ 已打包 $ZIP"

# 公證：有 notarytool 憑證才跑（建立方式見 README）。公證過的 ticket 要 staple
# 進 app，再重新打包一次 zip——不然下載端拿到的還是沒有 ticket 的版本。
NOTARY_PROFILE="${CHORUS_NOTARY_PROFILE:-chorus}"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
  echo "▸ 送公證（profile: $NOTARY_PROFILE）…"
  SUBMIT_LOG="$WORK/notary-submit.txt"
  xcrun notarytool submit "$WORK_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    2>&1 | tee "$SUBMIT_LOG" || true
  NOTARY_STATUS=$(grep -E '^ *status:' "$SUBMIT_LOG" | tail -1 | awk '{print $2}' || true)
  SUBMIT_ID=$(grep -E '^ *id:' "$SUBMIT_LOG" | tail -1 | awk '{print $2}' || true)
  # 被拒時畫面上只有一行 status，真正的原因要另外抓 log
  # （多半是巢狀 code 沒簽、缺 Hardened Runtime，或 entitlements 無效）。
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "✗ 公證未通過（status: ${NOTARY_STATUS:-未知}）" >&2
    if [[ -n "$SUBMIT_ID" ]]; then
      echo "  詳細原因（submission $SUBMIT_ID）：" >&2
      xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"   # ticket 有沒有真的貼上去，staple 成功不等於驗得過
  rm -f "$WORK_ZIP"
  ditto -c -k --keepParent "$APP" "$WORK_ZIP"
  # 最後一道：模擬別台 Mac 下載後開啟的判定。這關過不了就不該把包發出去，不吞錯。
  spctl -a -vvv -t exec "$APP"
  echo "▸ 已公證、staple 並重新打包"
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
