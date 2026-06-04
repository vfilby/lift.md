#!/usr/bin/env bash
# Capture App Store screenshots in both light and dark appearance.
#
# Drives the LiftMarkUITests `testScreenshots` scenario against an ISOLATED
# simulator so concurrent test runs can't collide, toggling the *simulator's*
# system appearance between runs. The app's default theme is `.auto`, so it
# follows the OS appearance — we never touch in-app settings. Output lands in
# Screenshots/light/ and Screenshots/dark/.
#
# The screenshot scenario auto-resets app data on its first launch (see
# ActionAdapter.executeLaunchApp), so each appearance run starts from the same
# clean, seeded state with no manual erase needed.
#
# Usage:
#   scripts/capture-screenshots.sh [--udid <id>] [--keep]
#                                  [--device <type-id>] [--runtime <runtime-id>]
#
#   --udid <id>   Reuse an existing simulator (implies --keep; never deleted).
#                 Default: create a throwaway iPhone 17 Pro Max and delete it
#                 on exit — built-in isolation from other simulators/tests.
#   --keep        Leave the created simulator booted afterward instead of
#                 deleting it (useful for inspecting the seeded state).
#   --device      CoreSimulator device type id (default: iPhone 17 Pro Max).
#   --runtime     CoreSimulator runtime id (default: iOS 26.4).

set -euo pipefail

SCHEME=LiftMark
PROJECT=LiftMark.xcodeproj
RESULT_BUNDLE=build/Screenshots.xcresult
OUT_ROOT=Screenshots
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-4"
MODES=(light dark)

UDID=""
KEEP=0
CREATED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid)    UDID="$2"; KEEP=1; shift 2;;
        --keep)    KEEP=1; shift;;
        --device)  DEVICE_TYPE="$2"; shift 2;;
        --runtime) RUNTIME="$2"; shift 2;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

if [[ -z "$UDID" ]]; then
    UDID="$(xcrun simctl create "LiftMark-Screenshots" "$DEVICE_TYPE" "$RUNTIME")"
    CREATED=1
    echo "Created throwaway simulator $UDID"
fi

cleanup() {
    if [[ "$CREATED" == "1" && "$KEEP" == "0" ]]; then
        xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
        echo "Deleted throwaway simulator $UDID"
    fi
}
trap cleanup EXIT

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

rm -rf "$OUT_ROOT"
for mode in "${MODES[@]}"; do
    echo "==> Capturing $mode appearance"
    xcrun simctl ui "$UDID" appearance "$mode"
    rm -rf "$RESULT_BUNDLE"
    SIMCTL_CHILD_SCREENSHOTS=1 xcodebuild test \
        -scheme "$SCHEME" -project "$PROJECT" \
        -only-testing:LiftMarkUITests/LiftMarkUITests/testScreenshots \
        -destination "platform=iOS Simulator,id=$UDID" \
        -resultBundlePath "$RESULT_BUNDLE"
    ./scripts/extract-screenshots.sh "$RESULT_BUNDLE" "$OUT_ROOT/$mode"
done

echo ""
echo "Screenshots written to $OUT_ROOT/{light,dark}/"
ls -1 "$OUT_ROOT"/*/
