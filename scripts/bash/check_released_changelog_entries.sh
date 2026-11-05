#!/bin/bash
# Fails a pull request that changes the CHANGELOG.md entry of a version already tagged, which is how a
# change ends up listed under a release it did not ship in. A pull request that changes nothing but
# CHANGELOG.md passes, so a released entry can still be corrected, and so does the weekly release's
# own release date pull request.
# The base is the branch's current tip and the tags are listed when the check runs, so re-running it
# catches a version released after the pull request was opened.
# With --push it checks a push instead, after the fact, for a pull request merged on a result from
# before its version was released. A push holding a merge commit is not checked, as merging another
# branch back brings that branch's released entries with it.
# Run from a checkout of the plugin with the history of the base branch and the pull request's head.
# Usage: check_released_changelog_entries.sh <base branch> <pull request head sha>
#        check_released_changelog_entries.sh --push <before sha> <after sha>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage="Usage: $0 <base branch> <pull request head sha> | --push <before sha> <after sha>"

if [[ "${1:-}" == --push ]]; then
    BEFORE="${2:-}"
    HEAD_SHA="${3:-}"
    if [[ -z "$BEFORE" || -z "$HEAD_SHA" ]]; then
        echo "$usage" >&2
        exit 1
    fi
    # A new branch's push has no before.
    if [[ "$BEFORE" =~ ^0+$ ]]; then
        echo "The push creates the branch, so there is nothing to compare."
        exit 0
    fi
    # A force push leaves the commit it replaced out of the fetched history.
    if ! git cat-file -e "$BEFORE^{commit}" 2> /dev/null; then
        echo "$BEFORE is not in the branch's history, as after a force push, so there is nothing to compare."
        exit 0
    fi
    if ! merge_base=$(git merge-base "$BEFORE" "$HEAD_SHA" 2>&1); then
        echo "::error::Could not compare the push with $BEFORE: $merge_base" >&2
        exit 1
    fi
    if [[ -n "$(git rev-list --merges "$merge_base..$HEAD_SHA")" ]]; then
        echo "The push holds a merge commit, so its changelog entries are not checked."
        exit 0
    fi
else
    BRANCH="${1:-}"
    HEAD_SHA="${2:-}"
    if [[ -z "$BRANCH" || -z "$HEAD_SHA" ]]; then
        echo "$usage" >&2
        exit 1
    fi
    if ! merge_base=$(git merge-base "refs/remotes/origin/$BRANCH" "$HEAD_SHA" 2>&1); then
        echo "::error::Could not find where the pull request branched from $BRANCH: $merge_base" >&2
        exit 1
    fi
fi

if ! diff_output=$(git diff --name-only --no-renames "$merge_base" "$HEAD_SHA" 2>&1); then
    echo "::error::Could not list the changed files: $diff_output" >&2
    exit 1
fi
mapfile -t changed_files <<< "$diff_output"
if ! grep -qxF CHANGELOG.md <<< "$diff_output"; then
    echo "CHANGELOG.md is not changed."
    exit 0
fi
if (( ${#changed_files[@]} == 1 )); then
    echo "Only CHANGELOG.md is changed, so a released entry may be corrected."
    exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Writes <rev>:<path> to <file>, leaving no file when the path is not in that commit. Read through the
# tree, so a blob that cannot be fetched fails rather than passing as a missing file.
show() {
    local rev="$1" path="$2" file="$3" out
    if ! out=$(git ls-tree --name-only "$rev" -- "$path" 2>&1); then
        echo "::error::Could not read the tree of $rev: $out" >&2
        exit 1
    fi
    [[ -n "$out" ]] || return 0
    if ! git show "$rev:$path" > "$file" 2> "$scratch/show-error"; then
        echo "::error::Could not read $path at $rev: $(tr '\n' ' ' < "$scratch/show-error")" >&2
        exit 1
    fi
}

# A changelog missing on one side reads as having no entries.
show "$merge_base" CHANGELOG.md "$scratch/old"
show "$HEAD_SHA" CHANGELOG.md "$scratch/new"
show "$HEAD_SHA" plugin.json "$scratch/plugin.json"

# The name lets the parser read "TestPlugin 6.0.2" version lines; without it they are not entries.
plugin_name=""
if [[ -f "$scratch/plugin.json" ]] && ! plugin_name=$(python3 -P -c \
    'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("name") or "")' \
    "$scratch/plugin.json" 2>&1); then
    echo "::error file=plugin.json::Could not read the plugin name from plugin.json: $plugin_name" >&2
    exit 1
fi
name_args=()
if [[ -n "$plugin_name" ]]; then
    name_args=(--plugin-name "$plugin_name")
fi

if ! changed=$(python3 "$SCRIPT_DIR/../python/changed_changelog_entries.py" "${name_args[@]}" \
    "$scratch/old" "$scratch/new" 2>&1); then
    echo "::error file=CHANGELOG.md::Could not compare the changelog entries: $changed" >&2
    exit 1
fi

if [[ -z "$changed" ]]; then
    echo "No changelog entry is changed."
    exit 0
fi

# Listed from origin when the job runs, not from the checkout, so a re-run sees a later release.
if ! tags=$(git ls-remote --tags --refs origin 2>&1); then
    echo "::error::Could not list the tags on origin: $tags" >&2
    exit 1
fi
released=()
while IFS= read -r version; do
    [[ -n "$version" ]] || continue
    if grep -qE "[[:space:]]refs/tags/v?${version//./\\.}$" <<< "$tags"; then
        released+=("$version")
    fi
done <<< "$changed"

if (( ${#released[@]} )); then
    list=$(printf '%s, ' "${released[@]}")
    echo "::error file=CHANGELOG.md::This changes the changelog entry of ${list%, }, already released. Add the change to the next version's entry instead. To correct a released entry, do it in a pull request that changes only CHANGELOG.md." >&2
    exit 1
fi

echo "No released changelog entry is changed."
