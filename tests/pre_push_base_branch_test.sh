#!/bin/bash
# Regression tests for the base branch hooks/pre-push diffs a push against, run against throwaway
# fixture repositories. Usage: bash tests/pre_push_base_branch_test.sh
#
# The hook is driven end to end rather than by extracting its functions, so what is asserted is the
# file list the analyser is actually handed. A stub analyser records that list.
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/pre-push"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=0

ZERO_OID='0000000000000000000000000000000000000000'

# A Matomo checkout holding one plugin, with a stub analyser that appends the arguments it was
# given to $MATOMO/analyser-args so a test can assert on them.
#
# $1 -- fixture name
new_fixture() {
  local matomo="$WORK/$1/matomo" plugin
  plugin="$matomo/plugins/TestPlugin"
  mkdir -p "$plugin/phpstan" "$matomo/vendor/bin"

  cat > "$matomo/vendor/bin/phpstan" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$(cd "$(dirname "$0")/../.." && pwd)/analyser-args"
STUB
  chmod 0755 "$matomo/vendor/bin/phpstan"
  : > "$matomo/analyser-args"
  echo 'parameters:' > "$plugin/phpstan/phpstan.created.neon"
  echo 'parameters:' > "$plugin/phpstan/phpstan.modified.neon"

  git -C "$plugin" init -q -b 5.x-dev
  git -C "$plugin" config user.email test@example.com
  git -C "$plugin" config user.name Test
  echo '<?php' > "$plugin/Shared.php"
  git -C "$plugin" add -A
  git -C "$plugin" commit -qm 'initial'
  # Remote-tracking refs are created directly: the hook only reads refs/remotes/origin/*, so a
  # real remote would add nothing but a clone.
  git -C "$plugin" update-ref refs/remotes/origin/5.x-dev HEAD

  printf '%s' "$plugin"
}

# $1 -- plugin dir, $2 -- commit to push
run_hook() {
  local plugin="$1" commit="$2"
  ( cd "$plugin" && echo "refs/heads/topic $commit refs/heads/topic $ZERO_OID" \
      | bash "$HOOK" origin git@example.com:matomo-org/plugin-TestPlugin.git 2>&1 )
}

# $1 -- description, $2 -- expected, $3 -- actual
assert_equals() {
  tests=$((tests + 1))
  if [[ "$2" == "$3" ]]; then
    echo "ok - $1"
  else
    echo "FAIL - $1"
    echo "  expected: [$2]"
    echo "  actual:   [$3]"
    failures=$((failures + 1))
  fi
}

# $1 -- plugin dir
analysed_files() {
  grep -E '\.php$' "$1/../../analyser-args" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'
}


# A 6.x branch in a clone whose origin/HEAD still names 5.x-dev must diff against 6.x-dev. Getting
# this wrong drags every commit 6.x-dev has that 5.x-dev does not into the analysis, and those
# files can fail on code the push never touched.
PLUGIN=$(new_fixture stale-head)
git -C "$PLUGIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/5.x-dev
git -C "$PLUGIN" checkout -q -b 6.x-dev
echo '<?php' > "$PLUGIN/SixOnly.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'six only'
git -C "$PLUGIN" update-ref refs/remotes/origin/6.x-dev HEAD
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // touched' >> "$PLUGIN/Shared.php"
git -C "$PLUGIN" commit -qam 'touch shared'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
assert_equals "stale origin/HEAD does not drag in 6.x-only files" "Shared.php" "$(analysed_files "$PLUGIN")"
assert_equals "stale origin/HEAD reports the 6.x-dev base" "1" "$(grep -c 'against origin/6.x-dev' <<< "$OUT")"

# A backport cut from 5.x-dev must diff against 5.x-dev even though 6.x-dev is the default branch,
# which is what a rule keyed on the default branch rather than the push gets wrong.
PLUGIN=$(new_fixture backport)
git -C "$PLUGIN" checkout -q -b 6.x-dev
echo '<?php' > "$PLUGIN/SixOnly.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'six only'
git -C "$PLUGIN" update-ref refs/remotes/origin/6.x-dev HEAD
git -C "$PLUGIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/6.x-dev
# 5.x-dev has to move on after the divergence, or both majors share a merge base and the
# resolution is a tie rather than a backport.
git -C "$PLUGIN" checkout -q 5.x-dev
echo '<?php' > "$PLUGIN/FiveOnly.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'five only'
git -C "$PLUGIN" update-ref refs/remotes/origin/5.x-dev HEAD
git -C "$PLUGIN" checkout -q -b five-topic origin/5.x-dev
echo '<?php // backported' >> "$PLUGIN/Shared.php"
git -C "$PLUGIN" commit -qam 'backport'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
assert_equals "a 5.x backport reports the 5.x-dev base" "1" "$(grep -c 'against origin/5.x-dev' <<< "$OUT")"
assert_equals "a 5.x backport does not drag in 6.x-only files" "Shared.php" "$(analysed_files "$PLUGIN")"

# No <major>.x-dev refs at all -- a single-branch clone, or a fork. The hook has to fall back to
# origin/HEAD rather than analysing nothing or failing the push.
PLUGIN=$(new_fixture no-dev-branches)
git -C "$PLUGIN" update-ref -d refs/remotes/origin/5.x-dev
git -C "$PLUGIN" update-ref refs/remotes/origin/main HEAD
git -C "$PLUGIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // fork' >> "$PLUGIN/Shared.php"
git -C "$PLUGIN" commit -qam 'fork work'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
assert_equals "falls back to origin/HEAD without *.x-dev refs" "1" "$(grep -c 'against origin/main' <<< "$OUT")"
assert_equals "the fallback still analyses the pushed change" "Shared.php" "$(analysed_files "$PLUGIN")"

