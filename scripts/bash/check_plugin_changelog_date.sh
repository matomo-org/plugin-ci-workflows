#!/bin/bash
# Fails unless the CHANGELOG.md entry for plugin.json's version is dated today in UTC, so a required
# check holds a production pull request until the release date pull request is merged.
# Run from a checkout whose origin can list tags.
# Usage: check_plugin_changelog_date.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tests pin the day; the workflow always uses the real one.
TODAY="${PLUGIN_RELEASE_TODAY:-$(date -u +%F)}"

if ! metadata=$(python3 -c 'import json; p = json.load(open("plugin.json", encoding="utf-8")); print(p["version"]); print(p["name"])' 2>&1); then
    echo "::error file=plugin.json::Could not read the version and name from plugin.json: $metadata" >&2
    exit 1
fi
mapfile -t metadata_lines <<< "$metadata"
VERSION="${metadata_lines[0]}"
PLUGIN_NAME="${metadata_lines[1]}"

# A pull request that doesn't bump the version releases nothing, so its old date is right.
tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$VERSION" > /dev/null || tag_status=$?
if (( tag_status == 0 )); then
    echo "$VERSION is already released, so there is no new release date to check."
    exit 0
elif (( tag_status != 2 )); then
    echo "::error::Could not list the tags on origin." >&2
    exit 1
fi

if ! changelog_date=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
    --read-date --plugin-name "$PLUGIN_NAME" CHANGELOG.md "$VERSION" 2>&1); then
    echo "::error file=CHANGELOG.md::The $VERSION entry has no release date ($changelog_date). Merge the release date pull request, or date the entry $TODAY." >&2
    exit 1
fi

if [[ "$changelog_date" != "$TODAY" ]]; then
    echo "::error file=CHANGELOG.md::The $VERSION entry is dated $changelog_date, not today ($TODAY in UTC). Merge the release date pull request, or date the entry $TODAY." >&2
    exit 1
fi

echo "The $VERSION entry is dated $changelog_date."
