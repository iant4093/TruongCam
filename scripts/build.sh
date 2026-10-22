#!/usr/bin/env bash
# Unsigned device Debug/Release builds; optional simulator build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PROJECT="TruongCam.xcodeproj"
SCHEME="TruongCam"
LOG_DIR="$ROOT/build/logs"
mkdir -p "$LOG_DIR"

mode="${1:-all}"

print_toolchain() {
  echo "== toolchain =="
  xcodebuild -version
  echo "xcode-select: $(xcode-select -p)"
  echo "iphoneos SDK: $(xcrun --sdk iphoneos --show-sdk-path)"
  echo "iphoneos SDK version: $(xcrun --sdk iphoneos --show-sdk-version)"
  swift --version 2>&1 | head -2
  echo
}

build_device() {
  local config="$1"
  local derived="$2"
  local log="$LOG_DIR/build-device-${config}.log"
  echo "== device build ($config) =="
  echo "log: $log"
  local overrides=()
  if [ -n "${TRUONGCAM_BUILD_NUMBER:-}" ]; then
    case "$TRUONGCAM_BUILD_NUMBER" in *[!0-9]*|'') echo "Invalid build number" >&2; return 2 ;; esac
    overrides+=("CURRENT_PROJECT_VERSION=$TRUONGCAM_BUILD_NUMBER")
  fi
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$config" \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO ${overrides[@]+"${overrides[@]}"} \
    build >"$log" 2>&1
  local status=$?
  if [ $status -eq 0 ]; then
    echo "PASS: $config device build (exit 0)"
    local app="$derived/Build/Products/${config}-iphoneos/TruongCam.app"
    if [ -d "$app" ]; then
      echo "artifact: $app"
      /usr/bin/du -sh "$app" | sed 's/^/size: /'
    fi
  else
    echo "FAIL: $config device build (exit $status)"
    grep -E "error:" "$log" | sort -u | head -40
  fi
  return $status
}

build_simulator() {
  local derived="$ROOT/build/SimDerivedData"
  local log="$LOG_DIR/build-simulator-Debug.log"
  echo "== simulator SDK build (Debug) =="
  echo "log: $log"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$log" 2>&1
  local status=$?
  if [ $status -eq 0 ]; then
    echo "PASS: simulator Debug build (exit 0)"
  else
    echo "FAIL: simulator Debug build (exit $status)"
    grep -E "error:" "$log" | sort -u | head -40
  fi
  return $status
}

print_toolchain

overall=0
case "$mode" in
  debug)     build_device Debug "$ROOT/build/DerivedData" || overall=1 ;;
  release)   build_device Release "$ROOT/build/ReleaseDerivedData" || overall=1 ;;
  simulator) build_simulator || overall=1 ;;
  all)
    build_device Debug "$ROOT/build/DerivedData" || overall=1
    echo
    build_device Release "$ROOT/build/ReleaseDerivedData" || overall=1
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

echo
if [ $overall -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi
exit $overall
