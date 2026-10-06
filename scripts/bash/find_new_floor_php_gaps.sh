#!/bin/bash
# Lists uses of PHP's own functions, classes and members that vendor/prefixed makes and the plugin's
# PHP floor does not have, and that the tree before the rebuild did not already make.
#
# Rector transpiles syntax down to the floor, but not what a newer PHP added to the standard library:
# a release that starts calling array_find() or json_validate() still transpiles and lints, and fails
# at runtime on the floor. PHPStan, given the floor as phpVersion, reports those as not found.
#
# Run it on the floor PHP itself. PHPStan takes whatever the running PHP has as present whatever
# phpVersion says, so on a newer PHP the newer additions are not reported. PHPStan needs PHP 7.4, so a
# 7.3 floor runs on 7.4 and misses what 7.4 added.
#
# Only PHP's own symbols are kept, those in the global namespace or one PHP ships, since a scoped tree
# has many references to packages it does not install, such as optional integrations. Constants are
# left out, because packages define() their own global ones. Every scoped tree already makes some such
# uses, in branches guarded by function_exists() or a version check, so a message is listed only when
# the rebuilt tree has it more often than the earlier tree did, and then for each file that has it more
# often. A use that only moved to another file is not listed.
#
# Usage: find_new_floor_php_gaps.sh <plugin-dir> <floor> <phpstan> [base-rev]
# floor is the PHP version as major.minor, such as 8.1. phpstan is the PHPStan executable. base-rev
# holds the tree before the rebuild, HEAD by default. Prints one "<path>: <message>" line per new
# message in each file, and exits 0 whether or not it found any, or 1 when jq or timeout is missing,
# it cannot read the tree at base-rev or PHPStan does not run, or 2 on a usage error. PHPStan gets
# PHPSTAN_TIMEOUT seconds for each tree, 300 by default.

set -u

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <plugin-dir> <floor> <phpstan> [base-rev]" >&2
  exit 2
fi

plugin_dir="$1"
floor="$2"
phpstan="$3"
base="${4:-HEAD}"