# The core major warning fires on a real mismatch, and stays quiet when the resolution was a tie:
# a tie means the branch predates the divergence, so no target major was established.
PLUGIN=$(new_fixture major-warning)
mkdir -p "$PLUGIN/../../core"
printf '<?php\nclass Version { const VERSION = %s; }\n' "'5.9.0'" > "$PLUGIN/../../core/Version.php"
git -C "$PLUGIN" checkout -q -b 6.x-dev
echo '<?php' > "$PLUGIN/SixOnly.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'six only'
git -C "$PLUGIN" update-ref refs/remotes/origin/6.x-dev HEAD
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // touched' >> "$PLUGIN/Shared.php"
git -C "$PLUGIN" commit -qam 'touch shared'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
assert_equals "warns when the checkout major differs from the base branch" "1" "$(grep -c 'WARNING: analysing against Matomo 5.x' <<< "$OUT")"

PLUGIN=$(new_fixture major-warning-tied)
mkdir -p "$PLUGIN/../../core"
printf '<?php\nclass Version { const VERSION = %s; }\n' "'5.9.0'" > "$PLUGIN/../../core/Version.php"
# 6.x-dev at the same commit as 5.x-dev: both are equally near, so the target major is unknown.
git -C "$PLUGIN" update-ref refs/remotes/origin/6.x-dev HEAD
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // touched' >> "$PLUGIN/Shared.php"
git -C "$PLUGIN" commit -qam 'touch shared'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
assert_equals "stays quiet when the base branch was a tie" "0" "$(grep -c 'WARNING: analysing against Matomo' <<< "$OUT")"

# An early tie between two branches that both go on to lose must not mark the winner ambiguous.
# 2.x-dev and 3.x-dev sit at the same old commit, so they tie; 6.x-dev is strictly closer and
# settles it, and the major warning has to fire.
PLUGIN=$(new_fixture tie-then-clear)
mkdir -p "$PLUGIN/../../core"
printf '<?php\nclass Version { const VERSION = %s; }\n' "'5.9.0'" > "$PLUGIN/../../core/Version.php"
git -C "$PLUGIN" update-ref refs/remotes/origin/2.x-dev HEAD
git -C "$PLUGIN" update-ref refs/remotes/origin/3.x-dev HEAD
git -C "$PLUGIN" update-ref -d refs/remotes/origin/5.x-dev
git -C "$PLUGIN" checkout -q -b 6.x-dev
echo '<?php' > "$PLUGIN/SixOnly.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'six only'
git -C "$PLUGIN" update-ref refs/remotes/origin/6.x-dev HEAD
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // touched' >> "$PLUGIN/Shared.php"
git -C "$PLUGIN" commit -qam 'touch shared'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
assert_equals "a closer candidate clears an earlier tie" "1" "$(grep -c 'against origin/6.x-dev' <<< "$OUT")"
assert_equals "the warning still fires after a cleared tie" "1" "$(grep -c 'WARNING: analysing against Matomo 5.x' <<< "$OUT")"

# The sibling audit reports plugins that ship a hook nothing runs, and must never touch their
# configuration: pointing core.hooksPath at a directory that does not exist silently disables a
# repository's own .git/hooks as well, so a plugin with no hook directory is left alone entirely.
PLUGIN=$(new_fixture sibling-audit)
MATOMO="$PLUGIN/../.."
git -C "$PLUGIN" update-ref refs/remotes/origin/6.x-dev HEAD
git -C "$PLUGIN" config core.hooksPath .git-hooks-matomo

# A sibling that ships a hook but has no core.hooksPath -- the case worth reporting.
mkdir -p "$MATOMO/plugins/Dormant/.git-hooks-matomo"
cp "$HOOK" "$MATOMO/plugins/Dormant/.git-hooks-matomo/pre-push"
git -C "$MATOMO/plugins/Dormant" init -q
# A sibling with no hook at all -- nothing to activate, so it must not be named.
mkdir -p "$MATOMO/plugins/NoHook"
git -C "$MATOMO/plugins/NoHook" init -q

git -C "$PLUGIN" checkout -q -b topic
echo '<?php // touched' >> "$PLUGIN/Shared.php"
git -C "$PLUGIN" commit -qam 'touch shared'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
assert_equals "names a sibling whose hook never runs" "1" "$(grep -c 'Dormant' <<< "$OUT")"
assert_equals "does not name a sibling with no hook to activate" "0" "$(grep -c 'NoHook' <<< "$OUT")"
assert_equals "leaves the dormant sibling's config untouched" "" "$(git -C "$MATOMO/plugins/Dormant" config --get core.hooksPath || true)"
assert_equals "leaves the hookless sibling's config untouched" "" "$(git -C "$MATOMO/plugins/NoHook" config --get core.hooksPath || true)"

# Once a day, not once a push.
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
assert_equals "stays quiet on the next push the same day" "0" "$(grep -c 'Dormant' <<< "$OUT")"


echo
echo "${tests} tests, ${failures} failures"
[[ "$failures" -eq 0 ]]
