#!/bin/zsh
# Generate the app icon and review sheet from the actual menu bar renderer.
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_WORK=$(mktemp -d /tmp/chorus-icons.XXXXXX)
trap 'rm -rf "$ICON_WORK"' EXIT
xcrun swiftc -emit-library -emit-module -module-name ChorusCore \
  Packages/ChorusCore/Sources/ChorusCore/StatusIcon.swift \
  Packages/ChorusCore/Sources/ChorusCore/StatusIconGeometry.swift \
  -emit-module-path "$ICON_WORK/ChorusCore.swiftmodule" -o "$ICON_WORK/libChorusCore.dylib"
xcrun swiftc -parse-as-library -I "$ICON_WORK" -L "$ICON_WORK" -lChorusCore \
  -Xlinker -rpath -Xlinker "$ICON_WORK" \
  Chorus/UI/StatusIconRenderer.swift scripts/render-icons.swift -o "$ICON_WORK/render-icons"
"$ICON_WORK/render-icons" "$ICON_WORK"
iconutil -c icns "$ICON_WORK/Chorus.iconset" -o Chorus/Support/Chorus.icns
