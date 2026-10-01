#!/bin/bash
# Creates the GitHub Release for an already-created plugin tag, or publishes an existing draft or
# prerelease of it.
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

# The name and notes are left alone: a maintainer may have edited them.
mark_published() {
    gh api --method PATCH "repos/$GITHUB_REPOSITORY/releases/$1" \
        --field draft=false \
        --field prerelease=false \
        --raw-field make_latest=false >/dev/null
}

set +e
gh api --include "repos/$GITHUB_REPOSITORY/releases/tags/$VERSION" \
    > "$release_response" 2> "$release_error"
release_status=$?
set -e

if [[ "$release_status" == 0 ]]; then
    release_state=$(python3 - "$release_response" <<'PY'
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
    if isinstance(payload, dict) and "id" in payload:
        print(payload["id"], "prerelease" if payload.get("prerelease") is True else "published")
        break
PY
)
    read -r release_id release_publication <<< "$release_state"
    if [[ -z "${release_id:-}" ]]; then
        echo "GitHub returned a release response without an id." >&2
        exit 1
    fi

    if [[ "$release_publication" == prerelease ]]; then
        mark_published "$release_id"
    else
        echo "The GitHub Release for $VERSION is already published; leaving it unchanged."
    fi
elif grep -Eq '^HTTP/[0-9.]+[[:space:]]+404([[:space:]]|$)' "$release_response"; then
    # The tag lookup only returns published releases, so a draft for this tag is found by listing.
    draft_releases=$(mktemp)
    gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
        --jq '.[] | select(.draft) | "\(.id) \(.tag_name)"' > "$draft_releases"
    draft_id=$(awk -v version="$VERSION" '$2 == version { print $1; exit }' "$draft_releases")
    rm -f "$draft_releases"

    if [[ -n "$draft_id" ]]; then
        mark_published "$draft_id"
    else
        gh release create "$VERSION" \
            --repo "$GITHUB_REPOSITORY" \
            --verify-tag \
            --title "$PLUGIN_NAME $VERSION" \
            --notes-file "$release_notes" \
            --latest=false
    fi
else
    cat "$release_error" >&2
    cat "$release_response" >&2
    exit "$release_status"
fi
