#!/bin/bash
# Opens the automated/release-date-<version> pull request into the base branch, after the version is
# tagged so the release date check passes on it, and sets it to merge once the branch protection's
# required checks pass, or leaves it open for a person. The workflow's token opened it, so its
# pull_request runs are held for approval, and this approves them. With RELEASE_APPROVER_TOKEN, a
# token for another user, that user approves and merges; GITHUB_TOKEN can do neither to a pull
# request it opened.
# Refuses a pull request that changes anything but CHANGELOG.md or carries a commit from anyone
# other than the workflow, since that is all the approver is trusted to approve.
# A pull request left waiting on a person is labelled Needs Review and, with the approver token,
# sent for review to RELEASE_REVIEWER_TEAM or the organisation's plugin reviewers.
# Usage: merge_plugin_release_date_pr.sh <base-branch> <version>

set -euo pipefail

BASE_BRANCH="${1:-}"
VERSION="${2:-}"
BRANCH="automated/release-date-$VERSION"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"
RUNS_WAIT_SECONDS="${RUNS_WAIT_SECONDS:-120}"
RUNS_POLL_SECONDS="${RUNS_POLL_SECONDS:-10}"
APPROVAL_BODY="Dates the $VERSION release; approved by the release workflow."

if [[ -z "$BASE_BRANCH" || -z "$VERSION" ]]; then
    echo "Usage: $0 <base-branch> <version>" >&2
    exit 1
fi

# GitHub decodes % in an annotation.
annotation() {
    local s="${1//[$'\r\n']/ }"
    echo "${s//%/%25}"
}

# Only for a pull request waiting on a person, so a release that merges itself notifies nobody.
# Requests review the way plugin-vendored-deps-update.yml's step does, which cannot share this:
# that job holds a write token, so it runs nothing from workflows-ref.
ask_for_review() {
    local out team="${RELEASE_REVIEWER_TEAM:-}" owner="${GITHUB_REPOSITORY%%/*}"
    local api="repos/$GITHUB_REPOSITORY/pulls/$pr"
    out=$(gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$pr/labels" -f 'labels[]=Needs Review' 2>&1 >/dev/null) \
        || echo "::warning::Could not label #$pr Needs Review: $(annotation "$out")"
    if [[ -z "${RELEASE_APPROVER_TOKEN:-}" ]]; then
        echo "::warning::No approver token, so no review was requested on #$pr. Request one by hand."
        return 0
    fi
    if [[ -z "$team" ]]; then
        case "$owner" in
            matomo-org) team=plugin-reviewers ;;
            innocraft) team=premium-plugins-reviewers ;;
            *)
                echo "::warning::No reviewer team is known for $owner, so none was requested on #$pr. Pass reviewer-team to request one."
                return 0
                ;;
        esac
    fi
    # GITHUB_TOKEN cannot request a team review; the approver token can. A rerun must not notify the
    # team again, and a reviewer leaves requested_reviewers once they review, so both are read. The
    # approver's own approval is not someone reviewing it.
    out=$(GH_TOKEN="$RELEASE_APPROVER_TOKEN" gh api "$api/requested_reviewers" --jq '(.users | length) + (.teams | length)' 2>&1) \
        || { echo "::warning::Could not read the requested reviewers on #$pr: $(annotation "$out")"; return 0; }
    [[ "$out" == 0 ]] || return 0
    out=$(GH_TOKEN="$RELEASE_APPROVER_TOKEN" gh api "$api/reviews" \
        --jq "[.[] | select(.body != \"$APPROVAL_BODY\")] | length" 2>&1) \
        || { echo "::warning::Could not read the reviews on #$pr: $(annotation "$out")"; return 0; }
    [[ "$out" == 0 ]] || return 0
    out=$(GH_TOKEN="$RELEASE_APPROVER_TOKEN" gh api --method POST "$api/requested_reviewers" -f "team_reviewers[]=$team" 2>&1) \
        || echo "::warning::Could not request review from $owner/$team on #$pr: $(annotation "$out")"
}

leave_open() {
    echo "::warning::Release date pull request #$pr was left open for a person to merge: $*"
    ask_for_review
    exit 0
}

# --head also matches a fork's branch of the same name, which anyone can open a pull request from.
find_pr() {
    gh pr list --head "$BRANCH" --base "$BASE_BRANCH" --state open --json number,isCrossRepository \
        --jq '[.[] | select(.isCrossRepository | not)][0].number // empty'
}

