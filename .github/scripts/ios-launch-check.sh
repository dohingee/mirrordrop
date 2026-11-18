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
# iPhone only (UIDeviceFamily = [1]). A universal build passes every simulator check but App Store
# Connect rejects it at upload (iPad multitasking needs all four orientations; the app is
# portrait-only): iOS TestFlight run #3. Checked here so the archive never starts.
family=$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily' "$app/Info.plist" 2>/dev/null | tr -d ' \n' || true)
if [ "$family" != "Array{1}" ]; then
  echo "::error::the app is not iPhone-only (UIDeviceFamily: ${family:-missing}); set TARGETED_DEVICE_FAMILY \"1\" in each target of ios/project.yml"
  summary "Bundle: FAILED, not iPhone-only (UIDeviceFamily ${family:-missing})"
  failed=1
else
  summary "Bundle: iPhone-only (UIDeviceFamily [1])"
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

ko=(-AppleLanguages "(ko)" -AppleLocale ko_KR)

# Every simulator command runs under a time limit and is logged with the time, so a hang fails in
# minutes and names its step. (Run #2 booted both simulators at once and hung silently for 21 min
# until the job was cancelled; one at a time is what works for Bottlepost.) macOS has no `timeout`:
# perl's alarm survives exec, so SIGALRM ends the command (exit 142).
# The limits for one device add up to about 13 min worst case; the workflow step allows 35 min
# (Release build + both devices + one hang), so these fire first and name the step.
limit() {  # seconds command...  (exit code of the command, 142 on timeout)
  local secs=$1; shift
  perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"
}
step() {  # seconds description command...  (fails the check on error or timeout)
  local secs=$1 what=$2; shift 2
  echo "[$(date +%H:%M:%S)] $what"
  if ! limit "$secs" "$@"; then
    echo "::error::launch check: '$what' failed or took longer than $secs s"
    summary "Launch check: FAILED at '$what'"
    exit 1
  fi
}

# Launches (replacing any running copy), waits, fails the check if the app died, screenshots.
check() {  # udid kind name wait [app arguments...]
  local udid=$1 kind=$2 name=$3 wait=$4; shift 4
  local pid
  echo "[$(date +%H:%M:%S)] launch $name on $kind"
  pid=$(limit 60 xcrun simctl launch --terminate-running-process "$udid" "$bundle" "$@" | awk '{print $NF}') || true
  sleep "$wait"
  limit 30 xcrun simctl io "$udid" screenshot --type=png "$out/$kind-$name.png" >/dev/null 2>&1 || true
  if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
    echo "ok: $name running on the $kind simulator after $wait s (pid $pid)"
  else
    echo "::error::MirrorDrop did not stay running on the $kind simulator ($name screen)"
    failed=1
  fi
}

touch "$out/.started"
for kind in iphone ipad; do
  devtype=$([ "$kind" = iphone ] && echo "$iphone" || echo "$ipad")
  echo "[$(date +%H:%M:%S)] create $kind ($devtype)"
  udid=$(limit 60 xcrun simctl create "launch-$kind" "$devtype" "$runtime") || {
    summary "Launch check: FAILED at 'create $kind'"; exit 1; }
  step 180 "boot $kind" xcrun simctl boot "$udid"
  step 300 "wait for $kind to finish booting" xcrun simctl bootstatus "$udid" -b
  # Cosmetic (same clock and battery in every screenshot), so a failure only warns. iOS TestFlight
  # run #2 failed here on the iPad (error text not seen; likely the cellular options on a Wi-Fi-only
  # iPad), so those go to the iPhone only.
  bar=(--time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100)
  [ "$kind" = iphone ] && bar+=(--cellularMode active --cellularBars 4)
  echo "[$(date +%H:%M:%S)] status bar on $kind"
  limit 30 xcrun simctl status_bar "$udid" override "${bar[@]}" \
    || { echo "::warning::status bar override failed on $kind (screenshots keep the real clock)"
         summary "Status bar: override failed on $kind (screenshots keep the real clock)"; }
  step 180 "install on $kind" xcrun simctl install "$udid" "$app"
  # First launch is slow (fresh install); 25 s also covers a crash shortly after start.
  check "$udid" "$kind" main 25 "${ko[@]}"
  if [ "$kind" = iphone ]; then
    check "$udid" iphone diagnostics 6 "${ko[@]}" -MDScreen diagnostics
    check "$udid" iphone clock 6 "${ko[@]}" -MDScreen clock
  fi
  limit 60 xcrun simctl shutdown "$udid" || true
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
