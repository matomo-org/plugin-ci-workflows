#!/bin/bash
# Decides whether the development branch has an unreleased version to release: plugin.json's version
# is stable, belongs to the branch's major, has no tag yet, and has a CHANGELOG.md entry the release
# can date. Writes release_needed, publish_needed, version, plugin_name, today and finish to
# GITHUB_OUTPUT.
# A version this workflow tagged is resumed until its release is published and its date is on the
# branch, including one plugin.json has since moved on from. finish lists each version to publish
# and merge, as <version>:<release date>, earliest first; release_needed covers only plugin.json's.
# Usage: prepare_plugin_dev_release.sh <development-branch ref, refs/heads/N.x-dev>

set -euo pipefail

REF="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tests pin the day; the workflow always uses the real one.
TODAY="${PLUGIN_RELEASE_TODAY:-$(date -u +%F)}"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"

# A tag named like the branch has the same ref_name, so only the full ref says a branch is running.
if [[ ! "$REF" =~ ^refs/heads/(([0-9]+)\.x-dev)$ ]]; then
    echo "::error::Unsupported release ref: $REF" >&2
    exit 1
fi
BRANCH="${BASH_REMATCH[1]}"
expected_major="${BASH_REMATCH[2]}"

emit() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    else
        printf '%s\n' "$1"
    fi
}

# -P keeps the plugin checkout, the working directory, off the import path, so its json.py cannot stand in for the real module.
if ! metadata=$(python3 -P -c 'import json; p = json.load(open("plugin.json", encoding="utf-8")); print(p["version"]); print(p["name"])' 2>&1); then
    echo "::error file=plugin.json::Could not read the version and name from plugin.json: $metadata" >&2
    exit 1
fi
mapfile -t metadata_lines <<< "$metadata"
VERSION="${metadata_lines[0]}"
PLUGIN_NAME="${metadata_lines[1]}"

if ! remote_refs=$(git ls-remote --tags --heads origin); then
    echo "::error::Could not list the tags and branches on origin." >&2
    exit 1
fi

tagged() {
    grep -qxF "refs/tags/$1" <<< "$(cut -f2 <<< "$remote_refs")"
}

# Only a tag this workflow made is resumed, so a version released another way is never published.
# Called only inside conditions, where set -e is off, so a failed fetch must exit by itself.
ours() {
    if ! git fetch --quiet --no-tags origin "+refs/tags/$1:refs/tags/$1"; then
        echo "::error::Could not fetch the $1 tag from origin." >&2
        exit 1
    fi
    [[ "$(git log -1 --format='%ae%n%ce%n%s' "refs/tags/$1^{commit}")" \
        == "$(printf '%s\n%s\n%s' "$BOT_EMAIL" "$BOT_EMAIL" "Add release date for $1")" ]]
}

# However the date pull request was merged, the branch then dates the version.
finished() {
    python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --read-date --plugin-name "$PLUGIN_NAME" CHANGELOG.md "$1" > /dev/null 2>&1 \
        && [[ "$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$1" --jq .prerelease 2>/dev/null || true)" == false ]]
}

tagged_date() {
    git show "refs/tags/$1:CHANGELOG.md" | python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --read-date --plugin-name "$PLUGIN_NAME" /dev/stdin "$1"
}

finish=()
# The date branches name every version this workflow has released.
earlier_versions=$(sed -nE "s#^.*\trefs/heads/automated/release-date-(${expected_major}\.[0-9]+\.[0-9]+)\$#\1#p" \
    <<< "$remote_refs" | sort -V)
for earlier in $earlier_versions; do
    if [[ "$earlier" != "$VERSION" ]] && tagged "$earlier" && ! finished "$earlier" && ours "$earlier"; then
        echo "$earlier is tagged but not yet published or not yet merged into $BRANCH; resuming it."
        finish+=("$earlier:$(tagged_date "$earlier")")
    fi
done

release_needed=false
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$VERSION is not a stable version, so nothing is released."
elif [[ "${VERSION%%.*}" != "$expected_major" ]]; then
    echo "::error file=plugin.json::Version $VERSION does not belong on $BRANCH." >&2
    exit 1
elif tagged "$VERSION"; then
    if ours "$VERSION" && ! finished "$VERSION"; then
        tagged_today=$(tagged_date "$VERSION")
        echo "$VERSION is tagged but not yet published or not yet merged into $BRANCH; resuming it, dated $tagged_today."
        finish+=("$VERSION:$tagged_today")
    else
        echo "$VERSION is already released; nothing new to release."
    fi
else
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
    release_needed=true
    finish+=("$VERSION:$TODAY")
fi

emit "release_needed=$release_needed"
if (( ${#finish[@]} > 0 )); then
    emit "publish_needed=true"
else
    emit "publish_needed=false"
fi
emit "version=$VERSION"
emit "plugin_name=$PLUGIN_NAME"
emit "today=$TODAY"
emit "finish=${finish[*]}"
