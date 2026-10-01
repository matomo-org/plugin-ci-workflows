#!/bin/bash
# Verifies the production branch tip immediately before creating a release tag.
# Usage: create_plugin_release_tag.sh <version> <production-branch>

set -euo pipefail

VERSION="${1:-}"
RELEASE_BRANCH="${2:-}"

if [[ -z "$VERSION" || -z "$RELEASE_BRANCH" ]]; then
    echo "Usage: $0 <version> <production-branch>" >&2
    exit 1
fi

if [[ ! "$RELEASE_BRANCH" =~ ^[0-9]+\.x-prod$ ]]; then
    echo "Unsupported release branch: $RELEASE_BRANCH" >&2
    exit 1
fi

git fetch --no-tags origin \
    "refs/heads/$RELEASE_BRANCH:refs/remotes/origin/$RELEASE_BRANCH"

head_commit=$(git rev-parse HEAD)
branch_commit=$(git rev-parse "refs/remotes/origin/$RELEASE_BRANCH^{commit}")
if [[ "$head_commit" != "$branch_commit" ]]; then
    echo "The production branch advanced before the release tag could be created. Refusing to tag a stale commit." >&2
    exit 1
fi

if git rev-parse --verify "refs/tags/$VERSION^{commit}" >/dev/null 2>&1; then
    echo "A tag for $VERSION already exists; refusing to create it again." >&2
    exit 1
fi

git tag "$VERSION"
git push origin "refs/tags/$VERSION"
