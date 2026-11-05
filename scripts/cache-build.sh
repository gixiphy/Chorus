#!/bin/bash
# Thin xcodebuild wrapper for HotData compilation-cache measurement (A/B + shared CAS).
# Does not touch package.sh, release.sh, project.yml, or global Xcode defaults.
set -euo pipefail

usage() {
  echo "usage: $0 <src_dir> <derived_data_dir> <log_prefix>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage

SRC_DIR=$1
DD_DIR=$2
LOG_PREFIX=$3

require_hotdata() {
  local path=$1
  case "$path" in
    /Volumes/HotData/*) ;;
    *)
      echo "error: path must be under /Volumes/HotData/: $path" >&2
      exit 2
      ;;
  esac
}

require_hotdata "$SRC_DIR"
require_hotdata "$DD_DIR"
require_hotdata "$LOG_PREFIX"

CAS_DIR=/Volumes/HotData/xcode-cas/Chorus
LOG_DIR=$(dirname "$LOG_PREFIX")
LOG_FILE="${LOG_PREFIX}.log"
TIME_FILE="${LOG_PREFIX}.time"

mkdir -p "$DD_DIR" "$CAS_DIR" "$LOG_DIR"

cd "$SRC_DIR"

# /usr/bin/time (BSD) has no -o; isolate timing on stderr while tee'ing build output.
set +e
/usr/bin/time -p \
  env \
  DD_DIR="$DD_DIR" \
  LOG_FILE="$LOG_FILE" \
  bash -c '
    set -o pipefail
    xcodebuild build \
      -scheme Chorus \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath "$DD_DIR" \
      COMPILATION_CACHE_ENABLE_CACHING=YES \
      COMPILATION_CACHE_CAS_PATH=/Volumes/HotData/xcode-cas/Chorus \
      COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES \
      SWIFT_ENABLE_PREFIX_MAPPING=YES \
      SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES \
      CLANG_ENABLE_PREFIX_MAPPING=YES \
      CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES \
      CODE_SIGNING_ALLOWED=NO \
      2>&1 | tee "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
  ' \
  2>"$TIME_FILE"
status=$?
set -e
exit "$status"
