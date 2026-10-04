#!/bin/bash
# Merges a released version back into its development branch, so the changelog
# date committed on N.x-prod cannot conflict with the next N.x-dev to N.x-prod merge.
# Usage: backmerge_plugin_release.sh <version> <production-branch>

set -euo pipefail

VERSION="${1:-}"
RELEASE_BRANCH="${2:-}"

if [[ -z "$VERSION" || -z "$RELEASE_BRANCH" ]]; then
    echo "Usage: $0 <version> <production-branch>" >&2
    exit 1
fi

if [[ ! "$RELEASE_BRANCH" =~ ^([0-9]+)\.x-prod$ ]]; then
    echo "Unsupported release branch: $RELEASE_BRANCH" >&2
    exit 1
fi
DEV_BRANCH="${BASH_REMATCH[1]}.x-dev"

error() {
    echo "::error::$VERSION is released, but could not be merged back into $DEV_BRANCH: $*" >&2
    exit 1
}

# The push is never forced, so a development branch that moves in the meantime rejects it rather
# than losing the commits that moved it.
push_dev() {
    git push origin "$1:refs/heads/$DEV_BRANCH" || error "the push failed. Merge it by hand."
}

# --is-ancestor exits 1 for "no" and 128 for an error, which a bare `if` would also read as "no".
is_ancestor() {
    local status=0
    git merge-base --is-ancestor "$1" "$2" || status=$?
    (( status <= 1 )) || error "the history of $DEV_BRANCH and $VERSION could not be read."
    return "$status"
}

# Exit status 2 is ls-remote's "no matching ref"; any other failure is an error, not a missing branch.
dev_lookup=0
git ls-remote --exit-code --heads origin "refs/heads/$DEV_BRANCH" >/dev/null || dev_lookup=$?
if (( dev_lookup == 2 )); then
    echo "::notice::$DEV_BRANCH does not exist; nothing to merge back into."
    exit 0
elif (( dev_lookup != 0 )); then
    error "$DEV_BRANCH could not be looked up."
fi
# The tag, not the branch tip, so that a production branch which moved on during the release
# contributes only what was released.
git fetch --no-tags origin \
    "refs/tags/$VERSION:refs/tags/$VERSION" \
    "+refs/heads/$DEV_BRANCH:refs/remotes/origin/$DEV_BRANCH" \
    || error "the release tag and $DEV_BRANCH could not be fetched."
release_commit=$(git rev-parse --verify -q "refs/tags/$VERSION^{commit}") \
    || error "tag $VERSION does not resolve to a commit."
dev_commit=$(git rev-parse --verify -q "refs/remotes/origin/$DEV_BRANCH^{commit}") \
    || error "$DEV_BRANCH does not resolve to a commit."

if is_ancestor "$release_commit" "$dev_commit"; then
    echo "$DEV_BRANCH already contains $VERSION; nothing to merge back."
    exit 0
fi

# Only the changelog is merged back unattended. Anything else the release has that dev lacks, such
# as a revert or a hotfix made on production, needs a person to decide whether dev should have it.
# Diffing the trees rather than walking commits also catches changes made while resolving a merge.
base_status=0
base_commit=$(git merge-base "$dev_commit" "$release_commit") || base_status=$?
if (( base_status == 1 )); then
    error "$DEV_BRANCH and $VERSION share no history. Merge it by hand."
elif (( base_status != 0 )); then
    error "the history of $DEV_BRANCH and $VERSION could not be read."
fi
# Files the release changed that are not identical on dev; a fix applied to both branches is not in
# the way until dev edits that file again. Renames are split into a delete and an add, so that a
# deletion cannot hide behind a rename.
released_files=$(git diff --no-renames --name-only "$base_commit" "$release_commit" -- . ':(exclude)CHANGELOG.md') \
    || error "the release could not be compared with $DEV_BRANCH."
differing_files=$(git diff --no-renames --name-only "$dev_commit" "$release_commit" -- . ':(exclude)CHANGELOG.md') \
    || error "the release could not be compared with $DEV_BRANCH."
other_files=$(comm -12 <(sort <<< "$released_files") <(sort <<< "$differing_files") | sed '/^$/d')
if [[ -n "$other_files" ]]; then
    error "it changes more than CHANGELOG.md ($(paste -sd ' ' <<< "$other_files")). Merge it by hand."
fi

if is_ancestor "$dev_commit" "$release_commit"; then
    push_dev "$release_commit"
    echo "Fast-forwarded $DEV_BRANCH to $VERSION."
    exit 0
fi

# Merged without a working tree, so the plugin checkout is never touched: no LFS downloads, and no
# untracked file in the workspace can block the merge.
# merge-tree exits 1 for conflicts, listing the files after the tree id, and above 1 when it cannot
# merge at all.
merge_status=0
merge_output=$(git merge-tree --write-tree --name-only --no-messages "$dev_commit" "$release_commit") \
    || merge_status=$?
if (( merge_status == 1 )); then
    conflicts=$(sed 1d <<< "$merge_output" | sort -u | paste -sd ' ')
    error "the merge conflicts in ${conflicts:-unknown files}. Merge it by hand."
elif (( merge_status != 0 )); then
    error "the merge could not be made. Merge it by hand."
fi
merge_commit=$(git -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" \
    commit-tree "${merge_output%%$'\n'*}" -p "$dev_commit" -p "$release_commit" \
    -m "Merge $VERSION from $RELEASE_BRANCH into $DEV_BRANCH") \
    || error "the merge commit could not be created."
push_dev "$merge_commit"
echo "Merged $VERSION into $DEV_BRANCH."