# The commit's email can be set by anyone who can push the branch; the tag can't be moved by a push to it.
tagged_sha=$(git rev-parse "refs/tags/$VERSION^{commit}")

pr=$(find_pr)
if [[ -z "$pr" ]]; then
    # Nothing to open when the base already had the date, or a person merged it before a resumed run.
    branch_status=0
    branch_sha=$(git ls-remote --exit-code --heads origin "refs/heads/$BRANCH") || branch_status=$?
    if (( branch_status == 2 )); then
        echo "$BRANCH does not exist, so there is nothing to bring into $BASE_BRANCH."
        exit 0
    elif (( branch_status != 0 )); then
        echo "::error::Could not list the branches on origin." >&2
        exit 1
    fi
    # The check below would refuse it, and a pull request opened only to be refused needs closing by hand.
    if [[ "${branch_sha%%[[:space:]]*}" != "$tagged_sha" ]]; then
        echo "::warning::$BRANCH has moved on from the commit tagged $VERSION, so no pull request was opened from it."
        exit 0
    fi
    ahead=$(gh api "repos/$GITHUB_REPOSITORY/compare/$BASE_BRANCH...$BRANCH" --jq .ahead_by)
    if (( ahead == 0 )); then
        echo "$BRANCH has nothing to bring into $BASE_BRANCH."
        exit 0
    fi
    gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "Add release date for $VERSION" \
        --body "Dates the $VERSION changelog entry with the day it was released."
    pr=$(find_pr)
    if [[ -z "$pr" ]]; then
        echo "::error::The release date pull request from $BRANCH was not found after opening it." >&2
        exit 1
    fi
fi
head_sha=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
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

# The pull_request runs appear a little after the pull request does, not necessarily together, so
# every held run seen before the deadline is approved.
deadline=$((SECONDS + RUNS_WAIT_SECONDS))
approved=" "
while :; do
    runs=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$head_sha&event=pull_request" \
        --jq '.workflow_runs[] | "\(.id) \(.conclusion)"')
    while read -r run_id conclusion; do
        if [[ "$conclusion" != action_required || "$approved" == *" $run_id "* ]]; then
            continue
        fi
        approved+="$run_id "
        if approve_run_output=$(gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runs/$run_id/approve" 2>&1); then
            echo "Approved held run $run_id."
        else
            echo "::warning::Could not approve held run $run_id: $approve_run_output"
        fi
    done <<< "$runs"
    if (( SECONDS >= deadline )); then
        break
    fi
    sleep "$RUNS_POLL_SECONDS"
done

if [[ -n "${RELEASE_APPROVER_TOKEN:-}" ]]; then
    if ! approve_output=$(GH_TOKEN="$RELEASE_APPROVER_TOKEN" gh pr review "$pr" --approve \
        --body "$APPROVAL_BODY" 2>&1); then
        leave_open "the approver token could not approve it: $approve_output"
    fi
    echo "Approved #$pr."
    merge_token="$RELEASE_APPROVER_TOKEN"
else
    merge_token="$GH_TOKEN"
fi

# --auto merges straight away when nothing required is outstanding, and otherwise once it is, so the
# release never waits on checks the branch protection does not require.
merge=(gh pr merge "$pr" --merge --match-head-commit "$head_sha")
if ! merge_output=$(GH_TOKEN="$merge_token" "${merge[@]}" --auto 2>&1); then
    # gh only asks for auto-merge when GitHub has not yet said the pull request can merge now, and
    # GitHub refuses it if, by then, it can.
    case "$merge_output" in
        *"clean status"* | *"unstable status"*)
            merge_output=$(GH_TOKEN="$merge_token" "${merge[@]}" 2>&1) || leave_open "$merge_output"
            ;;
        *) leave_open "$merge_output" ;;
    esac
fi
# Auto-merge also waits, without a word, on an approving review the branch protection needs, and on
# a person's requested changes.
decision=$(gh pr view "$pr" --json state,reviewDecision --jq '.state + " " + .reviewDecision' 2>&1) \
    || echo "::warning::Could not read whether #$pr waits on an approving review: $(annotation "$decision")"
case "$decision" in
    "OPEN REVIEW_REQUIRED" | "OPEN CHANGES_REQUESTED")
        echo "::warning::Release date pull request #$pr is set to merge, but waits on a review (${decision#OPEN })."
        ask_for_review
        exit 0
        ;;
esac
echo "#$pr merges into $BASE_BRANCH once its required checks pass, if it has not already."
