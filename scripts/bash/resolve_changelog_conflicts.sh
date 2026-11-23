#!/bin/bash
# Merges the base branch into each approved pull request against it whose only conflict is one
# resolve_changelog_conflict.py can resolve, pushes the merge, and has the approver token approve it
# again, so a pull request that conflicts only on its changelog line can still be merged as approved.
#
# Only a pull request from a branch of this repository is touched, and only while it is approved:
# that approval is what gets carried forward. It is approved again only when, file by file, the lines
# it adds and removes are the same before and after the merge, apart from a version line the base
# branch now has too. The merge is pushed with the workflow's token, so the approver is not the last
# pusher, and the pull_request runs that push leaves held for approval are approved.
# Anything else is left as it was, with a notice saying why.
# Usage: resolve_changelog_conflicts.sh <base-branch> [pull request number]

set -euo pipefail

BASE_BRANCH="${1:-}"
ONLY_PR="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/../python/resolve_changelog_conflict.py"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
RUNS_WAIT_SECONDS="${RUNS_WAIT_SECONDS:-120}"
RUNS_POLL_SECONDS="${RUNS_POLL_SECONDS:-15}"

if [[ -z "$BASE_BRANCH" ]]; then
    echo "Usage: resolve_changelog_conflicts.sh <base-branch> [pull request number]" >&2
    exit 1
