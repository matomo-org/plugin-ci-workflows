#!/bin/bash
# Tests for scripts/bash/resolve_plugin_min_php.sh and the lint step in
# .github/workflows/plugin-min-php-lint.yml.
# Usage: bash tests/min_php_lint_test.sh
#
# The floor is the whole point: linting transpiled dependencies against the wrong PHP passes
# whatever the scoper emitted, which is worse than not linting, because it reads as coverage.
# The copies this replaces hardcoded 8.1 and so were green-but-blind on every 5.x branch, where
# the floor is 7.2 or 7.4.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT/scripts/bash/resolve_plugin_min_php.sh"
WORKFLOW="$ROOT/.github/workflows/plugin-min-php-lint.yml"
# The lint step and the harness below both shell out to php. ubuntu-24.04 ships 8.3 today, but a
# check guarding a fleet-wide workflow should not rest on what a runner image happens to carry --
# the same reason plugin_ci_invariants_test.sh fails closed without PyYAML. Without this the suite
# reports `expected exit 0, got 1` and never says why.
if ! command -v php >/dev/null 2>&1; then
  echo "FAIL - php is not available, so the lint step cannot be exercised"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=()

pass() { echo "ok - $1"; }
fail() {
  local description="$1"; shift
  echo "FAIL - $description"
  [ $# -gt 0 ] && echo "$*"
  failures+=("$description")
}

# Writes $2 as plugin.json and $4 (when given) as composer.json, then asserts the resolver
# prints $3 -- or fails, when $3 is empty.
resolves() {
  local description="$1" plugin_json="$2" expected="$3" composer_json="${4:-}"
  local dir="$WORK/case-$tests"
  tests=$((tests + 1))
  mkdir -p "$dir"
  printf '%s' "$plugin_json" > "$dir/plugin.json"
  [ -n "$composer_json" ] && printf '%s' "$composer_json" > "$dir/composer.json"

  local output status
  output="$(bash "$RESOLVER" "$dir" 2>/dev/null)"
  status=$?

  if [ -z "$expected" ]; then
    if [ "$status" = 0 ]; then
      fail "$description (expected a non-zero exit, got 0 and '$output')"
      return
    fi
    pass "$description"
    return
  fi

  if [ "$status" != 0 ]; then
    fail "$description (exited $status: $output)"
    return
  fi
  if [ "$output" != "$expected" ]; then
    fail "$description (got '$output', expected '$expected')"
    return
  fi
  pass "$description"
}

resolves "a declared floor wins" \
  '{"require":{"php":">=8.1.0","matomo":">=6.0.0-b1,<7.0.0-b1"}}' '8.1'
# ApiReference on 5.x-dev. The copies this replaces linted it at 8.1.
resolves "a declared 7.4 floor is not rounded up" \
  '{"require":{"php":">=7.4.0","matomo":">=5.0.0-stable,<6.0.0-b1"}}' '7.4'
resolves "an upper bound does not become the floor" \
  '{"require":{"php":">=7.2.5 <9"}}' '7.2'
# The case above passed under the old first-token regex only because `>=` happened to come first.
# These three did not: a union written high-first linted a minor too high, and a bare upper bound
# became a floor out of nothing.
resolves "a union takes its lowest branch, whichever is written first" \
  '{"require":{"php":"^8.0 || ^7.4"}}' '7.4'
resolves "a union takes its lowest branch, low written first" \
  '{"require":{"php":"^7.4 || ^8.0"}}' '7.4'
resolves "an upper bound alone is no floor at all" \
  '{"require":{"php":"<8.0"}}' ''
resolves "a caret range floors at the version it names" \
  '{"require":{"php":"^8.1"}}' '8.1'
# A hand-written manifest carries a caret or a tilde, not the generator's `>=`. Matching only
# `>=` failed these outright, and they are the population that reaches the Matomo fallback.
resolves "a caret Matomo constraint reaches the Matomo floor" \
  '{"require":{"matomo":"^5.0"}}' 'matomo5_min_php'
resolves "a tilde Matomo constraint reaches the Matomo floor" \
  '{"require":{"matomo":"~5.0"}}' 'matomo5_min_php'
resolves "the Matomo upper bound is not mistaken for the floor" \
  '{"require":{"matomo":">=5.0.0-rc5,<6.0.0-b1"}}' 'matomo5_min_php'
# GoogleAnalyticsImporter and SearchEngineKeywordsPerformance declare no require.php.
resolves "no declared floor falls back to the Matomo major" \
  '{"require":{"matomo":">=5.0.0-rc5,<6.0.0-b1"}}' 'matomo5_min_php'
resolves "the Matomo 6 fallback is the 6 alias" \
  '{"require":{"matomo":">=6.0.0-b1,<7.0.0-b1"}}' 'matomo6_min_php'
# `piwik` is the pre-rename spelling and still present in older plugin.json files.
resolves "the legacy piwik key is read" \
  '{"require":{"piwik":">=5.0.0-rc5,<6.0.0-b1"}}' 'matomo5_min_php'

# Guessing a floor is the one thing this must never do: a wrong floor is silent.
resolves "no usable requirement fails rather than guessing" '{"require":{}}' ''
resolves "malformed json fails" '{not json' ''

tests=$((tests + 1))
if bash "$RESOLVER" "$WORK/absent" >/dev/null 2>&1; then
  fail "a directory with neither manifest fails"
else
  pass "a directory with neither manifest fails"
fi

# The lowest floor any manifest declares wins. OAuth2 is the live case: its composer platform
# is 8.2.0 while plugin.json declares >=8.1.0, and Matomo installs on the plugin.json floor with
# platform-check off, so a user on 8.1 loads a tree resolved for 8.2. Linting at 8.2 cannot see
# that; linting at 8.1 reports it.
resolves "the lower plugin.json floor wins over a higher composer platform" \
  '{"require":{"php":">=8.1.0"}}' '8.1' '{"config":{"platform":{"php":"8.2.0"}}}'
resolves "a lower composer platform wins over a higher plugin.json floor" \
  '{"require":{"php":">=8.2.0"}}' '8.0' '{"config":{"platform":{"php":"8.0.0"}}}'
# composer.json require.php is deliberately not a candidate: it constrains the platform
# package rather than describing the tree, so a stale value there would drag the floor below
# anything the evidence supports and the remedy would be to re-resolve a correct tree backwards.
resolves "composer require.php is not a floor candidate" \
  '{"require":{"php":">=8.3.0"}}' '8.3' '{"require":{"php":">=7.2.5"}}'
resolves "plugin.json is used when composer declares no php" \
  '{"require":{"php":">=7.4.0"}}' '7.4' '{"require":{"ext-json":"*"}}'
resolves "agreeing manifests resolve to the shared floor" \
  '{"require":{"php":">=8.1.0"}}' '8.1' \
  '{"require":{"php":">=8.1"},"config":{"platform":{"php":"8.1.0"}}}'
# The shape that made composer require.php dangerous: a stale template value well below both
# the pinned platform and the plugin's declared floor.
resolves "a stale composer require.php does not lower the floor" \
  '{"require":{"php":">=8.1"}}' '8.1' \
  '{"require":{"php":">=7.2.5"},"config":{"platform":{"php":"8.1.0"}}}'
# A bare major means .0, and a constraint with no version at all has no floor to take.
resolves "a bare major floors at .0" '{"require":{"php":">=8"}}' '8.0'
resolves "a space after the operator is still read" '{"require":{"php":">= 7.4"}}' '7.4'
resolves "a constraint naming no version falls through" \
  '{"require":{"php":"*","matomo":">=6.0.0-b1,<7.0.0-b1"}}' 'matomo6_min_php'

# --- the lint step itself -------------------------------------------------------------------

python3 - "$WORKFLOW" "$WORK/lint.sh" "$WORK/resolve.sh" "$WORK/look.sh" <<'PY' || { echo "could not extract the steps"; exit 1; }
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
steps = doc['jobs']['min-php-lint']['steps']


def only(predicate, what):
    found = [s for s in steps if predicate(s)]
    assert len(found) == 1, f"expected one {what} step, found {len(found)}"
    return found[0]


open(sys.argv[2], 'w').write(only(lambda s: s.get('name') == 'Lint', 'Lint')['run'])
open(sys.argv[3], 'w').write(only(lambda s: s.get('id') == 'resolve', 'resolve')['run'])
open(sys.argv[4], 'w').write(only(lambda s: s.get('id') == 'look', 'look')['run'])
PY

# Runs the extracted probe step. An absent lint-path is the supported no-op for most plugins and
# also what a mistyped path looks like, so the skip has to be visible without opening the step.
look_step() {
  local description="$1" make_dir="$2" want_present="$3" want_output="$4"
  local dir="$WORK/look-$tests"
  tests=$((tests + 1))
  mkdir -p "$dir"
  [ "$make_dir" = yes ] && mkdir -p "$dir/vendor/prefixed"

  local output
  output="$(cd "$dir" && GITHUB_OUTPUT="$dir/out" GITHUB_STEP_SUMMARY="$dir/summary" \
    LINT_PATH=vendor/prefixed bash --noprofile --norc -eo pipefail "$WORK/look.sh" 2>&1)"

  if ! grep -qx "present=$want_present" "$dir/out"; then
    fail "$description (expected present=$want_present, got '$(cat "$dir/out")')" "$output"
    return
  fi
  if [ -n "$want_output" ] && [[ "$output" != *"$want_output"* ]]; then
    fail "$description (output did not contain '$want_output')" "$output"
    return
  fi
  pass "$description"
}

look_step "a present lint-path is reported" yes true ''
look_step "an absent lint-path is annotated, not just logged" no false '::notice::No vendor/prefixed'

# Runs the extracted resolve step against stub checkouts. $2 chooses whether the floor resolver
# is present ("real") or missing ("absent", i.e. a workflows-ref predating it), and $3 is what
# the stubbed alias resolver echoes back.
resolve_step() {
  local description="$1" resolver="$2" alias_output="$3" expected="$4" want_output="$5"
  local dir="$WORK/step-$tests"
  tests=$((tests + 1))
  mkdir -p "$dir/wf/scripts/bash" "$dir/scripts/scripts/bash"
  printf '{"require":{"php":">=8.1.0"}}' > "$dir/plugin.json"
  [ -n "${COMPOSER_JSON:-}" ] && printf '%s' "$COMPOSER_JSON" > "$dir/composer.json"
  if [ "$resolver" = real ]; then
    cp "$RESOLVER" "$dir/wf/scripts/bash/resolve_plugin_min_php.sh"
  fi
  if [ "${ALIAS_RESOLVER:-real}" = real ]; then
    printf '#!/bin/bash\nprintf %%s "%s"\n' "$alias_output" \
      > "$dir/scripts/scripts/bash/resolve_php_version.sh"
    chmod +x "$dir/scripts/scripts/bash/resolve_php_version.sh"
  fi

  local output status
  output="$(cd "$dir" && GITHUB_OUTPUT="$dir/out" PHP_VERSION_INPUT="${OVERRIDE:-}" WORKFLOWS_REF=somesha \
    WORKFLOWS_CHECKOUT=wf SCRIPTS_CHECKOUT=scripts \
    bash --noprofile --norc -eo pipefail "$WORK/resolve.sh" 2>&1)"
  status=$?
  if [ "$status" != "$expected" ]; then
    fail "$description (expected exit $expected, got $status)" "$output"
    return
  fi
  if [ -n "$want_output" ] && [[ "$output" != *"$want_output"* ]]; then
    fail "$description (output did not contain '$want_output')" "$output"
    return
  fi
  pass "$description"
}

resolve_step "a resolvable floor reaches setup-php" real '8.1' 0 'Linting against PHP 8.1'
# A workflows-ref pinned before the resolver existed would otherwise fail as a bare 127.
resolve_step "a workflows-ref without the resolver fails loudly" absent '8.1' 1 '::error::workflows-ref'
# resolve_php_version.sh echoes an alias it does not know straight back, so an unknown Matomo
# major would otherwise reach setup-php verbatim.
resolve_step "an alias the shared table cannot resolve fails" real 'matomo9_min_php' 1 '::error::'

# The override path skips the workflows checkout entirely, so the resolver is absent by design
# and `rm -rf` runs against a directory that was never created.
OVERRIDE='8.3' resolve_step "an override skips the resolver" absent '8.3' 0 'Using the php-version override'
OVERRIDE='nonsense' resolve_step "a bad override is rejected" absent 'nonsense' 1 '::error::'

# The resolver writes its reasoning to stderr, so without promotion the most useful thing it
# says -- that the manifests disagree, which it calls the defect itself -- never reaches the
# pull request at all: the step succeeds and the line sits in a collapsed log.
COMPOSER_JSON='{"config":{"platform":{"php":"8.2.0"}}}' \
  resolve_step "a manifest disagreement is annotated" real '8.1' 0 '::warning::Manifests disagree'

# scripts-ref points at a different repository with different SHAs, so a stale pin there is at
# least as likely as one on workflows-ref -- and unguarded it exits 127 with no annotation.
ALIAS_RESOLVER=absent \
  resolve_step "a scripts-ref without the alias resolver fails loudly" real '8.1' 1 '::error::scripts-ref'


# Runs the extracted lint step over $2 and asserts the exit status and a substring.
lints() {
  local description="$1" dir="$2" expected="$3" want_output="$4"
  local output status
  tests=$((tests + 1))
  output="$(LINT_PATH="$dir" PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')" \
    bash --noprofile --norc -eo pipefail "$WORK/lint.sh" 2>&1)"
  status=$?
  if [ "$status" != "$expected" ]; then
    fail "$description (expected exit $expected, got $status)" "$output"
    return
  fi
  if [ -n "$want_output" ] && [[ "$output" != *"$want_output"* ]]; then
    fail "$description (output did not contain '$want_output')" "$output"
    return
  fi
  pass "$description"
}

