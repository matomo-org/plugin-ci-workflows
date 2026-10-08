#!/bin/bash
# Tests when the release date pull request is merged and when it is left open, with a fake gh CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/merge_plugin_release_date_pr.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GITHUB_REPOSITORY=matomo-org/plugin-TestPlugin
export GH_TOKEN=workflow-token
export MERGE_WAIT_SECONDS=0
BOT_EMAIL='github-actions[bot]@users.noreply.github.com'

FAKE_BIN="$WORK/bin"
mkdir "$FAKE_BIN"
# Each call is logged with the token it ran as, so a test can tell whose approval or merge it was.
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s %s\n' "$GH_TOKEN" "$*" >> "$FAKE_GH_LOG"
case "$*" in
    'pr list '*) if [[ -n "$FAKE_PR" ]]; then echo "$FAKE_PR"; elif [[ -f "$FAKE_GH_LOG.pr" ]]; then cat "$FAKE_GH_LOG.pr"; fi ;;
    'pr create '*) echo 35 > "$FAKE_GH_LOG.pr" ;;
    *'--jq .ahead_by') if [[ -z "$FAKE_AHEAD" ]]; then exit 1; fi; echo "$FAKE_AHEAD" ;;
    *'--json headRefOid'*) echo "$FAKE_HEAD" ;;
    *'--json files'*) printf '%s\n' $FAKE_FILES ;;
    *'/compare/'*) printf '%s\n' $FAKE_IDENTITIES ;;
    *'/actions/runs?'*) printf '%s\n' $FAKE_HELD_RUNS ;;
    *'/approve') ;;
    *'/check-runs'*) printf '%s\n' $FAKE_CHECKS ;;
    'pr review '*) exit "${FAKE_REVIEW_STATUS:-0}" ;;
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

# A pull request that is safe to merge, with its checks finished; each test changes one thing.
reset() {
    export FAKE_GH_LOG="$WORK/$1.log" OUT="$WORK/$1.out"
    : > "$FAKE_GH_LOG"
    export FAKE_PR=35 FAKE_FILES=CHANGELOG.md FAKE_IDENTITIES="$BOT_EMAIL" FAKE_HELD_RUNS='' FAKE_CHECKS='success success' FAKE_AHEAD=1 FAKE_HEAD="$TAGGED"
    unset FAKE_REVIEW_STATUS FAKE_MERGE_ERROR RELEASE_APPROVER_TOKEN
}

run() {
    (cd "$WORK/clone" && bash "$SCRIPT" 6.x-dev 6.0.3) > "$OUT" 2>&1
}

says() {
    grep -Fq "$1" "$OUT"
}

merged() {
    grep -q " pr merge 35 --merge --match-head-commit $TAGGED$" "$FAKE_GH_LOG"
}

reset merge
export FAKE_HELD_RUNS='101 102'
run || fail "merging succeeds"
grep -Fq 'workflow-token api -X POST repos/matomo-org/plugin-TestPlugin/actions/runs/101/approve' "$FAKE_GH_LOG" \
    || fail "the first held run is approved"
grep -Fq '/actions/runs/102/approve' "$FAKE_GH_LOG" || fail "every held run is approved"
grep -Fq "api --paginate repos/matomo-org/plugin-TestPlugin/commits/$TAGGED/check-runs?per_page=100" "$FAKE_GH_LOG" \
    || fail "every page of checks is read"
grep -q '^workflow-token pr merge 35 ' "$FAKE_GH_LOG" || fail "without an approver, the workflow's token merges"
grep -Fq 'pr list --head automated/release-date-6.0.3 --base 6.x-dev' "$FAKE_GH_LOG" || fail "the version's branch into the base is looked up"
if grep -Fq 'pr review' "$FAKE_GH_LOG"; then fail "without an approver nothing approves the pull request"; fi

reset approver
export RELEASE_APPROVER_TOKEN=approver-token
run || fail "merging with the approver succeeds"
grep -q '^approver-token pr review 35 --approve' "$FAKE_GH_LOG" || fail "the approver approves"
grep -q "^approver-token pr merge 35 --merge --match-head-commit $TAGGED$" "$FAKE_GH_LOG" || fail "the approver merges"

reset approver-refused
export RELEASE_APPROVER_TOKEN=approver-token FAKE_REVIEW_STATUS=1
run || fail "a refused approval leaves the pull request open, not failed"
says '::warning::Release date pull request #35 was left open' || fail "a refused approval warns"
if merged; then fail "nothing is merged after a refused approval"; fi

reset none
export FAKE_PR=''
git -C "$WORK/origin.git" branch -q -m automated/release-date-6.0.3 elsewhere
run || fail "no date branch is not a failure"
git -C "$WORK/origin.git" branch -q -m elsewhere automated/release-date-6.0.3
says 'does not exist' || fail "no date branch says so"
if grep -Fq 'pr create' "$FAKE_GH_LOG"; then fail "no pull request is opened without a date branch"; fi

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
export FAKE_IDENTITIES="$BOT_EMAIL someone@example.com"
run || fail "a pull request with another's commit is left open, not failed"
says 'commits from someone other than this workflow' || fail "another's commit says why"
if merged; then fail "a pull request with another's commit is never merged"; fi

reset failed
export FAKE_CHECKS='success success failure'
run || fail "a failed check leaves the pull request open, not failed"
says 'a check on it failed' || fail "a failed check says why"
if merged; then fail "a pull request with a failed check is never merged"; fi

reset pending
export FAKE_CHECKS='success success pending'
run || fail "a check still running at the deadline leaves the pull request open, not failed"
says 'had not finished after 0s' || fail "the timeout says why"
if merged; then fail "a pull request with a running check is never merged"; fi

reset no-checks
export FAKE_CHECKS=''
run || fail "no checks at the deadline leaves the pull request open, not failed"
if merged; then fail "a pull request with no checks yet is not merged"; fi

reset refused
export FAKE_MERGE_ERROR='base branch policy prohibits the merge'
run || fail "a refused merge leaves the pull request open, not failed"
says 'left open for a person to merge: base branch policy prohibits the merge' || fail "the refusal is passed on"

echo 'All release date merge tests passed.'
