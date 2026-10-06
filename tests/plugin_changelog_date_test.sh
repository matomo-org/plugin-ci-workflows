#!/bin/bash
# Tests the changelog date check and the release date pull request with a bare origin and a fake gh CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/bash/check_plugin_changelog_date.sh"
OPEN="$ROOT/scripts/bash/open_plugin_changelog_date_pr.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PLUGIN_RELEASE_TODAY=2026-10-12
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

FAKE_BIN="$WORK/bin"
mkdir "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == "pr list" && " $* " != *" --base "* ]]; then
    # Listing a head's open pull requests prints their bases.
    for base in ${FAKE_GH_HEAD_BASES:-}; do echo "$base"; done
elif [[ "$1 $2" == "pr list" ]]; then
    # The base is the argument after --base.
    for (( i = 1; i <= $#; i++ )); do
        if [[ "${!i}" == --base ]]; then
            j=$((i + 1))
            [[ " ${FAKE_GH_OPEN_BASES:-} " == *" ${!j} "* ]] && echo 7
        fi
    done
fi
exit 0
SH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

# Builds <name>/origin.git with 6.x-prod and 6.x-dev, and a clone of <branch> at <name>/clone.
new_repo() {
    local name="$1" changelog_line="$2" branch="${3:-6.x-dev}"
    local seed="$WORK/$name/seed"
    mkdir -p "$seed"
    git init -q "$seed"
    printf '{"name":"TestPlugin","version":"6.0.3"}\n' > "$seed/plugin.json"
    printf '## Changelog\n\n%s\n* 6.0.2 - 2026-10-05 - Two\n' "$changelog_line" > "$seed/CHANGELOG.md"
    git -C "$seed" add plugin.json CHANGELOG.md
    git -C "$seed" commit -q -m initial
    git -C "$seed" branch -M 6.x-prod
    git -C "$seed" branch 6.x-dev
    git clone -q --bare "$seed" "$WORK/$name/origin.git"
    git clone -q --branch "$branch" "$WORK/$name/origin.git" "$WORK/$name/clone"
    export FAKE_GH_LOG="$WORK/$name/gh.log"
    : > "$FAKE_GH_LOG"
}

run_check() {
    (cd "$WORK/$1/clone" && bash "$CHECK" "${2:-6.x-prod}") > "$WORK/$1/out" 2>&1
}

run_open() {
    local name="$1"
    shift
    (cd "$WORK/$name/clone" && bash "$OPEN" "$@") > "$WORK/$name/out" 2>&1
}

origin_changelog_line() {
    git -C "$WORK/$1/origin.git" show "automated/release-date-6.0.3:CHANGELOG.md" | sed -n 3p
}

new_repo dated '* 6.0.3 - 2026-10-12 - Three'
run_check dated || fail "an entry dated today passes"

new_repo undated '* 6.0.3 Three'
if run_check undated; then fail "an undated entry fails"; fi
grep -Fq 'has no release date' "$WORK/undated/out" || fail "an undated entry says so"

new_repo stale '* 6.0.3 - 2026-10-11 - Three'
if run_check stale; then fail "an entry dated yesterday fails"; fi
grep -Fq 'dated 2026-10-11, not today' "$WORK/stale/out" || fail "a stale entry names both dates"

new_repo released-check '* 6.0.3 - 2026-10-05 - Three'
git -C "$WORK/released-check/origin.git" tag 6.0.3 6.x-prod
run_check released-check || fail "a version that is already tagged passes, whatever its date"

new_repo wrong-major '* 6.0.3 - 2026-10-12 - Three'
if run_check wrong-major 5.x-prod; then fail "a 6.x version into 5.x-prod fails"; fi
grep -Fq 'does not belong on 5.x-prod' "$WORK/wrong-major/out" || fail "a wrong major names the branch"
run_check wrong-major 6.x-dev || fail "a branch other than N.x-prod is not checked for its major"

new_repo prerelease '* 6.0.3-rc1 - 2026-10-12 - Three'
printf '{"name":"TestPlugin","version":"6.0.3-rc1"}\n' > "$WORK/prerelease/clone/plugin.json"
if run_check prerelease; then fail "a prerelease version into 6.x-prod fails"; fi
grep -Fq 'not a stable release version' "$WORK/prerelease/out" || fail "a prerelease says why it fails"
git -C "$WORK/prerelease/origin.git" tag 6.0.3-rc1 6.x-prod
if run_check prerelease; then fail "a tagged prerelease into 6.x-prod still fails"; fi
run_open prerelease 6.x-dev "" 6.x-prod || fail "a prerelease into 6.x-prod is skipped, not failed"
git -C "$WORK/prerelease/origin.git" tag -d 6.0.3-rc1 > /dev/null
run_open prerelease 6.x-dev "" 6.x-prod || fail "an untagged prerelease into 6.x-prod is skipped, not failed"
grep -Fq 'cannot be released from 6.x-prod' "$WORK/prerelease/out" || fail "the skipped prerelease says why"
if git -C "$WORK/prerelease/origin.git" rev-parse --verify -q automated/release-date-6.0.3-rc1 > /dev/null; then
    fail "a version the production branch would refuse is never dated"
fi

new_repo to-dev '* 6.0.3 Three'
run_open to-dev 6.x-dev || { cat "$WORK/to-dev/out" >&2; fail "dating the development branch succeeds"; }
[[ "$(origin_changelog_line to-dev)" == '* 6.0.3 - 2026-10-12 - Three' ]] || fail "the branch carries today's date"
[[ "$(git -C "$WORK/to-dev/origin.git" log -1 --format=%ae automated/release-date-6.0.3)" == 'github-actions[bot]@users.noreply.github.com' ]] \
    || fail "the date commit is the workflow's"
grep -Fq 'pr create --base 6.x-dev --head automated/release-date-6.0.3' "$FAKE_GH_LOG" || fail "a pull request into 6.x-dev is opened"
[[ "$(grep -c 'pr create' "$FAKE_GH_LOG")" == 1 ]] || fail "only the development branch gets a pull request"

new_repo to-prod '* 6.0.3 - 2026-10-11 - Three' 6.x-prod
DATE_PR_RESULT_FILE="$WORK/to-prod/result" run_open to-prod 6.x-prod \
    || { cat "$WORK/to-prod/out" >&2; fail "dating the production branch succeeds"; }
[[ "$(cat "$WORK/to-prod/result")" == opened ]] || fail "opening the pull requests is reported"
grep -Fq 'pr create --base 6.x-prod --head automated/release-date-6.0.3' "$FAKE_GH_LOG" || fail "a pull request into 6.x-prod is opened"
grep -Fq 'pr create --base 6.x-dev --head automated/release-date-6.0.3' "$FAKE_GH_LOG" || fail "the same branch is proposed for 6.x-dev"

new_repo refresh '* 6.0.3 Three'
export FAKE_GH_OPEN_BASES=6.x-dev
DATE_PR_RESULT_FILE="$WORK/refresh/result" run_open refresh 6.x-dev 2026-10-13 || fail "refreshing an open pull request succeeds"
[[ "$(cat "$WORK/refresh/result")" == opened ]] || fail "a refreshed pull request is reported"
unset FAKE_GH_OPEN_BASES
[[ "$(origin_changelog_line refresh)" == '* 6.0.3 - 2026-10-13 - Three' ]] || fail "an explicit date is written"
if grep -Fq 'pr create' "$FAKE_GH_LOG"; then fail "an open pull request is not duplicated"; fi
grep -Fq 'Pull request #7 into 6.x-dev' "$WORK/refresh/out" || fail "the open pull request is reported"

new_repo already-dated '* 6.0.3 - 2026-10-12 - Three'
run_open already-dated 6.x-dev || fail "an entry already dated today succeeds"
if git -C "$WORK/already-dated/origin.git" rev-parse --verify -q automated/release-date-6.0.3 > /dev/null; then
    fail "nothing is pushed when the entry is already dated"
fi

new_repo released '* 6.0.3 - 2026-10-05 - Three'
git -C "$WORK/released/origin.git" tag 6.0.3 6.x-prod
run_open released 6.x-dev || fail "a released version is skipped, not failed"
grep -Fq 'already released' "$WORK/released/out" || fail "a released version says why it is skipped"
if git -C "$WORK/released/origin.git" rev-parse --verify -q automated/release-date-6.0.3 > /dev/null; then
    fail "a released version is never re-dated"
fi

new_repo hand-edited '* 6.0.3 Three'
git -C "$WORK/hand-edited/clone" switch -q -c automated/release-date-6.0.3
printf 'note\n' >> "$WORK/hand-edited/clone/CHANGELOG.md"
git -C "$WORK/hand-edited/clone" commit -q -am 'a human edit'
git -C "$WORK/hand-edited/clone" push -q origin automated/release-date-6.0.3
HAND_COMMIT=$(git -C "$WORK/hand-edited/clone" rev-parse HEAD)
git -C "$WORK/hand-edited/clone" switch -q 6.x-dev
DATE_PR_RESULT_FILE="$WORK/hand-edited/result" run_open hand-edited 6.x-dev || fail "a branch with a human commit is skipped, not failed"
[[ ! -s "$WORK/hand-edited/result" ]] || fail "a skipped branch is not reported as opened"
[[ "$(git -C "$WORK/hand-edited/origin.git" rev-parse automated/release-date-6.0.3)" == "$HAND_COMMIT" ]] \
    || fail "a human commit on the branch is never overwritten"

new_repo amended '* 6.0.3 Three'
git -C "$WORK/amended/clone" switch -q -c automated/release-date-6.0.3
printf 'note\n' >> "$WORK/amended/clone/CHANGELOG.md"
GIT_AUTHOR_NAME="github-actions[bot]" GIT_AUTHOR_EMAIL="github-actions[bot]@users.noreply.github.com" \
    git -C "$WORK/amended/clone" commit -q -am 'an amended date commit'
git -C "$WORK/amended/clone" push -q origin automated/release-date-6.0.3
AMENDED_COMMIT=$(git -C "$WORK/amended/clone" rev-parse HEAD)
git -C "$WORK/amended/clone" switch -q 6.x-dev
run_open amended 6.x-dev || fail "a branch with an amended commit is skipped, not failed"
[[ "$(git -C "$WORK/amended/origin.git" rev-parse automated/release-date-6.0.3)" == "$AMENDED_COMMIT" ]] \
    || fail "a commit someone else committed is never overwritten, whoever authored it"
grep -Fq 'has commits from someone other than this workflow' "$WORK/amended/out" || fail "an amended commit says why it is skipped"

new_repo own-branch '* 6.0.3 Three'
git -C "$WORK/own-branch/clone" switch -q -c automated/release-date-6.0.3
printf 'note\n' >> "$WORK/own-branch/clone/CHANGELOG.md"
GIT_AUTHOR_NAME="github-actions[bot]" GIT_AUTHOR_EMAIL="github-actions[bot]@users.noreply.github.com" \
    GIT_COMMITTER_NAME="github-actions[bot]" GIT_COMMITTER_EMAIL="github-actions[bot]@users.noreply.github.com" \
    git -C "$WORK/own-branch/clone" commit -q -am 'an earlier date commit'
git -C "$WORK/own-branch/clone" push -q origin automated/release-date-6.0.3
git -C "$WORK/own-branch/clone" switch -q 6.x-dev
run_open own-branch 6.x-dev 2026-10-13 || { cat "$WORK/own-branch/out" >&2; fail "the workflow's own branch is refreshed"; }
[[ "$(origin_changelog_line own-branch)" == '* 6.0.3 - 2026-10-13 - Three' ]] || fail "the refreshed branch carries the new date"

new_repo other-base '* 6.0.3 Three'
git -C "$WORK/other-base/clone" push -q origin origin/6.x-prod:refs/heads/automated/release-date-6.0.3
PROD_TIP=$(git -C "$WORK/other-base/origin.git" rev-parse 6.x-prod)
export FAKE_GH_HEAD_BASES=6.x-prod
DATE_PR_RESULT_FILE="$WORK/other-base/result" run_open other-base 6.x-dev || fail "a branch proposed for another base is skipped, not failed"
[[ ! -s "$WORK/other-base/result" ]] || fail "a branch proposed for another base is not reported as opened"
unset FAKE_GH_HEAD_BASES
[[ "$(git -C "$WORK/other-base/origin.git" rev-parse automated/release-date-6.0.3)" == "$PROD_TIP" ]] \
    || fail "a branch proposed for production is never rebuilt on development"
grep -Fq 'is proposed for 6.x-prod' "$WORK/other-base/out" || fail "the skipped base is named"

new_repo same-base '* 6.0.3 Three' 6.x-prod
git -C "$WORK/same-base/clone" push -q origin 6.x-prod:refs/heads/automated/release-date-6.0.3
export FAKE_GH_HEAD_BASES="6.x-prod 6.x-dev" FAKE_GH_OPEN_BASES="6.x-prod 6.x-dev"
run_open same-base 6.x-prod || { cat "$WORK/same-base/out" >&2; fail "a branch proposed for the same bases is refreshed"; }
unset FAKE_GH_HEAD_BASES FAKE_GH_OPEN_BASES
[[ "$(origin_changelog_line same-base)" == '* 6.0.3 - 2026-10-12 - Three' ]] || fail "the refreshed branch carries today's date"

echo 'All changelog date tests passed.'
