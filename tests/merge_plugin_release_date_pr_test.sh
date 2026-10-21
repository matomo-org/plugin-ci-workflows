#!/bin/bash
# Tests when the release date pull request is merged and when it is left open, with a fake gh CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/merge_plugin_release_date_pr.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GITHUB_REPOSITORY=matomo-org/plugin-TestPlugin
export GH_TOKEN=workflow-token
export RUNS_WAIT_SECONDS=0
BOT_EMAIL='github-actions[bot]@users.noreply.github.com'

FAKE_BIN="$WORK/bin"
mkdir "$FAKE_BIN"
# Each call is logged with the token it ran as, so a test can tell whose approval or merge it was.
# Each read builds the API's JSON from the FAKE_ variables and runs the real --jq filter, the last
# argument, over it.
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s %s\n' "$GH_TOKEN" "$*" >> "$FAKE_GH_LOG"
filter() { jq -r "$JQ_FILTER"; }
JQ_FILTER="${*: -1}"
case "$*" in
    'pr list '*)
        number="$FAKE_PR"
        if [[ -z "$number" && -f "$FAKE_GH_LOG.pr" ]]; then number=$(cat "$FAKE_GH_LOG.pr"); fi
        prs='[]'
        if [[ -n "${FAKE_FORK_PR:-}" ]]; then prs=$(jq -c --argjson n "$FAKE_FORK_PR" '. + [{number: $n, isCrossRepository: true}]' <<< "$prs"); fi
        if [[ -n "$number" ]]; then prs=$(jq -c --argjson n "$number" '. + [{number: $n, isCrossRepository: false}]' <<< "$prs"); fi
        filter <<< "$prs"
        ;;
    'pr create '*) echo 35 > "$FAKE_GH_LOG.pr" ;;
    # FAKE_LATE_HEAD is the head from the second look on.
    'pr view '*'--json headRefOid'*)
        head="$FAKE_HEAD"
        if [[ -f "$FAKE_GH_LOG.head" ]]; then
            if [[ -n "${FAKE_LATE_HEAD_ERROR:-}" ]]; then
                echo "$FAKE_LATE_HEAD_ERROR" >&2
                exit 1
            fi
            head="${FAKE_LATE_HEAD:-$FAKE_HEAD}"
        fi
        touch "$FAKE_GH_LOG.head"
        jq -n --arg h "$head" '{headRefOid: $h}' | filter
        ;;
    'pr view '*'--json files'*) jq -n '{files: ($ARGS.positional | map({path: .}))}' --args $FAKE_FILES | filter ;;
    'pr view '*'--json state,reviewDecision'*)
        if [[ -n "${FAKE_DECISION_ERROR:-}" ]]; then
            echo "$FAKE_DECISION_ERROR" >&2
            exit 1
        fi
        jq -n --arg d "${FAKE_REVIEW_DECISION:-}" '{state: "OPEN", reviewDecision: $d}' | filter
        ;;
    *'/issues/'*'/labels'*) ;;
    # FAKE_COMMENT is the body of the one comment already on the pull request.
    *'/issues/'*'/comments'*)
        if [[ -n "${FAKE_COMMENTS_ERROR:-}" ]]; then
            echo "$FAKE_COMMENTS_ERROR" >&2
            exit 1
        fi
        jq -n --arg b "${FAKE_COMMENT:-}" '[if $b == "" then empty else {id: 1, body: $b} end]' | filter
        ;;
    'pr comment '*)
        if [[ -n "${FAKE_COMMENT_ERROR:-}" ]]; then
            echo "$FAKE_COMMENT_ERROR" >&2
            exit 1
        fi
        ;;
    *'--method POST '*'/requested_reviewers'*)
        if [[ -n "${FAKE_REQUEST_ERROR:-}" ]]; then
            echo "$FAKE_REQUEST_ERROR" >&2
            exit 1
        fi
        ;;
    *'--method POST '*'/pulls/'*'/reviews '*)
        if [[ "${FAKE_REVIEW_STATUS:-0}" != 0 ]]; then exit "$FAKE_REVIEW_STATUS"; fi
        touch "$FAKE_GH_LOG.approved"
        ;;
    # FAKE_REQUESTED and FAKE_REVIEWS count who is requested and who, besides the approver, has reviewed.
    *'/requested_reviewers'*) jq -n --argjson n "${FAKE_REQUESTED:-0}" '{users: [range($n) | {}], teams: []}' | filter ;;
    *'/reviews'*)
        approvals=0
        if [[ -f "$FAKE_GH_LOG.approved" ]]; then approvals=1; fi
        jq -n --argjson n "${FAKE_REVIEWS:-0}" --argjson a "$approvals" \
            '[range($n) | {body: "Looks right"}] + [range($a) | {body: "Dates the 6.0.3 release; approved by the release workflow."}]' | filter
        ;;
    *'/compare/'*'--jq .ahead_by')
        if [[ -z "$FAKE_AHEAD" ]]; then exit 1; fi
        jq -n --argjson n "$FAKE_AHEAD" '{ahead_by: $n}' | filter
        ;;
    # FAKE_COMMITS is author:committer email pairs.
    *'/compare/'*)
        jq -n '{commits: ($ARGS.positional | map(split(":") | {commit: {author: {email: .[0]}, committer: {email: .[1]}}}))}' \
            --args $FAKE_COMMITS | filter
        ;;
    # FAKE_RUNS is id:conclusion pairs; FAKE_LATE_RUNS join them from the second listing on.
    *'/actions/runs?'*)
        runs="$FAKE_RUNS"
        if [[ -f "$FAKE_GH_LOG.listed" ]]; then runs="$runs ${FAKE_LATE_RUNS:-}"; fi
        touch "$FAKE_GH_LOG.listed"
        jq -n '{workflow_runs: ($ARGS.positional | map(split(":") | {id: (.[0] | tonumber), conclusion: .[1], status: "completed"}))}' \
            --args $runs | filter
        ;;
    *'/approve') ;;
    'pr merge '*' --auto')
        if [[ -n "${FAKE_AUTO_MERGE_ERROR:-}" ]]; then
            echo "$FAKE_AUTO_MERGE_ERROR" >&2
            exit 1
        fi
        ;;
    'pr merge '*)
        if [[ -n "${FAKE_MERGE_ERROR:-}" ]]; then
            echo "$FAKE_MERGE_ERROR" >&2
            exit 1
        fi
        ;;
