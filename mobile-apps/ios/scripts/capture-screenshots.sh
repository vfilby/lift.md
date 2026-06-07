#!/usr/bin/env bash
# Capture App Store screenshots for iPhone and iPad, in both light and dark
# appearance.
#
# Drives the LiftMarkUITests `testScreenshots` scenario against ISOLATED
# throwaway simulators (one per device) so concurrent test runs can't collide,
# toggling the *simulator's* system appearance between runs. The app's default
# theme is `.auto`, so it follows the OS appearance — we never touch in-app
# settings. Output lands in Screenshots/<device>/<mode>/, e.g.
# Screenshots/iphone/light/ and Screenshots/ipad/dark/.
#
# The screenshot scenario auto-resets app data on its first launch (see
# ActionAdapter.executeLaunchApp), so each appearance run starts from the same
# clean, seeded state with no manual erase needed.
#
# Default devices (the largest App Store Connect slots):
#   iphone -> iPhone 17 Pro Max (1320×2868, the 6.9" slot)
#   ipad   -> iPad Pro 13-inch M4 (2064×2752, the 13" slot)
#
# Usage:
#   scripts/capture-screenshots.sh [--only iphone|ipad]
#                                  [--udid <id>] [--keep]
#                                  [--device <type-id>] [--runtime <runtime-id>]
#
#   --only <dev>  Capture just one default device (iphone or ipad).
#   --udid <id>   Reuse an existing simulator (implies --keep; never deleted).
#                 Captures only that sim into Screenshots/custom/. Default:
#                 create throwaway sims per device and delete them on exit —
#                 built-in isolation from other simulators/tests.
#   --keep        Leave created simulators booted afterward instead of
#                 deleting them (useful for inspecting the seeded state).
#   --device      CoreSimulator device type id. Overrides the defaults with a
#                 single custom device, captured into Screenshots/custom/.
#   --runtime     CoreSimulator runtime id (default: iOS 26.4).

set -euo pipefail

SCHEME=LiftMark
PROJECT=LiftMark.xcodeproj
RESULT_BUNDLE=build/Screenshots.xcresult
OUT_ROOT=Screenshots
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-4"
MODES=(light dark)

# Default capture targets, as "label:device-type-id". Each gets its own
# throwaway simulator and output subdirectory under Screenshots/.
IPHONE_DEVICE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
IPAD_DEVICE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"
DEFAULT_TARGETS=("iphone:$IPHONE_DEVICE" "ipad:$IPAD_DEVICE")

UDID=""
KEEP=0
ONLY=""
DEVICE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)    ONLY="$2"; shift 2;;
        --udid)    UDID="$2"; KEEP=1; shift 2;;
        --keep)    KEEP=1; shift;;
        --device)  DEVICE_OVERRIDE="$2"; shift 2;;
        --runtime) RUNTIME="$2"; shift 2;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

# Resolve the list of targets ("label:device-type") to capture.
TARGETS=()
if [[ -n "$UDID" || -n "$DEVICE_OVERRIDE" ]]; then
    # A reused sim or an explicit device type → one custom target.
    TARGETS=("custom:${DEVICE_OVERRIDE}")
elif [[ -n "$ONLY" ]]; then
    for t in "${DEFAULT_TARGETS[@]}"; do
        [[ "${t%%:*}" == "$ONLY" ]] && TARGETS=("$t")
    done
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        echo "unknown --only value: $ONLY (expected iphone or ipad)" >&2
        exit 2
    fi
else
    TARGETS=("${DEFAULT_TARGETS[@]}")
fi

CREATED_UDIDS=()
cleanup() {
    if [[ "$KEEP" == "0" ]]; then
        for u in "${CREATED_UDIDS[@]:-}"; do
            [[ -z "$u" ]] && continue
            xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
            xcrun simctl delete "$u" >/dev/null 2>&1 || true
            echo "Deleted throwaway simulator $u"
        done
    fi
}
trap cleanup EXIT

rm -rf "$OUT_ROOT"
for target in "${TARGETS[@]}"; do
    label="${target%%:*}"
    device_type="${target#*:}"

    if [[ -n "$UDID" ]]; then
        sim_udid="$UDID"
    else
        sim_udid="$(xcrun simctl create "LiftMark-Screenshots-$label" "$device_type" "$RUNTIME")"
        CREATED_UDIDS+=("$sim_udid")
        echo "Created throwaway $label simulator $sim_udid"
    fi

    xcrun simctl boot "$sim_udid" 2>/dev/null || true
    xcrun simctl bootstatus "$sim_udid" -b

    for mode in "${MODES[@]}"; do
        echo "==> Capturing $label / $mode appearance"
        xcrun simctl ui "$sim_udid" appearance "$mode"
        rm -rf "$RESULT_BUNDLE"
        SIMCTL_CHILD_SCREENSHOTS=1 xcodebuild test \
            -scheme "$SCHEME" -project "$PROJECT" \
            -only-testing:LiftMarkUITests/LiftMarkUITests/testScreenshots \
            -destination "platform=iOS Simulator,id=$sim_udid" \
            -resultBundlePath "$RESULT_BUNDLE"
        ./scripts/extract-screenshots.sh "$RESULT_BUNDLE" "$OUT_ROOT/$label/$mode"
    done
done

echo ""
echo "Screenshots written under $OUT_ROOT/<device>/{light,dark}/"
ls -1 "$OUT_ROOT"/*/*/ 2>/dev/null || ls -1R "$OUT_ROOT"
