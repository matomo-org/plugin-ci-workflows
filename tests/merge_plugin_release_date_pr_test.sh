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
    'pr view '*'--json headRefOid'*) jq -n --arg h "$FAKE_HEAD" '{headRefOid: $h}' | filter ;;
    'pr view '*'--json files'*) jq -n '{files: ($ARGS.positional | map({path: .}))}' --args $FAKE_FILES | filter ;;
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
    'pr review '*) exit "${FAKE_REVIEW_STATUS:-0}" ;;
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
    rm -f "$FAKE_GH_LOG.listed"
    export FAKE_PR=35 FAKE_FILES=CHANGELOG.md FAKE_COMMITS="$BOT_EMAIL:$BOT_EMAIL" FAKE_RUNS='' FAKE_AHEAD=1 FAKE_HEAD="$TAGGED"
    unset FAKE_REVIEW_STATUS FAKE_AUTO_MERGE_ERROR FAKE_MERGE_ERROR RELEASE_APPROVER_TOKEN FAKE_FORK_PR
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
if grep -Fq 'pr review' "$FAKE_GH_LOG"; then fail "without an approver nothing approves the pull request"; fi

reset late-runs
export FAKE_RUNS='101:action_required' FAKE_LATE_RUNS='104:action_required'
RUNS_WAIT_SECONDS=1 RUNS_POLL_SECONDS=1 run || fail "merging with a late run succeeds"
unset FAKE_LATE_RUNS
grep -Fq '/actions/runs/104/approve' "$FAKE_GH_LOG" || fail "a held run that appears after the first is approved"
[[ "$(grep -c '/actions/runs/101/approve' "$FAKE_GH_LOG")" == 1 ]] || fail "a held run is approved once"

reset approver
export RELEASE_APPROVER_TOKEN=approver-token
run || fail "merging with the approver succeeds"
grep -q '^approver-token pr review 35 --approve' "$FAKE_GH_LOG" || fail "the approver approves"
grep -q "^approver-token pr merge 35 --merge --match-head-commit $TAGGED --auto$" "$FAKE_GH_LOG" || fail "the approver merges"

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
git -C "$WORK/origin.git" branch -q -f automated/release-date-6.0.3 "$(git -C "$WORK/origin.git" commit-tree -p "$TAGGED" -m later "$TAGGED^{tree}")"
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

echo 'All release date merge tests passed.'