esac
SH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"

# An origin with the dated commit tagged 6.0.3 and pushed to its date branch, and a clone to run in.
git init -q "$WORK/seed"
git -C "$WORK/seed" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m 'Add release date for 6.0.3'
git -C "$WORK/seed" tag 6.0.3
git -C "$WORK/seed" branch -q automated/release-date-6.0.3
git clone -q --bare "$WORK/seed" "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/clone"
TAGGED=$(git -C "$WORK/clone" rev-parse 6.0.3)

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

# A pull request that is safe to merge; each test changes one thing.
reset() {
    export FAKE_GH_LOG="$WORK/$1.log" OUT="$WORK/$1.out"
    : > "$FAKE_GH_LOG"
    rm -f "$FAKE_GH_LOG.listed" "$FAKE_GH_LOG.approved" "$FAKE_GH_LOG.head"
    export FAKE_PR=35 FAKE_FILES=CHANGELOG.md FAKE_COMMITS="$BOT_EMAIL:$BOT_EMAIL" FAKE_RUNS='' FAKE_AHEAD=1 FAKE_HEAD="$TAGGED"
    unset FAKE_REVIEW_STATUS FAKE_AUTO_MERGE_ERROR FAKE_MERGE_ERROR RELEASE_APPROVER_TOKEN FAKE_FORK_PR \
        FAKE_REVIEW_DECISION FAKE_REQUESTED FAKE_REVIEWS FAKE_REQUEST_ERROR RELEASE_REVIEWER_TEAM FAKE_DECISION_ERROR FAKE_LATE_HEAD FAKE_LATE_HEAD_ERROR \
        FAKE_COMMENT FAKE_COMMENT_ERROR FAKE_COMMENTS_ERROR
}

run() {
    (cd "$WORK/clone" && bash "$SCRIPT" 6.x-dev 6.0.3) > "$OUT" 2>&1
}

says() {
    grep -Fq "$1" "$OUT"
}

merged() {
    grep -Eq " pr merge 35 --merge --match-head-commit $TAGGED( --auto)?$" "$FAKE_GH_LOG"
}

labelled() {
    grep -Fq 'workflow-token api --method POST repos/matomo-org/plugin-TestPlugin/issues/35/labels -f labels[]=Needs Review' "$FAKE_GH_LOG"
}

