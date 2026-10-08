#!/bin/bash
# Opens the automated/release-date-<version> pull request into the base branch, after the version is
# tagged so the release date check passes on it, and merges it once its checks finish, or leaves it
# open for a person. The workflow's token opened it, so its pull_request runs
# are held for approval, and this approves them. With RELEASE_APPROVER_TOKEN, a token for another
# user, that user approves and merges; GITHUB_TOKEN can do neither to a pull request it opened.
# Refuses a pull request that changes anything but CHANGELOG.md or carries a commit from anyone
# other than the workflow, since that is all the approver is trusted to approve.
# Usage: merge_plugin_release_date_pr.sh <base-branch> <version>

set -euo pipefail

BASE_BRANCH="${1:-}"
VERSION="${2:-}"
BRANCH="automated/release-date-$VERSION"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"
WAIT_SECONDS="${MERGE_WAIT_SECONDS:-600}"

if [[ -z "$BASE_BRANCH" || -z "$VERSION" ]]; then
    echo "Usage: $0 <base-branch> <version>" >&2
    exit 1
fi

leave_open() {
    echo "::warning::Release date pull request #$pr was left open for a person to merge: $*"
    exit 0
}

pr=$(gh pr list --head "$BRANCH" --base "$BASE_BRANCH" --state open --json number --jq '.[0].number // empty')
if [[ -z "$pr" ]]; then
    # Nothing to open when the base already had the date, or a person merged it before a resumed run.
    branch_status=0
    git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" > /dev/null || branch_status=$?
    if (( branch_status == 2 )); then
        echo "$BRANCH does not exist, so there is nothing to bring into $BASE_BRANCH."
        exit 0
    elif (( branch_status != 0 )); then
        echo "::error::Could not list the branches on origin." >&2
        exit 1
    fi
    ahead=$(gh api "repos/$GITHUB_REPOSITORY/compare/$BASE_BRANCH...$BRANCH" --jq .ahead_by)
    if (( ahead == 0 )); then
        echo "$BRANCH has nothing to bring into $BASE_BRANCH."
        exit 0
    fi
    gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "Add release date for $VERSION" \
        --body "Dates the $VERSION changelog entry with the day it was released."
    pr=$(gh pr list --head "$BRANCH" --base "$BASE_BRANCH" --state open --json number --jq '.[0].number // empty')
    if [[ -z "$pr" ]]; then
        echo "::error::The release date pull request from $BRANCH was not found after opening it." >&2
        exit 1
    fi
fi
head_sha=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
# The commit's email can be set by anyone who can push the branch; the tag can't be moved by a push to it.
tagged_sha=$(git rev-parse "refs/tags/$VERSION^{commit}")
if [[ "$head_sha" != "$tagged_sha" ]]; then
    leave_open "its head is not the commit tagged $VERSION."
fi

files=$(gh pr view "$pr" --json files --jq '.files[].path')
if [[ "$files" != "CHANGELOG.md" ]]; then
    leave_open "it changes more than CHANGELOG.md ($(tr '\n' ' ' <<< "$files"))."
fi
identities=$(gh api "repos/$GITHUB_REPOSITORY/compare/$BASE_BRANCH...$head_sha" \
    --jq '.commits[] | .commit.author.email, .commit.committer.email' | sort -u)
if [[ -n "$identities" ]] && grep -qvxF "$BOT_EMAIL" <<< "$identities"; then
    leave_open "it has commits from someone other than this workflow."
fi

approve_held_runs() {
    local run_ids run_id
    run_ids=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$head_sha&event=pull_request" \
        --jq '.workflow_runs[] | select(.conclusion == "action_required") | .id')
    for run_id in $run_ids; do
        if approve_run_output=$(gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runs/$run_id/approve" 2>&1); then
            echo "Approved held run $run_id."
        else
            echo "::warning::Could not approve held run $run_id: $approve_run_output"
        fi
    done
}

# This token can't read branch protection, so it waits for every check to finish rather than for
# the required ones.
deadline=$((SECONDS + WAIT_SECONDS))
while :; do
    # The pull_request runs can appear a little after the pull request does.
    approve_held_runs
    # Paginated, since a check past the first page could otherwise be running or failed unseen.
    conclusions=$(gh api --paginate "repos/$GITHUB_REPOSITORY/commits/$head_sha/check-runs?per_page=100" \
        --jq '.check_runs[] | .conclusion // "pending"')
    total=$(grep -c . <<< "$conclusions" || true)
    pending=$(grep -cx pending <<< "$conclusions" || true)
    failed=$(grep -cvxE 'success|skipped|neutral|pending|' <<< "$conclusions" || true)
    if (( failed > 0 )); then
        leave_open "a check on it failed."
    fi
    if (( total > 0 && pending == 0 )); then
        break
    fi
    if (( SECONDS >= deadline )); then
        leave_open "its checks had not finished after ${WAIT_SECONDS}s."
    fi
    sleep 15
done

if [[ -n "${RELEASE_APPROVER_TOKEN:-}" ]]; then
    if ! approve_output=$(GH_TOKEN="$RELEASE_APPROVER_TOKEN" gh pr review "$pr" --approve \
        --body "Dates the $VERSION release; approved by the release workflow." 2>&1); then
        leave_open "the approver token could not approve it: $approve_output"
    fi
    echo "Approved #$pr."
    merge_token="$RELEASE_APPROVER_TOKEN"
else
    merge_token="$GH_TOKEN"
fi

if ! merge_output=$(GH_TOKEN="$merge_token" gh pr merge "$pr" --merge --match-head-commit "$head_sha" 2>&1); then
    leave_open "$merge_output"
fi
echo "Merged #$pr into $BASE_BRANCH."
