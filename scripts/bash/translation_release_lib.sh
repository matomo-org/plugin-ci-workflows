# Sourced by prepare_plugin_dev_release.sh and bump_plugin_translations.sh: whether the translation
# updates merged since a release can be released as its next patch. The caller sets BRANCH,
# remote_refs (git ls-remote --tags --heads origin) and SCRIPT_DIR.
# shellcheck shell=bash

# shellcheck disable=SC2154 # remote_refs is set by the caller
tagged() {
    grep -qxF "refs/tags/$1" <<< "$(cut -f2 <<< "$remote_refs")"
}

# Whether <commit> changes plugin.json against its first parent only to set the version, to <version> when given.
version_only() {
    local old new status=0
    old=$(mktemp)
    new=$(mktemp)
    if git show "$1^:plugin.json" > "$old" 2> /dev/null && git show "$1:plugin.json" > "$new" 2> /dev/null; then
        python3 "$SCRIPT_DIR/../python/version_only_change.py" "$old" "$new" ${2:+"$2"} || status=$?
    else
        status=1
    fi
    rm -f "$old" "$new"
    return "$status"
}

# shellcheck disable=SC2034 # read by the callers
TRANSLATION_ENTRY="Updated translations"
VENDORED_DEPS_BRANCH="automated/vendored-dependencies-$BRANCH"
# bump_plugin_translations.sh proposes the next patch from this branch, followed by the version.
# shellcheck disable=SC2034 # read by the callers
TRANSLATION_BUMP_PREFIX="automated/translation-version-"

# Whether <commit> is marked [ignore_release] or [no_release], which the release monitor also accepts,
# where the developer guide puts the marker: the subject, or for a merge the pull request title on the
# first body line. A squash body lists every sub-commit, so a marker on a screenshot commit there says
# nothing about the code the squash also changes.
ignored() {
    local marked
    marked=$(git log -1 --format=%s "$1")
    if git rev-parse -q --verify "$1^2" > /dev/null; then
        marked+=$'\n'$(git log -1 --format=%b "$1" | sed -n '/[^[:space:]]/{p;q;}')
    fi
    [[ "$marked" == *"[ignore_release]"* || "$marked" == *"[no_release]"* ]]
}

# Prints the version the vendored dependencies update branch moves plugin.json to, if there is one.
vendored_deps_version() {
    grep -qxF "refs/heads/$VENDORED_DEPS_BRANCH" <<< "$(cut -f2 <<< "$remote_refs")" || return 0
    # Runs in a command substitution, where exit only ends the subshell, so the caller exits on failure.
    if ! git fetch --quiet --no-tags origin "+refs/heads/$VENDORED_DEPS_BRANCH:refs/remotes/origin/$VENDORED_DEPS_BRANCH"; then
        echo "::error::Could not fetch $VENDORED_DEPS_BRANCH from origin." >&2
        return 1
    fi
    git show "refs/remotes/origin/$VENDORED_DEPS_BRANCH:plugin.json" 2> /dev/null \
        | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("version", ""))' 2> /dev/null || true
}

# Sets translation_version to the patch after the released <version> when every commit on the branch
# since its tag is a translation update, only records a version, or is marked [ignore_release] or
# [no_release], and at least one is a translation update. Weblate's are the usual ones: a translation
# update changes nothing but lang/*.json, and not lang/en.json, which holds the source strings code
# adds. Merges are read against their first parent, so a merged pull request counts as one commit.
translation_release() {
    local tag="$1" next commit files blocker="" translations=0 vendored
    translation_version=""
    [[ "$tag" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    next="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((10#${BASH_REMATCH[3]} + 1))"
    # Only until the release of $next is merged into the branch, which then moves plugin.json on.
    if tagged "$next" || tagged "v$next"; then
        return 1
    fi
    # Called only inside conditions, where set -e is off, so a failed fetch must exit by itself.
    if ! git fetch --quiet --no-tags origin "+refs/tags/$tag:refs/tags/$tag"; then
        echo "::error::Could not fetch the $tag tag from origin." >&2
        exit 1
    fi
    for commit in $(git rev-list --first-parent "refs/tags/$tag..HEAD"); do
        ! ignored "$commit" || continue
        if ! files=$(git diff --name-only --no-renames "$commit^" "$commit" 2>&1); then
            echo "::error::Could not list the files $commit changes: $files" >&2
            exit 1
        fi
        # The release date commit and its merge, and the date pull request of a translation release.
        if [[ -z "$files" || "$files" == CHANGELOG.md ]] \
            || { [[ "$files" == plugin.json || "$files" == $'CHANGELOG.md\nplugin.json' ]] && version_only "$commit"; }; then
            continue
        fi
        if ! grep -qvE '^lang/[^/]+\.json$' <<< "$files" && ! grep -qxF lang/en.json <<< "$files"; then
            translations=$((translations + 1))
        else
            blocker="$commit"
        fi
    done
    (( translations > 0 )) || return 1
    if [[ -n "$blocker" ]]; then
        echo "Translations were merged after $tag, but they wait for a person to release them with $(git log -1 --format='%h (%s)' "$blocker")."
        return 1
    fi
    # Its pull request bumps plugin.json to the same patch, so releasing it here would conflict with it.
    vendored=$(vendored_deps_version) || exit 1
    if [[ "$vendored" == "$next" ]]; then
        echo "::notice::Translations were merged after $tag, but $VENDORED_DEPS_BRANCH already moves plugin.json to $next, so they are released with that update."
        return 1
    fi
    # shellcheck disable=SC2034 # read by the callers
    translation_version="$next"
}
