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

if [[ -n "$DEVID" ]]; then
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

# 硬性驗證：巢狀 code（HAL driver、chorus CLI）都要簽得過才算打包成功。
if ! codesign --verify --deep --strict "$APP"; then
  echo "簽章驗證失敗，不產出 zip" >&2
  exit 1
fi

# --verify --deep --strict 對開發簽章一樣會過，所以還要確認「是誰簽的、有沒有開
# Hardened Runtime」。這兩項不對公證一定被拒，但要送出去等上好幾分鐘才知道。
if [[ -n "$DEVID" ]]; then
  SIGN_INFO=$(codesign -dv --verbose=4 "$APP" 2>&1)
  if ! grep -q '^Authority=Developer ID Application' <<< "$SIGN_INFO"; then
    echo "✗ 簽出來的不是 Developer ID 憑證，不產出 zip：" >&2
    grep '^Authority=' <<< "$SIGN_INFO" >&2 || true
    exit 1
  fi
  if ! grep -qE '^CodeDirectory .*flags=[^ ]*runtime' <<< "$SIGN_INFO"; then
    echo "✗ 沒有啟用 Hardened Runtime，公證會被拒，不產出 zip" >&2
    exit 1
  fi
  echo "▸ 簽章驗證通過（Developer ID＋Hardened Runtime＋巢狀 driver 與 CLI）"
else
  echo "▸ 簽章驗證通過（開發簽章，含巢狀 driver 與 CLI）"
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
