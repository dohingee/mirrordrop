"""
Reads back what App Store Connect has for the version after `fastlane deliver` (ios-store.yml) with
GET requests only, and fails unless every local screenshot is there and finished processing.
Writes the report to $OUT/upload.txt (published to the ci-results branch, which is public: the
review contact is reported only as set / not set, never its values).
Env: KEY_ID, ISSUER, KEY (asc_api.py), BUNDLE_ID, VERSION, SCREENSHOTS (folder of <locale>/*.png),
METADATA (ios/fastlane/metadata), OUT.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api  # noqa: E402

shots_dir = Path(os.environ["SCREENSHOTS"])
meta = Path(os.environ["METADATA"])
out = Path(os.environ["OUT"])
out.mkdir(parents=True, exist_ok=True)
want = {d.name: len([f for f in d.iterdir() if f.suffix in (".png", ".jpg")]) for d in shots_dir.iterdir() if d.is_dir()}
auth = asc_api.token()


def get(path, **params):
    return asc_api.call("GET", path, auth, params or None)


lines, ok = [], True
app = get("/apps", **{"filter[bundleId]": os.environ["BUNDLE_ID"]})["data"][0]
ver = get(f"/apps/{app['id']}/appStoreVersions",
          **{"filter[versionString]": os.environ["VERSION"], "filter[platform]": "IOS"})["data"][0]
va = ver["attributes"]
lines.append(f"Version {va['versionString']}: state {va.get('appVersionState') or va.get('appStoreState')}, "
             f"release {va.get('releaseType')}, copyright {va.get('copyright')!r}")

# Screenshots: Apple processes uploads for a short while, so look again for up to about 3 minutes.
for attempt in range(18):
    shot_lines, done = [], True
    seen = {}
    for loc in get(f"/appStoreVersions/{ver['id']}/appStoreVersionLocalizations")["data"]:
        locale, a = loc["attributes"]["locale"], loc["attributes"]
        count = 0
        for s in get(f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]:
            shots = get(f"/appScreenshotSets/{s['id']}/appScreenshots")["data"]
            states = [(x["attributes"].get("assetDeliveryState") or {}).get("state") for x in shots]
            count += len(shots)
            done &= all(st == "COMPLETE" for st in states)
            shot_lines.append(f"  {locale} {s['attributes']['screenshotDisplayType']}: {len(shots)} ({', '.join(map(str, states))})")
        seen[locale] = count
        shot_lines.append(f"  {locale} text: description {len(a.get('description') or '')} chars, "
                          f"keywords {len((a.get('keywords') or '').encode())} bytes, "
                          f"promotional {len(a.get('promotionalText') or '')} chars, "
                          f"support {a.get('supportUrl')}, marketing {a.get('marketingUrl')}")
    if done and all(seen.get(k) == n for k, n in want.items()):
        break
    time.sleep(10)
lines.append("Version localizations and screenshots:")
lines += shot_lines
for locale, n in want.items():
    if seen.get(locale) != n:
        ok = False
        lines.append(f"PROBLEM: {locale} has {seen.get(locale, 0)} screenshots in App Store Connect, {n} were sent")
if not done:
    ok = False
    lines.append("PROBLEM: some screenshots did not finish processing (state not COMPLETE)")

# App information: the editable app info (the one not yet live), its languages, categories, age rating.
infos = get(f"/apps/{app['id']}/appInfos")["data"]
info = next((i for i in infos if i["attributes"].get("state") != "READY_FOR_DISTRIBUTION"), infos[0])
lines.append(f"App info: state {info['attributes'].get('state')}")
for loc in get(f"/appInfos/{info['id']}/appInfoLocalizations")["data"]:
    a = loc["attributes"]
    lines.append(f"  {a['locale']}: name {a.get('name')!r}, subtitle {a.get('subtitle')!r}, privacy {a.get('privacyPolicyUrl')}")
for rel in ("primaryCategory", "secondaryCategory"):
    data = (get(f"/appInfos/{info['id']}/{rel}") or {}).get("data")
    lines.append(f"  {rel}: {data['id'] if data else None}")
    expected = (meta / f"{'primary' if rel == 'primaryCategory' else 'secondary'}_category.txt").read_text().strip()
    if not data or data["id"] != expected:
        ok = False
        lines.append(f"PROBLEM: {rel} is not {expected}")
try:
    age = get(f"/appInfos/{info['id']}/ageRatingDeclaration")["data"]["attributes"]
    set_answers = ", ".join(f"{k}={v}" for k, v in sorted(age.items()) if v not in (None, "NONE", False))
    lines.append(f"  age rating answers other than none/no: {set_answers or '(none)'}")
except asc_api.ApiError as e:
    lines.append(f"  age rating: could not read ({e})")

# Review details: notes length and whether a contact is set (values stay private).
try:
    rd = (get(f"/appStoreVersions/{ver['id']}/appStoreReviewDetail") or {}).get("data")
    a = rd["attributes"] if rd else {}
    contact = all(a.get(k) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail"))
    lines.append(f"Review: notes {len(a.get('notes') or '')} chars, sign-in required {a.get('demoAccountRequired')}, "
                 f"contact {'set' if contact else 'NOT set (enter it in App Store Connect or set REVIEW_* variables, docs/SETUP.md 5)'}")
except asc_api.ApiError as e:
    lines.append(f"Review: could not read ({e})")

lines.append("Result: " + ("OK" if ok else "PROBLEMS above"))
report = "\n".join(lines)
print(report)
(out / "upload.txt").write_text(report + "\n", encoding="utf-8")
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a", encoding="utf-8") as f:
        f.write("### What App Store Connect has now\n```\n" + report + "\n```\n")
sys.exit(0 if ok else 1)
