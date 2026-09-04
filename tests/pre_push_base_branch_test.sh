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

# Point a fixture's stub analyser at a canned result. It always records the arguments it was given,
# so analysed_files() keeps working whatever the result is. The streams and exit code are read from
# sidecar files: a canned message containing quotes then needs no escaping.
#
# $1 -- plugin dir, $2 -- exit code, $3 -- stdout text, $4 -- stderr text
stub_analyser() {
  local plugin="$1" matomo
  matomo=$(cd "$plugin/../.." && pwd)

  printf '%s' "$3" > "$matomo/stub-stdout"
  printf '%s' "$4" > "$matomo/stub-stderr"
  printf '%s' "$2" > "$matomo/stub-exit"

  cat > "$matomo/vendor/bin/phpstan" <<'STUB'
#!/bin/bash
matomo=$(cd "$(dirname "$0")/../.." && pwd)
printf '%s\n' "$@" >> "$matomo/analyser-args"
printf 'COLUMNS=%s\n' "${COLUMNS-}" >> "$matomo/analyser-env"
[[ -s "$matomo/stub-stdout" ]] && cat "$matomo/stub-stdout"
[[ -s "$matomo/stub-stderr" ]] && cat "$matomo/stub-stderr" >&2
exit "$(cat "$matomo/stub-exit")"
STUB
  chmod 0755 "$matomo/vendor/bin/phpstan"
}