mentioned() {
    grep -Fq "workflow-token pr comment 35 --body @$1 please review and merge." "$FAKE_GH_LOG"
}

requested() {
    grep -Fq "approver-token api --method POST repos/matomo-org/plugin-TestPlugin/pulls/35/requested_reviewers -f team_reviewers[]=$1" "$FAKE_GH_LOG"
}

reset merge
export FAKE_RUNS='101:action_required 102:action_required 103:success'
run || fail "merging succeeds"
grep -Fq 'workflow-token api -X POST repos/matomo-org/plugin-TestPlugin/actions/runs/101/approve' "$FAKE_GH_LOG" \
    || fail "the first held run is approved"
grep -Fq '/actions/runs/102/approve' "$FAKE_GH_LOG" || fail "every held run is approved"
if grep -Fq '/actions/runs/103/approve' "$FAKE_GH_LOG"; then fail "a run that is not held is not approved"; fi
grep -q "^workflow-token pr merge 35 --merge --match-head-commit $TAGGED --auto$" "$FAKE_GH_LOG" \
    || fail "without an approver, the workflow's token sets it to merge once the required checks pass"
if grep -Fq '/check-runs' "$FAKE_GH_LOG"; then fail "the merge does not wait on checks the branch protection does not require"; fi
grep -Fq 'pr list --head automated/release-date-6.0.3 --base 6.x-dev' "$FAKE_GH_LOG" || fail "the version's branch into the base is looked up"
if grep -Eq 'event=APPROVE| pr review ' "$FAKE_GH_LOG"; then fail "without an approver nothing approves the pull request"; fi
if labelled || grep -Eq 'requested_reviewers| pr comment ' "$FAKE_GH_LOG"; then fail "a release that merges itself asks nobody to review it"; fi

reset late-runs
export FAKE_RUNS='101:action_required' FAKE_LATE_RUNS='104:action_required'
RUNS_WAIT_SECONDS=1 RUNS_POLL_SECONDS=1 run || fail "merging with a late run succeeds"
unset FAKE_LATE_RUNS
grep -Fq '/actions/runs/104/approve' "$FAKE_GH_LOG" || fail "a held run that appears after the first is approved"
[[ "$(grep -c '/actions/runs/101/approve' "$FAKE_GH_LOG")" == 1 ]] || fail "a held run is approved once"

reset approver
export RELEASE_APPROVER_TOKEN=approver-token
run || fail "merging with the approver succeeds"
grep -Fq "approver-token api --method POST repos/matomo-org/plugin-TestPlugin/pulls/35/reviews -f event=APPROVE -f commit_id=$TAGGED" "$FAKE_GH_LOG" \
    || fail "the approver approves the tagged commit"
grep -q "^approver-token pr merge 35 --merge --match-head-commit $TAGGED --auto$" "$FAKE_GH_LOG" || fail "the approver merges"

reset head-moved-while-waiting
export RELEASE_APPROVER_TOKEN=approver-token FAKE_LATE_HEAD=0000000000000000000000000000000000000000
run || fail "a head that moves during the wait leaves the pull request open, not failed"
says 'its head moved on from the commit tagged 6.0.3 during the wait' || fail "a head that moved during the wait warns"
if grep -Eq 'event=APPROVE| pr review ' "$FAKE_GH_LOG"; then fail "a head that moved during the wait is not approved"; fi
if merged; then fail "nothing is merged once the head has moved"; fi

reset head-lookup-failed
export RELEASE_APPROVER_TOKEN=approver-token FAKE_LATE_HEAD_ERROR='HTTP 502: Bad Gateway'
if run; then fail "a failed head lookup after the wait fails the run"; fi
if says 'moved on'; then fail "a failed head lookup is not reported as a moved head"; fi
if grep -Eq 'event=APPROVE| pr review ' "$FAKE_GH_LOG" || labelled; then fail "a failed head lookup approves and labels nothing"; fi

reset approver-refused
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1
run || fail "a refused approval leaves the pull request open, not failed"
says '::warning::Release date pull request #35 was left open' || fail "a refused approval warns"
if merged; then fail "nothing is merged after a refused approval"; fi

