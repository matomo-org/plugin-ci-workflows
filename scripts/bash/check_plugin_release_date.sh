#!/bin/bash
# Fails when plugin.json's unreleased version has a dated CHANGELOG.md entry, or one the release
# could not date, in a plugin released by plugin-dev-release.yml. That workflow dates the entry the
# day it releases it, so a date written by hand is a guess it would overwrite.
# Passes for any other plugin or branch, a prerelease version, or a version already tagged, which
# includes the release date pull request the workflow opens after tagging.
# Run from a checkout of the plugin.
# Usage: check_plugin_release_date.sh <branch>

set -euo pipefail

BRANCH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tests pin the day; the workflow always uses the real one.
TODAY="${PLUGIN_RELEASE_TODAY:-$(date -u +%F)}"
RELEASE_WORKFLOW='plugin-ci-workflows/.github/workflows/plugin-dev-release.yml@'

if [[ -z "$BRANCH" ]]; then
    echo "Usage: $0 <branch>" >&2
    exit 1
fi

error() {
    echo "::error file=$1::$2" >&2
    exit 1
}

if [[ ! "$BRANCH" =~ ^([0-9]+)\.x-dev$ ]]; then
    echo "$BRANCH is not released by the weekly release, so the changelog date is not checked."
    exit 0
fi
expected_major="${BASH_REMATCH[1]}"

shopt -s nullglob
workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
if (( ${#workflow_files[@]} == 0 )) || ! grep -qF "$RELEASE_WORKFLOW" "${workflow_files[@]}"; then
    echo "This plugin does not call plugin-dev-release.yml, so its changelog dates are its own."
    exit 0
fi

if ! metadata=$(python3 -c 'import json; p = json.load(open("plugin.json", encoding="utf-8")); print(p["version"]); print(p["name"])' 2>&1); then
    error plugin.json "Could not read the version and name from plugin.json: $metadata"
fi
mapfile -t metadata_lines <<< "$metadata"
VERSION="${metadata_lines[0]}"
PLUGIN_NAME="${metadata_lines[1]}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$VERSION is not a stable version, so it is not released and its date is not checked."
    exit 0
fi
if [[ "${VERSION%%.*}" != "$expected_major" ]]; then
    error plugin.json "Version $VERSION does not belong on $BRANCH."
fi

tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$VERSION" > /dev/null || tag_status=$?
if (( tag_status == 0 )); then
    echo "$VERSION is already released."
    exit 0
elif (( tag_status != 2 )); then
    echo "::error::Could not list the tags on origin." >&2
    exit 1
fi

# Dating a scratch copy proves the release will find the entry and can date it.
scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT
cp CHANGELOG.md "$scratch"
if ! dating_error=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
    --plugin-name "$PLUGIN_NAME" "$scratch" "$VERSION" "$TODAY" 2>&1); then
    error CHANGELOG.md "The weekly release could not date the $VERSION entry: $dating_error"
fi

if changelog_date=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
    --read-date --plugin-name "$PLUGIN_NAME" CHANGELOG.md "$VERSION" 2>/dev/null); then
    error CHANGELOG.md "The $VERSION entry is dated $changelog_date. Leave it undated or write Unreleased: the weekly release dates it on the day it releases."
fi

echo "$VERSION is undated, so the weekly release will date it."
