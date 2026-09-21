#!/bin/bash
# Validates plugin release metadata and decides whether the current production branch needs a
# release. The caller must fetch origin/<branch> before invoking this script.
# Usage: prepare_plugin_release.sh <plugin.json> <production-branch>

set -euo pipefail

PLUGIN_JSON="${1:-}"
RELEASE_BRANCH="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$PLUGIN_JSON" || -z "$RELEASE_BRANCH" ]]; then
    echo "Usage: $0 <plugin.json> <production-branch>" >&2
    exit 1
fi

error() {
    echo "::error::$*" >&2
    exit 1
}

if ! metadata=$(python3 - "$PLUGIN_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as plugin_file:
        plugin = json.load(plugin_file)
except (OSError, json.JSONDecodeError) as error:
    print(f"Could not read {path}: {error}", file=sys.stderr)
    sys.exit(1)

version = plugin.get("version")
name = plugin.get("name")
if not isinstance(version, str) or not isinstance(name, str):
    print(f"{path} must contain string values for version and name", file=sys.stderr)
    sys.exit(1)
if not name or "\n" in name or "\r" in name:
    print(f"{path} contains an invalid plugin name", file=sys.stderr)
    sys.exit(1)

print(version)
print(name)
PY
  2>&1
); then
    error "$metadata"
fi

mapfile -t metadata_lines <<< "$metadata"
if (( ${#metadata_lines[@]} != 2 )); then
    error "$PLUGIN_JSON contains metadata with an unsupported newline"
fi
VERSION="${metadata_lines[0]}"
PLUGIN_NAME="${metadata_lines[1]}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "$PLUGIN_JSON contains a non-stable release version: $VERSION"
fi

if [[ ! "$RELEASE_BRANCH" =~ ^([0-9]+)\.x-prod$ ]]; then
    error "Unsupported release branch: $RELEASE_BRANCH"
fi
EXPECTED_MAJOR="${BASH_REMATCH[1]}"
if [[ "${VERSION%%.*}" != "$EXPECTED_MAJOR" ]]; then
    error "Version $VERSION does not belong on $RELEASE_BRANCH"
fi

emit() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    else
        printf '%s\n' "$1"
    fi
}

read_tag_release_date() {
    local tag_commit="$1"
    local tag_changelog
    local parsed_date
    tag_changelog=$(mktemp)

    if ! git show "$tag_commit:CHANGELOG.md" > "$tag_changelog"; then
        rm -f "$tag_changelog"
        return 1
    fi
    if ! parsed_date=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --read-date "$tag_changelog" "$VERSION"); then
        rm -f "$tag_changelog"
        return 1
    fi
    rm -f "$tag_changelog"
    printf '%s\n' "$parsed_date"
}

HEAD_COMMIT=$(git rev-parse HEAD)
REMOTE_BRANCH_REF="refs/remotes/origin/$RELEASE_BRANCH"
REMOTE_BRANCH_COMMIT=""
if REMOTE_BRANCH_COMMIT=$(git rev-parse --verify "$REMOTE_BRANCH_REF^{commit}" 2>/dev/null); then
    :
else
    REMOTE_BRANCH_COMMIT=""
fi

tag_commit=""
if tag_commit=$(git rev-parse --verify "refs/tags/$VERSION^{commit}" 2>/dev/null); then
    if ! release_date=$(read_tag_release_date "$tag_commit"); then
        error "The tagged changelog entry for $VERSION has no readable release date."
    fi

    if [[ "$tag_commit" == "$HEAD_COMMIT" ]]; then
        echo "A tag for $VERSION already points at HEAD; the release can be safely resumed."
        emit "tag_exists=true"
        emit "release_needed=false"
    elif git merge-base --is-ancestor "$tag_commit" "$HEAD_COMMIT"; then
        echo "Version $VERSION is already released and its tag is behind this production branch; nothing to release."
        emit "tag_exists=true"
        emit "release_needed=false"
    elif git merge-base --is-ancestor "$HEAD_COMMIT" "$tag_commit"; then
        if [[ "$REMOTE_BRANCH_COMMIT" == "$tag_commit" ]]; then
            git checkout --detach "$tag_commit"
            echo "Recovered the previously tagged commit for $VERSION; the release can be safely resumed."
            emit "tag_exists=true"
            emit "release_needed=false"
        elif [[ -n "$REMOTE_BRANCH_COMMIT" ]] && git merge-base --is-ancestor "$tag_commit" "$REMOTE_BRANCH_COMMIT"; then
            echo "Version $VERSION is already released and its tag is behind this production branch; nothing to release."
            emit "tag_exists=true"
            emit "release_needed=false"
        else
            error "A tag for $VERSION exists on a commit unrelated to the current production branch. Refusing to move or rebuild it."
        fi
    else
        error "A tag for $VERSION exists on a commit unrelated to the current production branch. Refusing to move or rebuild it."
    fi
else
    if [[ -n "$REMOTE_BRANCH_COMMIT" && "$REMOTE_BRANCH_COMMIT" != "$HEAD_COMMIT" ]]; then
        if git merge-base --is-ancestor "$HEAD_COMMIT" "$REMOTE_BRANCH_COMMIT"; then
            error "The production branch advanced after this workflow run. Dispatch the release workflow again from the current branch tip instead of re-running failed jobs."
        fi
        error "The current commit and production branch tip have diverged. Dispatch the release workflow again from the current branch tip."
    fi

    release_date=$(date -u +%F)
    echo "Preparing a new release for $VERSION."
    emit "tag_exists=false"
    emit "release_needed=true"
fi

emit "version=$VERSION"
emit "plugin_name=$PLUGIN_NAME"
emit "release_date=$release_date"
emit "publish_release=true"
