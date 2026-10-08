#!/bin/bash
# Tests that tagging re-fetches and verifies the production branch tip first.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/create_plugin_release_tag.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REMOTE="$WORK/remote.git"
REPO="$WORK/repo"
ADVANCER="$WORK/advancer"
git init --bare -q "$REMOTE"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
printf 'initial\n' > "$REPO/file"
git -C "$REPO" add file
git -C "$REPO" commit -q -m initial
git -C "$REPO" branch -M 5.x-prod
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q -u origin 5.x-prod

git clone -q --branch 5.x-prod "$REMOTE" "$ADVANCER"
git -C "$ADVANCER" config user.email test@example.com
git -C "$ADVANCER" config user.name Test
printf 'advanced\n' >> "$ADVANCER/file"
git -C "$ADVANCER" add file
git -C "$ADVANCER" commit -q -m advanced
git -C "$ADVANCER" push -q origin HEAD:5.x-prod

git -C "$REPO" checkout -q --detach HEAD
if (cd "$REPO" && bash "$SCRIPT" 5.0.0 5.x-prod) > "$WORK/stale.out" 2>&1; then
    echo 'A stale local commit must not be tagged' >&2
    exit 1
fi
grep -Fq 'Refusing to tag a stale commit' "$WORK/stale.out"
if git -C "$REPO" rev-parse --verify refs/tags/5.0.0 >/dev/null 2>&1; then
    echo 'A stale local commit must not create a tag' >&2
    exit 1
fi

git -C "$REPO" checkout -q --detach refs/remotes/origin/5.x-prod
(cd "$REPO" && bash "$SCRIPT" 5.0.0 5.x-prod)
test "$(git -C "$REMOTE" rev-parse refs/tags/5.0.0)" = "$(git -C "$REPO" rev-parse HEAD)"

echo 'All plugin release tag tests passed.'