if ! [[ "$floor" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
  echo "The floor is a PHP version as major.minor, such as 8.1, not $floor." >&2
  exit 2
fi
php_version=$((BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100))
# Otherwise their absence reads as PHPStan failing to run.
for tool in timeout jq; do
  if ! command -v "$tool" > /dev/null; then
    echo "This needs $tool." >&2
    exit 1
  fi
done

if ! git -C "$plugin_dir" rev-parse --quiet --verify "$base^{commit}" > /dev/null; then
  echo "Cannot read $base in $plugin_dir, so there is no earlier tree to compare vendor/prefixed with." >&2
  exit 1
fi
# A first rebuild has nothing to compare with, and would otherwise list every guarded use in the tree.
if [ -z "$(git -C "$plugin_dir" ls-tree -d --name-only "$base" -- vendor/prefixed)" ]; then
  echo "$base has no vendor/prefixed in $plugin_dir, so there is no earlier tree to compare with." >&2
  exit 1
fi

# Not $(cd "$(mktemp -d)" && pwd -P) in one go: a failed mktemp leaves cd "", which succeeds, and the
# trap would then delete the caller's directory.
tmp=$(mktemp -d) || exit 1
work=$(cd "$tmp" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

mkdir "$work/base"
# Not git archive, which leaves out whatever .gitattributes marks export-ignore, so every use in
# those files would read as new. From the top level, because in a subdirectory checkout-index skips
# every entry outside it, and so writes nothing and still succeeds.
if ! top=$(git -C "$plugin_dir" rev-parse --show-toplevel) \
  || ! tree=$(git -C "$plugin_dir" rev-parse "$base:./vendor/prefixed") \
  || ! GIT_INDEX_FILE="$work/index" git -C "$top" read-tree "$tree" \
  || ! GIT_INDEX_FILE="$work/index" git -C "$top" checkout-index -a --prefix="$work/base/vendor/prefixed/" \
  || ! [ -d "$work/base/vendor/prefixed" ]; then
  echo "Cannot extract vendor/prefixed at $base in $plugin_dir." >&2
  exit 1
fi

# The identifier of each finding that names a missing symbol, and a pattern whose s group is the
# class or function the floor has to have.
# shellcheck disable=SC2016 # $ is jq's, not the shell's.
filter='
  def symbol_pattern:
    "\\\\?(?<s>[A-Za-z_][\\\\A-Za-z0-9_]*)" as $n
    # PHPStan names a union receiver A|B::, of which only the last member is checked.
    | "(?:static\\()?(?:[\\\\A-Za-z0-9_]+\\|)*" as $receiver
    | {
        "function.notFound": ("^Function " + $n + " not found"),
        "class.notFound": ("(?:[Cc]lass|unknown class) " + $n + "(?: not found|\\.$)"),
        "interface.notFound": ("(?:[Ii]nterface|unknown interface) " + $n + "(?: not found|\\.$)"),
        "method.notFound": ("undefined method " + $receiver + $n + "\\)?::"),
        "staticMethod.notFound": ("undefined static method " + $receiver + $n + "\\)?::"),
        "property.notFound": ("undefined property " + $receiver + $n + "\\)?::"),
        "staticProperty.notFound": ("undefined static property " + $receiver + $n + "\\)?::"),
        "classConstant.notFound": ("undefined constant " + $receiver + $n + "\\)?::"),
        "arguments.count": ("^(?:Function|Method|Static method|Class) " + $n + "(?:::|(?:\\(\\))? invoked| constructor)")
      }[.] // null;
  # PHP names are case-insensitive, and PHPStan prints them as the source wrote them.
  def builtin:
    ltrimstr("\\") | ascii_downcase as $s
    | ($s | contains("\\") | not)
      # The namespaces PHPStan has stubs of PHP for, in phpstan/php-8-stubs/stubs/ext.
      or any(("bcmath\\", "dba\\", "dom\\", "ffi\\", "filter\\", "ftp\\", "imap\\", "io\\", "ldap\\", "odbc\\", "openssl\\", "pcntl\\", "pdo\\", "pgsql\\", "pspell\\", "random\\", "snmp\\", "soap\\", "time\\", "uri\\");
        . as $ns | $s | startswith($ns));
  .files
  | if type == "object" then to_entries else [] end
  # PHPStan reports a trait once for each class that uses it, keyed "<file> (in context of class X)",
  # so a release that adds such a class would repeat every use in the trait. A finding is kept once
  # for all the contexts it appears in, so one that only some of them have is still kept.
  | map(.key |= sub(" \\(in context of [^)]*\\)$"; "")) | group_by(.key)[]
  | (.[0].key | ltrimstr($root)) as $path
  | if length == 1 then .[0].value.messages[]
    else map(.value.messages[]) | unique_by([.line, .identifier, .message])[] end
  | (.identifier // "" | symbol_pattern) as $pattern
  | select($pattern != null)
  # A docblock or type alias that names a missing class never runs, and catching one never fails.
  | select(.message | startswith("PHPDoc tag") or startswith("Type alias") or startswith("Caught class") | not)
  | select([.message | capture($pattern)] | first | (.s // "") | (. != "" and builtin))
  | [.identifier, (.message | gsub("[\t\n]"; " ")), $path]
  | join("\t")
'

# Prints identifier, message and path for each kept finding in the tree under $1.
analyse() {
  local root="$1" name="$2"
  # JSON strings are NEON strings, so a path with a comma or a # in it stays one value.
  printf 'parameters:\n  level: 2\n  phpVersion: %s\n  paths: [%s]\n  tmpDir: %s\n' \
    "$php_version" "$(jq -n --arg p "$root/vendor/prefixed" '$p')" "$(jq -n --arg p "$work/tmp-$name" '$p')" > "$work/$name.neon"
  # 1 only means PHPStan found something, so the JSON is what says whether it ran. A run killed by
  # the timeout leaves none. The job's timeout-minutes leaves room for both runs at this limit, since
  # the job timing out would lose the pull request over a check that only warns.
  timeout "${PHPSTAN_TIMEOUT:-300}" "$phpstan" analyse -c "$work/$name.neon" --memory-limit=2G --no-progress --error-format=json \
    > "$work/$name.json" 2> "$work/$name.err"
  local status=$?
  if [ "$status" -eq 124 ]; then
    echo "PHPStan ran past ${PHPSTAN_TIMEOUT:-300}s on vendor/prefixed in $name." >&2
    return 1
  fi
  if ! jq -e '.totals' "$work/$name.json" > /dev/null 2>&1; then
    echo "PHPStan did not analyse vendor/prefixed in $name:" >&2
    tail -n 20 "$work/$name.err" >&2
    return 1
  fi
  # A worker that crashes still leaves JSON, with the files it never analysed missing from .files.
  if ! jq -e '(.errors // []) | length == 0' "$work/$name.json" > /dev/null; then
    echo "PHPStan did not analyse all of vendor/prefixed in $name:" >&2
    jq -r '.errors[]' "$work/$name.json" | head -n 20 >&2
    return 1
  fi
  jq -r --arg root "$root/" "$filter" "$work/$name.json"
}

# Only the files the pull request commits, so not what .gitignore excludes: the base never has those, so
# every use in them would read as new on every run.
mkdir "$work/rebuilt"
if ! (cd "$plugin_dir" && git ls-files -z --cached --others --exclude-standard -- vendor/prefixed > "$work/rebuilt-files") \
  || ! (cd "$plugin_dir" \
    && while IFS= read -r -d '' file; do
      # --cached still lists a tracked file the rebuild deleted.
      if [ -f "$file" ]; then printf '%s\0' "$file"; fi
    done < "$work/rebuilt-files" | xargs -0 -r cp --parents -t "$work/rebuilt") \
  || ! [ -d "$work/rebuilt/vendor/prefixed" ]; then
  echo "Cannot copy vendor/prefixed in $plugin_dir." >&2
  exit 1
fi

export LC_ALL=C
analyse "$work/base" base > "$work/known" || exit 1
analyse "$work/rebuilt" rebuilt > "$work/found" || exit 1

# Each line is one use, so the counts are how often each tree makes it.
awk -F '\t' '
    # Not NR == FNR, which an empty first file makes true of every line.
    FILENAME == ARGV[1] { known[$1 FS $2]++; known_in[$1 FS $2 FS $3]++; next }
    { found[$1 FS $2]++; found_in[$1 FS $2 FS $3]++; message[$1 FS $2 FS $3] = $3 ": " $2; use[$1 FS $2 FS $3] = $1 FS $2 }
    END {
      for (k in found_in) {
        if (found[use[k]] > known[use[k]] && found_in[k] > known_in[k]) print message[k]
      }
    }' "$work/known" "$work/found" \
  | sort -u
