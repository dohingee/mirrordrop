#!/usr/bin/env bash
# Pushes CI results to the ci-results branch so they can be read from the Windows PC with plain git
# (no gh CLI needed):
#   git fetch origin ci-results && git archive origin/ci-results | tar -x -C <folder>
# The branch is always one orphan commit, force-pushed (no history piles up in the repository).
#   publish-ci-results.sh launch-check <dir> : <dir> becomes <short sha>/, replacing the previous
#                                              commit's folder (asc-status/ and store/ are kept)
#   publish-ci-results.sh asc-status <dir>   : <dir> becomes asc-status/ (everything else is kept)
#   publish-ci-results.sh store <dir>        : <dir> becomes store/ (everything else is kept)
# Env: GITHUB_TOKEN (contents: write), GITHUB_REPOSITORY, SOURCE_SHA (the checked commit),
# optional RUN_URL. Never touches any other branch.
set -euo pipefail
kind=$1 src=$2
[ -d "$src" ] && [ -n "$(ls -A "$src")" ] || { echo "nothing to publish in $src"; exit 0; }
branch=ci-results
remote=${CI_RESULTS_REMOTE:-"https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"}  # override: local tests
sha7=${SOURCE_SHA:0:7}
work=$(mktemp -d)
git -C "$work" init -q -b "$branch"
git -C "$work" config user.name "github-actions[bot]"
git -C "$work" config user.email "41898231+github-actions[bot]@users.noreply.github.com"
# Keep the other kind's folder from the current branch tip, if the branch exists.
if git -C "$work" fetch -q --depth=1 "$remote" "$branch" 2>/dev/null; then
  git -C "$work" checkout -q FETCH_HEAD -- .
fi
case "$kind" in
  launch-check)
    find "$work" -mindepth 1 -maxdepth 1 ! -name .git ! -name asc-status ! -name store -exec rm -rf {} +
    dest="$work/$sha7" ;;
  asc-status|store)
    rm -rf "${work:?}/$kind"
    dest="$work/$kind" ;;
  *) echo "unknown kind $kind"; exit 1 ;;
esac
mkdir -p "$dest"
cp -R "$src"/. "$dest"/
printf '%s\n' "commit ${SOURCE_SHA}" "run ${RUN_URL:-?}" "time $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dest/source.txt"
cat > "$work/README.md" <<MD
# CI results (generated, replaced on every run)

- \`<short sha>/\`: launch check of that commit (.github/scripts/ios-launch-check.sh): screenshots,
  summary.txt, unit-tests.txt, entitlements.txt, crash reports if any.
- \`asc-status/\`: App Store Connect / TestFlight state (.github/workflows/ios-asc-status.yml).
- \`store/\`: App Store listing run (.github/workflows/ios-store.yml): screenshots/<locale>/ as
  uploaded, summary.txt, upload.txt (what App Store Connect has afterwards).
MD
git -C "$work" add -A
# Orphan commit: drop the fetched history so the branch stays a single commit.
tree=$(git -C "$work" write-tree)
commit=$(git -C "$work" commit-tree "$tree" -m "$kind for ${sha7}: $(tail -n 1 "$dest/summary.txt" 2>/dev/null || echo done)")
git -C "$work" push -qf "$remote" "$commit:refs/heads/$branch"
echo "Published $kind to branch $branch (${dest#$work/}/)" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
rm -rf "$work"
