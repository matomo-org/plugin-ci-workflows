#!/bin/bash
# Lists the classes in vendor/prefixed that fail to load on the PHP running this, and that loaded in
# the tree before the rebuild.
#
# Linting reads one file at a time, so it cannot see a class that only fails when PHP links it to
# its parents. Rector made one: OAuth2's 5.x rebuild dropped the return types of Uri::withScheme()
# and its siblings, which UriInterface kept, and every request that touched Uri was a fatal error.
# Every scoped tree already has classes that never load, such as integrations with packages it does
# not install, which is why only the classes the earlier tree could load are listed.
#
# Run it on the plugin's floor PHP: a downgraded tree is only expected to load there and later.
#
# Usage: find_new_unloadable_classes.sh <plugin-dir> [base-rev]
# base-rev holds the tree before the rebuild, HEAD by default. Prints the class and the error,
# separated by a tab, one line per class. Only the files the pull request would commit are loaded.
# Exits 0 whether or not it found any, 1 when it cannot read either tree, timeout is missing or
# load_prefixed_classes.php does not finish within LOAD_TIMEOUT seconds (600 by default), 2 on a usage
# error, 3 when base-rev has no vendor/prefixed, or 4 when its autoloader is missing or does not run,
# after listing every class that fails to load.

set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <plugin-dir> [base-rev]" >&2
  exit 2
fi

plugin_dir="$1"
base="${2:-HEAD}"
loader="$(cd "$(dirname "${BASH_SOURCE[0]}")/../php" && pwd)/load_prefixed_classes.php"

if ! git -C "$plugin_dir" rev-parse --quiet --verify "$base^{commit}" > /dev/null; then
  echo "Cannot read $base in $plugin_dir, so there is no earlier tree to compare vendor/prefixed with." >&2
  exit 1
fi

if ! command -v timeout > /dev/null; then
  echo "timeout is not on PATH." >&2
  exit 1
fi

# Not $(cd "$(mktemp -d)" && pwd -P) in one go: a failed mktemp leaves cd "", which succeeds, and the
# trap would then delete the caller's directory.
tmp=$(mktemp -d) || exit 1
work=$(cd "$tmp" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

load() {
  # A file that blocks at the top level would otherwise hold the job until its own limit.
  timeout "${LOAD_TIMEOUT:-600}" php "$loader" "$1" > "$2" && return
  echo "Cannot load the classes in $1, or it took longer than ${LOAD_TIMEOUT:-600}s." >&2
  exit 1
}

# The same file set as find_new_floor_php_gaps.sh, which says why.
mkdir "$work/rebuilt"
if ! (cd "$plugin_dir" && git ls-files -z --cached --others --exclude-standard -- vendor/prefixed > "$work/rebuilt-files") \
  || ! (cd "$plugin_dir" && set -o pipefail \
    && while IFS= read -r -d '' file; do
      if [ -f "$file" ]; then printf '%s\0' "$file"; fi
    done < "$work/rebuilt-files" | tar --null -T - -cf - | tar -xf - -C "$work/rebuilt") \
  || ! [ -d "$work/rebuilt/vendor/prefixed" ]; then
  echo "Cannot copy vendor/prefixed in $plugin_dir." >&2
  exit 1
fi

if [ -z "$(git -C "$plugin_dir" ls-tree -d --name-only "$base" -- vendor/prefixed)" ]; then
  echo "$base has no vendor/prefixed in $plugin_dir, so every class that fails to load is listed." >&2
  load "$work/rebuilt/vendor/prefixed" "$work/found"
  awk -F '\t' '$2 == "fail" { print $1 FS $3 }' "$work/found"
  exit 3
fi

# The same extraction as find_new_floor_php_gaps.sh, which says why it is not git archive.
mkdir "$work/base"
if ! top=$(git -C "$plugin_dir" rev-parse --show-toplevel) \
  || ! tree=$(git -C "$plugin_dir" rev-parse "$base:./vendor/prefixed") \
  || ! GIT_INDEX_FILE="$work/index" git -C "$top" read-tree "$tree" \
  || ! GIT_INDEX_FILE="$work/index" git -C "$top" checkout-index -a --prefix="$work/base/vendor/prefixed/" \
  || ! [ -d "$work/base/vendor/prefixed" ]; then
  echo "Cannot extract vendor/prefixed at $base in $plugin_dir." >&2
  exit 1
fi

load "$work/rebuilt/vendor/prefixed" "$work/found"
if [ -f "$work/base/vendor/prefixed/vendor/autoload.php" ]; then
  load "$work/base/vendor/prefixed" "$work/known"
else
  : > "$work/known"
fi

if [ "$(head -n 1 "$work/known" | cut -f 2)" != ok ]; then
  echo "The autoloader at $base is missing or does not run here, so every class that fails to load is listed." >&2
  awk -F '\t' '$2 == "fail" { print $1 FS $3 }' "$work/found"
  exit 4
fi

export LC_ALL=C
# Only classes that loaded before: a release can add a class that never loads, such as an integration
# with a package the plugin does not install.
awk -F '\t' 'FILENAME == ARGV[1] { if ($2 == "ok") loaded[$1]; next } $2 == "fail" && ($1 in loaded) { print $1 FS $3 }' "$work/known" "$work/found"
