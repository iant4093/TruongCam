#!/usr/bin/env bash
# Require real Simulator execution in CI; local portable tests are explicit.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-native}"
if [ "$mode" = local ]; then exec bash scripts/verify-logic.sh; fi
if [ "$mode" != native ]; then echo "Usage: scripts/test.sh [native|local]" >&2; exit 2; fi
mkdir -p build/logs build/test-results
udid="$(xcrun simctl list devices available --json | python3 -c '
import json,sys,re
choices=[]
for runtime,devices in json.load(sys.stdin).get("devices",{}).items():
    match=re.search(r"iOS-(\d+)-(\d+)",runtime)
    if not match or int(match[1])<27: continue
    for d in devices:
        # Pixel fixtures use iPhone 17 geometry. A newer runtime or a newly
        # installed device type must not silently change that reference canvas.
        if d.get("isAvailable") and d.get("deviceTypeIdentifier")=="com.apple.CoreSimulator.SimDeviceType.iPhone-17":
            choices.append(((int(match[1]),int(match[2]),d.get("state")=="Booted"),d["udid"]))
if not choices: sys.exit("No iOS 27+ iPhone 17 Simulator is installed; the native layout fixtures require that device")
print(max(choices)[1])')"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b
result="build/test-results/TruongCam-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
xcodebuild -version
echo "Testing on iPhone 17 ($udid); result: $result"
status=0
xcodebuild -project TruongCam.xcodeproj -scheme TruongCam -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/SimulatorDerivedData \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath "$result" CODE_SIGNING_ALLOWED=NO test 2>&1 | tee build/logs/test-native.log || status=$?
tail -30 build/logs/test-native.log
exit "$status"
