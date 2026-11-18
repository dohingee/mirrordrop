"""
Looks for a passed "iOS build" run (unit tests + launch check) that covers this commit, so iOS
TestFlight need not repeat the unit tests and the launch check (it runs both itself otherwise).
It counts only when all of these hold:
  - the run checked out its commit itself: an ios-check-* tag push or workflow_dispatch (a
    pull_request run tests a merge with the base branch, not a commit; branch pushes from before
    2026-11 had no launch check, so the step test below rejects them);
  - that commit is this commit, or an ancestor of it from which nothing the app build depends on
    changed (APP_PATHS below; e.g. only docs or the TestFlight workflow changed since);
  - the whole run concluded "success" (unit tests too) and its launch step succeeded under the same Xcode version and
    build as this job (the step name carries it, see ios-build.yml).
Anything else, including any API error, prints nothing to GITHUB_OUTPUT: the caller then runs the
check itself. Env: GH_TOKEN (needs actions: read), GITHUB_API_URL, GITHUB_REPOSITORY, GITHUB_SHA,
XCODE (the "26.5-17F42" string from .github/actions/ios-setup).
"""
import json
import os
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
REPO = os.environ["GITHUB_REPOSITORY"]
SHA = os.environ["GITHUB_SHA"]
STEP = f"Launch on iPhone and iPad simulators (Xcode {os.environ['XCODE']})"
# What the app build, the unit tests and the launch check depend on (same list as ios-build.yml's
# pull_request paths).
APP_PATHS = ("ios/", ".github/actions/ios-setup/", ".github/scripts/ios-unit-tests.sh",
             ".github/scripts/ios-launch-check.sh", ".github/workflows/ios-build.yml")


def app_affected(path: str) -> bool:
    return path.startswith(APP_PATHS)


def get(url: str):
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urllib.request.urlopen(req, timeout=30) as res:
        return json.load(res)


def find():
    if not os.environ["XCODE"].strip():
        raise RuntimeError("Xcode version unknown")
    runs = get(f"{API}/repos/{REPO}/actions/workflows/ios-build.yml/runs"
               f"?status=success&per_page=20")["workflow_runs"]
    for run in runs:  # newest first
        if (run["conclusion"] != "success"
                or run["event"] not in ("push", "workflow_dispatch")
                or (run.get("head_repository") or {}).get("full_name") != REPO):
            continue
        if run["head_sha"] != SHA:
            cmp = get(f"{API}/repos/{REPO}/compare/{run['head_sha']}...{SHA}")
            # "ahead": the run's commit is an ancestor. The file list stops at 300 files: treat a
            # comparison that large as affected.
            if (cmp["status"] != "ahead" or len(cmp.get("files", [])) >= 300
                    or any(app_affected(f["filename"]) for f in cmp.get("files", []))):
                continue
        for job in get(f"{run['jobs_url']}?per_page=100")["jobs"]:
            if job["conclusion"] == "success" and any(
                    s["name"] == STEP and s["conclusion"] == "success" for s in job.get("steps", [])):
                return run
    return None


def write(path_var: str, text: str):
    with open(os.environ[path_var], "a", encoding="utf-8") as f:
        f.write(text)


try:
    run = find()
except Exception as e:  # never fail the release on this lookup: run the check instead
    print(f"::warning::could not look up earlier launch checks ({e}); running the launch check")
    run = None

if run:
    print(f"Reusing launch check {run['html_url']} (commit {SHA[:7]}, Xcode {os.environ['XCODE']})")
    write("GITHUB_OUTPUT", f"run_url={run['html_url']}\n")
    write("GITHUB_STEP_SUMMARY",
          f"Launch check skipped: [iOS build #{run['run_number']}]({run['html_url']}) already passed "
          f"for commit `{run['head_sha'][:7]}` (no app change up to `{SHA[:7]}`) with Xcode {os.environ['XCODE']} ({run['event']}, {run['updated_at']}).\n")
else:
    print(f"No passed launch check for commit {SHA[:7]} with Xcode {os.environ['XCODE']}; running it here")