reset clean
export FAKE_AUTO_MERGE_ERROR='GraphQL: Pull request Pull request is in clean status (enablePullRequestAutoMerge)'
run || fail "a pull request GitHub can already merge is merged, not failed"
grep -q "^workflow-token pr merge 35 --merge --match-head-commit $TAGGED$" "$FAKE_GH_LOG" \
    || fail "a pull request refused auto-merge for being mergeable now is merged directly"

reset auto-disabled
export FAKE_AUTO_MERGE_ERROR='GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)'
run || fail "a repository without auto-merge leaves the pull request open, not failed"
says 'left open for a person to merge: GraphQL: Auto merge is not allowed' || fail "the auto-merge refusal is passed on"
if grep -q " pr merge 35 --merge --match-head-commit $TAGGED$" "$FAKE_GH_LOG"; then
    fail "a refused auto-merge is not turned into a merge that skips the required checks"
fi

reset fork
export FAKE_FORK_PR=36
run || fail "merging beside a fork's pull request succeeds"
merged || fail "the repository's own pull request is merged, not the fork's"
if grep -Eq ' pr (merge|review|view) 36' "$FAKE_GH_LOG"; then fail "a fork's pull request from the same branch name is never used"; fi

reset fork-only
export FAKE_PR='' FAKE_FORK_PR=36
run || fail "opening beside a fork's pull request succeeds"
grep -Fq 'pr create --base 6.x-dev' "$FAKE_GH_LOG" || fail "a fork's pull request does not stop the real one being opened"
merged || fail "the pull request it opened is merged"

reset none
export FAKE_PR=''
git -C "$WORK/origin.git" branch -q -m automated/release-date-6.0.3 elsewhere
run || fail "no date branch is not a failure"
git -C "$WORK/origin.git" branch -q -m elsewhere automated/release-date-6.0.3
says 'does not exist' || fail "no date branch says so"
if grep -Fq 'pr create' "$FAKE_GH_LOG"; then fail "no pull request is opened without a date branch"; fi

reset stale
export FAKE_PR=''
git -C "$WORK/origin.git" branch -q -f automated/release-date-6.0.3 "$(git -c user.name=Test -c user.email=test@example.com -C "$WORK/origin.git" commit-tree -p "$TAGGED" -m later "$TAGGED^{tree}")"
run || fail "a date branch that moved on from the tag is not a failure"
git -C "$WORK/origin.git" branch -q -f automated/release-date-6.0.3 "$TAGGED"
says 'has moved on from the commit tagged 6.0.3' || fail "a moved date branch says why"
if grep -Fq 'pr create' "$FAKE_GH_LOG"; then fail "no pull request is opened only to be refused"; fi

reset merged-already
export FAKE_PR='' FAKE_AHEAD=0
run || fail "a date branch already merged is not a failure"
if grep -Fq 'pr create' "$FAKE_GH_LOG"; then fail "no pull request is opened for a date already merged"; fi

reset open
export FAKE_PR=''
run || fail "opening and merging succeeds"
grep -Fq 'pr create --base 6.x-dev --head automated/release-date-6.0.3' "$FAKE_GH_LOG" || fail "the pull request is opened"
merged || fail "the pull request it opened is merged"

reset files
export FAKE_FILES='CHANGELOG.md plugin.json'
run || fail "a pull request changing more is left open, not failed"
says 'it changes more than CHANGELOG.md (CHANGELOG.md plugin.json' || fail "the extra file is named"
if merged; then fail "a pull request changing more than CHANGELOG.md is never merged"; fi

reset api-error
export FAKE_PR='' FAKE_AHEAD=''
if run; then fail "a failed comparison fails the step rather than passing as nothing to do"; fi

reset moved
export FAKE_HEAD=0000000000000000000000000000000000000000
run || fail "a head other than the tagged commit is left open, not failed"
says 'its head is not the commit tagged 6.0.3' || fail "an untagged head says why"
if grep -Fq "pr merge" "$FAKE_GH_LOG"; then fail "only the tagged commit is merged"; fi

reset identity
export FAKE_COMMITS="$BOT_EMAIL:$BOT_EMAIL someone@example.com:$BOT_EMAIL"
run || fail "a pull request with another's commit is left open, not failed"
says 'commits from someone other than this workflow' || fail "another's commit says why"
if merged; then fail "a pull request with another's commit is never merged"; fi

