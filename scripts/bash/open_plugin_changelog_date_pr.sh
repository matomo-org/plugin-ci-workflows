#!/bin/bash
# Dates the CHANGELOG.md entry for plugin.json's version on automated/release-date-<version>, and
# opens a pull request into the target branch or leaves the open one refreshed. When the target is
# N.x-prod and N.x-dev exists, the same branch is also proposed for N.x-dev, because dating the two
# branches with separate commits makes the next development-to-production merge conflict.
# Nothing is dated for a version the production branch (the target, or the pull request's base
# when given) would refuse to release.
# Run from a checkout of the target branch, with a pushable origin and an authenticated gh. When
# DATE_PR_RESULT_FILE is set, "opened" is written to it once a pull request carries the date.
# Usage: open_plugin_changelog_date_pr.sh <target-branch> [release-date] [production-branch]

set -euo pipefail

TARGET_BRANCH="${1:-}"
RELEASE_DATE="${2:-}"
PRODUCTION_BRANCH="${3:-}"
if [[ -z "$PRODUCTION_BRANCH" && "$TARGET_BRANCH" =~ ^[0-9]+\.x-prod$ ]]; then
    PRODUCTION_BRANCH="$TARGET_BRANCH"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"

if [[ -z "$TARGET_BRANCH" ]]; then
    echo "Usage: $0 <target-branch> [release-date] [production-branch]" >&2
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

if [[ "$PRODUCTION_BRANCH" =~ ^([0-9]+)\.x-prod$ ]]; then
    expected_major="${BASH_REMATCH[1]}"
    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "${VERSION%%.*}" != "$expected_major" ]]; then
        echo "::notice::$VERSION cannot be released from $PRODUCTION_BRANCH, so its changelog date is left alone."
        exit 0
    fi
fi

# Re-dating a released version would make the changelog disagree with the published release.
tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$VERSION" > /dev/null || tag_status=$?
if (( tag_status == 0 )); then
    echo "::notice::$VERSION is already released, so its changelog date is left alone."
    exit 0
elif (( tag_status != 2 )); then
    error "Could not list the tags on origin."
fi

targets=("$TARGET_BRANCH")
if [[ "$TARGET_BRANCH" =~ ^([0-9]+)\.x-prod$ ]]; then
    dev_branch="${BASH_REMATCH[1]}.x-dev"
    dev_status=0
    git ls-remote --exit-code --heads origin "refs/heads/$dev_branch" > /dev/null || dev_status=$?
    if (( dev_status == 0 )); then
        targets+=("$dev_branch")
    elif (( dev_status != 2 )); then
        error "Could not list the branches on origin."
    fi
fi

python3 "$SCRIPT_DIR/../python/update_changelog_date.py" --plugin-name "$PLUGIN_NAME" \
    CHANGELOG.md "$VERSION" "$RELEASE_DATE"
if git diff --quiet -- CHANGELOG.md; then
    echo "$TARGET_BRANCH already dates $VERSION as $RELEASE_DATE."
    exit 0
fi

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
        echo "::warning::$BRANCH has commits from someone other than this workflow, so it was left alone."
        exit 0
    fi
    # Rebuilding the branch on another base would put that base's history into this pull request,
    # such as development commits into one meant to merge only the date into production.
    open_bases=$(gh pr list --head "$BRANCH" --state open --json baseRefName --jq '.[].baseRefName')
    while IFS= read -r open_base; do
        if [[ -n "$open_base" && " ${targets[*]} " != *" $open_base "* ]]; then
            echo "::warning::$BRANCH is proposed for $open_base, so it was left alone. Merge or close that pull request first."
            exit 0
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

for target in "${targets[@]}"; do
    existing=$(gh pr list --head "$BRANCH" --base "$target" --state open --json number --jq '.[0].number // empty')
    if [[ -n "$existing" ]]; then
        echo "Pull request #$existing into $target now dates $VERSION as $RELEASE_DATE."
        continue
    fi
    body="Dates the $VERSION changelog entry as $RELEASE_DATE."
    if (( ${#targets[@]} > 1 )); then
        body+=" The same branch is proposed for ${targets[*]}: merge it into each, so the dated line does not conflict on the next merge into $TARGET_BRANCH."
    fi
    gh pr create --base "$target" --head "$BRANCH" --title "Add release date for $VERSION" --body "$body"
done

if [[ -n "${DATE_PR_RESULT_FILE:-}" ]]; then
    echo opened > "$DATE_PR_RESULT_FILE"
fi
