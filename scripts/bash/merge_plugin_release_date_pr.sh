#!/bin/bash
# Opens the automated/release-date-<version> pull request into the base branch, after the version is
# tagged so the release date check passes on it, and sets it to merge once the branch protection's
# required checks pass, or leaves it open for a person. Where the repository does not allow
# auto-merge, the approver token waits on the required checks and merges once they have all passed.
# The workflow's token opened it, so its pull_request runs are held for approval, and this approves
# them. With RELEASE_APPROVER_TOKEN, a token for another user, that user approves and merges;
# GITHUB_TOKEN can do neither to a pull request it opened.
# Refuses a pull request that changes anything but CHANGELOG.md or carries a commit from anyone
# other than the workflow, since that is all the approver is trusted to approve.
# A pull request left waiting on a person is labelled Needs Review and, with the approver token,
# sent for review to RELEASE_REVIEWER_TEAM or the organisation's plugin reviewers. Without it, a
# comment mentions that team instead.
# Usage: merge_plugin_release_date_pr.sh <base-branch> <version>

set -euo pipefail

BASE_BRANCH="${1:-}"
VERSION="${2:-}"
BRANCH="automated/release-date-$VERSION"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"
RUNS_WAIT_SECONDS="${RUNS_WAIT_SECONDS:-120}"
RUNS_POLL_SECONDS="${RUNS_POLL_SECONDS:-10}"
(( RUNS_POLL_SECONDS > 0 )) || RUNS_POLL_SECONDS=1
CHECKS_WAIT_SECONDS="${CHECKS_WAIT_SECONDS:-1800}"
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
    local out mention team="${RELEASE_REVIEWER_TEAM:-}" owner="${GITHUB_REPOSITORY%%/*}"
    local api="repos/$GITHUB_REPOSITORY/pulls/$pr"
    out=$(gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$pr/labels" -f 'labels[]=Needs Review' 2>&1 >/dev/null) \
        || echo "::warning::Could not label #$pr Needs Review: $(annotation "$out")"
    if [[ -z "$team" ]]; then
        case "$owner" in
            matomo-org) team=plugin-reviewers ;;
            innocraft) team=premium-plugins-reviewers ;;
            *)
                echo "::warning::No reviewer team is known for $owner, so none was asked to review #$pr. Pass reviewer-team to name one."
                return 0
                ;;
        esac
    fi
    # A rerun must not notify the team again, and a reviewer leaves requested_reviewers once they
    # review, so both are read. The approver's own approval is not someone reviewing it.
    out=$(GH_TOKEN="${RELEASE_APPROVER_TOKEN:-$GH_TOKEN}" gh api "$api/requested_reviewers" --jq '(.users | length) + (.teams | length)' 2>&1) \
        || { echo "::warning::Could not read the requested reviewers on #$pr: $(annotation "$out")"; return 0; }
    [[ "$out" == 0 ]] || return 0
    out=$(GH_TOKEN="${RELEASE_APPROVER_TOKEN:-$GH_TOKEN}" gh api "$api/reviews" \
        --jq "[.[] | select(.body != \"$APPROVAL_BODY\")] | length" 2>&1) \
        || { echo "::warning::Could not read the reviews on #$pr: $(annotation "$out")"; return 0; }
    [[ "$out" == 0 ]] || return 0
    if [[ -z "${RELEASE_APPROVER_TOKEN:-}" ]]; then
        # GITHUB_TOKEN cannot request a team review, but it can mention the team, once. Whether a
        # bot's team mention notifies anyone is unconfirmed, so the run still warns.
        mention="@$owner/$team please review and merge."
        out=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$pr/comments" \
            --jq ".[] | select(.body == \"$mention\") | .id" 2>&1) \
            || { echo "::warning::Could not read the comments on #$pr: $(annotation "$out")"; return 0; }
        if [[ -n "$out" ]] || out=$(gh pr comment "$pr" --body "$mention" 2>&1); then
            echo "::warning::No approver token, so $owner/$team was mentioned on #$pr rather than asked to review."
        else
            echo "::warning::Could not mention $owner/$team on #$pr: $(annotation "$out")"
        fi
        return 0
    fi
    # GITHUB_TOKEN cannot request a team review; the approver token can.
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
# every held run seen while waiting is approved. Polls are counted rather than timed against
# SECONDS, whose whole-second ticks can end a short wait before the second look.
polls=$(( (RUNS_WAIT_SECONDS + RUNS_POLL_SECONDS - 1) / RUNS_POLL_SECONDS ))
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
    if (( polls-- <= 0 )); then
        break
    fi
    sleep "$RUNS_POLL_SECONDS"
