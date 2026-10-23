#!/bin/bash
# Tests the development release's preparation, dating, tagging and release date check with a bare
# origin and a fake gh CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASH_SCRIPTS="$ROOT/scripts/bash"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PLUGIN_RELEASE_TODAY=2026-10-12
export RELEASE_CI_WAIT_MINUTES=0
export GITHUB_REPOSITORY=matomo-org/plugin-TestPlugin
# On a runner prepare would write its outputs there, where the assertions below cannot see them.
unset GITHUB_OUTPUT
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
BOT=(GIT_AUTHOR_NAME="github-actions[bot]" GIT_AUTHOR_EMAIL="github-actions[bot]@users.noreply.github.com"
    GIT_COMMITTER_NAME="github-actions[bot]" GIT_COMMITTER_EMAIL="github-actions[bot]@users.noreply.github.com")

FAKE_BIN="$WORK/bin"
mkdir "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == "pr list" && " $* " != *" --base "* ]]; then
    # Listing a head's open pull requests runs the real --jq filter, the last argument, over them.
    prs='[]'
    for base in ${FAKE_GH_HEAD_BASES:-}; do
        prs=$(jq -c --arg b "$base" '. + [{baseRefName: $b, isCrossRepository: false}]' <<< "$prs")
    done
    for base in ${FAKE_GH_FORK_BASES:-}; do
        prs=$(jq -c --arg b "$base" '. + [{baseRefName: $b, isCrossRepository: true}]' <<< "$prs")
    done
    jq -r "${*: -1}" <<< "$prs"
elif [[ "$1 $2" == "pr list" && -n "${FAKE_GH_OPEN_PR:-}" ]]; then
    echo "$FAKE_GH_OPEN_PR"
elif [[ "$*" == *'/actions/runs?'* ]]; then
    # FAKE_GH_RUNS is workflow:id:status:conclusion:name entries, FAKE_GH_RUNS_ERROR a failed read.
    if [[ -n "${FAKE_GH_RUNS_ERROR:-}" ]]; then
        echo "$FAKE_GH_RUNS_ERROR" >&2
        exit 1
    fi
    # FAKE_GH_RUNS_LATER replaces FAKE_GH_RUNS from the second listing on.
    runs="${FAKE_GH_RUNS:-}"
    if [[ -f "$FAKE_GH_LOG.listed" ]]; then runs="${FAKE_GH_RUNS_LATER:-$runs}"; fi
    : > "$FAKE_GH_LOG.listed"
    jq -nc '{workflow_runs: ($ARGS.positional | map(split(":")) | map({workflow_id: (.[0] | tonumber),
        id: (.[1] | tonumber), status: .[2], conclusion: (if .[3] == "" then null else .[3] end), name: .[4]}))}' \
        --args $runs | jq -r "${*: -1}"
