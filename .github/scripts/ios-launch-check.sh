#!/usr/bin/env bash
# Launch check, also the "PC test" of the app (screenshots the lead reads from the ci-results branch):
#  - builds the Release app for the simulator with its entitlements (ad-hoc signed), as shipped;
#  - checks the broadcast extension is embedded and both CFBundleVersion values match (TestFlight
#    rejects a mismatch; both come from CURRENT_PROJECT_VERSION);
#  - installs it fresh on an iPhone and an iPad simulator (the iPhone-only app runs there in
#    compatibility mode, as App Review tests it) and fails if it does not stay up;
#  - screenshots the main, diagnostics, clock and usage guide screens on the iPhone (Korean, status bar 9:41,
#    full battery) through the app's `-MDScreen` launch argument (UI/ContentView.swift
#    LaunchScreen), and the launch screen on the iPad;
#  - App Store screenshots (iphone-store-*.png): the iPhone is a 6.9-inch model picked by name from
#    the runtime's device types (iPhone 17 Pro Max first; the 6.9-inch slot takes 1320x2868, 1290x2796
#    or 1260x2736). Build 16's run took "the last Pro Max" in list order and got the iPhone 11 Pro Max
#    (1242x2688, 6.5-inch). No 6.9-inch type, or a capture of another size, fails the check.
#    `-MDDemo connected|sending` shows a connected TV / the screen being sent without a Cast device
#    (MirrorDrop/App/DemoMode.swift);
#  - the same in English (`-AppleLanguages "(en)"`): iphone-en-main/-guide.png and
#    iphone-store-en-sending/-connected.png (String Catalogs, MirrorDrop/Resources/Localizable.xcstrings);
#  - copies the Google Cast SDK's privacy files (NutritionLabel.txt, PrivacyInfo.xcprivacy) for the
#    App Privacy answers (docs/RELEASE.md).
# The demo needs the MD_DEMO compilation condition, so this build adds it. That only compiles in the
# `#if MD_DEMO` code; the TestFlight/App Store archive (ios-testflight.yml) is built without it.
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
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MD_DEMO' \
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

