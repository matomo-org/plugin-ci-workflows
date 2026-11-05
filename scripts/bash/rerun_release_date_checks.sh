#!/bin/bash
# Re-runs the release date job on each open pull request into <branch>, once a version has been
# tagged, so a pull request that adds to that version's changelog entry fails before it is merged
# rather than passing on a result from before the release.
# Only warns: a pull request it cannot re-run must not hold back the release.
# Usage: rerun_release_date_checks.sh <branch>

set -uo pipefail

BRANCH="${1:-}"
if [[ -z "$BRANCH" ]]; then
    echo "Usage: $0 <branch>" >&2
    exit 1
fi

annotation() {
    tr '\n' ' ' <<< "$1"
}

if ! prs=$(gh pr list --repo "$GITHUB_REPOSITORY" --base "$BRANCH" --state open --limit 200 \
    --json number,headRefOid --jq '.[] | "\(.number) \(.headRefOid)"' 2>&1); then
    echo "::warning::Could not list the open pull requests into $BRANCH, so their release date checks were not re-run: $(annotation "$prs")"
    exit 0
fi

while read -r pr sha; do
    [[ -n "$pr" ]] || continue
    # Newest first, so the first run with the job is the one the pull request shows.
    if ! runs=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$sha&event=pull_request&per_page=100" \
        --jq '.workflow_runs[] | "\(.id) \(.status)"' 2>&1); then
        echo "::warning::Could not list the runs on #$pr: $(annotation "$runs")"
        continue
    fi
    found=""
    while read -r run status; do
        [[ -n "$run" ]] || continue
        # Called through Plugins CI, the job is named "<caller job> / release-date / Release date", or
        # "<caller job> / release-date" when skip-release-date skips it.
        if ! job=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/jobs?per_page=100" \
            --jq '[.jobs[] | select(.name == "Release date" or (.name | endswith("/ Release date")) or (.name | endswith("/ release-date")))][0] // empty | "\(.id) \(.conclusion)"' 2>&1); then
            echo "::warning::Could not list the jobs of run $run on #$pr: $(annotation "$job")"
            found=error
            break
        fi
        [[ -n "$job" ]] || continue
        found=yes
        read -r job_id conclusion <<< "$job"
        if [[ "$status" != completed ]]; then
            # A run in progress cannot be re-run, and its release date job may already have passed.
            echo "::warning::Run $run on #$pr is still in progress, so its release date check was not re-run. Re-run it once the run finishes."
        elif [[ "$conclusion" == skipped ]]; then
            echo "#$pr skips the release date check."
        elif out=$(gh api --method POST "repos/$GITHUB_REPOSITORY/actions/jobs/$job_id/rerun" 2>&1 >/dev/null); then
            echo "Re-ran the release date check on #$pr."
        else
            echo "::warning::Could not re-run the release date check on #$pr: $(annotation "$out")"
        fi
        break
    done <<< "$runs"
    if [[ -z "$found" ]]; then
        echo "#$pr has no release date check to re-run."
    fi
done <<< "$prs"
