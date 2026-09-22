#!/bin/bash
# Creates or updates the GitHub Release for an already-created plugin tag.
# Usage: publish_plugin_release.sh <plugin-name> <version> <release-date>

set -euo pipefail

PLUGIN_NAME="${1:-}"
VERSION="${2:-}"
RELEASE_DATE="${3:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

if [[ -z "$PLUGIN_NAME" || -z "$VERSION" || -z "$RELEASE_DATE" || -z "$GITHUB_REPOSITORY" ]]; then
    echo "Usage: $0 <plugin-name> <version> <release-date>" >&2
    exit 1
fi

release_notes=$(mktemp)
release_response=$(mktemp)
release_error=$(mktemp)
trap 'rm -f "$release_notes" "$release_response" "$release_error"' EXIT

{
    printf 'Released on %s.\n\n' "$RELEASE_DATE"
    printf 'See [CHANGELOG.md](https://github.com/%s/blob/%s/CHANGELOG.md) for the changes in this release.\n' \
        "$GITHUB_REPOSITORY" "$VERSION"
} > "$release_notes"

set +e
gh api --include "repos/$GITHUB_REPOSITORY/releases/tags/$VERSION" \
    > "$release_response" 2> "$release_error"
release_status=$?
set -e

if [[ "$release_status" == 0 ]]; then
    release_id=$(python3 - "$release_response" <<'PY'
import json
import re
import sys

response = open(sys.argv[1], "rb").read()
parts = re.split(rb"\r?\n\r?\n", response)
for part in reversed(parts):
    try:
        payload = json.loads(part)
    except json.JSONDecodeError:
        continue
    if "id" in payload:
        print(payload["id"])
        break
PY
)
    if [[ -z "$release_id" ]]; then
        echo "GitHub returned a release response without an id." >&2
        exit 1
    fi

    gh api --method PATCH "repos/$GITHUB_REPOSITORY/releases/$release_id" \
        --raw-field "name=$PLUGIN_NAME $VERSION" \
        --raw-field "body=$(cat "$release_notes")" \
        --field draft=false \
        --field prerelease=false \
        --raw-field make_latest=false >/dev/null
elif grep -Eq '^HTTP/[0-9.]+[[:space:]]+404([[:space:]]|$)' "$release_response"; then
    gh release create "$VERSION" \
        --repo "$GITHUB_REPOSITORY" \
        --verify-tag \
        --title "$PLUGIN_NAME $VERSION" \
        --notes-file "$release_notes" \
        --latest=false
else
    cat "$release_error" >&2
    cat "$release_response" >&2
    exit "$release_status"
fi