# A Matomo checkout holding one plugin, with a stub analyser that appends the arguments it was
# given to $MATOMO/analyser-args so a test can assert on them.
#
# $1 -- fixture name
new_fixture() {
  local matomo="$WORK/$1/matomo" plugin
  plugin="$matomo/plugins/TestPlugin"
  mkdir -p "$plugin/phpstan" "$matomo/vendor/bin"

  : > "$matomo/analyser-args"
  : > "$matomo/analyser-env"
  stub_analyser "$plugin" 0 '' ''
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


# PHPStan exits non-zero when its config excludes every file it was handed, which a commit whose
# only new file is a test reaches against a config that excludes tests/. Nothing is wrong with the
# push, so it must not be blocked. The diagnostic goes to stderr and leaves stdout empty.
PLUGIN=$(new_fixture all-files-excluded)
stub_analyser "$PLUGIN" 1 '' '
 [ERROR] No files found to analyse.
'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // excluded' > "$PLUGIN/ExcludedOnly.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'excluded only'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "an entirely excluded file list does not block the push" "0" "$STATUS"
# The exemption reads a line of stderr, so the analyser must not be allowed to decorate it. Git
# Bash sets the environment that makes PHPStan colour output even into a file, and the escape
# codes defeat the anchored match -- blocking precisely the push this exemption is for.
assert_equals "and asks the analyser not to decorate its output" "1" \
  "$(grep -cx -- '--no-ansi' "$PLUGIN/../../analyser-args")"
# Symfony wraps the block to the terminal width, so a narrow exported COLUMNS splits the line the
# exemption matches. Pinning the width is what stops an inherited one reaching the analyser.
assert_equals "and fixes the width the block wraps to" "1" \
  "$(grep -cx -- 'COLUMNS=120' "$PLUGIN/../../analyser-env")"
# Both streams are captured, so a progress bar can never render live and only arrives as debris.
assert_equals "and turns the progress bar off" "1" \
  "$(grep -cx -- '--no-progress' "$PLUGIN/../../analyser-args")"
# Naming the files is what stops an excludePaths that matches everything retiring the hook in
# silence, so the message has to carry them rather than just say nothing was analysed.
assert_equals "and names the files it skipped" "1" "$(grep -c 'nothing to analyse: ExcludedOnly.php' <<< "$OUT")"
# ...without also reporting the [ERROR] it is deliberately going ahead with. The message above
# says the same thing in plain English, and it is the only line the exempt path drops.
assert_equals "and does not report the error it is overriding" "0" \
  "$(grep -c 'No files found to analyse' <<< "$OUT")"
# Nor the blank lines Symfony pads that block with, which are all that would otherwise survive it.
assert_equals "and leaves no blank padding behind" "0" "$(grep -c '^[[:space:]]*$' <<< "$OUT")"

# The same run through ddev, which appends its own coloured wrapper around PHPStan's exit code.
PLUGIN=$(new_fixture ddev-wrapper)
stub_analyser "$PLUGIN" 1 '' ' [ERROR] No files found to analyse.
'"$(printf '\033')"'[31mFailed to execute command phpstan analyse: exit status 1'"$(printf '\033')"'[0m'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // ddev' > "$PLUGIN/DdevExcluded.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'ddev excluded'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "a ddev-wrapped excluded run does not block the push" "0" "$STATUS"
assert_equals "and does not report ddev's failure line" "0" \
  "$(grep -c 'Failed to execute command' <<< "$OUT")"

# A failure that reports no diagnostic of its own still blocks.
PLUGIN=$(new_fixture real-failure)
stub_analyser "$PLUGIN" 1 ' [ERROR] Found 1 error' 'Note: analysed 1 file'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // broken' > "$PLUGIN/Broken.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'broken'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "a real analysis failure still blocks the push" "1" "$STATUS"
# Capturing both streams is what makes the exemption decidable, but it also buffers what used to
# go straight to the terminal: a blocked push that reports nothing is worse than the bug this
# replaced, so both streams have to survive the round trip.
assert_equals "and reports what the analyser found" "1" "$(grep -c 'Found 1 error' <<< "$OUT")"
assert_equals "and its stderr along with it" "1" "$(grep -c 'Note: analysed 1 file' <<< "$OUT")"

# A failure carrying no diagnostic block at all -- a missing file, an unknown config key, a memory
# limit that cannot be set. Stdout is empty and nothing is [ERROR]-prefixed, so every other
# condition is satisfied and the phrase itself is all that stands between these and an exemption.
PLUGIN=$(new_fixture undiagnosed-failure)
stub_analyser "$PLUGIN" 1 '' 'Path /nonexistent/Missing.php does not exist'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // undiagnosed' > "$PLUGIN/Undiagnosed.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'undiagnosed'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "a failure with no diagnostic block still blocks the push" "1" "$STATUS"

# The phrase inside a real diagnostic must not buy an exemption: a custom rule can put any text in
# a message, and quoting a file's contents is enough. Analysis output goes to stdout, so a run that
# produced any is never exempt however its text reads.
PLUGIN=$(new_fixture phrase-inside-a-real-error)
stub_analyser "$PLUGIN" 1 "  3      Parameter #1 \$x expects int, 'No files found to analyse' given.
 [ERROR] Found 1 error" ''
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // quotes the phrase' > "$PLUGIN/Quoting.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'quoting'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "the phrase inside a real diagnostic does not exempt the push" "1" "$STATUS"

# And the exemption is the whole stderr line, not a substring of one: a diagnostic that merely
# mentions the phrase is still a failure.
PLUGIN=$(new_fixture phrase-within-a-longer-line)
stub_analyser "$PLUGIN" 1 '' ' [ERROR] Rule crashed: No files found to analyse in bundle X'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // mentions the phrase' > "$PLUGIN/Mentions.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'mentions'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "the phrase inside a longer stderr line does not exempt the push" "1" "$STATUS"

# Analysis output on stdout means files were analysed, so the stderr diagnostic cannot be taken at
# face value however exactly it matches. Both halves of the guard are load-bearing: this is the
# case that fails if the stdout check is dropped and only the message is consulted.
PLUGIN=$(new_fixture excluded-alongside-real-errors)
stub_analyser "$PLUGIN" 1 ' [ERROR] Found 1 error' ' [ERROR] No files found to analyse.'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // both' > "$PLUGIN/Both.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'both'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "a real diagnostic alongside the phrase does not exempt the push" "1" "$STATUS"

# The same case on one stream: a second PHPStan diagnostic on stderr withdraws the exemption, so a
# run that failed for its own reasons is not waved through merely because it also reported having
# nothing to analyse.
PLUGIN=$(new_fixture real-error-on-stderr)
stub_analyser "$PLUGIN" 1 '' ' [ERROR] Rule crashed while collecting files
 [ERROR] No files found to analyse.'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // second diagnostic' > "$PLUGIN/SecondDiagnostic.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'second diagnostic'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "a second stderr diagnostic does not exempt the push" "1" "$STATUS"

# A process that died is never a clean "nothing to analyse", whatever else it managed to print on
# the way out. PHPStan has not been seen to emit either of these alongside the no-files line, but a
# fatal is never benign noise, so withdrawing the exemption for one cannot cost a legitimate push.
PLUGIN=$(new_fixture php-fatal)
stub_analyser "$PLUGIN" 255 '' 'PHP Fatal error:  Allowed memory size of 134217728 bytes exhausted in /x.php on line 9
 [ERROR] No files found to analyse.'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // fatal' > "$PLUGIN/Fatal.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'fatal'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "a PHP fatal does not exempt the push" "1" "$STATUS"

# The same fatal without PHP's log prefix: PHPStan forces display_errors=stderr, so an environment
# with log_errors off gets the bare display form instead.
PLUGIN=$(new_fixture bare-fatal)
stub_analyser "$PLUGIN" 255 '' 'Fatal error: Uncaught Error: Call to undefined method in /x.php:9
 [ERROR] No files found to analyse.'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // bare fatal' > "$PLUGIN/BareFatal.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'bare fatal'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "an unprefixed PHP fatal does not exempt the push" "1" "$STATUS"

PLUGIN=$(new_fixture fatal-block)
stub_analyser "$PLUGIN" 1 '' ' [FATAL] Child process died
 [ERROR] No files found to analyse.'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // fatal block' > "$PLUGIN/FatalBlock.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'fatal block'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "a [FATAL] block does not exempt the push" "1" "$STATUS"

# Environment noise on stderr is not a diagnostic, and this case is pinned deliberately: PHP writes
# log_errors output to stderr when error_log is unset, and Xdebug announces itself there, so
# tightening the guard to "stderr holds nothing else" would re-block the pushes the exemption is
# for. Keying it to the shapes a real failure takes is what this test holds in place.
#
# The PHP Warning line below is verbatim from a real run: one stale extension entry in php.ini is
# enough to produce it, on a machine where the analysis itself is perfectly healthy. Classifying
# warnings as failures has been proposed twice in review and is wrong for exactly that reason --
# a warning is startup noise, a fatal is a dead process. This case is what says so.
PLUGIN=$(new_fixture noise-on-stderr)
stub_analyser "$PLUGIN" 1 '' 'PHP Warning:  PHP Startup: Unable to load dynamic library '"'"'xdebug.so'"'"' in Unknown on line 0
PHP Deprecated:  Implicit conversion from float 1.5 to int loses precision in /x.php on line 3
Xdebug: [Step Debug] Could not connect to debugging client.
 [ERROR] No files found to analyse.'
git -C "$PLUGIN" checkout -q -b topic
echo '<?php // noisy environment' > "$PLUGIN/NoisyEnvironment.php"
git -C "$PLUGIN" add -A && git -C "$PLUGIN" commit -qm 'noisy environment'
OUT=$(run_hook "$PLUGIN" "$(git -C "$PLUGIN" rev-parse HEAD)")
STATUS=$?
assert_equals "environment noise on stderr still exempts the push" "0" "$STATUS"
# The exemption turns on one stderr line, so the rest of what the analyser said has to survive it.
assert_equals "and the analyser's own output is not swallowed" "1" \
  "$(grep -c 'Could not connect to debugging client' <<< "$OUT")"

echo
echo "${tests} tests, ${failures} failures"
[[ "$failures" -eq 0 ]]