mkdir -p "$WORK/good" "$WORK/bad" "$WORK/empty"
printf '<?php\nclass Fine { public function f() { return 1; } }\n' > "$WORK/good/Fine.php"
printf '<?php\nclass Fine { public function f() { return 1; } }\n' > "$WORK/bad/Fine.php"
printf '<?php\nclass Broken { public function f(  { }\n' > "$WORK/bad/Broken.php"
# php -l renders the offending token, so a parse error can carry a literal %. GitHub unescapes
# %25 as well as %0A, so an unescaped % could be decoded as something else entirely.
mkdir -p "$WORK/percent"
printf '<?php\nfunction f(%%) { }\n' > "$WORK/percent/Pct.php"

lints "valid PHP passes and reports what it parsed" "$WORK/good" 0 'Parsed 1 file(s)'
lints "a parse error fails and is annotated" "$WORK/bad" 1 '::error file='
lints "a parse error names the offending file" "$WORK/bad" 1 'Broken.php'
# A path that exists but holds nothing would otherwise report success having parsed nothing,
# which is indistinguishable from a check that has quietly stopped testing anything.
lints "an empty directory fails rather than passing quietly" "$WORK/empty" 1 '::error::'
# php -l emits the parse error and a trailing summary, and a workflow command is parsed one line
# at a time, so an unescaped newline drops the rest of the message out of the annotation.
lints "a multi-line parse error stays in one annotation" "$WORK/bad" 1 '%0A'
lints "a percent in the parse error is escaped" "$WORK/percent" 1 '"%25"'

