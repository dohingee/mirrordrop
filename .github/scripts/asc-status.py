"""
Writes the TestFlight state of the app (GET requests only, never changes anything) so the lead can
read it from the PC: .github/workflows/ios-asc-status.yml publishes the output folder to the
ci-results branch (asc-status/). Shows the newest builds with their processing state (PROCESSING,
VALID, INVALID, FAILED), beta review state and expiry, and the App Store versions.
Never prints secrets. Env: KEY_ID, ISSUER, KEY (.p8 contents), BUNDLE_ID, OUT (output folder).
API reference: https://developer.apple.com/documentation/appstoreconnectapi
"""
from __future__ import annotations

import os
import subprocess
import sys

from asc_api import ApiError, call, token

lines: list[str] = []


def out(text: str = "") -> None:
    print(text, flush=True)
    lines.append(text)


def rel_id(resource: dict, name: str):
    data = ((resource.get("relationships") or {}).get(name) or {}).get("data")
    return data["id"] if isinstance(data, dict) else None


def main() -> int:
    for var in ("KEY_ID", "ISSUER", "KEY", "BUNDLE_ID", "OUT"):
        if not os.environ.get(var):
            print(f"::error::environment variable {var} is not set")
            return 1
    bundle_id, folder = os.environ["BUNDLE_ID"], os.environ["OUT"]
    os.makedirs(folder, exist_ok=True)
    result, failed = "?", False
    try:
        auth = token()
        apps = [a for a in call("GET", "/apps", auth, {"filter[bundleId]": bundle_id})["data"]
                if a["attributes"].get("bundleId") == bundle_id]
        if not apps:
            result = f"no app with bundle id {bundle_id} in App Store Connect"
            out(result)
        else:
            app = apps[0]
            out(f"App: {app['attributes'].get('name')} ({bundle_id})")
            doc = call("GET", "/builds", auth, {
                "filter[app]": app["id"], "sort": "-uploadedDate", "limit": "5",
                "include": "preReleaseVersion,buildBetaDetail"})
            inc = {(r["type"], r["id"]): r.get("attributes", {}) for r in doc.get("included", [])}
            out("\n== Newest builds (TestFlight)")
            for b in doc["data"]:
                a = b["attributes"]
                version = inc.get(("preReleaseVersions", rel_id(b, "preReleaseVersion")), {}).get("version", "?")
                beta = inc.get(("buildBetaDetails", rel_id(b, "buildBetaDetail")), {})
                out(f"{version} ({a.get('version')}): {a.get('processingState')}, uploaded {a.get('uploadedDate')}, "
                    f"internal {beta.get('internalBuildState', '-')}, external {beta.get('externalBuildState', '-')}, "
                    f"expired {a.get('expired')}, expires {a.get('expirationDate')}")
            if doc["data"]:
                newest = doc["data"][0]["attributes"]
                result = f"newest build {newest.get('version')}: {newest.get('processingState')}"
            else:
                result = "no builds uploaded yet"
            vs = call("GET", f"/apps/{app['id']}/appStoreVersions", auth,
                      {"filter[platform]": "IOS", "limit": "5"})["data"]
            out("\n== App Store versions (iOS)")
            for v in vs or []:
                a = v["attributes"]
                out(f"{a.get('versionString')}: {a.get('appVersionState') or a.get('appStoreState')}, created {a.get('createdDate')}")
            if not vs:
                out("none")
    except (ApiError, OSError, KeyError, ValueError, subprocess.SubprocessError) as e:
        result, failed = f"request failed: {e}", True
        out(result)
        print(f"::error title=App Store Connect::{str(e).replace('%', '%25').replace(chr(10), '%0A')}")
    with open(os.path.join(folder, "status.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(folder, "summary.txt"), "w", encoding="utf-8") as f:
        f.write(f"TestFlight: {result}\n")
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write("## App Store Connect status (read only)\n\n```\n" + "\n".join(lines) + "\n```\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
