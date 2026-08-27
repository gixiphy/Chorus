#!/bin/zsh
# 安裝／移除 ChorusAudioDevice.driver（需 sudo；會重啟 coreaudiod，音訊短暫中斷）。
# 用法：
#   sudo scripts/install-audio-driver.sh            # 安裝 dist/ 裡剛建好的 driver
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

[[ -d dist/ChorusAudioDevice.driver ]] || { echo "先跑 scripts/build-audio-driver.sh" >&2; exit 1; }
mkdir -p "$HAL"
rm -rf "$TARGET"
ditto dist/ChorusAudioDevice.driver "$TARGET"
chown -R root:wheel "$TARGET"
killall coreaudiod 2>/dev/null || true
echo "▸ 已安裝 $TARGET 並重啟 coreaudiod（裝置：Chorus Screen Output）"
