#!/usr/bin/env bash
# Package an unsigned arm64 device app for sideloading; preserve matching symbols.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

CONFIG="Release"
DERIVED="$ROOT/build/ReleaseDerivedData"
APP="$DERIVED/Build/Products/${CONFIG}-iphoneos/TruongCam.app"
OUT_DIR="$ROOT/build/ipa"
STAGE="$OUT_DIR/Payload"
LOG_DIR="$ROOT/build/logs"
mkdir -p "$OUT_DIR" "$LOG_DIR"

# Read the versions from the BUILT app: build settings such as
# $(MARKETING_VERSION) are only resolved during the build, so the source
# Info.plist still contains the unexpanded token.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || echo 1.0.0)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist" 2>/dev/null || echo 1)"
IPA="$OUT_DIR/TruongCam-${VERSION}-${BUILD}-unsigned.ipa"

if [ ! -d "$APP" ]; then
  echo "Release app not found at $APP"
  echo "Run 'scripts/build.sh release' first."
  exit 1
fi

echo "== inspect the built app =="
BINARY="$APP/TruongCam"
if [ ! -f "$BINARY" ]; then
  echo "FAIL: expected executable $BINARY"
  exit 1
fi

echo "architectures: $(/usr/bin/lipo -archs "$BINARY" 2>/dev/null || echo unknown)"
echo "bundle id:     $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null)"
echo "min OS:        $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist" 2>/dev/null)"
echo "app size:      $(/usr/bin/du -sh "$APP" | /usr/bin/awk '{print $1}')"
echo "embedded frameworks:"
if [ -d "$APP/Frameworks" ]; then
  /bin/ls -1 "$APP/Frameworks" | /usr/bin/sed 's/^/  /'
else
  echo "  (none)"
fi
echo "code signature:"
/usr/bin/codesign -dvv "$APP" 2>&1 | /usr/bin/head -4 | /usr/bin/sed 's/^/  /' || true
if /usr/bin/codesign -d "$APP" >/dev/null 2>&1 || [ -e "$APP/_CodeSignature" ]; then
  echo "FAIL: this unsigned packaging route requires an unsigned build. Run scripts/build.sh release first."
  exit 1
fi

# Release postprocessing strips the executable while keeping its matching dSYM
# beside the app. Preserve that external symbol file for crash diagnosis; it
# does not belong in the installed payload.
DSYM="$APP.dSYM"
BINARY_UUID="$(xcrun dwarfdump --uuid "$BINARY" 2>/dev/null | /usr/bin/awk '/^UUID:/ {print $2, $3}')"
DSYM_UUID="$(xcrun dwarfdump --uuid "$DSYM" 2>/dev/null | /usr/bin/awk '/^UUID:/ {print $2, $3}')"
if [ -z "$BINARY_UUID" ] || [ "$BINARY_UUID" != "$DSYM_UUID" ]; then
  echo "FAIL: missing or mismatched Release dSYM at $DSYM"
  exit 1
fi

# Apple Silicon simulator executables are arm64 too. Architecture alone cannot
# establish a device build; verify the Mach-O platform before staging anything.
"$ROOT/scripts/validate-device-binary.sh" "$BINARY" || exit 1

echo
echo "== stage Payload =="
/bin/rm -rf "$STAGE"
/bin/mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/TruongCam.app" || exit 1

echo "== archive =="
/bin/rm -f "$IPA"
( cd "$OUT_DIR" && /usr/bin/zip -9qry "$(basename "$IPA")" Payload ) || exit 1
/usr/bin/unzip -tq "$IPA" || exit 1

echo
echo "candidate: $IPA"
echo "sha256:    $(/usr/bin/shasum -a 256 "$IPA" | /usr/bin/awk '{print $1}')"
echo "size:      $(/usr/bin/du -sh "$IPA" | /usr/bin/awk '{print $1}')"

cat > "$OUT_DIR/PACKAGING.txt" <<TXT
TruongCam IPA candidate
========================
version:        $VERSION ($BUILD)
configuration:  $CONFIG (device, iphoneos)
bundle id:      $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null)
architectures:  $(/usr/bin/lipo -archs "$BINARY" 2>/dev/null)
signature:      UNSIGNED (CODE_SIGNING_ALLOWED=NO). This is NOT installable as-is.
archive method: /usr/bin/ditto into Payload/ then /usr/bin/zip -9qry; unzip integrity checked
external dSYM:  $DSYM
binary UUID:    $BINARY_UUID (matches external dSYM)
file:           $(basename "$IPA")
sha256:         $(/usr/bin/shasum -a 256 "$IPA" | /usr/bin/awk '{print $1}')
created:        $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)

INSTALLATION STATUS: NOT VERIFIED.
AltStore Classic must re-sign this candidate with the user's own free Apple
account before it can be installed. No signing credentials, provisioning profile
or export method are invented here. Actual import/launch has not been performed.
TXT

echo "notes:     $OUT_DIR/PACKAGING.txt"