tests=$((tests + 1))
annotation="$(LINT_PATH="$WORK/bad" PHP_VERSION=8.3 bash --noprofile --norc -eo pipefail \
  "$WORK/lint.sh" 2>&1 | grep -c '^::error file=')"
if [ "$annotation" = 1 ]; then
  pass "the whole parse error is one annotation line"
else
  fail "the whole parse error is one annotation line (got $annotation ::error lines)"
fi

# --- the workflow's own guarantees ----------------------------------------------------------

# Every step after the probe has to be gated on it. One missing `if:` sets up PHP in the ~40
# plugin repositories that ship no scoped dependencies, on every pull request.
yaml_output="$(python3 - "$WORKFLOW" <<'YAMLPY'
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
failed = []


def check(description, condition):
    print(("ok - " if condition else "FAIL - ") + description)
    if not condition:
        failed.append(description)


triggers = doc['on'] if 'on' in doc else doc[True]
check("the lint is a reusable workflow", 'workflow_call' in triggers)
check("it asks for no more than contents: read", (doc.get('permissions') or {}) == {'contents': 'read'})

steps = doc['jobs']['min-php-lint']['steps']
names = [s.get('name') or s.get('uses') for s in steps]
probe = next(i for i, s in enumerate(steps) if s.get('id') == 'look')
ungated = [names[i] for i, s in enumerate(steps[probe + 1:], start=probe + 1)
           if "steps.look.outputs.present == 'true'" not in str(s.get('if', ''))]
