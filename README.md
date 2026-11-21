# CI results (generated, replaced on every run)

- `<short sha>/`: launch check of that commit (.github/scripts/ios-launch-check.sh): screenshots,
  summary.txt, unit-tests.txt, entitlements.txt, crash reports if any.
- `asc-status/`: App Store Connect / TestFlight state (.github/workflows/ios-asc-status.yml).
- `store/`: App Store listing run (.github/workflows/ios-store.yml): screenshots/<locale>/ as
  uploaded, summary.txt, upload.txt (what App Store Connect has afterwards).
