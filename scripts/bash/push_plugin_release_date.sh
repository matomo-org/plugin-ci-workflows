#!/bin/bash
# Dates the CHANGELOG.md entry for plugin.json's version and pushes it to
# automated/release-date-<version>, refreshing an open pull request from that branch. The pull
# request is opened after tagging, by merge_plugin_release_date_pr.sh. HEAD is left on the dated
# commit when one is pushed, and on the target branch's tip otherwise.
# Run from a checkout of the target branch, with a pushable origin and an authenticated gh.
# Usage: push_plugin_release_date.sh <target-branch> [release-date]

set -euo pipefail

TARGET_BRANCH="${1:-}"
RELEASE_DATE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"

if [[ -z "$TARGET_BRANCH" ]]; then
    echo "Usage: $0 <target-branch> [release-date]" >&2
    exit 1
fi
if [[ -z "$RELEASE_DATE" ]]; then
    # Tests pin the day; the workflow always uses the real one.
    RELEASE_DATE="${PLUGIN_RELEASE_TODAY:-$(date -u +%F)}"
fi

error() {
    echo "::error::$*" >&2
    exit 1
}

if ! metadata=$(python3 -c 'import json; p = json.load(open("plugin.json", encoding="utf-8")); print(p["version"]); print(p["name"])' 2>&1); then
    error "Could not read the version and name from plugin.json: $metadata"
fi
mapfile -t metadata_lines <<< "$metadata"
VERSION="${metadata_lines[0]}"
PLUGIN_NAME="${metadata_lines[1]}"
BRANCH="automated/release-date-$VERSION"

# Re-dating a released version would make the changelog disagree with the published release.
tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$VERSION" > /dev/null || tag_status=$?
if (( tag_status == 0 )); then
    echo "::notice::$VERSION is already released, so its changelog date is left alone."
    exit 0
elif (( tag_status != 2 )); then
    error "Could not list the tags on origin."
fi

python3 "$SCRIPT_DIR/../python/update_changelog_date.py" --plugin-name "$PLUGIN_NAME" \
    CHANGELOG.md "$VERSION" "$RELEASE_DATE"
if git diff --quiet -- CHANGELOG.md; then
    echo "$TARGET_BRANCH already dates $VERSION as $RELEASE_DATE."
    exit 0
fi

# Leaves the working tree as HEAD has it, so nothing after this reads a date that was not pushed.
leave_alone() {
    git checkout --quiet -- CHANGELOG.md
    echo "::warning::$*"
    exit 0
}

# The branch is rebuilt and force-pushed, so a commit someone added to it by hand is never overwritten.
branch_status=0
expected_tip=""
git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" > /dev/null || branch_status=$?
if (( branch_status == 0 )); then
    # In a shallow checkout, the range below would take all the history behind the branch as commits on it.
    unshallow=()
    if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
        unshallow=(--unshallow)
    fi
    git fetch --quiet --no-tags "${unshallow[@]}" origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
    expected_tip=$(git rev-parse "refs/remotes/origin/$BRANCH")
    # The committer is checked too, because amending the workflow's commit keeps its author. The log
    # is captured first: grep -q exiting early would SIGPIPE git log, and pipefail would read that as no match.
    identities=$(git log --format='%ae%n%ce' "HEAD..refs/remotes/origin/$BRANCH")
    if [[ -n "$identities" ]] && grep -qvxF "$BOT_EMAIL" <<< "$identities"; then
        leave_alone "$BRANCH has commits from someone other than this workflow, so it was left alone."
    fi
    # Rebuilding the branch on another base would put that base's history into this pull request.
    open_bases=$(gh pr list --head "$BRANCH" --state open --json baseRefName --jq '.[].baseRefName')
    while IFS= read -r open_base; do
        if [[ -n "$open_base" && "$open_base" != "$TARGET_BRANCH" ]]; then
            leave_alone "$BRANCH is proposed for $open_base, so it was left alone. Merge or close that pull request first."
        fi
    done <<< "$open_bases"
elif (( branch_status != 2 )); then
    error "Could not list the branches on origin."
fi

# The identity check above relies on these, and GIT_AUTHOR_* and GIT_COMMITTER_* would override git config.
GIT_AUTHOR_NAME="github-actions[bot]" GIT_AUTHOR_EMAIL="$BOT_EMAIL" \
    GIT_COMMITTER_NAME="github-actions[bot]" GIT_COMMITTER_EMAIL="$BOT_EMAIL" \
    git commit --quiet -m "Add release date for $VERSION" -- CHANGELOG.md
# The lease refuses the push if anyone pushed to the branch since the check above.
git push --quiet --force-with-lease="refs/heads/$BRANCH:$expected_tip" origin "HEAD:refs/heads/$BRANCH"
echo "$BRANCH dates $VERSION as $RELEASE_DATE."
