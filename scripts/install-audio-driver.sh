#!/bin/zsh
# 安裝／移除 ChorusAudioDevice.driver（需 sudo；會重啟 coreaudiod，音訊短暫中斷）。
# 正常情況用 Chorus 設定頁「音訊」分頁一鍵安裝即可；此腳本是無 GUI 時的備援。
# 來源：App 內嵌的 driver（Contents/PlugIns，隨 App target 一起建置）。
# 用法：
#   sudo scripts/install-audio-driver.sh            # 從 /Applications 或 dist/ 的 Chorus.app 安裝
#   sudo scripts/install-audio-driver.sh --remove   # 移除
set -euo pipefail
cd "$(dirname "$0")/.."

HAL=/Library/Audio/Plug-Ins/HAL
TARGET=$HAL/ChorusAudioDevice.driver

if [[ ${1:-} == --remove ]]; then
  rm -rf "$TARGET"
  killall coreaudiod 2>/dev/null || true
  echo "▸ 已移除並重啟 coreaudiod"
  exit 0
fi

SOURCE=""
for app in /Applications/Chorus.app dist/Chorus.app; do
  if [[ -d "$app/Contents/PlugIns/ChorusAudioDevice.driver" ]]; then
    SOURCE="$app/Contents/PlugIns/ChorusAudioDevice.driver"
    break
  fi
done
[[ -n "$SOURCE" ]] || { echo "找不到內嵌 driver 的 Chorus.app（先建置／安裝 App）" >&2; exit 1; }

mkdir -p "$HAL"
rm -rf "$TARGET"
ditto "$SOURCE" "$TARGET"
chown -R root:wheel "$TARGET"
killall coreaudiod 2>/dev/null || true
echo "▸ 已安裝 $TARGET 並重啟 coreaudiod（裝置：Chorus Screen Output）"
