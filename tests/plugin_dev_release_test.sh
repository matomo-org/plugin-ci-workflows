#!/bin/bash
# Tests the development release's preparation, dating, tagging and release date check with a bare
# origin and a fake gh CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASH_SCRIPTS="$ROOT/scripts/bash"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PLUGIN_RELEASE_TODAY=2026-10-12
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
    # Listing a head's open pull requests prints their bases.
    for base in ${FAKE_GH_HEAD_BASES:-}; do echo "$base"; done
elif [[ "$1 $2" == "pr list" && -n "${FAKE_GH_OPEN_PR:-}" ]]; then
    echo "$FAKE_GH_OPEN_PR"
elif [[ "$*" == *'/releases/tags/'* ]]; then
    # Unset is a release that does not exist, which the API reports as a 404.
    [[ -n "${FAKE_GH_PRERELEASE:-}" ]] || exit 1
    echo "$FAKE_GH_PRERELEASE"
fi
exit 0
SH
chmod +x "$FAKE_BIN/gh"
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
run prepare prepare_plugin_dev_release.sh 6.x-dev || fail "an unreleased version is prepared"
says prepare 'release_needed=true' || fail "an unreleased version is released"
if ! { says prepare 'version=6.0.3' && says prepare 'plugin_name=TestPlugin' && says prepare 'today=2026-10-12'; }; then
    fail "preparation reports the version, the name and the day"
fi

new_repo prepare-tagged '* 6.0.3 - 2026-10-05 - Three'
git -C "$WORK/prepare-tagged/origin.git" tag 6.0.3 6.x-dev
run prepare-tagged prepare_plugin_dev_release.sh 6.x-dev || fail "a released version is skipped, not failed"
says prepare-tagged 'release_needed=false' || fail "a released version is not released again"
says prepare-tagged 'publish_needed=false' || fail "a version tagged another way is not published"

# A run that tagged the dated commit and then failed is resumed from that tag by the next run.
new_repo prepare-resume '* 6.0.3 - Three'
run prepare-resume push_plugin_release_date.sh 6.x-dev 2026-10-12 || fail "dating for the resume succeeds"
git -C "$WORK/prepare-resume/clone" tag 6.0.3
git -C "$WORK/prepare-resume/clone" push -q origin refs/tags/6.0.3
git -C "$WORK/prepare-resume/clone" checkout -q -B 6.x-dev origin/6.x-dev
run prepare-resume prepare_plugin_dev_release.sh 6.x-dev || fail "an unpublished tag is resumed, not failed"
if ! { says prepare-resume 'release_needed=false' && says prepare-resume 'publish_needed=true' \
    && says prepare-resume 'today=2026-10-12'; }; then
    fail "an unpublished tag is published with the tag's date, without tagging again"
fi
export FAKE_GH_PRERELEASE=false
run prepare-resume prepare_plugin_dev_release.sh 6.x-dev || fail "a published release is resumed, not failed"
says prepare-resume 'publish_needed=true' || fail "a published release whose date is not merged is resumed"
# However the date reached the branch, squashed included, the release is then finished.
git -C "$WORK/prepare-resume/clone" checkout -q 6.0.3 -- CHANGELOG.md
run prepare-resume prepare_plugin_dev_release.sh 6.x-dev || fail "a finished release is skipped, not failed"
unset FAKE_GH_PRERELEASE
says prepare-resume 'publish_needed=false' || fail "a published release with its date merged is not resumed"

new_repo prepare-prerelease '* 6.0.3-rc1 - Three'
set_version prepare-prerelease 6.0.3-rc1
run prepare-prerelease prepare_plugin_dev_release.sh 6.x-dev || fail "a prerelease is skipped, not failed"
says prepare-prerelease 'release_needed=false' || fail "a prerelease is not released"

new_repo prepare-major '* 5.0.3 - Three'
set_version prepare-major 5.0.3
if run prepare-major prepare_plugin_dev_release.sh 6.x-dev; then fail "a 5.x version on 6.x-dev fails"; fi
says prepare-major 'does not belong on 6.x-dev' || fail "a wrong major names the branch"

new_repo prepare-branch '* 6.0.3 - Three'
if run prepare-branch prepare_plugin_dev_release.sh 6.x-prod; then fail "a branch other than N.x-dev fails"; fi

new_repo prepare-missing '* 6.0.1 - 2026-09-28 - One'
if run prepare-missing prepare_plugin_dev_release.sh 6.x-dev; then fail "a version with no changelog entry fails"; fi
says prepare-missing 'cannot be dated' || fail "a missing entry says why"

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

new_repo open-other-base '* 6.0.3 Three'
git -C "$WORK/open-other-base/clone" push -q origin 6.x-dev:refs/heads/automated/release-date-6.0.3
export FAKE_GH_HEAD_BASES=6.x-prod
run open-other-base push_plugin_release_date.sh 6.x-dev || fail "a branch proposed for another base is skipped, not failed"
unset FAKE_GH_HEAD_BASES
says open-other-base 'is proposed for 6.x-prod' || fail "the other base is named"

# --- tag_plugin_dev_release.sh ---

new_repo tag '* 6.0.3 Three'
run tag push_plugin_release_date.sh 6.x-dev
run tag tag_plugin_dev_release.sh 6.0.3 2026-10-12 || { cat "$WORK/tag/out" >&2; fail "the dated commit is tagged"; }
[[ "$(git -C "$WORK/tag/origin.git" rev-parse '6.0.3^{commit}')" == "$(git -C "$WORK/tag/origin.git" rev-parse automated/release-date-6.0.3)" ]] \
    || fail "the tag is on the release date commit"
if run tag tag_plugin_dev_release.sh 6.0.3 2026-10-12; then fail "an existing tag is not created again"; fi

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

# --- check_plugin_release_date.sh ---

new_repo check-undated '* 6.0.3 Three'
run check-undated check_plugin_release_date.sh 6.x-dev || fail "an undated entry passes"

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

new_repo check-other-branch '* 6.0.3 - 2026-10-12 - Three'
run check-other-branch check_plugin_release_date.sh 6.x-prod || fail "a branch other than N.x-dev passes"

echo 'All development release tests passed.'
