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
# by file, so a release that moves a file does not list everything in it again, and ignoring the
# quotes, escaping and a leading separator, so one that only rewrites a string in another form does not
# list it either.
#
# Usage: find_new_unprefixed_strings.sh <plugin-dir> <plugin-name> [base-rev]
# base-rev holds the tree before the rebuild, HEAD by default, so a rebuild that is already committed
# lists nothing. Prints one "<path>: <string>" line per new string in each file, the string as written
# from just after its opening quote. The string never holds a colon or a space, so the last ": " ends the
# path, which can. Exits 0 whether or not it found any, 1 when it cannot search either
# tree, 2 on a usage error, or 3 when base-rev has no vendor/prefixed.

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

# A first rebuild has nothing to compare with, and would otherwise list every string in the tree.
if [ -z "$(git -C "$plugin_dir" ls-tree -d --name-only "$base" -- vendor/prefixed)" ]; then
  echo "$base has no vendor/prefixed in $plugin_dir, so there is no earlier tree to compare with." >&2
  exit 3
fi

# Otherwise a grep.lineNumber, grep.column, grep.fullName or color.grep in the user's git config changes what
# each line is, and core.quotePath, on by default, quotes and escapes a path with a non-ASCII name.
search=(-c core.quotePath=false -c grep.fullName=false grep --text --no-line-number --no-column --no-color)

# The first segment under the prefix of every namespace the tree declares, such as phpseclib3 or
# GuzzleHttp: the names php-scoper prefixed, and so the ones a string must not use bare.
# The rebuilt tree is searched with --untracked, which leaves out what .gitignore excludes, as the pull
# request does. A plain grep would list strings in those files on every run, since the base never has them.
namespaces=$(mktemp) || exit 1
git -C "$plugin_dir" "${search[@]}" --untracked -hoE '^[[:space:]]*(<\?php[[:space:]]+)?namespace[[:space:]]+[A-Za-z0-9_\\]+' \
  -- 'vendor/prefixed/*.php' > "$namespaces"
# 1 only means nothing matched.
if [ "$?" -gt 1 ]; then
  echo "Cannot search vendor/prefixed in $plugin_dir." >&2
  rm -f "$namespaces"
  exit 1
fi
roots=$(sed -E 's/.*namespace[[:space:]]+//' "$namespaces" \
  | grep -F "$prefix" \
  | cut -c$((${#prefix} + 1))- \
  | cut -d"\\" -f1 \
  | sort -u \
  | paste -sd'|' -)
rm -f "$namespaces"
[ -n "$roots" ] || exit 0

# A quote, an optional leading backslash, then a scoped root followed by a namespace separator and
# optionally more of the name, since a package may append the rest itself. Either separator may be
# doubled, as it is inside a PHP string literal.
pattern="['\"]"'\\{0,2}('"$roots"')\\{1,2}([A-Za-z_][A-Za-z0-9_\\]{0,200})?'
# A scoped root can itself be Matomo, and then the pattern matches the prefixed form as well. Anchored
# at the end, since the match has no colon and the path before it can.
prefixed=":['\"]"'\\{0,2}Matomo\\{1,2}Dependencies\\{1,2}'"$plugin_name"'\\{1,2}[^:]*$'

export LC_ALL=C
known=$(mktemp) || exit 1
git -C "$plugin_dir" "${search[@]}" -hoE "$pattern" "$base" -- 'vendor/prefixed/*.php' > "$known"
if [ "$?" -gt 1 ]; then
  echo "Cannot search vendor/prefixed at $base in $plugin_dir." >&2
  rm -f "$known"
  exit 1
fi

found=$(mktemp) || { rm -f "$known"; exit 1; }
git -C "$plugin_dir" "${search[@]}" --untracked -oE "$pattern" -- 'vendor/prefixed/*.php' > "$found"
if [ "$?" -gt 1 ]; then
  echo "Cannot search vendor/prefixed in $plugin_dir." >&2
  rm -f "$known" "$found"
  exit 1
fi

{ grep -vE "$prefixed" "$found"; [ "$?" -le 1 ]; } \
  | sort -u \
  | awk '
      # Not NR == FNR, which an empty first file makes true of every line.
      # Either quote, any leading separator dropped, and each separator single or doubled: all name
      # the same class.
      function normalise(s,  out, i, c) {
        s = substr(s, 2)
        while (substr(s, 1, 1) == "\\") s = substr(s, 2)
        out = ""
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          out = out c
          if (c == "\\" && substr(s, i + 1, 1) == "\\") i++
        }
        return out
      }
      FILENAME == ARGV[1] { known[normalise($0)] = 1; next }
      {
        match($0, /:[^:]*$/)
        path = substr($0, 1, RSTART - 1)
        string = substr($0, RSTART + 1)
        # Not the closing quote, which the match stops short of, since a package may append the rest of the name.
        if (!(normalise(string) in known)) print path ": " substr(string, 2)
      }' "$known" -
compared="${PIPESTATUS[*]}"
rm -f "$known" "$found"
if [ "$compared" != "0 0 0" ]; then
  echo "Cannot compare the strings in vendor/prefixed in $plugin_dir." >&2
  exit 1
fi
