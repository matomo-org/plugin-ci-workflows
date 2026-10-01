#!/bin/bash
# Tests for scripts/bash/generate_compatibility_checks.sh, the templates it writes, and
# scripts/bash/check_compatibility_results.sh.
# Usage: bash tests/compatibility_checks_test.sh
#
# The generated tests only run inside a Matomo checkout on a runner, so nothing short of an Actions
# run exercises them end to end. What can go wrong before that is covered here: files landing
# where run_tests.sh does not look, a namespace the test framework does not map back to the
# plugin, PHP the oldest target cannot parse, and a checkout token left for PHPUnit to find.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GENERATOR="$ROOT/scripts/bash/generate_compatibility_checks.sh"
CHECKER="$ROOT/scripts/bash/check_compatibility_results.sh"
CLASSES=(GeneratedAssetCompilationTest GeneratedTwigCompilationTest)

if ! command -v php >/dev/null 2>&1; then
  echo "FAIL - php is not available, so the generated files cannot be linted"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The generator unsets composer's global github-oauth entry; keep it away from the real one.
export COMPOSER_HOME="$WORK/composer-home"
unset DEPENDENT_PLUGINS

tests=0
failures=()

pass() { echo "ok - $1"; }
fail() {
  local description="$1"; shift
  echo "FAIL - $description"
  [ $# -gt 0 ] && echo "$*"
  failures+=("$description")
}
check() {
  tests=$((tests + 1))
  if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi
}

# A Matomo root holding plugins/$1, with each of the remaining arguments created inside it.
make_matomo() {
  local dir="$WORK/matomo-$tests-$RANDOM" plugin="$1"; shift
  mkdir -p "$dir/plugins/$plugin"
  local sub
  for sub in "$@"; do mkdir -p "$dir/plugins/$plugin/$sub"; done
  echo "$dir"
}

generate() {
  (cd "$1" && PLUGIN_NAME="$2" "$GENERATOR") 2>&1
}

# $1 layout label, $2 expected test root, remaining args: directories the plugin ships.
layout_case() {
  local label="$1" expected="$2"; shift 2
  local matomo output status
  matomo="$(make_matomo Example "$@")"
  output="$(generate "$matomo" Example)"
  status=$?

  check "$label: generator succeeds" "[ $status -eq 0 ]" "$output"

  local class file
  for class in "${CLASSES[@]}"; do
    file="$matomo/plugins/Example/$expected/Integration/$class.php"
    check "$label: $class lands in $expected/Integration" "[ -f '$file' ]" "$output"
    [ -f "$file" ] || continue
    check "$label: $class is namespaced under $expected" \
      "grep -qxF 'namespace Piwik\\Plugins\\Example\\$expected\\Integration;' '$file'" \
      "$(grep -m1 '^namespace' "$file")"
    check "$label: $class leaves no placeholder behind" "! grep -q '{{' '$file'"
    check "$label: $class parses on $(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')" \
      "php -l '$file' >/dev/null 2>&1" "$(php -l "$file" 2>&1)"
  done
}

# run_tests.sh picks Test/ over tests/, and falls back to --group when neither exists.
layout_case "tests/ layout" tests tests
layout_case "Test/ layout" Test Test
layout_case "both layouts" Test Test tests
layout_case "neither layout" tests

for name in '' 'Bad-Name' 'Evil/../x' 'a b'; do
  matomo="$(make_matomo Example tests)"
  output="$(generate "$matomo" "$name")"
  status=$?
  check "rejects PLUGIN_NAME '$name'" "[ $status -ne 0 ] && [ -z \"\$(find '$matomo/plugins/Example/tests' -type f)\" ]" "$output"
done

matomo="$(make_matomo Example tests)"
output="$(generate "$matomo" Missing)"
status=$?
check "fails when the plugin is not in the checkout" "[ $status -ne 0 ]" "$output"

matomo="$(make_matomo Example tests/Integration)"
echo 'shipped' > "$matomo/plugins/Example/tests/Integration/GeneratedTwigCompilationTest.php"
output="$(generate "$matomo" Example)"
status=$?
check "refuses to overwrite a file the plugin ships" \
  "[ $status -ne 0 ] && grep -qx shipped '$matomo/plugins/Example/tests/Integration/GeneratedTwigCompilationTest.php' && [ ! -e '$matomo/plugins/Example/tests/Integration/GeneratedAssetCompilationTest.php' ]" "$output"

matomo="$(make_matomo Example tests)"
mkdir -p "$matomo/plugins/Example/.git" "$matomo/plugins/Dependency/.git" "$matomo/plugins/Dependency/nested/.git"
output="$(generate "$matomo" Example)"
check "removes .git from every plugin, where the dependent-plugin token lives" \
  "[ ! -e '$matomo/plugins/Example/.git' ] && [ ! -e '$matomo/plugins/Dependency/.git' ]" "$output"
check "leaves .git deeper inside a plugin alone" "[ -d '$matomo/plugins/Dependency/nested/.git' ]"

matomo="$(make_matomo Example tests)"
mkdir -p "$matomo/plugins/Dependency" "$matomo/plugins/Other"
output="$(DEPENDENT_PLUGINS="innocraft/plugin-Dependency matomo-org/plugin-Other" generate "$matomo" Example)"
status=$?
check "accepts dependent plugins that were all checked out" "[ $status -eq 0 ]" "$output"

matomo="$(make_matomo Example tests)"
mkdir -p "$matomo/plugins/Dependency"
output="$(DEPENDENT_PLUGINS="innocraft/plugin-Dependency innocraft/plugin-Absent" generate "$matomo" Example)"
status=$?
check "fails naming a dependent plugin that was not checked out" \
  "[ $status -ne 0 ] && grep -qF innocraft/plugin-Absent <<<\"\$output\" && [ -z \"\$(find '$matomo/plugins/Example/tests' -type f)\" ]" "$output"

matomo="$(make_matomo Example tests)"
mkdir -p "$matomo/plugins/Dependency/nested/.git"
echo 'url = https://x-access-token:abc@github.com/innocraft/plugin-Dependency' > "$matomo/plugins/Dependency/nested/.git/config"
output="$(generate "$matomo" Example)"
status=$?
check "fails when a token URL survives the scrub" "[ $status -ne 0 ] && grep -qF 'Credential material' <<<\"\$output\"" "$output"

matomo="$(make_matomo Example tests)"
mkdir -p "$matomo/plugins/Dependency/nested/.git" "$matomo/plugins/Other/nested/.git"
echo 'url = https://x-access-token:abc@github.com/innocraft/plugin-Dependency' > "$matomo/plugins/Dependency/nested/.git/config"
echo 'unreadable' > "$matomo/plugins/Other/nested/.git/config"
chmod 000 "$matomo/plugins/Other/nested/.git/config"
output="$(generate "$matomo" Example)"
status=$?
chmod 644 "$matomo/plugins/Other/nested/.git/config"
check "fails on a surviving token even when another config cannot be read" "[ $status -ne 0 ] && grep -qF 'Credential material' <<<\"\$output\"" "$output"

matomo="$(make_matomo Example tests)"
mkdir -p "$matomo/plugins/Other/nested/.git"
echo 'url = https://x-access-token:abc@github.com/innocraft/plugin-Other' > "$matomo/plugins/Other/nested/.git/config"
chmod 000 "$matomo/plugins/Other/nested/.git/config"
output="$(generate "$matomo" Example)"
status=$?
chmod 644 "$matomo/plugins/Other/nested/.git/config"
check "fails when a config cannot be read to rule a token out" "[ $status -ne 0 ] && grep -qF 'Credential material' <<<\"\$output\"" "$output"

matomo="$(make_matomo Example tests)"
mkdir -p "$matomo/compatibility-results"
echo ran > "$matomo/compatibility-results/GeneratedAssetCompilationTest"
output="$(generate "$matomo" Example)"
check "starts from an empty results directory, so no stale marker counts" \
  "[ -d '$matomo/compatibility-results' ] && [ -z \"\$(ls -A '$matomo/compatibility-results')\" ]" "$output"
for class in "${CLASSES[@]}"; do
  check "$class records its outcome in the results directory" \
    "grep -qF \"PIWIK_DOCUMENT_ROOT . '/compatibility-results/$class'\" '$matomo/plugins/Example/tests/Integration/$class.php'"
done
# markTestSkipped() throws, so a marker written after it would never land.
twig_file="$matomo/plugins/Example/tests/Integration/GeneratedTwigCompilationTest.php"
record_line="$(grep -n "recordOutcome('skipped')" "$twig_file" | cut -d: -f1)"
skip_line="$(grep -n 'markTestSkipped(' "$twig_file" | cut -d: -f1)"
check "the Twig test records a skip before it skips" \
  "[ -n '$record_line' ] && [ -n '$skip_line' ] && [ '$record_line' -lt '$skip_line' ]"
check "the workflow checks the results directory the generator creates" \
  "grep -qE 'check_compatibility_results\.sh compatibility-results\$' '$ROOT/.github/workflows/plugin-compatibility.yml'"
check "the workflow no longer relies on a JUnit log" \
  "! grep -qE 'phpunit-test-options:.*log-junit' '$ROOT/.github/workflows/plugin-compatibility.yml'"

# A composer whose unset silently does nothing, so the entry is still readable afterwards.
mkdir -p "$WORK/stuck-composer"
printf '#!/bin/sh\nexit 0\n' > "$WORK/stuck-composer/composer"
chmod +x "$WORK/stuck-composer/composer"
matomo="$(make_matomo Example tests)"
output="$(PATH="$WORK/stuck-composer:$PATH" generate "$matomo" Example)"
status=$?
check "fails when composer's github-oauth entry survives the unset" "[ $status -ne 0 ] && grep -qF 'is still set' <<<\"\$output\"" "$output"

if command -v composer >/dev/null 2>&1; then
  composer config --global github-oauth.github.com not-a-real-token >/dev/null 2>&1
  matomo="$(make_matomo Example tests)"
  output="$(generate "$matomo" Example)"
  check "removes composer's global github-oauth entry" \
    "! composer config --global github-oauth.github.com >/dev/null 2>&1" "$output"
else
  echo "skip - composer is not available, so the github-oauth removal is not exercised"
fi

# $1 description, $2 expected exit (0 or 1), then class=outcome pairs to write (none: no directory).
results_case() {
  local description="$1" expected="$2" dir="$WORK/results-$tests" output status pair
  shift 2
  if [ $# -gt 0 ]; then
    mkdir -p "$dir"
    for pair in "$@"; do
      [ -n "${pair#*=}" ] && printf '%s' "${pair#*=}" > "$dir/${pair%%=*}"
    done
  fi
  output="$("$CHECKER" "$dir" 2>&1)"
  status=$?
  check "results check $description" "[ $status -eq $expected ]" "$output"
}
asset=GeneratedAssetCompilationTest
twig=GeneratedTwigCompilationTest

results_case "passes when both ran" 0 "$asset=ran" "$twig=ran"
results_case "passes when only the Twig test was skipped" 0 "$asset=ran" "$twig=skipped"
results_case "fails when the asset test was skipped" 1 "$asset=skipped" "$twig=ran"
results_case "fails when the Twig test recorded nothing" 1 "$asset=ran" "$twig="
results_case "fails when the asset test recorded nothing" 1 "$asset=" "$twig=ran"
results_case "fails on an unrecognised outcome" 1 "$asset=ran" "$twig=ran,skipped"
results_case "fails on an outcome that only ends in ran" 1 "$asset=corrupted:ran" "$twig=ran"
results_case "fails when the directory is missing" 1

# github-action-tests executes the setup-script directly rather than through bash, and the workflow
# runs the results check the same way.
for script in generate_compatibility_checks.sh check_compatibility_results.sh; do
  check "$script is executable" "[ -x '$ROOT/scripts/bash/$script' ]"
  mode="$(git -C "$ROOT" ls-files --stage -- "scripts/bash/$script" | cut -d' ' -f1)"
  if [ -n "$mode" ]; then
    check "$script is committed executable" "[ '$mode' = 100755 ]" "mode is $mode"
  fi
done

echo
echo "$tests tests, ${#failures[@]} failures"
[ ${#failures[@]} -eq 0 ] || exit 1