done

# Assigned on its own line so a failed lookup stops the run rather than reading as a moved head.
current_head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
if [[ "$current_head" != "$head_sha" ]]; then
    leave_open "its head moved on from the commit tagged $VERSION during the wait."
fi

if [[ -n "${RELEASE_APPROVER_TOKEN:-}" ]]; then
    # gh pr review approves whatever the head is by then; with commit_id, GitHub refuses (422) once the head
    # has moved on from the tagged commit.
    if ! approve_output=$(GH_TOKEN="$RELEASE_APPROVER_TOKEN" gh api --method POST \
        "repos/$GITHUB_REPOSITORY/pulls/$pr/reviews" -f event=APPROVE -f "commit_id=$head_sha" \
        -f "body=$APPROVAL_BODY" 2>&1 >/dev/null); then
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
        # Only with the approver token: the job's token is not granted checks: read, and without an
        # approval the branch protection would usually refuse the merge after the wait anyway. That
        # token may also bypass the branch protection, so nothing is merged until GitHub says the
        # pull request can merge.
        *"Auto merge is not allowed"*)
            [[ -n "${RELEASE_APPROVER_TOKEN:-}" ]] || leave_open "$merge_output"
            # Earlier versions in the same run can use up the shared wait; timeout 0 would never time out.
            (( CHECKS_WAIT_SECONDS > 0 )) \
                || leave_open "auto-merge is not allowed, and the wait on required checks was used up by earlier versions."
            echo "Auto-merge is not allowed, so waiting up to ${CHECKS_WAIT_SECONDS}s on the required checks of #$pr."
            checks_deadline=$(( $(date +%s) + CHECKS_WAIT_SECONDS ))
            merge_state=UNKNOWN
            # gh only watches checks that have reported, and a job gated by needs: reports only once it
            # starts, so GitHub's merge state decides whether every required check has passed. A
            # BLOCKED pull request is watched again until the wait runs out.
            while :; do
                remaining=$(( checks_deadline - $(date +%s) ))
                (( remaining > 0 )) \
                    || leave_open "auto-merge is not allowed, and it was still $(annotation "$merge_state") after ${CHECKS_WAIT_SECONDS}s."
                checks_status=0
                checks_output=$(GH_TOKEN="$RELEASE_APPROVER_TOKEN" timeout "$remaining" \
                    gh pr checks "$pr" --required --watch --fail-fast 2>&1) || checks_status=$?
                if [[ "$checks_status" != 0 && "$checks_output" == *"no "*"checks reported"* ]]; then
                    checks_status=0
                fi
                case "$checks_status" in
                    0) ;;
                    124) leave_open "auto-merge is not allowed, and its required checks had not finished after ${CHECKS_WAIT_SECONDS}s." ;;
                    *)
                        # Without a terminal, gh prints a tab-separated row per check, again on each refresh.
                        failed=$(awk -F'\t' '($2 == "fail" || $2 == "cancel") && !seen[$1]++ { printf "%s%s", sep, $1; sep = ", " }' <<< "$checks_output")
                        [[ -n "$failed" ]] \
                            || leave_open "auto-merge is not allowed, and its required checks could not be read: $(annotation "$(tail -n 1 <<< "$checks_output")")"
                        leave_open "auto-merge is not allowed, and its required checks did not pass: $(annotation "$failed")"
                        ;;
                esac
                # GitHub works the state out after the read that asks for it.
                for look in 1 2 3; do
                    review=
                    if merge_state=$(GH_TOKEN="$RELEASE_APPROVER_TOKEN" gh pr view "$pr" --json mergeStateStatus,reviewDecision \
                        --jq '.mergeStateStatus + " " + .reviewDecision' 2>&1); then
                        review=${merge_state#* }
                        merge_state=${merge_state%% *}
                    else
                        merge_state="unreadable: $merge_state"
                    fi
                    [[ "$merge_state" == UNKNOWN && "$look" != 3 ]] || break
                    sleep "$RUNS_POLL_SECONDS"
                done
                case "$merge_state $review" in
                    "BLOCKED REVIEW_REQUIRED" | "BLOCKED CHANGES_REQUESTED")
                        leave_open "auto-merge is not allowed, and its required checks have passed but it waits on a review ($review)." ;;
                    CLEAN* | UNSTABLE* | HAS_HOOKS*) break ;;
                    "BLOCKED "*) sleep "$RUNS_POLL_SECONDS" ;;
                    *) leave_open "auto-merge is not allowed, and its required checks have passed but it is $(annotation "$merge_state")." ;;
                esac
            done
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
