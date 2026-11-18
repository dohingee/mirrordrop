#!/usr/bin/env bash
# Unit tests: Debug build of the MirrorDropTests scheme (logic tests on Shared/, no host app, so the
# app and the Cast SDK are not built) for an iPhone simulator, unsigned, no secrets. Shared by
# ios-build.yml and ios-testflight.yml so both run exactly the same tests. Run from ios/ after
# .github/actions/ios-setup (generates the project, sets SPM_PACKAGES_DIR). Full xcodebuild output
# goes to ../xcodebuild-output.txt (the workflows' "Report build errors" step reads it); the test
# lines and the result go to $RESULTS_DIR/unit-tests.txt and summary.txt (published to ci-results).
set -euo pipefail
results=${RESULTS_DIR:-build/ci-results}
mkdir -p "$results"
udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
print(next(d["udid"] for rt in sorted(devices, reverse=True) if ".iOS-" in rt
           for d in devices[rt] if d["name"].startswith("iPhone")))')
xcodebuild test \
  -project MirrorDrop.xcodeproj -scheme MirrorDropTests \
  -destination "id=$udid" \
  -clonedSourcePackagesDirPath "${SPM_PACKAGES_DIR:-build/spm}" -disablePackageRepositoryCache \
  -derivedDataPath build/dd \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee ../xcodebuild-output.txt \
  | grep -E "error:|warning: .*(MirrorDrop|Shared)/|Test Suite|Test Case .* failed|Executed|\*\* " | tee "$results/unit-tests.txt" || true
if grep -q '\*\* TEST SUCCEEDED \*\*' ../xcodebuild-output.txt; then result=passed; else result=FAILED; fi
echo "Unit tests: $result (Debug, iPhone simulator)" | tee -a "$results/summary.txt" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
[ "$result" = passed ]