fi
if [[ -n "$ONLY_PR" && ! "$ONLY_PR" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::'$ONLY_PR' is not a pull request number." >&2
    exit 1
fi
if [[ -z "${APPROVER_TOKEN:-}" ]]; then
    # Resolving without approving again would dismiss the approval, which is no better than by hand.
    echo "::error::No approver token, so no conflict was resolved. Pass approver-token under secrets:." >&2
    exit 1
fi

git config user.name "$BOT_NAME"
git config user.email "$BOT_EMAIL"
git config merge.conflictStyle zdiff3
git fetch --quiet --tags origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH"
base_sha=$(git rev-parse "refs/remotes/origin/$BASE_BRANCH")
mapfile -t released < <(git tag -l | sed 's/^v//')

# Prints "file<TAB>+line" or "file<TAB>-line" for each line a diff adds or removes, sorted.
changed_lines() {
    git diff --no-color --no-ext-diff --no-renames -U0 "$@" \
        | awk '/^diff --git / { file = substr($4, 3); next }
               /^(\+\+\+|---) / { next }
               /^[+-]/ { print file "\t" $0 }' \
        | LC_ALL=C sort
}

skip() {
    echo "::notice::#$pr was left as it is, because $1"
}

# Approves the pull_request runs a push by the workflow's token leaves held, until RUNS_WAIT_SECONDS
# have passed, so the required checks report on the merge.
approve_held_runs() {
    local sha="$1" polls=$(( RUNS_WAIT_SECONDS / RUNS_POLL_SECONDS )) approved=" " runs run_id conclusion
    while :; do
        runs=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$sha&event=pull_request" \
            --jq '.workflow_runs[] | "\(.id) \(.conclusion)"') || runs=''
        while read -r run_id conclusion; do
            if [[ -z "$run_id" || "$conclusion" != action_required || "$approved" == *" $run_id "* ]]; then
                continue
            fi
            approved+="$run_id "
            if out=$(gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runs/$run_id/approve" 2>&1); then
                echo "Approved held run $run_id."
            else
                echo "::warning::Could not approve held run $run_id: $out"
            fi
        done <<< "$runs"
        if (( polls-- <= 0 )); then
            break
        fi
        sleep "$RUNS_POLL_SECONDS"
    done
}

filter='.[] | select(.isCrossRepository == false and .reviewDecision == "APPROVED")
    | "\(.number) \(.headRefOid) \(.headRefName)"'
if [[ -n "$ONLY_PR" ]]; then
    candidates=$(gh pr view "$ONLY_PR" --json number,baseRefName,headRefOid,headRefName,isCrossRepository,reviewDecision,state \
        --jq "[select(.state == \"OPEN\" and .baseRefName == \"$BASE_BRANCH\")] | $filter")
    if [[ -z "$candidates" ]]; then
        echo "::notice::#$ONLY_PR is not an open, approved pull request from this repository against $BASE_BRANCH."
    fi
else
    candidates=$(gh pr list --base "$BASE_BRANCH" --state open --limit 200 \
        --json number,headRefOid,headRefName,isCrossRepository,reviewDecision --jq "$filter")
fi

status=0
while read -r pr head_sha head_ref; do
    [[ -n "$pr" ]] || continue
    git fetch --quiet --no-tags origin "+refs/heads/$head_ref:refs/remotes/origin/$head_ref"
    if [[ "$(git rev-parse "refs/remotes/origin/$head_ref")" != "$head_sha" ]]; then
        skip "its branch moved on while this ran."
        continue
    fi
    git checkout --quiet --detach "$head_sha"
    if git merge --quiet --no-edit "$base_sha" >/dev/null 2>&1; then
        # A clean merge is GitHub's Update branch, which needs nothing from this.
        git reset --quiet --hard "$head_sha"
        continue
    fi
    conflicted=$(git diff --name-only --diff-filter=U)
    if [[ "$conflicted" != CHANGELOG.md ]]; then
        git merge --abort
        skip "it conflicts in more than CHANGELOG.md: $(echo "$conflicted" | paste -sd' ')."
        continue
    fi
    if ! reason=$(python3 -I "$RESOLVER" CHANGELOG.md "${released[@]}" 2>&1 >"$RUNNER_TEMP/CHANGELOG.md"); then
        git merge --abort
        skip "${reason#CHANGELOG.md was left for a person, because }"
        continue
    fi
    cp "$RUNNER_TEMP/CHANGELOG.md" CHANGELOG.md
    git add CHANGELOG.md
    git commit --quiet --no-edit -m "Merge $BASE_BRANCH into $head_ref, resolving the CHANGELOG.md conflict"
    merge_sha=$(git rev-parse HEAD)

    # Lines the pull request no longer adds may only be version or blank lines the base branch now has too.
    before=$(changed_lines "$base_sha...$head_sha")
    after=$(changed_lines "$base_sha" "$merge_sha")
    gained=$(LC_ALL=C comm -13 <(echo "$before") <(echo "$after"))
    lost=$(LC_ALL=C comm -23 <(echo "$before") <(echo "$after") \
        | grep -vxF -f <(git show "$base_sha:CHANGELOG.md" | grep -E '^(#*[ \t]*v?[0-9]+\.[0-9]+\.[0-9]+|[[:space:]]*$)' \
            | sed 's/^/CHANGELOG.md\t+/') || true)
    if [[ -n "$gained" || -n "$lost" ]]; then
        skip "resolving the conflict would change what it adds or removes."
        git reset --quiet --hard "$head_sha"
        continue
    fi
    # The workflow's token cannot push a commit that changes a workflow.
    if git diff --name-only "$head_sha" "$merge_sha" | grep -q '^\.github/workflows/'; then
        skip "the merge brings in workflow changes from $BASE_BRANCH, which this token cannot push. Use Update branch first."
        git reset --quiet --hard "$head_sha"
        continue
    fi

    if ! out=$(git push --quiet origin "$merge_sha:refs/heads/$head_ref" 2>&1); then
        # A plain push fails rather than overwrite anything pushed since the fetch.
        echo "::warning::Could not push the resolved merge to #$pr: $out"
        status=1
        continue
    fi
    echo "Resolved the CHANGELOG.md conflict on #$pr with ${merge_sha:0:12}."
    approve_held_runs "$merge_sha"
    # With commit_id, GitHub refuses (422) once someone has pushed on top of the merge.
    if ! out=$(GH_TOKEN="$APPROVER_TOKEN" gh api --method POST "repos/$GITHUB_REPOSITORY/pulls/$pr/reviews" \
        -f event=APPROVE -f "commit_id=$merge_sha" \
        -f "body=Merged $BASE_BRANCH and resolved the CHANGELOG.md conflict; the pull request's own changes are as approved before, so the approval stands." \
        2>&1 >/dev/null); then
        echo "::warning::Resolved #$pr, but could not approve it again, so it needs a new review: $out"
        status=1
    fi
done <<< "$candidates"
exit "$status"
