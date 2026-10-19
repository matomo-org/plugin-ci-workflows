#!/bin/bash
# Creates the GitHub Release for an already-created plugin tag, or publishes a draft or prerelease
# of it that this workflow made. Anyone else's is left for them, since it may carry their own notes
# and files.
# Usage: publish_plugin_release.sh <plugin-name> <version> <release-date>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME="${1:-}"
VERSION="${2:-}"
RELEASE_DATE="${3:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
WORKFLOW_LOGIN="github-actions[bot]"

if [[ -z "$PLUGIN_NAME" || -z "$VERSION" || -z "$RELEASE_DATE" || -z "$GITHUB_REPOSITORY" ]]; then
    echo "Usage: $0 <plugin-name> <version> <release-date>" >&2
    exit 1
fi

release_notes=$(mktemp)
release_response=$(mktemp)
release_error=$(mktemp)
notes_error=$(mktemp)
trap 'rm -f "$release_notes" "$release_response" "$release_error" "$notes_error"' EXIT

# Reads the tag's changelog, since a run finishing an earlier version has a later commit checked out.
write_release_notes() {
    local changes reason
    changes=$( { git show "refs/tags/$VERSION:CHANGELOG.md" \
        | python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
            --read-notes --plugin-name "$PLUGIN_NAME" /dev/stdin "$VERSION"; } 2> "$notes_error") || changes=""
    {
        printf 'Released on %s.\n\n' "$RELEASE_DATE"
        if [[ -n "$changes" ]]; then
            printf '%s\n\n' "$changes"
        else
            reason=$(tr '\n' ' ' < "$notes_error")
            echo "::warning::No changes were read from the changelog entry for $VERSION in its tag${reason:+ (${reason% })}, so its release notes only link to CHANGELOG.md" >&2
        fi
        # Kept after the changes too, in case the entry's end was misread.
        printf 'See [CHANGELOG.md](https://github.com/%s/blob/%s/CHANGELOG.md) for the full changelog.\n' \
            "$GITHUB_REPOSITORY" "$VERSION"
    } > "$release_notes"
}

# Prints true when VERSION is higher than the current latest release, or there is none, so a patch
# on an older major never takes latest from a newer one. GitHub's own default is whichever was
# published last.
latest_flag() {
    local response status=0 latest
    response=$(gh api --include "repos/$GITHUB_REPOSITORY/releases/latest" 2>/dev/null) || status=$?
    if (( status != 0 )); then
        if grep -Eq '^HTTP/[0-9.]+[[:space:]]+404([[:space:]]|$)' <<< "$response"; then
            echo true
            return
        fi
        echo "Could not look up the latest GitHub Release." >&2
        return 1
    fi
    # -P keeps the plugin checkout, the working directory, off the import path, so its json.py cannot stand in for the real module.
    latest=$(python3 -P -c '
import json, re, sys
for part in reversed(re.split(r"\r?\n\r?\n", sys.stdin.read())):
    try:
        payload = json.loads(part)
    except json.JSONDecodeError:
        continue
    if isinstance(payload, dict) and "tag_name" in payload:
        print(payload["tag_name"])
        break
' <<< "$response")
    if [[ -z "$latest" ]]; then
        echo "GitHub returned a latest release without a tag." >&2
        return 1
    fi
    latest="${latest#v}"
    if [[ "$latest" != "$VERSION" && "$(printf '%s\n%s\n' "$latest" "$VERSION" | sort -V | tail -n 1)" == "$VERSION" ]]; then
        echo true
    else
        echo false
    fi
}

# Takes the release's id and its author's login. The name and notes are left alone: a maintainer may
# have edited them.
mark_published() {
    if [[ "$2" != "$WORKFLOW_LOGIN" ]]; then
        echo "::warning::The unpublished GitHub Release for $VERSION was made by $2, so it was left for them to publish."
        return
    fi
    local make_latest
    make_latest=$(latest_flag)
    gh api --method PATCH "repos/$GITHUB_REPOSITORY/releases/$1" \
        --field draft=false \
        --field prerelease=false \
        --raw-field "make_latest=$make_latest" >/dev/null
}

set +e
gh api --include "repos/$GITHUB_REPOSITORY/releases/tags/$VERSION" \
    > "$release_response" 2> "$release_error"
release_status=$?
set -e

if [[ "$release_status" == 0 ]]; then
    # -P keeps the plugin checkout, the working directory, off the import path, so its json.py cannot stand in for the real module.
    release_state=$(python3 -P - "$release_response" <<'PY'
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
        print(
            payload["id"],
            "prerelease" if payload.get("prerelease") is True else "published",
            (payload.get("author") or {}).get("login", ""),
        )
        break
PY
)
    read -r release_id release_publication release_author <<< "$release_state"
    if [[ -z "${release_id:-}" ]]; then
        echo "GitHub returned a release response without an id." >&2
        exit 1
    fi

    if [[ "$release_publication" == prerelease ]]; then
        mark_published "$release_id" "${release_author:-}"
    else
        echo "The GitHub Release for $VERSION is already published; leaving it unchanged."
    fi
elif grep -Eq '^HTTP/[0-9.]+[[:space:]]+404([[:space:]]|$)' "$release_response"; then
    # The tag lookup only returns published releases, so a draft for this tag is found by listing.
    draft_releases=$(mktemp)
    gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
        --jq '.[] | select(.draft) | "\(.id) \(.tag_name) \(.author.login)"' > "$draft_releases"
    read -r draft_id draft_author < <(awk -v version="$VERSION" '$2 == version { print $1, $3; exit }' "$draft_releases") || true
    rm -f "$draft_releases"

    if [[ -n "${draft_id:-}" ]]; then
        mark_published "$draft_id" "${draft_author:-}"
    else
        make_latest=$(latest_flag)
        write_release_notes
        gh release create "$VERSION" \
            --repo "$GITHUB_REPOSITORY" \
            --verify-tag \
            --title "$PLUGIN_NAME $VERSION" \
            --notes-file "$release_notes" \
            "--latest=$make_latest"
    fi
else
    cat "$release_error" >&2
    cat "$release_response" >&2
    exit "$release_status"
fi
