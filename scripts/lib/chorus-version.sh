#!/bin/zsh
# Exact App-property version extraction from project.yml (spec §14.4 / W1-2).
# Only the Chorus application info.properties block — never helper INFOPLIST keys
# or CURRENT_PROJECT_VERSION / MARKETING_VERSION lines.
#
# Usage:
#   source scripts/lib/chorus-version.sh
#   chorus_read_app_version project.yml   # sets CHORUS_APP_VERSION / CHORUS_APP_BUILD
#   chorus_extract_app_version <yml>      # prints "VERSION BUILD" on one line
#
# Never execute release.sh / package.sh from tests — call these functions on fixtures.

chorus_extract_app_version() {
  local yml="${1:?project.yml path}"
  local version build
  version=$(awk '
    /^  Chorus:$/ { in_chorus=1; next }
    /^  [A-Za-z]/ {
      if (in_chorus && index($0, "  Chorus:") != 1) in_chorus=0
    }
    in_chorus && /^    info:/ { in_info=1; next }
    in_chorus && in_info && /^    [a-z]/ { in_info=0 }
    in_chorus && in_info && /^      properties:/ { in_props=1; next }
    in_chorus && in_props && /^      [a-z]/ { in_props=0 }
    in_chorus && in_props && /CFBundleShortVersionString:/ {
      if (match($0, /"[^"]+"/)) {
        print substr($0, RSTART+1, RLENGTH-2)
        exit
      }
    }
  ' "$yml")
  build=$(awk '
    /^  Chorus:$/ { in_chorus=1; next }
    /^  [A-Za-z]/ {
      if (in_chorus && index($0, "  Chorus:") != 1) in_chorus=0
    }
    in_chorus && /^    info:/ { in_info=1; next }
    in_chorus && in_info && /^    [a-z]/ { in_info=0 }
    in_chorus && in_info && /^      properties:/ { in_props=1; next }
    in_chorus && in_props && /^      [a-z]/ { in_props=0 }
    in_chorus && in_props && /CFBundleVersion:/ {
      if (match($0, /"[^"]+"/)) {
        print substr($0, RSTART+1, RLENGTH-2)
        exit
      }
    }
  ' "$yml")
  if [[ -z "$version" || -z "$build" ]]; then
    echo "chorus_extract_app_version: failed to read Chorus info.properties" >&2
    return 1
  fi
  case "$build" in
    (*[^0-9]*|'') echo "chorus_extract_app_version: non-numeric build '$build'" >&2; return 1 ;;
  esac
  print -r -- "$version $build"
}

chorus_read_app_version() {
  local yml="${1:?project.yml path}"
  local line
  line=$(chorus_extract_app_version "$yml") || return 1
  CHORUS_APP_VERSION=${line%% *}
  CHORUS_APP_BUILD=${line##* }
}

# Fail-closed helper embedded-metadata checks (W1-3 / PKG-8/9/11).
# Args: app_info_plist helper_bin expected_helper_id
# Prints nothing; returns non-zero on failure. Does not run codesign --sign.
chorus_verify_helper_metadata() {
  local app_plist="${1:?}"
  local helper_bin="${2:?}"
  local expected_id="${3:-com.hermes.Chorus.PowerHelper}"
  local app_build helper_plist helper_build helper_id

  [[ -f "$app_plist" ]] || { echo "✗ App Info.plist missing: $app_plist" >&2; return 1; }
  [[ -f "$helper_bin" ]] || { echo "✗ helper binary missing: $helper_bin" >&2; return 1; }

  app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_plist" 2>/dev/null) || {
    echo "✗ unreadable App CFBundleVersion" >&2
    return 1
  }

  helper_plist=$(mktemp)
  # codesign -d works for ad-hoc and Developer ID; failure must not substitute NEXT_BUILD.
  # codesign has no --info-plist; read the embedded __TEXT,__info_plist section (thin first if fat).
  local helper_thin
  helper_thin=$(mktemp)
  lipo "$helper_bin" -thin arm64 -output "$helper_thin" 2>/dev/null || cp "$helper_bin" "$helper_thin"
  if ! segedit "$helper_thin" -extract __TEXT __info_plist "$helper_plist" 2>/dev/null; then
    rm -f "$helper_plist" "$helper_thin"
    echo "✗ cannot extract helper embedded Info.plist (codesign -d)" >&2
    return 1
  fi
  rm -f "$helper_thin"
  helper_build=$(plutil -extract CFBundleVersion raw "$helper_plist" 2>/dev/null) || true
  helper_id=$(plutil -extract CFBundleIdentifier raw "$helper_plist" 2>/dev/null) || true
  rm -f "$helper_plist"

  if [[ -z "$helper_build" ]]; then
    echo "✗ helper CFBundleVersion missing/unreadable" >&2
    return 1
  fi
  if [[ -z "$helper_id" ]]; then
    echo "✗ helper CFBundleIdentifier missing/unreadable" >&2
    return 1
  fi
  if [[ "$helper_id" != "$expected_id" ]]; then
    echo "✗ helper CFBundleIdentifier ($helper_id) ≠ $expected_id" >&2
    return 1
  fi
  if [[ "$app_build" != "$helper_build" ]]; then
    echo "✗ App CFBundleVersion ($app_build) ≠ helper ($helper_build)" >&2
    return 1
  fi
  return 0
}
