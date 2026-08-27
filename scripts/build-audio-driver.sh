#!/bin/zsh
# 建置 ChorusAudioDevice.driver（HAL AudioServerPlugIn，BV）。
# 純 clang++，Command Line Tools 即可（不需 Xcode）——Mac mini 上也能建。
# 產出：dist/ChorusAudioDevice.driver
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=AudioDriver/Source
OUT=dist/ChorusAudioDevice.driver
BUILD=.build-audio-driver
mkdir -p "$BUILD"

clang++ -bundle \
  -std=c++17 \
  -O2 \
  -fobjc-arc \
  -mmacosx-version-min=12.0 \
  -I "$SRC" -I "$SRC/PublicUtility" \
  -framework CoreAudio -framework CoreFoundation -framework CoreServices -framework IOKit \
  "$SRC"/ProxyAudioDevice.cpp \
  "$SRC"/AudioRingBuffer.cpp \
  "$SRC"/utilities.cpp \
  "$SRC"/AudioDevice.cpp \
  "$SRC"/PublicUtility/CADebugMacros.cpp \
  "$SRC"/PublicUtility/CADebugPrintf.cpp \
  "$SRC"/PublicUtility/CAHostTimeBase.cpp \
  "$SRC"/PublicUtility/CAMutex.cpp \
  -o "$BUILD/ChorusAudioDevice"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp AudioDriver/Info.plist "$OUT/Contents/Info.plist"
cp "$BUILD/ChorusAudioDevice" "$OUT/Contents/MacOS/ChorusAudioDevice"
codesign --force --sign - "$OUT"
echo "▸ $OUT"
