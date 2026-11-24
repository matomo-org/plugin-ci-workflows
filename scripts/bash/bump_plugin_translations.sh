#!/bin/bash
# Proposes the version bump for translation updates as soon as they are merged: when plugin.json's
# version on the branch is released and every commit since is a translation update, by the weekly
# release's rule in translation_release_lib.sh, pushes a commit bumping plugin.json to the next patch
# with an "Updated translations" changelog entry to automated/translation-version-<version>, for
# merge_plugin_release_date_pr.sh to open and merge. The weekly release then releases that version as
# any other. Writes version and sha to GITHUB_OUTPUT, both empty when there is nothing to bump.
# Works from origin's tip of the branch rather than the commit that triggered the run, so a run queued
# behind a bump that has since been merged finds the version unreleased and does nothing.
# Run from a full clone of the plugin with a pushable origin.
# Usage: bump_plugin_translations.sh <branch>

set -euo pipefail

BRANCH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"

if [[ -z "$BRANCH" ]]; then
    echo "Usage: $0 <branch>" >&2
    exit 1
fi

emit() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    else
        printf '%s\n' "$1"
    fi
}

nothing() {
    echo "$*"
    emit "version="
    emit "sha="
    exit 0
}

if ! remote_refs=$(git ls-remote --tags --heads origin); then
    echo "::error::Could not list the tags and branches on origin." >&2
    exit 1
fi
# shellcheck source=scripts/bash/translation_release_lib.sh
. "$SCRIPT_DIR/translation_release_lib.sh"

git fetch --quiet --no-tags origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
git checkout --quiet --detach "refs/remotes/origin/$BRANCH"
base_sha=$(git rev-parse HEAD)

# Only the weekly release releases the bumped version, so a plugin or branch it does not release is left alone.
shopt -s nullglob
workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob
calls_status=0
calls_output=$(python3 -I "$SCRIPT_DIR/../python/weekly_release_branches.py" \
    'plugin-ci-workflows/.github/workflows/plugin-dev-release.yml@' "${workflow_files[@]}") || calls_status=$?
if (( calls_status == 3 )); then
    nothing "This plugin does not call plugin-dev-release.yml, so its translations are not bumped."
elif (( calls_status != 0 )); then
    echo "::error::Could not read the plugin's workflows: $calls_output" >&2
    exit 1
fi
if ! grep -qxF -- "$BRANCH" <<< "$calls_output" \
    && ! { [[ "$BRANCH" =~ ^[0-9]+\.x-dev$ ]] && grep -qxF '*' <<< "$calls_output"; }; then
    nothing "$BRANCH is not released by the weekly release, so its translations are not bumped."
fi

# -P keeps the plugin checkout, the working directory, off the import path, so its json.py cannot stand in for the real module.
if ! metadata=$(python3 -P -c 'import json; p = json.load(open("plugin.json", encoding="utf-8")); print(p["version"]); print(p["name"])' 2>&1); then
    echo "::error file=plugin.json::Could not read the version and name from plugin.json: $metadata" >&2
    exit 1
fi
mapfile -t metadata_lines <<< "$metadata"
VERSION="${metadata_lines[0]}"
if ! tagged "$VERSION"; then
    nothing "$VERSION is not released yet, so translations merged into $BRANCH are released with it."
fi
# A bump merged before the release's date pull request would conflict with it, as both edit the top
# of the changelog.
if grep -qxF "refs/heads/automated/release-date-$VERSION" <<< "$(cut -f2 <<< "$remote_refs")" \
    && ! python3 -I "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --read-date --plugin-name "${metadata_lines[1]}" CHANGELOG.md "$VERSION" > /dev/null 2>&1; then
    nothing "The $VERSION release date pull request is not merged yet, so translations wait for it."
fi
translation_release "$VERSION" || nothing "Nothing on $BRANCH since $VERSION calls for a translation release."

bump_status=0
bump_note=$(python3 -I "$SCRIPT_DIR/../python/bump_plugin_version.py" . released "$TRANSLATION_ENTRY") || bump_status=$?
bumped=$(python3 -P -c 'import json; print(json.load(open("plugin.json", encoding="utf-8"))["version"])' 2> /dev/null) || bumped=""
if (( bump_status != 0 )) || [[ "$bumped" != "$translation_version" ]]; then
    # Not a checkout of the two files by name: a plugin may have no CHANGELOG.md.
    git reset --quiet --hard
    echo "::warning::Translations were merged into $BRANCH after $VERSION, but the version could not be bumped for them: $bump_note"
    nothing "The weekly release tries again."
fi

TARGET="$TRANSLATION_BUMP_PREFIX$translation_version"
# The identity check below relies on these, and GIT_AUTHOR_* and GIT_COMMITTER_* would override git config.
GIT_AUTHOR_NAME="github-actions[bot]" GIT_AUTHOR_EMAIL="$BOT_EMAIL" \
    GIT_COMMITTER_NAME="github-actions[bot]" GIT_COMMITTER_EMAIL="$BOT_EMAIL" \
    git commit --quiet -m "Bump version to $translation_version for updated translations" -- plugin.json CHANGELOG.md
sha=$(git rev-parse HEAD)

# The branch is rebuilt on the base's tip and force-pushed, so a commit someone added to it by hand is
# never overwritten.
branch_status=0
expected_tip=""
git ls-remote --exit-code --heads origin "refs/heads/$TARGET" > /dev/null || branch_status=$?
if (( branch_status == 0 )); then
    git fetch --quiet --no-tags origin "+refs/heads/$TARGET:refs/remotes/origin/$TARGET"
    expected_tip=$(git rev-parse "refs/remotes/origin/$TARGET")
    # The committer is checked too, because amending the workflow's commit keeps its author. The log
    # is captured first: grep -q exiting early would SIGPIPE git log, and pipefail would read that as no match.
    identities=$(git log --format='%ae%n%ce' "$base_sha..$expected_tip")
    if [[ -n "$identities" ]] && grep -qvxF "$BOT_EMAIL" <<< "$identities"; then
        echo "::warning::$TARGET has commits from someone other than this workflow, so it was left alone."
        nothing "Translations wait for a person to merge $TARGET."
    fi
    # A rerun, or a run after a push that left the base as it was, pushes nothing, so the pull request
    # keeps its runs and approval.
    if [[ "$(git rev-parse "$expected_tip^" 2> /dev/null)" == "$base_sha" \
        && "$(git rev-parse "$expected_tip^{tree}")" == "$(git rev-parse "$sha^{tree}")" ]]; then
        sha="$expected_tip"
    fi
elif (( branch_status != 2 )); then
    echo "::error::Could not list the branches on origin." >&2
    exit 1
fi
if [[ "$sha" != "$expected_tip" ]]; then
    # The lease refuses the push if anyone pushed to the branch since the check above.
    git push --quiet --force-with-lease="refs/heads/$TARGET:$expected_tip" origin "$sha:refs/heads/$TARGET"
fi
echo "$TARGET bumps plugin.json to $translation_version for the translations merged after $VERSION."
emit "version=$translation_version"
emit "sha=$sha"