# Amending the workflow's commit keeps its author, so only the committer gives it away.
reset committer
export FAKE_COMMITS="$BOT_EMAIL:someone@example.com"
run || fail "a pull request with another's amended commit is left open, not failed"
if merged; then fail "a pull request whose commit someone else amended is never merged"; fi

reset refused
export FAKE_AUTO_MERGE_ERROR='base branch policy prohibits the merge'
run || fail "a refused merge leaves the pull request open, not failed"
says 'left open for a person to merge: base branch policy prohibits the merge' || fail "the refusal is passed on"

reset review-required
export FAKE_REVIEW_DECISION=REVIEW_REQUIRED
run || fail "auto-merge waiting on a review is not a failure"
says 'is set to merge, but waits on a review (REVIEW_REQUIRED)' || fail "auto-merge waiting on a review warns"
labelled || fail "a pull request waiting on a review is labelled"
mentioned matomo-org/plugin-reviewers || fail "without an approver, a comment mentions matomo-org's plugin reviewers"
if grep -Fq -- '--method POST repos/matomo-org/plugin-TestPlugin/pulls/35/requested_reviewers' "$FAKE_GH_LOG"; then
    fail "the workflow's token, which cannot, does not request a team review"
fi
says 'No approver token, so matomo-org/plugin-reviewers was mentioned on #35' || fail "a mention in place of a review request warns"

reset mention-left-open
export FAKE_AUTO_MERGE_ERROR='base branch policy prohibits the merge'
run || fail "a pull request left open without an approver is not a failure"
mentioned matomo-org/plugin-reviewers || fail "a pull request left open without an approver mentions the team"

reset mention-premium
export FAKE_REVIEW_DECISION=REVIEW_REQUIRED
GITHUB_REPOSITORY=innocraft/plugin-TestPlugin run || fail "mentioning in innocraft is not a failure"
mentioned innocraft/premium-plugins-reviewers || fail "innocraft's premium plugin reviewers are mentioned"

reset mention-team
export FAKE_REVIEW_DECISION=REVIEW_REQUIRED RELEASE_REVIEWER_TEAM=core-team
run || fail "mentioning a chosen team is not a failure"
mentioned matomo-org/core-team || fail "reviewer-team picks the team mentioned"

reset mention-again
export FAKE_REVIEW_DECISION=REVIEW_REQUIRED FAKE_COMMENT='@matomo-org/plugin-reviewers please review and merge.'
run || fail "a pull request already mentioning the team is not a failure"
grep -Fq 'workflow-token api --paginate repos/matomo-org/plugin-TestPlugin/issues/35/comments' "$FAKE_GH_LOG" \
    || fail "the comments are read before mentioning the team"
if grep -Fq ' pr comment ' "$FAKE_GH_LOG"; then fail "a rerun does not mention the team again"; fi
says 'No approver token, so matomo-org/plugin-reviewers was mentioned on #35' || fail "a rerun still warns that the team was only mentioned"

reset mention-reviewed
export FAKE_REVIEW_DECISION=CHANGES_REQUESTED FAKE_REVIEWS=1
run || fail "a reviewed pull request without an approver is not a failure"
if grep -Fq ' pr comment ' "$FAKE_GH_LOG"; then fail "nobody is mentioned once someone has reviewed"; fi

reset mention-requested
export FAKE_REVIEW_DECISION=REVIEW_REQUIRED FAKE_REQUESTED=1
run || fail "a pull request with a reviewer requested is not a failure without an approver"
if grep -Fq ' pr comment ' "$FAKE_GH_LOG"; then fail "nobody is mentioned while a reviewer is requested"; fi

reset mention-unreadable
export FAKE_REVIEW_DECISION=REVIEW_REQUIRED FAKE_COMMENTS_ERROR='HTTP 502: Bad Gateway'
run || fail "unreadable comments are not a failure"
says 'Could not read the comments on #35: HTTP 502' || fail "unreadable comments warn"
if grep -Fq ' pr comment ' "$FAKE_GH_LOG"; then fail "nobody is mentioned when an earlier mention cannot be ruled out"; fi

reset mention-unknown-owner
export FAKE_REVIEW_DECISION=REVIEW_REQUIRED
GITHUB_REPOSITORY=someone/plugin-TestPlugin run || fail "an organisation with no known team is not a failure without an approver"
says 'No reviewer team is known for someone' || fail "an organisation with no known team warns without an approver"
if grep -Fq ' pr comment ' "$FAKE_GH_LOG"; then fail "no team is guessed to mention"; fi

