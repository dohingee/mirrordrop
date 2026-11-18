#!/usr/bin/env bash
# Launch check, also the "PC test" of the app (screenshots the lead reads from the ci-results branch):
#  - builds the Release app for the simulator with its entitlements (ad-hoc signed), as shipped;
#  - checks the broadcast extension is embedded and both CFBundleVersion values match (TestFlight
#    rejects a mismatch; both come from CURRENT_PROJECT_VERSION);
#  - installs it fresh on an iPhone and an iPad simulator (the iPhone-only app runs there in
#    compatibility mode, as App Review tests it) and fails if it does not stay up;
#  - screenshots the main, diagnostics and clock screens on the iPhone (Korean, status bar 9:41,
#    full battery) through the app's `-MDScreen` launch argument (UI/ContentView.swift
#    LaunchScreen), and the launch screen on the iPad.
# Unit tests cannot see a launch crash: they run unsigned, without the app. The broadcast itself
# (ReplayKit) and Google Cast discovery cannot run in a simulator: those stay on the device test.
# Run from ios/ after .github/actions/ios-setup. Writes png, entitlements.txt, summary.txt and any
# crash reports to $RESULTS_DIR (default build/ci-results).
set -euo pipefail
out=${RESULTS_DIR:-build/ci-results}
bundle=com.mirrordrop.app
mkdir -p "$out"
summary() { echo "$1" | tee -a "$out/summary.txt" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

# Full log stays out of $out (megabytes, and $out is pushed to git); errors are copied on failure.
log=build/launch-build.txt
xcodebuild build \
  -project MirrorDrop.xcodeproj -scheme MirrorDrop -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/launch \
  -clonedSourcePackagesDirPath "${SPM_PACKAGES_DIR:-build/spm}" -disablePackageRepositoryCache \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  2>&1 | tee "$log" | grep -E "error:|\*\* " || true
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"; then
  { grep -E "error:" "$log" || tail -n 40 "$log"; } | tail -n 40 > "$out/build-errors.txt"
  summary "Launch check: FAILED (Release simulator build, see build-errors.txt)"
  exit 1
fi
app=build/launch/Build/Products/Release-iphonesimulator/MirrorDrop.app
appex="$app/PlugIns/MirrorDropBroadcast.appex"

failed=0
if [ ! -d "$appex" ]; then
  echo "::error::the broadcast extension is not embedded ($appex missing)"; failed=1
else
  v_app=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
  v_ext=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$appex/Info.plist")
  if [ "$v_app" != "$v_ext" ]; then
    echo "::error::CFBundleVersion differs: app $v_app, extension $v_ext"; failed=1
  else
    summary "Bundle: extension embedded, CFBundleVersion $v_app in both"
  fi
fi
# Both targets need the App Group (the app reads the extension's status through it). Simulator
# signing may keep entitlements out of the signature, so a missing group only warns; the archive
# (device signing) is the real proof.
for b in "$app" "$appex"; do
  echo "== ${b#build/launch/Build/Products/}"
  codesign -d --entitlements - "$b" 2>&1 || true
done > "$out/entitlements.txt"
[ "$(grep -c 'group.com.mirrordrop.app' "$out/entitlements.txt")" -ge 2 ] \
  || echo "::warning::App Group group.com.mirrordrop.app not found in both signatures (entitlements.txt)"

read -r runtime iphone ipad <<<"$(xcrun simctl list -j | python3 -c '
import json, sys
d = json.load(sys.stdin)
rt = sorted((r for r in d["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]),
            key=lambda r: [int(x) for x in r["version"].split(".")])[-1]
types = rt.get("supportedDeviceTypes", d["devicetypes"])
def pick(prefix):
    return [t["identifier"] for t in types if t["name"].startswith(prefix)][-1]
print(rt["identifier"], pick("iPhone"), pick("iPad Air"))')"
echo "runtime $runtime"

# Boot both simulators at once (each boot takes a minute or more on the Intel runner).
# udid_iphone / udid_ipad: plain variables, macOS /bin/bash 3.2 has no associative arrays.
for kind in iphone ipad; do
  devtype=$([ "$kind" = iphone ] && echo "$iphone" || echo "$ipad")
  printf -v "udid_$kind" '%s' "$(xcrun simctl create "launch-$kind" "$devtype" "$runtime")"
  var="udid_$kind"; xcrun simctl boot "${!var}"
done
ko=(-AppleLanguages "(ko)" -AppleLocale ko_KR)

# Launches (replacing any running copy), waits, fails the check if the app died, screenshots.
check() {  # kind name wait [app arguments...]
  local kind=$1 name=$2 wait=$3; shift 3
  local var="udid_$kind" pid
  local udid=${!var}
  pid=$(xcrun simctl launch --terminate-running-process "$udid" "$bundle" "$@" | awk '{print $NF}') || true
  sleep "$wait"
  xcrun simctl io "$udid" screenshot --type=png "$out/$kind-$name.png" >/dev/null 2>&1 || true
  if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
    echo "ok: $name running on the $kind simulator after $wait s (pid $pid)"
  else
    echo "::error::MirrorDrop did not stay running on the $kind simulator ($name screen)"
    failed=1
  fi
}

touch "$out/.started"
for kind in iphone ipad; do
  var="udid_$kind"; udid=${!var}
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl install "$udid" "$app"
  # First launch is slow (fresh install); 25 s also covers a crash shortly after start.
  check "$kind" main 25 "${ko[@]}"
  if [ "$kind" = iphone ]; then
    check iphone diagnostics 6 "${ko[@]}" -MDScreen diagnostics
    check iphone clock 6 "${ko[@]}" -MDScreen clock
  fi
  xcrun simctl shutdown "$udid" || true
done

crashes=$(find ~/Library/Logs/DiagnosticReports -name 'MirrorDrop*' -newer "$out/.started" 2>/dev/null || true)
rm -f "$out/.started"
if [ -n "$crashes" ]; then
  echo "::error::crash reports found: $(echo "$crashes" | xargs -n1 basename | paste -sd ' ' -)"
  while IFS= read -r crash; do cp "$crash" "$out/"; head -c 4000 "$crash"; done <<<"$crashes"
  failed=1
fi
summary "Launch check: $([ $failed = 0 ] && echo passed || echo FAILED) on iPhone and iPad simulators ($runtime)"
exit $failed
