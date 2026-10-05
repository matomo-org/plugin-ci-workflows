#!/bin/bash
# Lists string literals in vendor/prefixed that name a scoped namespace without the prefix, and that
# the tree before the rebuild did not already have.
#
# php-scoper rewrites namespace declarations and class references, but not class names a package
# builds in a string, so a scoper.inc.php patcher has to. A patcher matches literal text, and does
# nothing once a release builds the name some other way: the tree still loads, and the class is not
# found at runtime. check_scoped_tree.sh cannot see this, because the namespace declarations are all
# prefixed.
#
# Every scoped tree already holds strings like these that are harmless, in error messages, comments
# and dead branches, so only strings the earlier tree held nowhere are listed. By string rather than
# by file, so a release that moves a file does not list everything in it again.
#
# Usage: find_new_unprefixed_strings.sh <plugin-dir> <plugin-name> [base-rev]
# base-rev holds the tree before the rebuild, HEAD by default, so a rebuild that is already committed
# lists nothing. Prints one "<path>: <string>" line per new string in each file, and exits 0 whether
# or not it found any, or 1 when it cannot read the tree at base-rev.

set -u

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <plugin-dir> <plugin-name> [base-rev]" >&2
  exit 2
fi

plugin_dir="$1"
plugin_name="$2"
base="${3:-HEAD}"
prefix="Matomo\\Dependencies\\$plugin_name\\"

if ! git -C "$plugin_dir" rev-parse --quiet --verify "$base^{commit}" > /dev/null; then
  echo "Cannot read $base in $plugin_dir, so there is no earlier tree to compare vendor/prefixed with." >&2
  exit 1
fi

# The first segment under the prefix of every namespace the tree declares, such as phpseclib3 or
# GuzzleHttp: the names php-scoper prefixed, and so the ones a string must not use bare.
# The rebuilt tree is searched with --untracked, which leaves out what .gitignore excludes, as the pull
# request does. A plain grep would list strings in those files on every run, since the base never has them.
roots=$(git -C "$plugin_dir" grep --untracked --text -hoE '^[[:space:]]*(<\?php[[:space:]]+)?namespace[[:space:]]+[A-Za-z0-9_\\]+' \
  -- 'vendor/prefixed/*.php' 2>/dev/null \
  | sed -E 's/.*namespace[[:space:]]+//' \
  | grep -F "$prefix" \
  | cut -c$((${#prefix} + 1))- \
  | cut -d"\\" -f1 \
  | sort -u \
  | paste -sd'|')
[ -n "$roots" ] || exit 0

# A quote, an optional leading backslash, then a scoped root followed by a namespace separator and
# optionally more of the name, since a package may append the rest itself. Either separator may be
# doubled, as it is inside a PHP string literal.
pattern="['\"]"'\\{0,2}('"$roots"')\\{1,2}([A-Za-z_][A-Za-z0-9_\\]{0,200})?'
# A scoped root can itself be Matomo, and then the pattern matches the prefixed form as well.
prefixed="^[^:]*:['\"]"'\\{0,2}Matomo\\{1,2}Dependencies\\{1,2}'"$plugin_name"'\\{1,2}'

# A first rebuild has nothing to compare with, and would otherwise list every string in the tree.
if [ -z "$(git -C "$plugin_dir" ls-tree -d --name-only "$base" -- vendor/prefixed)" ]; then
  echo "$base has no vendor/prefixed in $plugin_dir, so there is no earlier tree to compare with." >&2
  exit 1
fi

export LC_ALL=C
known=$(mktemp)
git -C "$plugin_dir" grep --text -hoE "$pattern" "$base" -- 'vendor/prefixed/*.php' > "$known"
# 1 only means nothing matched.
if [ "$?" -gt 1 ]; then
  echo "Cannot search vendor/prefixed at $base in $plugin_dir." >&2
  rm -f "$known"
  exit 1
fi

found=$(mktemp)
git -C "$plugin_dir" grep --untracked --text -oE "$pattern" -- 'vendor/prefixed/*.php' > "$found"
if [ "$?" -gt 1 ]; then
  echo "Cannot search vendor/prefixed in $plugin_dir." >&2
  rm -f "$known" "$found"
  exit 1
fi

{ grep -vE "$prefixed" "$found" || true; } \
  | sort -u \
  | awk '
      # Not NR == FNR, which an empty first file makes true of every line.
      FILENAME == ARGV[1] { known[$0] = 1; next }
      {
        path = substr($0, 1, index($0, ":") - 1)
        string = substr($0, length(path) + 2)
        if (!(string in known)) print path ": " string
      }' "$known" -
rm -f "$known" "$found"