# 6.9-inch iPhones (App Store screenshot slot, docs/RELEASE.md), best first. GitHub's macos-26 image
# (Xcode 26, iOS 26.x runtimes) has iPhone 17 Pro Max and iPhone Air; the older names cover other
# images. Display: 17/16 Pro Max 1320x2868, Air 1260x2736, 16 Plus / 15 Pro Max / 15 Plus / 14 Pro Max
# 1290x2796. Pixel sizes the slot accepts are checked again on the captured screenshot below.
store_iphones="iPhone 17 Pro Max|iPhone 16 Pro Max|iPhone Air|iPhone 16 Plus|iPhone 15 Pro Max|iPhone 15 Plus|iPhone 14 Pro Max"
store_sizes="1320x2868 1290x2796 1260x2736"
read -r runtime iphone ipad store_ok <<<"$(xcrun simctl list -j | STORE_IPHONES="$store_iphones" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
rt = sorted((r for r in d["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]),
            key=lambda r: [int(x) for x in r["version"].split(".")])[-1]
types = rt.get("supportedDeviceTypes", d["devicetypes"])
by_name = {t["name"]: t["identifier"] for t in types}
store = [by_name[n] for n in os.environ["STORE_IPHONES"].split("|") if n in by_name]
# No 6.9-inch type: still run the launch check on some iPhone, but the store screenshots fail.
iphones = [t["identifier"] for t in types if t["name"].startswith("iPhone")]
ipads = [t["identifier"] for t in types if t["name"].startswith("iPad Air")]
print(rt["identifier"], (store or iphones)[0], ipads[-1], "yes" if store else "no")')"
echo "runtime $runtime, iPhone $iphone, iPad $ipad"
if [ "$store_ok" != yes ]; then
  echo "::error::no 6.9-inch iPhone simulator in $runtime (looked for: $store_iphones)"
  summary "Store screenshots: FAILED, no 6.9-inch iPhone simulator in $runtime (looked for: $store_iphones); using $iphone"
  failed=1
fi

ko=(-AppleLanguages "(ko)" -AppleLocale ko_KR)
en=(-AppleLanguages "(en)" -AppleLocale en_US)

# Every simulator command runs under a time limit and is logged with the time, so a hang fails in
# minutes and names its step. (Run #2 booted both simulators at once and hung silently for 21 min
# until the job was cancelled; one at a time is what works for Bottlepost.) macOS has no `timeout`:
# perl's alarm survives exec, so SIGALRM ends the command (exit 142).
# Worst case (one boot retry, one launch retry, every launch at its 180 s limit): boots and installs
# about 20 min, nine launches with screenshots about 30 min, so a hang can still reach the workflow
# step's 40 min limit; a typical run is about 18 min (the four English captures add about 3).
# Whatever fires, summary.txt names the last step
# reached (the timestamps in the log show where the time went).
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
  # `simctl launch` itself can take over a minute on the Intel runner right after a boot (iOS
  # TestFlight run #6: the first iPhone launch hit a 60 s limit, no pid, no crash, home screen in the
  # screenshot; the next launches took about 60 s too). So 180 s, and once per run (like the boot
  # retry) one more try without a pid, noted in the summary so a first-launch hang is not hidden.
  pid=$(limit 180 xcrun simctl launch --terminate-running-process "$udid" "$bundle" "$@" | awk '{print $NF}') || true
  if [ -z "$pid" ] && [ "$launch_retried" = 0 ]; then
    launch_retried=1
    echo "::warning::launch $name on $kind returned no pid within 180 s; trying once more"
    summary "Launch: $name on $kind gave no pid in 180 s, launched a second time"
    pid=$(limit 180 xcrun simctl launch --terminate-running-process "$udid" "$bundle" "$@" | awk '{print $NF}') || true
  fi
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
retried=0
launch_retried=0
for kind in iphone ipad; do
  devtype=$([ "$kind" = iphone ] && echo "$iphone" || echo "$ipad")
  echo "[$(date +%H:%M:%S)] create $kind ($devtype)"
  udid=$(limit 60 xcrun simctl create "launch-$kind" "$devtype" "$runtime") || {
    summary "Launch check: FAILED at 'create $kind'"; exit 1; }
  # Booting on the Intel runner sometimes stalls (iOS TestFlight run #4: the iPhone was not up after
  # 300 s; iOS build run #2 hung 21 min). Once per run, a stalled device is deleted and a fresh one
  # is booted with `bootstatus -b` (boots it and waits, no device-state error); a second stall fails.
  step 180 "boot $kind" xcrun simctl boot "$udid"
  echo "[$(date +%H:%M:%S)] wait for $kind to finish booting"
  if ! limit 300 xcrun simctl bootstatus "$udid" -b; then
    [ "$retried" = 0 ] || { summary "Launch check: FAILED at 'wait for $kind to finish booting' (no retry left)"; exit 1; }
    retried=1
    echo "::warning::$kind did not finish booting in 300 s; trying once more on a fresh simulator"
    limit 60 xcrun simctl shutdown "$udid" || true
    limit 60 xcrun simctl delete "$udid" || true
    udid=$(limit 60 xcrun simctl create "launch-$kind-2" "$devtype" "$runtime") || {
      summary "Launch check: FAILED at 'create $kind (retry)'"; exit 1; }
    step 300 "boot $kind on a fresh simulator (retry)" xcrun simctl bootstatus "$udid" -b
    summary "Boot: $kind needed a fresh simulator"
  fi
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
    check "$udid" iphone diagnostics 15 "${ko[@]}" -MDScreen diagnostics
    check "$udid" iphone clock 15 "${ko[@]}" -MDScreen clock
    check "$udid" iphone guide 15 "${ko[@]}" -MDScreen guide
    # App Store screenshots: first-run tips already seen (plist values in the argument domain).
    seen=(-volumeTipSeen '<true/>' -usageGuideSeen '<true/>')
    check "$udid" iphone store-sending 15 "${ko[@]}" "${seen[@]}" -MDDemo sending
    check "$udid" iphone store-connected 15 "${ko[@]}" "${seen[@]}" -MDDemo connected
    # English UI (worldwide release): the same store screenshots, plus the main screen (with the volume
    # tip, not seen in its argument domain) and the guide, to check the translated layout.
    check "$udid" iphone store-en-sending 15 "${en[@]}" "${seen[@]}" -MDDemo sending
    check "$udid" iphone store-en-connected 15 "${en[@]}" "${seen[@]}" -MDDemo connected
    check "$udid" iphone en-main 15 "${en[@]}"
    check "$udid" iphone en-guide 15 "${en[@]}" -MDScreen guide
    size=$(sips -g pixelWidth -g pixelHeight "$out/iphone-store-sending.png" 2>/dev/null \
      | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {if (w && h) print w "x" h}' || true)
    if [ -n "$size" ] && [[ " $store_sizes " == *" $size "* ]]; then
      summary "Store screenshots: iPhone $iphone, $size (6.9-inch slot)"
    else
      echo "::error::store screenshots are ${size:-of unknown size}, the 6.9-inch slot needs one of: $store_sizes"
      summary "Store screenshots: FAILED, iPhone $iphone gave ${size:-unknown size} (6.9-inch needs one of $store_sizes)"
      failed=1
    fi
  fi
  limit 60 xcrun simctl shutdown "$udid" || true
done

# Google Cast SDK privacy details for the App Privacy answers (Google: check them for each SDK version).
mkdir -p "$out/cast-sdk-privacy"
find "${SPM_PACKAGES_DIR:-build/spm}" "$app/Frameworks" \( -name NutritionLabel.txt -o -name PrivacyInfo.xcprivacy \) \
  -path '*GoogleCast*' 2>/dev/null | while IFS= read -r f; do
    cp "$f" "$out/cast-sdk-privacy/$(echo "${f#*GoogleCast}" | tr '/' '_')"
  done || true
[ -n "$(ls -A "$out/cast-sdk-privacy" 2>/dev/null)" ] || summary "Cast SDK privacy files: not found"

crashes=$(find ~/Library/Logs/DiagnosticReports -name 'MirrorDrop*' -newer "$out/.started" 2>/dev/null || true)
rm -f "$out/.started"
if [ -n "$crashes" ]; then
  echo "::error::crash reports found: $(echo "$crashes" | xargs -n1 basename | paste -sd ' ' -)"
  while IFS= read -r crash; do cp "$crash" "$out/"; head -c 4000 "$crash"; done <<<"$crashes"
  failed=1
fi
summary "Launch check: $([ $failed = 0 ] && echo passed || echo FAILED) on iPhone and iPad simulators ($runtime)"
exit $failed
