#!/bin/bash
# Fails a pull request that changes the CHANGELOG.md entry of a version already tagged, which is how a
# change ends up listed under a release it did not ship in. A pull request that changes nothing but
# CHANGELOG.md passes, so a released entry can still be corrected, and so does the weekly release's
# own release date pull request.
# The base is the branch's current tip and the tags are listed when the check runs, so re-running it
# catches a version released after the pull request was opened.
# With --push it checks a push instead, after the fact, for a pull request merged on a result from
# before its version was released. A force push is not checked, and nor is a push holding a merge
# commit, as merging another branch back brings that branch's released entries with it. A re-run after
# the push's own version is released does not fail for that version's entry.
# Run from a checkout of the plugin with the history of the base branch and the pull request's head.
# Usage: check_released_changelog_entries.sh <base branch> <pull request head sha>
#        check_released_changelog_entries.sh --push <before sha> <after sha>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
usage="Usage: $0 <base branch> <pull request head sha> | --push <before sha> <after sha>"

PUSH=""
if [[ "${1:-}" == --push ]]; then
    PUSH=1
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
    # A force push's replaced commit may be gone, or, as the blobless checkout fetches a missing commit
    # on demand, still present but no longer an ancestor.
    force_pushed="$BEFORE is not in the branch's history, as after a force push, so there is nothing to compare."
    if ! git cat-file -e "$BEFORE^{commit}" 2> /dev/null; then
        echo "$force_pushed"
        exit 0
    fi
    status=0
    git merge-base --is-ancestor "$BEFORE" "$HEAD_SHA" 2> "$scratch/ancestor-error" || status=$?
    if (( status == 1 )); then
        echo "$force_pushed"
        exit 0
    elif (( status )); then
        echo "::error::Could not compare the push with $BEFORE: $(tr '\n' ' ' < "$scratch/ancestor-error")" >&2
        exit 1
    fi
    merge_base="$BEFORE"
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

# Listed from origin when the job runs, not from the checkout, so a re-run sees a later release. An
# annotated tag is also listed peeled, as <ref>^{}, which names its commit.
if ! tags=$(git ls-remote --tags origin 2>&1); then
    echo "::error::Could not list the tags on origin: $tags" >&2
    exit 1
fi
released=()
while IFS= read -r version; do
    [[ -n "$version" ]] || continue
    # Through ENVIRON, as awk -v would turn the escaped dots into any character.
    tag_shas=$(TAG_PATTERN="^refs/tags/v?${version//./\\.}(\\^\\{\\})?$" awk '
        $2 ~ ENVIRON["TAG_PATTERN"] { ref = $2; sub(/\^\{\}$/, "", ref); if ($2 != ref || !(ref in commit)) commit[ref] = $1 }
        END { for (ref in commit) print commit[ref] }' <<< "$tags")
    [[ -n "$tag_shas" ]] || continue
    # A re-run of a push after the release: the push shipped in that version, so it did not change a
    # released entry.
    if [[ -n "$PUSH" ]]; then
        shipped=""
        for tag_sha in $tag_shas; do
            if git merge-base --is-ancestor "$HEAD_SHA" "$tag_sha" 2> "$scratch/ancestor-error"; then
                shipped=1
                break
            elif (( $? != 1 )); then
                echo "::error::Could not check whether $tag_sha holds $HEAD_SHA: $(tr '\n' ' ' < "$scratch/ancestor-error")" >&2
                exit 1
            fi
        done
        [[ -z "$shipped" ]] || continue
    fi
    released+=("$version")
done <<< "$changed"

if (( ${#released[@]} )); then
    list=$(printf '%s, ' "${released[@]}")
    echo "::error file=CHANGELOG.md::This changes the changelog entry of ${list%, }, already released. Add the change to the next version's entry instead. To correct a released entry, do it in a pull request that changes only CHANGELOG.md." >&2
    exit 1
fi

echo "No released changelog entry is changed."