check(f"every step after the probe is gated on it (ungated: {ungated})", not ungated)

# The floor is derived, not pinned: a literal here is the defect this workflow replaces.
resolve = next(s for s in steps if s.get('id') == 'resolve')
check("the floor comes from the resolver, not a literal",
      'resolve_plugin_min_php.sh' in str(resolve.get('run', '')))

# The harness runs the extracted steps under `bash -eo pipefail`, which is what shell: bash
# gives. Left unset, GitHub uses `bash -e {0}` with no pipefail, so the tests would certify a
# shell the workflow never asked for and the first pipeline added here would be unguarded.
# The caller checkout dominates the cost in the ~40 repositories where this no-ops, so losing
# the sparse pattern is a fleet-wide slowdown that nothing else would report.
caller_checkout = next(s for s in steps if str(s.get('uses', '')).startswith('actions/checkout')
                       and not (s.get('with') or {}).get('repository'))
check("the caller checkout is sparse",
      (caller_checkout.get('with') or {}).get('sparse-checkout') == '${{ inputs.lint-path }}')

unshelled = [s.get('name') or s.get('id') for s in steps if 'run' in s and s.get('shell') != 'bash']
check(f"every run step declares shell: bash (missing: {unshelled})", not unshelled)

setup = next(s for s in steps if str(s.get('uses', '')).startswith('shivammathur/setup-php'))
check("setup-php takes the resolved version",
      setup.get('with', {}).get('php-version') == "${{ steps.resolve.outputs.version }}")

sys.exit(1 if failed else 0)
YAMLPY
)"
yaml_status=$?
echo "$yaml_output"
tests=$((tests + $(printf '%s\n' "$yaml_output" | grep -c '^\(ok\|FAIL\) - ')))
if [ "$yaml_status" != 0 ]; then
  while IFS= read -r line; do failures+=("$line"); done \
    < <(printf '%s\n' "$yaml_output" | grep '^FAIL - ')
  # A traceback exits non-zero and prints no FAIL line -- its output went to stderr, which the
  # capture above does not take. Without this the greps find nothing and the suite reports
  # success having asserted none of the invariants, which renaming a step id was enough to cause.
  if ! printf '%s\n' "$yaml_output" | grep -q '^FAIL - '; then
    tests=$((tests + 1))
    echo "FAIL - the workflow invariants block ran to completion (exited $yaml_status)"
    failures+=("the workflow invariants block ran to completion")
  fi
fi

echo
echo "$tests tests, ${#failures[@]} failures"
[ ${#failures[@]} -eq 0 ] || exit 1