elif [[ "$*" == *'/releases/tags/'* ]]; then
    # FAKE_GH_RELEASES is tag:prerelease pairs; a tag not listed has no release, which the API reports as a 404.
    args="$*"
    tag="${args##*/releases/tags/}"
    release=$(jq -nc --arg t "${tag%% *}" '($ARGS.positional | map(split(":")) | map(select(.[0] == $t))[0] // empty)
        | {tag_name: .[0], prerelease: (.[1] == "true")}' --args ${FAKE_GH_RELEASES:-})
    [[ -n "$release" ]] || exit 1
    jq -r "${*: -1}" <<< "$release"
fi
exit 0
SH
# Records the CI wait instead of sleeping through it.
cat > "$FAKE_BIN/sleep" <<'SH'
#!/bin/bash
printf 'sleep %s\n' "$*" >> "$FAKE_GH_LOG"
SH
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/sleep"
export PATH="$FAKE_BIN:$PATH"

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

# Builds <name>/origin.git with 6.x-dev, and a clone of it at <name>/clone. The plugin calls the
# weekly release unless a third argument says otherwise.
new_repo() {
    local name="$1" changelog_line="$2" calls_release="${3:-yes}"
    local seed="$WORK/$name/seed"
    mkdir -p "$seed/.github/workflows"
    git init -q "$seed"
    printf '{"name":"TestPlugin","version":"6.0.3"}\n' > "$seed/plugin.json"
    printf '## Changelog\n\n%s\n* 6.0.2 - 2026-10-05 - Two\n' "$changelog_line" > "$seed/CHANGELOG.md"
    if [[ "$calls_release" == yes ]]; then
        printf 'jobs:\n  release:\n    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-dev-release.yml@main\n' \
            > "$seed/.github/workflows/release.yml"
    elif [[ "$calls_release" == commented ]]; then
        printf 'jobs:\n  release:\n    # uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-dev-release.yml@main\n    runs-on: ubuntu-24.04\n' \
            > "$seed/.github/workflows/release.yml"
    else
        printf 'jobs: {}\n' > "$seed/.github/workflows/ci.yml"
    fi
    git -C "$seed" add .
    git -C "$seed" commit -q -m initial
    git -C "$seed" branch -M 6.x-dev
    git clone -q --bare "$seed" "$WORK/$name/origin.git"
    git clone -q --branch 6.x-dev "$WORK/$name/origin.git" "$WORK/$name/clone"
    export FAKE_GH_LOG="$WORK/$name/gh.log"
    : > "$FAKE_GH_LOG"
}

set_version() {
    printf '{"name":"TestPlugin","version":"%s"}\n' "$2" > "$WORK/$1/clone/plugin.json"
}

run() {
    local name="$1" script="$2"
    shift 2
    (cd "$WORK/$name/clone" && bash "$BASH_SCRIPTS/$script" "$@") > "$WORK/$name/out" 2>&1
}

says() {
    grep -Fq "$2" "$WORK/$1/out"
}

origin_has() {
    git -C "$WORK/$1/origin.git" rev-parse --verify -q "$2" > /dev/null
}

date_branch_line() {
    git -C "$WORK/$1/origin.git" show "automated/release-date-6.0.3:CHANGELOG.md" | sed -n 3p
}

# --- prepare_plugin_dev_release.sh ---

new_repo prepare '* 6.0.3 Unreleased - Three'
run prepare prepare_plugin_dev_release.sh refs/heads/6.x-dev || { cat "$WORK/prepare/out" >&2; fail "an unreleased version is prepared"; }
says prepare 'release_needed=true' || fail "an unreleased version is released"
if ! { says prepare 'version=6.0.3' && says prepare 'plugin_name=TestPlugin' && says prepare 'today=2026-10-12'; }; then
    fail "preparation reports the version, the name and the day"
fi
# The workflow reads the outputs from the runner's file, not stdout.
GITHUB_OUTPUT="$WORK/prepare/gh_output" run prepare prepare_plugin_dev_release.sh refs/heads/6.x-dev \
    || fail "an unreleased version is prepared on a runner"
if ! grep -qx 'release_needed=true' "$WORK/prepare/gh_output" || ! grep -qx 'version=6.0.3' "$WORK/prepare/gh_output" \
    || says prepare 'release_needed='; then
    fail "on a runner the outputs go to its output file"
fi

new_repo prepare-tagged '* 6.0.3 - 2026-10-05 - Three'
git -C "$WORK/prepare-tagged/origin.git" tag 6.0.3 6.x-dev
run prepare-tagged prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a released version is skipped, not failed"
says prepare-tagged 'release_needed=false' || fail "a released version is not released again"
says prepare-tagged 'publish_needed=false' || fail "a version tagged another way is not published"

# A run that tagged the dated commit and then failed is resumed from that tag by the next run.
new_repo prepare-resume '* 6.0.3 - Three'
run prepare-resume push_plugin_release_date.sh 6.x-dev 2026-10-05 || fail "dating for the resume succeeds"
git -C "$WORK/prepare-resume/clone" tag 6.0.3
git -C "$WORK/prepare-resume/clone" push -q origin refs/tags/6.0.3
git -C "$WORK/prepare-resume/clone" checkout -q -B 6.x-dev origin/6.x-dev
run prepare-resume prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "an unpublished tag is resumed, not failed"
if ! { says prepare-resume 'release_needed=false' && says prepare-resume 'publish_needed=true' \
    && says prepare-resume 'finish=6.0.3:2026-10-05'; }; then
    fail "an unpublished tag is published with the tag's date, without tagging again"
fi
export FAKE_GH_RELEASES=6.0.3:true
run prepare-resume prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a prerelease is resumed, not failed"
says prepare-resume 'finish=6.0.3:2026-10-05' || fail "a release left as a prerelease is resumed"
export FAKE_GH_RELEASES=6.0.3:false
run prepare-resume prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a published release is resumed, not failed"
says prepare-resume 'publish_needed=true' || fail "a published release whose date is not merged is resumed"
# However the date reached the branch, squashed included, the release is then finished.
git -C "$WORK/prepare-resume/clone" checkout -q 6.0.3 -- CHANGELOG.md
run prepare-resume prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a finished release is skipped, not failed"
unset FAKE_GH_RELEASES
says prepare-resume 'publish_needed=false' || fail "a published release with its date merged is not resumed"

# A version tagged by a run that then failed is still finished once plugin.json has moved on.
# Builds <name> with 6.0.3 dated 2026-10-05 and tagged, by the workflow unless a second argument
# says otherwise, and plugin.json moved on to an undated 6.0.4.
new_earlier() {
    local name="$1" by="${2:-workflow}" clone="$WORK/$1/clone"
    new_repo "$name" '* 6.0.3 - Three'
    if [[ "$by" == workflow ]]; then
        run "$name" push_plugin_release_date.sh 6.x-dev 2026-10-05 || fail "dating the earlier version succeeds"
    else
        # Every other value commits as the bot, forging the workflow's date commit in that way.
        local as=()
        [[ "$by" == human ]] || as=("${BOT[@]}")
        git -C "$clone" switch -q -c automated/release-date-6.0.3
        if [[ "$by" == unreviewed-parent ]]; then
            printf 'unreviewed\n' > "$clone/extra.php"
            git -C "$clone" add extra.php
            git -C "$clone" commit -q -m 'an unreviewed commit'
        fi
        sed -i 's/6.0.3 - Three/6.0.3 - 2026-10-05 - Three/' "$clone/CHANGELOG.md"
        if [[ "$by" == extra-file ]]; then
            printf 'unreviewed\n' > "$clone/extra.php"
            git -C "$clone" add extra.php
        fi
        if [[ "$by" == merge ]]; then
            git -C "$clone" switch -q -c side
            git -C "$clone" commit -q -am 'a side commit'
            git -C "$clone" switch -q automated/release-date-6.0.3
            env "${as[@]}" git -C "$clone" merge -q --no-ff -m 'Add release date for 6.0.3' side
        else
            env "${as[@]}" git -C "$clone" commit -q -am 'Add release date for 6.0.3'
        fi
        git -C "$clone" push -q origin automated/release-date-6.0.3
    fi
    git -C "$clone" tag 6.0.3
    git -C "$clone" push -q origin refs/tags/6.0.3
    git -C "$clone" checkout -q -B 6.x-dev origin/6.x-dev
    sed -i 's/^\* 6.0.3 - Three$/* 6.0.4 - Four\n&/' "$clone/CHANGELOG.md"
    set_version "$name" 6.0.4
}

new_earlier prepare-earlier
run prepare-earlier prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "an earlier unfinished version is resumed, not failed"
if ! { says prepare-earlier 'release_needed=true' && says prepare-earlier 'version=6.0.4' \
    && says prepare-earlier 'finish=6.0.3:2026-10-05 6.0.4:2026-10-12'; }; then
    fail "an earlier unfinished version is finished first, then plugin.json's is released"
fi
! says prepare-earlier 'tag carries this workflow' || fail "the workflow's own date commit is not warned about"
rm -f "$FAKE_GH_LOG.listed"
held_finishes_earlier() {
    if ! { says prepare-earlier 'finish=6.0.3:2026-10-05' && ! says prepare-earlier 'finish=6.0.3:2026-10-05 6.0.4' \
        && says prepare-earlier 'ci_held=6.0.4 is not released from'; }; then
        fail "$1 still finishes the earlier version"
    fi
}
FAKE_GH_RUNS='11:500:completed:failure:Plugins-CI' run prepare-earlier prepare_plugin_dev_release.sh refs/heads/6.x-dev \
    || fail "a CI hold with an earlier version to finish is not failed"
held_finishes_earlier "a CI hold"
FAKE_GH_RUNS_ERROR=$'error connecting to api.github.com\ncheck your internet connection' \
    run prepare-earlier prepare_plugin_dev_release.sh refs/heads/6.x-dev \
    || fail "unreadable CI runs with an earlier version to finish are not failed"
held_finishes_earlier "unreadable CI runs"
grep -q '^ci_held=.*(error connecting to api.github.com check your internet connection )' "$WORK/prepare-earlier/out" \
    || fail "a gh error over several lines is held on one output line"

mkdir "$WORK/prepare-earlier/bin"
cat > "$WORK/prepare-earlier/bin/git" <<SH
#!/bin/bash
[[ "\$1" == fetch ]] && exit 128
exec $(command -v git) "\$@"
SH
chmod +x "$WORK/prepare-earlier/bin/git"
if PATH="$WORK/prepare-earlier/bin:$PATH" run prepare-earlier prepare_plugin_dev_release.sh refs/heads/6.x-dev; then
    fail "a tag that cannot be fetched fails rather than passing as someone else's"
fi
says prepare-earlier 'Could not fetch the 6.0.3 tag' || fail "a failed tag fetch says so"

new_earlier prepare-earlier-done
sed -i 's/6.0.3 - Three/6.0.3 - 2026-10-05 - Three/' "$WORK/prepare-earlier-done/clone/CHANGELOG.md"
export FAKE_GH_RELEASES=6.0.3:false
run prepare-earlier-done prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "an earlier finished version is skipped, not failed"
unset FAKE_GH_RELEASES
says prepare-earlier-done 'finish=6.0.4:2026-10-12' || fail "an earlier finished version is not resumed"

new_earlier prepare-earlier-human human
run prepare-earlier-human prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "an earlier version tagged by a person is skipped, not failed"
says prepare-earlier-human 'finish=6.0.4:2026-10-12' || fail "an earlier version tagged by a person is never published by the workflow"

for forged in extra-file unreviewed-parent merge; do
    new_earlier "prepare-forged-$forged" "$forged"
    run "prepare-forged-$forged" prepare_plugin_dev_release.sh refs/heads/6.x-dev \
        || fail "a forged date commit ($forged) is skipped, not failed"
    says "prepare-forged-$forged" 'finish=6.0.4:2026-10-12' \
        || fail "a commit only dressed as the workflow's ($forged) is never published"
    says "prepare-forged-$forged" 'The 6.0.3 tag carries this workflow' || fail "a rejected forged tag ($forged) says so"
done

new_repo prepare-prerelease '* 6.0.3-rc1 - Three'
set_version prepare-prerelease 6.0.3-rc1
run prepare-prerelease prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a prerelease is skipped, not failed"
says prepare-prerelease 'release_needed=false' || fail "a prerelease is not released"

new_repo prepare-major '* 5.0.3 - Three'
set_version prepare-major 5.0.3
if run prepare-major prepare_plugin_dev_release.sh refs/heads/6.x-dev; then fail "a 5.x version on 6.x-dev fails"; fi
says prepare-major 'does not belong on 6.x-dev' || fail "a wrong major names the branch"

new_repo prepare-branch '* 6.0.3 - Three'
if run prepare-branch prepare_plugin_dev_release.sh refs/heads/6.x-prod; then fail "a branch other than N.x-dev fails"; fi
if run prepare-branch prepare_plugin_dev_release.sh refs/tags/6.x-dev; then fail "a tag named like the branch fails"; fi
says prepare-branch 'Unsupported release ref: refs/tags/6.x-dev' || fail "a tag ref says why"
if run prepare-branch prepare_plugin_dev_release.sh refs/heads/main; then fail "main fails without release-branch"; fi
says prepare-branch 'Unsupported release ref: refs/heads/main' || fail "main without release-branch says why"

# A bundle releases from main, versioned apart from Matomo. 1.0.3 was dated and tagged by a run that
# then failed, and plugin.json has moved on to 1.0.4.
new_repo prepare-release-branch '* 1.0.3 - Three'
release_clone="$WORK/prepare-release-branch/clone"
set_version prepare-release-branch 1.0.3
git -C "$release_clone" commit -q -am 'Release 1.0.3'
git -C "$release_clone" push -q origin HEAD:main
git -C "$release_clone" checkout -q -B main origin/main
run prepare-release-branch push_plugin_release_date.sh main 2026-10-05 || fail "dating 1.0.3 on main succeeds"
git -C "$release_clone" tag 1.0.3
git -C "$release_clone" push -q origin refs/tags/1.0.3
git -C "$release_clone" checkout -q -B main origin/main
sed -i 's/^\* 1.0.3 - Three$/* 1.0.4 - Four\n&/' "$release_clone/CHANGELOG.md"
set_version prepare-release-branch 1.0.4
RELEASE_BRANCH=main run prepare-release-branch prepare_plugin_dev_release.sh refs/heads/main \
    || { cat "$WORK/prepare-release-branch/out" >&2; fail "a release-branch version is prepared"; }
says prepare-release-branch 'release_needed=true' || fail "a release-branch version of any major is released"
says prepare-release-branch 'version=1.0.4' || fail "a release-branch release reports its version"
grep -Fq 'branch=main&event=push' "$FAKE_GH_LOG" || fail "the release branch's push runs are read"
says prepare-release-branch '::warning::No push CI ran on' || fail "a release branch with no push CI warns"
FAKE_GH_RUNS='11:500:completed:success:Plugins-CI' RELEASE_BRANCH=main \
    run prepare-release-branch prepare_plugin_dev_release.sh refs/heads/main || fail "a release branch with push CI is prepared"
if says prepare-release-branch 'No push CI ran'; then fail "a release branch whose CI ran does not warn"; fi
says prepare-release-branch 'finish=1.0.3:2026-10-05 1.0.4:2026-10-12' \
    || fail "an unfinished earlier version on the release branch is resumed"
# A plugin that released 5.0.3 through the workflow before moving to main and 1.x leaves that date
# branch and tag behind, and main's restarted changelog never dates 5.0.3.
new_repo prepare-release-branch-moved '* 5.0.3 - Three'
moved_clone="$WORK/prepare-release-branch-moved/clone"
set_version prepare-release-branch-moved 5.0.3
git -C "$moved_clone" commit -q -am 'Release 5.0.3'
git -C "$moved_clone" push -q origin HEAD:main
git -C "$moved_clone" checkout -q -B main origin/main
run prepare-release-branch-moved push_plugin_release_date.sh main 2026-09-28 || fail "dating 5.0.3 succeeds"
git -C "$moved_clone" tag 5.0.3
git -C "$moved_clone" push -q origin refs/tags/5.0.3
git -C "$moved_clone" checkout -q -B main origin/main
printf '## Changelog\n\n* 1.0.0 - One\n' > "$moved_clone/CHANGELOG.md"
set_version prepare-release-branch-moved 1.0.0
RELEASE_BRANCH=main run prepare-release-branch-moved prepare_plugin_dev_release.sh refs/heads/main \
    || { cat "$WORK/prepare-release-branch-moved/out" >&2; fail "a release branch after a major move is prepared"; }
says prepare-release-branch-moved 'finish=1.0.0:2026-10-12' || fail "another major's date branch is not resumed on the release branch"

if RELEASE_BRANCH=main run prepare-release-branch prepare_plugin_dev_release.sh refs/heads/6.x-dev; then
    fail "release-branch refuses any other branch, N.x-dev included"
fi
says prepare-release-branch 'release-branch only releases refs/heads/main' || fail "a ref other than release-branch says why"

new_repo prepare-missing '* 6.0.1 - 2026-09-28 - One'
if run prepare-missing prepare_plugin_dev_release.sh refs/heads/6.x-dev; then fail "a version with no changelog entry fails"; fi
says prepare-missing 'cannot be dated' || fail "a missing entry says why"

new_repo prepare-ci '* 6.0.3 Three'
head_sha=$(git -C "$WORK/prepare-ci/clone" rev-parse HEAD)
export FAKE_GH_RUNS='11:500:completed:failure:Plugins-CI 12:501:completed:success:Other'
run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a version whose CI failed is skipped, not failed"
grep -Fq "actions/runs?head_sha=$head_sha&branch=6.x-dev&event=push" "$FAKE_GH_LOG" || fail "the branch's push runs on its head are read"
says prepare-ci 'release_needed=false' || fail "a version whose CI failed is not released"
says prepare-ci 'publish_needed=false' || fail "a version whose CI failed is not published"
says prepare-ci "ci_held=6.0.3 is not released from ${head_sha:0:12}, because CI has not passed on it: Plugins-CI (failure)." \
    || fail "a failed CI run is named"
if says prepare-ci 'Other ('; then fail "a passing workflow is not named"; fi
export FAKE_GH_RUNS='11:500:completed:failure:Plugins-CI 11:502:completed:success:Plugins-CI 12:501:completed:skipped:Other'
run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a version whose CI passed on a later run is prepared"
says prepare-ci 'release_needed=true' || fail "the newest run of each workflow decides"
if ! grep -qx 'ci_held=' "$WORK/prepare-ci/out"; then fail "a release CI passed is not held"; fi
export FAKE_GH_RUNS='11:500:in_progress::Plugins-CI'
run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a version whose CI is running is skipped, not failed"
says prepare-ci 'release_needed=false' || fail "a version whose CI is still running is not released"
says prepare-ci 'ci_held=6.0.3 is not released from' || fail "a running CI run holds the release"
says prepare-ci 'Plugins-CI (in_progress)' || fail "a running CI run is named"
rm -f "$FAKE_GH_LOG.listed"
: > "$FAKE_GH_LOG"
RELEASE_CI_WAIT_MINUTES=2 RELEASE_CI_POLL_SECONDS=60 FAKE_GH_RUNS_LATER='11:500:completed:success:Plugins-CI' \
    run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "CI that passes while waiting is prepared"
says prepare-ci 'Waiting for CI on' || fail "the wait for running CI is reported"
says prepare-ci 'release_needed=true' || fail "CI that passes while waiting releases"
[[ "$(grep -c '^sleep 60$' "$FAKE_GH_LOG")" == 1 ]] || fail "the wait ends once CI has finished"
rm -f "$FAKE_GH_LOG.listed"
: > "$FAKE_GH_LOG"
RELEASE_CI_WAIT_MINUTES=2 RELEASE_CI_POLL_SECONDS=60 run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev \
    || fail "CI still running after the wait is skipped, not failed"
says prepare-ci 'ci_held=6.0.3 is not released from' || fail "CI still running after the wait holds the release"
[[ "$(grep -c '^sleep 60$' "$FAKE_GH_LOG")" == 2 ]] || fail "the wait is capped by ci-wait-minutes"
rm -f "$FAKE_GH_LOG.listed"
: > "$FAKE_GH_LOG"
export FAKE_GH_RUNS='11:500:completed:failure:Plugins-CI 12:501:in_progress::Other'
RELEASE_CI_WAIT_MINUTES=2 run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev || fail "a failure with CI still running is skipped, not failed"
if grep -q '^sleep' "$FAKE_GH_LOG"; then fail "a failed run is not waited on"; fi
says prepare-ci 'Plugins-CI (failure), Other (in_progress)' || fail "both the failed and the running CI are named"
for wait in 2.5 -1 46 18446744073709551616; do
    if RELEASE_CI_WAIT_MINUTES=$wait run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev; then
        fail "a ci-wait-minutes of $wait fails"
    fi
    says prepare-ci "::error::ci-wait-minutes must be a whole number of minutes from 0 to 45, not $wait." \
        || fail "a ci-wait-minutes of $wait is explained"
done
unset FAKE_GH_RUNS
FAKE_GH_RUNS_ERROR='HTTP 502: Bad Gateway' run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev \
    || fail "unreadable CI runs hold the release rather than stop the run"
says prepare-ci 'ci_held=6.0.3 is not released from' || fail "unreadable CI runs hold the release rather than read as nothing to release"
says prepare-ci '::error::Could not read the CI runs on' || fail "unreadable CI runs say why"
says prepare-ci 'HTTP 502' || fail "unreadable CI runs give the error"
FAKE_GH_RUNS='11:500:completed:failure:Plugins-CI' RELEASE_SKIP_CI_CHECK=true run prepare-ci prepare_plugin_dev_release.sh refs/heads/6.x-dev \
    || fail "skip-ci-check prepares a version whose CI failed"
says prepare-ci 'release_needed=true' || fail "skip-ci-check releases whatever the CI says"
says prepare-ci '::warning::skip-ci-check is set' || fail "skip-ci-check warns"

# --- push_plugin_release_date.sh ---

new_repo open '* 6.0.3 Unreleased - Three'
run open push_plugin_release_date.sh 6.x-dev 2026-10-12 || { cat "$WORK/open/out" >&2; fail "dating succeeds"; }
[[ "$(date_branch_line open)" == '* 6.0.3 - 2026-10-12 - Three' ]] || fail "the date branch carries the release date"
[[ "$(git -C "$WORK/open/origin.git" log -1 --format=%ae automated/release-date-6.0.3)" == 'github-actions[bot]@users.noreply.github.com' ]] \
    || fail "the date commit is the workflow's"
[[ "$(git -C "$WORK/open/clone" rev-parse HEAD)" == "$(git -C "$WORK/open/origin.git" rev-parse automated/release-date-6.0.3)" ]] \
    || fail "HEAD is left on the dated commit"
if grep -Fq 'pr create' "$FAKE_GH_LOG"; then fail "the pull request waits until the version is tagged"; fi
[[ "$(git -C "$WORK/open/origin.git" show 6.x-dev:CHANGELOG.md | sed -n 3p)" == '* 6.0.3 Unreleased - Three' ]] \
    || fail "nothing is pushed to the development branch"

new_repo open-refresh '* 6.0.3 Three'
export FAKE_GH_OPEN_PR=7
run open-refresh push_plugin_release_date.sh 6.x-dev 2026-10-13 || fail "refreshing an open pull request succeeds"
unset FAKE_GH_OPEN_PR
[[ "$(date_branch_line open-refresh)" == '* 6.0.3 - 2026-10-13 - Three' ]] || fail "an explicit date is written"
says open-refresh 'dates 6.0.3 as 2026-10-13' || fail "the refreshed date is reported"
if says open-refresh '::warning'; then fail "an undated entry is dated without a warning"; fi

new_repo open-hand-dated '* 6.0.3 - 2026-10-01 - Three'
run open-hand-dated push_plugin_release_date.sh 6.x-dev 2026-10-12 || fail "an entry dated by hand is re-dated, not failed"
[[ "$(date_branch_line open-hand-dated)" == '* 6.0.3 - 2026-10-12 - Three' ]] || fail "a date set by hand is replaced"
says open-hand-dated '::warning file=CHANGELOG.md::6.x-dev dates 6.0.3 as 2026-10-01, which the release replaces with 2026-10-12.' \
    || fail "replacing a date set by hand warns"
run open-hand-dated push_plugin_release_date.sh 6.x-dev 2026-10-01 || fail "an entry dated by hand for today is kept"
if says open-hand-dated '::warning'; then fail "a date set by hand that matches the release does not warn"; fi

new_repo open-released '* 6.0.3 - 2026-10-05 - Three'
git -C "$WORK/open-released/origin.git" tag 6.0.3 6.x-dev
run open-released push_plugin_release_date.sh 6.x-dev || fail "a released version is skipped, not failed"
if origin_has open-released automated/release-date-6.0.3; then fail "a released version is never re-dated"; fi

new_repo open-human '* 6.0.3 Three'
git -C "$WORK/open-human/clone" switch -q -c automated/release-date-6.0.3
printf 'note\n' >> "$WORK/open-human/clone/CHANGELOG.md"
git -C "$WORK/open-human/clone" commit -q -am 'a human edit'
git -C "$WORK/open-human/clone" push -q origin automated/release-date-6.0.3
HUMAN_COMMIT=$(git -C "$WORK/open-human/clone" rev-parse HEAD)
git -C "$WORK/open-human/clone" switch -q 6.x-dev
run open-human push_plugin_release_date.sh 6.x-dev || fail "a branch with a human commit is skipped, not failed"
[[ "$(git -C "$WORK/open-human/origin.git" rev-parse automated/release-date-6.0.3)" == "$HUMAN_COMMIT" ]] \
    || fail "a human commit on the branch is never overwritten"
git -C "$WORK/open-human/clone" diff --quiet || fail "a skipped date leaves no unpushed date in the working tree"
says open-human 'has commits from someone other than this workflow' || fail "a human commit says why it is skipped"

new_repo open-own '* 6.0.3 Three'
git -C "$WORK/open-own/clone" switch -q -c automated/release-date-6.0.3
printf 'note\n' >> "$WORK/open-own/clone/CHANGELOG.md"
env "${BOT[@]}" git -C "$WORK/open-own/clone" commit -q -am 'an earlier date commit'
git -C "$WORK/open-own/clone" push -q origin automated/release-date-6.0.3
git -C "$WORK/open-own/clone" switch -q 6.x-dev
run open-own push_plugin_release_date.sh 6.x-dev 2026-10-13 || { cat "$WORK/open-own/out" >&2; fail "the workflow's own branch is refreshed"; }
[[ "$(date_branch_line open-own)" == '* 6.0.3 - 2026-10-13 - Three' ]] || fail "the refreshed branch carries the new date"

# Amending the workflow's commit keeps its author, so only the committer gives it away.
new_repo open-amended '* 6.0.3 Three'
git -C "$WORK/open-amended/clone" switch -q -c automated/release-date-6.0.3
printf 'note\n' >> "$WORK/open-amended/clone/CHANGELOG.md"
env "${BOT[@]:0:2}" git -C "$WORK/open-amended/clone" commit -q -am 'an amended date commit'
git -C "$WORK/open-amended/clone" push -q origin automated/release-date-6.0.3
AMENDED_COMMIT=$(git -C "$WORK/open-amended/clone" rev-parse HEAD)
git -C "$WORK/open-amended/clone" switch -q 6.x-dev
run open-amended push_plugin_release_date.sh 6.x-dev || fail "a branch with an amended commit is skipped, not failed"
[[ "$(git -C "$WORK/open-amended/origin.git" rev-parse automated/release-date-6.0.3)" == "$AMENDED_COMMIT" ]] \
    || fail "a commit someone else amended is never overwritten"

# A person pushes to the workflow's branch between its check and its push.
new_repo open-race '* 6.0.3 Three'
run open-race push_plugin_release_date.sh 6.x-dev 2026-10-12 || fail "dating for the race succeeds"
git -C "$WORK/open-race/clone" switch -q 6.x-dev
git clone -q --branch automated/release-date-6.0.3 "$WORK/open-race/origin.git" "$WORK/open-race/human"
git -C "$WORK/open-race/human" commit -q --allow-empty -m 'a human commit'
RACE_COMMIT=$(git -C "$WORK/open-race/human" rev-parse HEAD)
mkdir "$WORK/open-race/bin"
cat > "$WORK/open-race/bin/git" <<SH
#!/bin/bash
if [[ "\$1" == push ]]; then
    $(command -v git) -C "$WORK/open-race/human" push -q origin automated/release-date-6.0.3
fi
exec $(command -v git) "\$@"
SH
chmod +x "$WORK/open-race/bin/git"
if PATH="$WORK/open-race/bin:$PATH" run open-race push_plugin_release_date.sh 6.x-dev 2026-10-13; then
    fail "a push racing a person's push fails"
fi
[[ "$(git -C "$WORK/open-race/origin.git" rev-parse automated/release-date-6.0.3)" == "$RACE_COMMIT" ]] \
    || fail "a commit pushed during the run is never overwritten"

# A shallow checkout of a branch that has moved on since the date branch was cut from it.
new_repo open-shallow '* 6.0.3 Three'
run open-shallow push_plugin_release_date.sh 6.x-dev 2026-10-12 || fail "dating for the shallow checkout succeeds"
git -C "$WORK/open-shallow/clone" switch -q 6.x-dev
git -C "$WORK/open-shallow/clone" commit -q --allow-empty -m 'later work'
git -C "$WORK/open-shallow/clone" push -q origin 6.x-dev
rm -rf "$WORK/open-shallow/clone"
git clone -q --depth 1 --branch 6.x-dev "file://$WORK/open-shallow/origin.git" "$WORK/open-shallow/clone"
run open-shallow push_plugin_release_date.sh 6.x-dev 2026-10-13 \
    || { cat "$WORK/open-shallow/out" >&2; fail "the workflow's own branch is refreshed from a shallow checkout"; }
[[ "$(date_branch_line open-shallow)" == '* 6.0.3 - 2026-10-13 - Three' ]] || fail "the shallow checkout refreshes the date"

new_repo open-other-base '* 6.0.3 Three'
git -C "$WORK/open-other-base/clone" push -q origin 6.x-dev:refs/heads/automated/release-date-6.0.3
export FAKE_GH_HEAD_BASES=6.x-prod
run open-other-base push_plugin_release_date.sh 6.x-dev || fail "a branch proposed for another base is skipped, not failed"
unset FAKE_GH_HEAD_BASES
says open-other-base 'is proposed for 6.x-prod' || fail "the other base is named"

new_repo open-fork '* 6.0.3 Three'
git -C "$WORK/open-fork/clone" push -q origin 6.x-dev:refs/heads/automated/release-date-6.0.3
export FAKE_GH_FORK_BASES=6.x-prod
run open-fork push_plugin_release_date.sh 6.x-dev || { cat "$WORK/open-fork/out" >&2; fail "a fork's pull request does not stop the date being pushed"; }
unset FAKE_GH_FORK_BASES
[[ "$(date_branch_line open-fork)" == '* 6.0.3 - 2026-10-12 - Three' ]] || fail "the branch is dated despite a fork's pull request from the same name"

# --- tag_plugin_dev_release.sh ---

new_repo tag '* 6.0.3 Three'
run tag push_plugin_release_date.sh 6.x-dev
run tag tag_plugin_dev_release.sh 6.0.3 2026-10-12 || { cat "$WORK/tag/out" >&2; fail "the dated commit is tagged"; }
[[ "$(git -C "$WORK/tag/origin.git" rev-parse '6.0.3^{commit}')" == "$(git -C "$WORK/tag/origin.git" rev-parse automated/release-date-6.0.3)" ]] \
    || fail "the tag is on the release date commit"
# Only origin's tag is left, so only the check against origin can refuse it.
git -C "$WORK/tag/clone" tag -d 6.0.3 > /dev/null
if run tag tag_plugin_dev_release.sh 6.0.3 2026-10-12; then fail "an existing tag is not created again"; fi
says tag 'already exists' || fail "an existing tag says why"

new_repo tag-undated '* 6.0.3 Three'
if run tag-undated tag_plugin_dev_release.sh 6.0.3 2026-10-12; then fail "an undated HEAD is not tagged"; fi
says tag-undated 'does not date 6.0.3 as 2026-10-12' || fail "an undated HEAD says why"

# The working tree holds a date that HEAD does not, as when dating was refused after the dater ran.
new_repo tag-dirty '* 6.0.3 Three'
sed -i 's/6.0.3 Three/6.0.3 - 2026-10-12 - Three/' "$WORK/tag-dirty/clone/CHANGELOG.md"
if run tag-dirty tag_plugin_dev_release.sh 6.0.3 2026-10-12; then fail "a date only in the working tree is not tagged"; fi
if origin_has tag-dirty refs/tags/6.0.3; then fail "no tag is pushed for an undated commit"; fi

new_repo tag-version '* 6.0.3 - 2026-10-12 - Three'
if run tag-version tag_plugin_dev_release.sh 6.0.4 2026-10-12; then fail "a different version is not tagged"; fi

# The scripts run from the plugin checkout, whose own json.py must not stand in for the real module.
new_repo shadow '* 6.0.3 Three'
printf 'raise SystemExit("planted json.py was imported")\n' > "$WORK/shadow/clone/json.py"
run shadow check_plugin_release_date.sh 6.x-dev || { cat "$WORK/shadow/out" >&2; fail "the date check ignores a json.py in the plugin"; }
run shadow prepare_plugin_dev_release.sh refs/heads/6.x-dev || { cat "$WORK/shadow/out" >&2; fail "preparing ignores a json.py in the plugin"; }
run shadow push_plugin_release_date.sh 6.x-dev || { cat "$WORK/shadow/out" >&2; fail "dating ignores a json.py in the plugin"; }
run shadow tag_plugin_dev_release.sh 6.0.3 2026-10-12 || { cat "$WORK/shadow/out" >&2; fail "tagging ignores a json.py in the plugin"; }

# --- check_plugin_release_date.sh ---

new_repo check-undated '* 6.0.3 Three'
run check-undated check_plugin_release_date.sh 6.x-dev || fail "an undated entry passes"
# Bash 5.2 only warns about a here-document left outside its $( ); bash 5.1 runs its body as commands.
! says check-undated 'here-document' || fail "every here-document closes inside its command substitution"

new_repo check-unreleased '* 6.0.3 Unreleased - Three'
run check-unreleased check_plugin_release_date.sh 6.x-dev || fail "an Unreleased entry passes"

new_repo check-dated '* 6.0.3 - 2026-10-12 - Three'
if run check-dated check_plugin_release_date.sh 6.x-dev; then fail "an entry dated by hand fails"; fi
says check-dated '::error file=CHANGELOG.md::The 6.0.3 entry is dated 2026-10-12' || fail "a dated entry names its date"

new_repo check-missing '* 6.0.1 - 2026-09-28 - One'
if run check-missing check_plugin_release_date.sh 6.x-dev; then fail "a version with no changelog entry fails"; fi
says check-missing 'could not date the 6.0.3 entry' || fail "a missing entry says why"

new_repo check-released '* 6.0.3 - 2026-10-12 - Three'
git -C "$WORK/check-released/origin.git" tag 6.0.3 6.x-dev
run check-released check_plugin_release_date.sh 6.x-dev || fail "a released version passes, as on the release date pull request"

new_repo check-prerelease '* 6.0.3-rc1 - 2026-10-12 - Three'
set_version check-prerelease 6.0.3-rc1
run check-prerelease check_plugin_release_date.sh 6.x-dev || fail "a prerelease passes"

new_repo check-major '* 5.0.3 Three'
set_version check-major 5.0.3
if run check-major check_plugin_release_date.sh 6.x-dev; then fail "a 5.x version on 6.x-dev fails"; fi

new_repo check-not-adopted '* 6.0.3 - 2026-10-12 - Three' no
run check-not-adopted check_plugin_release_date.sh 6.x-dev || fail "a plugin without the weekly release passes"

new_repo check-commented '* 6.0.3 - 2026-10-12 - Three' commented
run check-commented check_plugin_release_date.sh 6.x-dev || fail "a commented-out call to the weekly release passes"

new_repo check-malformed '* 6.0.3 - 2026-10-12 - Three' no
printf 'jobs: [unclosed\n' > "$WORK/check-malformed/clone/.github/workflows/broken.yml"
if run check-malformed check_plugin_release_date.sh 6.x-dev; then fail "an unreadable workflow fails rather than passing as not adopted"; fi
says check-malformed 'broken.yml' || fail "an unreadable workflow is named"

new_repo check-invalid '* 6.0.3 - 2026-13-45 - Three'
if run check-invalid check_plugin_release_date.sh 6.x-dev; then fail "an impossible date fails"; fi
says check-invalid 'invalid date' || fail "an impossible date says why"

new_repo check-skipped '* 6.0.3 Three'
printf '## Changelog\n\n6.0.3\n- Three\n\n6.0.2\n- Two\n' > "$WORK/check-skipped/clone/CHANGELOG.md"
if run check-skipped check_plugin_release_date.sh 6.x-dev; then fail "a version bumped past an unreleased one fails"; fi
says check-skipped '::error file=CHANGELOG.md::The 6.0.2 entry is undated and 6.0.2 has not been released' || fail "a skipped version is named"

new_repo check-skipped-list '* 6.0.3 Three'
printf '## Changelog\n\n* 6.0.3 Three\n* 6.0.2 Two\n' > "$WORK/check-skipped-list/clone/CHANGELOG.md"
if run check-skipped-list check_plugin_release_date.sh 6.x-dev; then fail "a one-line entry bumped past an unreleased one fails"; fi
says check-skipped-list 'The 6.0.2 entry is undated' || fail "a skipped one-line entry is named"

new_repo check-earlier-v-tag '* 6.0.3 Three'
printf '## Changelog\n\n* 6.0.3 Three\n* 6.0.2 Two\n' > "$WORK/check-earlier-v-tag/clone/CHANGELOG.md"
git -C "$WORK/check-earlier-v-tag/origin.git" tag v6.0.2 6.x-dev
run check-earlier-v-tag check_plugin_release_date.sh 6.x-dev || fail "an undated entry below that was released as v6.0.2 passes"

new_repo check-earlier-major '* 6.0.0 Six'
set_version check-earlier-major 6.0.0
printf '## Changelog\n\n* 6.0.0 Six\n* 5.9.0 Five\n' > "$WORK/check-earlier-major/clone/CHANGELOG.md"
run check-earlier-major check_plugin_release_date.sh 6.x-dev || fail "an undated entry below from the previous major passes"

new_repo check-earlier-long-date '* 6.0.3 Three'
printf '## Changelog\n\n## 6.0.3\n- Three\n\n## 6.0.2 September 20, 2026\n- Two\n' > "$WORK/check-earlier-long-date/clone/CHANGELOG.md"
run check-earlier-long-date check_plugin_release_date.sh 6.x-dev || fail "an entry below dated in a format the release cannot write passes"

new_repo check-earlier-released '* 6.0.3 Three'
printf '## Changelog\n\n* 6.0.3 Three\n* 6.0.2 Two\n' > "$WORK/check-earlier-released/clone/CHANGELOG.md"
git -C "$WORK/check-earlier-released/origin.git" tag 6.0.2 6.x-dev
run check-earlier-released check_plugin_release_date.sh 6.x-dev || fail "an undated entry below that was released passes"

new_repo check-version-in-notes '* 6.0.3 Three'
printf '## Changelog\n\n## 6.0.3\n- Three\n\n6.0.2 behaviour is kept\n\n## 6.0.2 - 2026-10-05\n- Two\n' > "$WORK/check-version-in-notes/clone/CHANGELOG.md"
run check-version-in-notes check_plugin_release_date.sh 6.x-dev || { cat "$WORK/check-version-in-notes/out" >&2; fail "a note starting with a version is not read as an entry"; }

new_repo check-other-branch '* 6.0.3 - 2026-10-12 - Three'
run check-other-branch check_plugin_release_date.sh 6.x-prod || fail "a branch other than N.x-dev passes"

echo 'All development release tests passed.'
