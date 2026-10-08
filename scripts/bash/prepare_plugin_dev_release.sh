#!/bin/bash
# Decides whether the development branch has an unreleased version to release: plugin.json's version
# is stable, belongs to the branch's major, has no tag yet, and has a CHANGELOG.md entry the release
# can date. Writes release_needed, publish_needed, version, plugin_name and today to GITHUB_OUTPUT.
# A version this workflow tagged is resumed until its release is published and its date is on the
# branch: release_needed is false, and publish_needed carries both on from the tagged commit.
# Usage: prepare_plugin_dev_release.sh <development-branch>

set -euo pipefail

BRANCH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tests pin the day; the workflow always uses the real one.
TODAY="${PLUGIN_RELEASE_TODAY:-$(date -u +%F)}"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"

if [[ ! "$BRANCH" =~ ^([0-9]+)\.x-dev$ ]]; then
    echo "::error::Unsupported release branch: $BRANCH" >&2
    exit 1
fi
expected_major="${BASH_REMATCH[1]}"

emit() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    else
        printf '%s\n' "$1"
    fi
}

if ! metadata=$(python3 -c 'import json; p = json.load(open("plugin.json", encoding="utf-8")); print(p["version"]); print(p["name"])' 2>&1); then
    echo "::error file=plugin.json::Could not read the version and name from plugin.json: $metadata" >&2
    exit 1
fi
mapfile -t metadata_lines <<< "$metadata"
VERSION="${metadata_lines[0]}"
PLUGIN_NAME="${metadata_lines[1]}"

skip() {
    echo "$1"
    emit "release_needed=false"
    emit "publish_needed=false"
    exit 0
}

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    skip "$VERSION is not a stable version, so nothing is released."
fi
if [[ "${VERSION%%.*}" != "$expected_major" ]]; then
    echo "::error file=plugin.json::Version $VERSION does not belong on $BRANCH." >&2
    exit 1
fi

tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$VERSION" > /dev/null || tag_status=$?
if (( tag_status == 0 )); then
    git fetch --quiet --no-tags origin "+refs/tags/$VERSION:refs/tags/$VERSION"
    tag_commit=$(git log -1 --format='%ae%n%ce%n%s' "refs/tags/$VERSION^{commit}")
    ours=$(printf '%s\n%s\n%s' "$BOT_EMAIL" "$BOT_EMAIL" "Add release date for $VERSION")
    # Only a tag this workflow made is resumed, so a version released another way is never published.
    if [[ "$tag_commit" != "$ours" ]]; then
        skip "$VERSION is already released; nothing new to release."
    fi
    published=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$VERSION" --jq .prerelease 2>/dev/null || true)
    # However the date pull request was merged, the branch then dates the version.
    if [[ "$published" == false ]] && python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --read-date --plugin-name "$PLUGIN_NAME" CHANGELOG.md "$VERSION" > /dev/null 2>&1; then
        skip "$VERSION is already released; nothing new to release."
    fi
    tagged_date=$(git show "refs/tags/$VERSION:CHANGELOG.md" | python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --read-date --plugin-name "$PLUGIN_NAME" /dev/stdin "$VERSION")
    echo "$VERSION is tagged but not yet published or not yet merged into $BRANCH; resuming it, dated $tagged_date."
    emit "release_needed=false"
    emit "publish_needed=true"
    emit "version=$VERSION"
    emit "plugin_name=$PLUGIN_NAME"
    emit "today=$tagged_date"
    exit 0
elif (( tag_status != 2 )); then
    echo "::error::Could not list the tags on origin." >&2
    exit 1
fi

# Dating a scratch copy proves the entry exists and can be dated, before anything is pushed.
scratch=$(mktemp)
cp CHANGELOG.md "$scratch"
dating_status=0
dating_error=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
    --plugin-name "$PLUGIN_NAME" "$scratch" "$VERSION" "$TODAY" 2>&1) || dating_status=$?
rm -f "$scratch"
if (( dating_status != 0 )); then
    echo "::error file=CHANGELOG.md::plugin.json is at $VERSION, but its changelog entry cannot be dated: $dating_error" >&2
    exit 1
fi

echo "Releasing $VERSION, dated $TODAY."
emit "release_needed=true"
emit "publish_needed=true"
emit "version=$VERSION"
emit "plugin_name=$PLUGIN_NAME"
emit "today=$TODAY"