reset mention-refused
export FAKE_REVIEW_DECISION=REVIEW_REQUIRED FAKE_COMMENT_ERROR='Resource not accessible by integration'
run || fail "a refused comment is not a failure"
says 'Could not mention matomo-org/plugin-reviewers on #35: Resource not accessible' || fail "a refused comment is passed on"

reset review-required-approved
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_DECISION=REVIEW_REQUIRED
run || fail "an approved pull request still waiting on a review is not a failure"
grep -Fq 'approver-token api --method POST repos/matomo-org/plugin-TestPlugin/pulls/35/reviews -f event=APPROVE' "$FAKE_GH_LOG" || fail "the approver approved before the review is requested"
requested plugin-reviewers || fail "the approver's own approval does not stop the team review being requested"

reset review-required-approved-merge-refused
export RELEASE_APPROVER_TOKEN=approver-token FAKE_AUTO_MERGE_ERROR='base branch policy prohibits the merge'
run || fail "an approved pull request refused the merge is not a failure"
requested plugin-reviewers || fail "an approved pull request left open requests the team review"

reset changes-requested
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_DECISION=CHANGES_REQUESTED FAKE_REVIEWS=1
run || fail "auto-merge waiting on requested changes is not a failure"
says 'is set to merge, but waits on a review (CHANGES_REQUESTED)' || fail "auto-merge waiting on requested changes warns"
labelled || fail "a pull request with changes requested is labelled"
if requested plugin-reviewers; then fail "the team is not asked again once someone has reviewed"; fi

reset decision-error
export FAKE_DECISION_ERROR='HTTP 502: Bad Gateway (50% of the time)'
run || fail "a failed review decision lookup is not a failure"
says 'Could not read whether #35 waits on an approving review: HTTP 502: Bad Gateway (50%25 of the time)' \
    || fail "a failed review decision lookup warns, with % escaped"

reset review-requested
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1
run || fail "requesting review on a pull request left open is not a failure"
labelled || fail "a pull request left open is labelled"
requested plugin-reviewers || fail "the approver requests review from matomo-org's plugin reviewers"
if grep -Fq ' pr comment ' "$FAKE_GH_LOG"; then fail "with an approver, the team is requested, not mentioned"; fi

reset review-premium
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1
GITHUB_REPOSITORY=innocraft/plugin-TestPlugin run || fail "requesting review in innocraft is not a failure"
grep -Fq 'approver-token api --method POST repos/innocraft/plugin-TestPlugin/pulls/35/requested_reviewers -f team_reviewers[]=premium-plugins-reviewers' "$FAKE_GH_LOG" \
    || fail "innocraft's premium plugin reviewers are requested"

reset review-unknown-owner
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1
GITHUB_REPOSITORY=someone/plugin-TestPlugin run || fail "an organisation with no known team is not a failure"
says 'No reviewer team is known for someone' || fail "an organisation with no known team warns"
if grep -Fq -- '--method POST repos/someone/plugin-TestPlugin/pulls/35/requested_reviewers' "$FAKE_GH_LOG"; then fail "no team is guessed"; fi

reset review-team
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1 RELEASE_REVIEWER_TEAM=core-team
run || fail "requesting a chosen team is not a failure"
requested core-team || fail "reviewer-team picks the team"

reset review-already-requested
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1 FAKE_REQUESTED=1
run || fail "a pull request with a reviewer requested is not a failure"
if grep -Fq -- '--method POST repos/matomo-org/plugin-TestPlugin/pulls/35/requested_reviewers' "$FAKE_GH_LOG"; then
    fail "nobody is notified again while a reviewer is requested"
fi

reset review-already-reviewed
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1 FAKE_REVIEWS=1
run || fail "a reviewed pull request is not a failure"
if grep -Fq -- '--method POST repos/matomo-org/plugin-TestPlugin/pulls/35/requested_reviewers' "$FAKE_GH_LOG"; then
    fail "nobody is notified again once someone has reviewed"
fi

reset review-refused
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1 FAKE_REQUEST_ERROR='Resource not accessible by integration'
run || fail "a refused review request leaves the pull request open, not failed"
says 'Could not request review from matomo-org/plugin-reviewers on #35: Resource not accessible' || fail "a refused review request is passed on"

echo 'All release date merge tests passed.'
