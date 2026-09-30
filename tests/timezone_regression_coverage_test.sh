#!/bin/bash
# shellcheck disable=SC2016 # The single-quoted fixtures are PHP source; their $ must stay literal.

# Regression tests for scripts/bash/check_timezone_regression_coverage.sh.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/bash/check_timezone_regression_coverage.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=0

# check <description> <exit> <output> <dir> [--flag ...] [VAR=value ...]
check() {
  local description="$1" expected_exit="$2" expected_output="$3" dir="$4"
  shift 4
  tests=$((tests + 1))
  local output actual arg flags=() vars=()
  for arg in "$@"; do
    if [[ "$arg" == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi
  done
  output=$(env "${vars[@]}" bash "$SCRIPT" "${flags[@]}" "$dir" 2>&1)
  actual=$?
  if [ "$actual" -eq "$expected_exit" ] && { [ -z "$expected_output" ] || grep -qF -- "$expected_output" <<< "$output"; }; then
    echo "ok - $description"
  else
    failures=$((failures + 1))
    echo "FAIL - $description (exit $actual, expected $expected_exit)"
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<< "$output"
  fi
}

# new_repo <name> <path> <php body>: a git repository whose one tracked PHP file holds the body.
new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/$(dirname "$2")"
  printf '<?php\n%s\n' "$3" > "$dir/$2"
  git -C "$dir" init -q
  git -C "$dir" add .
  echo "$dir"
}

add_workflow() {
  mkdir -p "$1/.github/workflows"
  cat > "$1/.github/workflows/$2"
}

NOT_REQUIRED='no regression suite is required'
MISSING='::warning::This plugin has date or site-timezone logic but no timezone regression suite'

dir=$(new_repo plain API.php 'return $this->model->getAll($idSite);')
check 'plugins without date logic need no suite' 0 "$NOT_REQUIRED" "$dir"
check 'plugins without date logic pass when enforced' 0 "$NOT_REQUIRED" "$dir" --enforce

dir=$(new_repo server-time Archiver.php '$sql = "SELECT COUNT(*) FROM log_link_visit_action WHERE server_time >= ?";')
check 'log table event times are date logic' 0 "$MISSING" "$dir"
check 'the evidence names the file' 0 '  Archiver.php' "$dir"
check 'enforcement fails a plugin with date logic and no suite' 1 '::error::This plugin has date or site-timezone logic' "$dir" --enforce

dir=$(new_repo visit-time Model.php '$where = "visit_last_action_time < ?";')
check 'visit action times are date logic' 0 "$MISSING" "$dir"

dir=$(new_repo qualified-column Model.php '$where = "log_link_visit_action.server_time >= ?";')
check 'a table-qualified event time is date logic' 0 "$MISSING" "$dir"

dir=$(new_repo similar-names Config.php '$timeout = $config["server_timeout"] + $observer_time; $zone = $cfg["server_timezone"]; $last = $this->prev_visit_last_action_times; $s = $x->mygetTimezone();')
check 'names that only contain a column or method name are not date logic' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo period-bounds API.php '$start = $period->getDateTimeStartUTC();')
check 'period boundaries are date logic' 0 "$MISSING" "$dir"

dir=$(new_repo period-start RecordBuilder.php '$day = $this->period->getDateStart ();')
check 'spacing before the call does not hide a period boundary' 0 "$MISSING" "$dir"

dir=$(new_repo site-timezone API.php '$timezone = Site::getTimezoneFor($idSite);')
check 'the site timezone is date logic' 0 "$MISSING" "$dir"

dir=$(new_repo site-object Reports.php '$timezone = $site->getTimezone();')
check 'a site object timezone is date logic' 0 "$MISSING" "$dir"

dir=$(new_repo in-tests tests/Integration/ApiTest.php '$tz = Site::getTimezoneFor(1);')
check 'test code is not production date logic' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo in-capital-tests Test/Integration/ApiTest.php '$tz = Site::getTimezoneFor(1);')
check 'a capitalised Test directory is test code too' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo in-vendor vendor/lib/Clock.php '$start = $period->getDateStart();')
check 'vendored code is not the plugin'"'"'s date logic' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo in-updates Updates/5.2.2.php '$sql = "UPDATE log_visit SET x = 1 WHERE server_time > ?";')
check 'one-off migrations are not per-report date logic' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo in-comments Model.php "// server_time is stored in UTC
/**
 * Uses getDateStart() of the period.
 */
# getTimezoneFor(\$idSite)")
check 'comments that mention date logic do not count' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo block-comment-body Model.php '/*
    Old code, kept for reference:
    $tz = Site::getTimezoneFor($idSite);
*/
return 1; // server_time is UTC
$attribute = 1; # getDateStart() once lived here')
check 'block comment bodies and trailing comments do not count' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo code-after-comment Model.php '/* the site day */ $tz = Site::getTimezoneFor($idSite);')
check 'code after a block comment on the same line counts' 0 "$MISSING" "$dir"

dir=$(new_repo comment-in-string Model.php '$url = "https://example.org/*"; $where = "server_time >= ?";')
check 'a comment opener inside a string does not hide the code after it' 0 "$MISSING" "$dir"

dir=$(new_repo heredoc Model.php "\$sql = <<<SQL
SELECT 'it''s' FROM log_visit /* not a PHP comment
SQL;
\$tz = \$site->getTimezone();")
check 'a heredoc does not open a comment or string that hides later code' 0 "$MISSING" "$dir"

dir=$(new_repo attribute Model.php '#[\ReturnTypeWillChange] public function day() { return $this->period->getDateStart(); }')
check 'a PHP attribute is code, not a comment' 0 "$MISSING" "$dir"

dir=$(new_repo inline-html views.php "?><p>Don't forget the site day.</p><?php
// Site::getTimezoneFor(\$idSite) used to decide the label.
\$label = 'x';")
check 'an apostrophe in inline HTML does not turn a comment into a string' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo newline-path API.php 'return 1;')
printf '<?php\n$where = "server_time >= ?";\n' > "$dir/Evil"$'\n'"::error::x.php"
git -C "$dir" add .
tests=$((tests + 1))
if bash "$SCRIPT" "$dir" 2>&1 | grep -q '^[[:space:]]*::error::x'; then
  failures=$((failures + 1))
  echo 'FAIL - a file name cannot start a workflow command'
else
  echo 'ok - a file name cannot start a workflow command'
fi

dir=$(new_repo colon-path 'Reports/a:b.php' '$where = "server_time >= ?";')
check 'a path containing a colon is reported whole' 0 '  Reports/a:b.php' "$dir"

check 'a repository root that does not exist fails closed' 2 '' "$WORK/does-not-exist"

dir=$(new_repo untracked API.php 'return 1;')
printf '<?php\n$tz = Site::getTimezoneFor(1);\n' > "$dir/Scratch.php"
check 'untracked files are not scanned' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo not-php API.php 'return 1;')
echo 'server_time getDateStart( getTimezoneFor(' > "$dir/notes.md"
git -C "$dir" add notes.md
check 'only PHP files are scanned' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo enabled Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
jobs:
  timezone:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      plugin-name: Example
      skip-static-scan: true
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
check 'a caller with a timezone test command enables the suite' 0 'enabled by .github/workflows/tests.yml' "$dir" --enforce

dir=$(new_repo enabled-folded Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yaml <<'YAML'
jobs:
  timezone:
    uses: 'matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@0123456789abcdef0123456789abcdef01234567'
    with:
      plugin-name: Example
      timezone-test-command: >-
        ./tests/run-timezone-suite.sh
YAML
check 'a folded command in a .yaml caller pinned by SHA enables the suite' 0 'enabled by .github/workflows/tests.yaml' "$dir" --enforce

for empty in "''" '""' '' "'' # not yet"; do
  dir=$(new_repo "empty-command-$tests" Archiver.php '$where = "server_time >= ?";')
  add_workflow "$dir" tests.yml <<YAML
jobs:
  timezone:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      plugin-name: Example
      timezone-test-command: $empty
YAML
  check "an empty timezone test command ($empty) does not enable the suite" 1 '::error::' "$dir" --enforce
done

dir=$(new_repo commented-caller Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
jobs:
  timezone:
    # uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    uses: ./.github/workflows/local.yml
    with:
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
check 'a commented-out caller does not enable the suite' 1 '::error::' "$dir" --enforce

dir=$(new_repo command-in-other-job Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
jobs:
  timezone:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      plugin-name: Example
  other:
    uses: ./.github/workflows/local.yml
    with:
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
check 'a command in another job does not enable the suite' 1 '::error::' "$dir" --enforce

dir=$(new_repo second-job-enabled Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
on: pull_request
jobs:
  tests:
    runs-on: ubuntu-24.04
    steps:
      - run: echo timezone-test-command
  timezone:
    # The suite runs under Pacific/Auckland.
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:

      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
check 'a caller that is not the first job enables the suite' 0 'enabled by .github/workflows/tests.yml' "$dir" --enforce

dir=$(new_repo flow-style Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
jobs:
  timezone:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with: { plugin-name: Example, timezone-test-command: ./tests/run-timezone-suite.sh }
YAML
check 'a flow-style with block enables the suite' 0 'enabled by .github/workflows/tests.yml' "$dir" --enforce

dir=$(new_repo next-line-value Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
jobs:
  timezone:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      timezone-test-command:
        ./tests/run-timezone-suite.sh
YAML
check 'a command on the next line enables the suite' 0 'enabled by .github/workflows/tests.yml' "$dir" --enforce

for condition in false "'false'" '${{ false }}'; do
  dir=$(new_repo "disabled-$tests" Archiver.php '$where = "server_time >= ?";')
  add_workflow "$dir" tests.yml <<YAML
jobs:
  timezone:
    if: $condition
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
  check "a caller switched off with if: $condition does not enable the suite" 1 '::error::' "$dir" --enforce
done

dir=$(new_repo conditional Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
jobs:
  timezone:
    if: ${{ github.event_name == 'pull_request' }}
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
check 'a caller with a real condition enables the suite' 0 'enabled by .github/workflows/tests.yml' "$dir" --enforce

mkdir -p "$WORK/no-yaml"
echo 'raise ImportError("hidden by the test")' > "$WORK/no-yaml/yaml.py"
check 'a runner without PyYAML fails closed' 2 'PyYAML is not available' "$dir" PYTHONPATH="$WORK/no-yaml"

dir=$(new_repo umbrella-only Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" ci.yml <<'YAML'
jobs:
  ci:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-ci.yml@main
    with:
      plugin-name: Example
YAML
check 'the Plugins CI caller alone does not enable the suite' 1 '::error::' "$dir" --enforce

dir=$(new_repo exempt Archiver.php '$where = "server_time >= ?";')
check 'an exemption reason satisfies the check' 0 'exempted by the caller: Generates fixture data only' "$dir" \
  --enforce TIMEZONE_REGRESSION_EXEMPT='Generates fixture data only'
check 'a blank exemption is not an exemption' 1 '::error::' "$dir" --enforce TIMEZONE_REGRESSION_EXEMPT='   '

tests=$((tests + 1))
output=$(TIMEZONE_REGRESSION_EXEMPT=$'reason\n::error::injected' bash "$SCRIPT" "$dir" 2>&1)
if grep -q '^::' <<< "$output"; then
  failures=$((failures + 1))
  echo 'FAIL - an exemption reason cannot start a workflow command'
  while IFS= read -r line; do printf '    %s\n' "$line"; done <<< "$output"
else
  echo 'ok - an exemption reason cannot start a workflow command'
fi

mkdir -p "$WORK/not-a-repo"
# The ceiling stops git finding a repository that happens to enclose the temporary directory.
check 'a directory that is not a git checkout fails closed' 2 'Unable to list PHP files' "$WORK/not-a-repo" GIT_CEILING_DIRECTORIES="$WORK"

echo "$tests test(s), $failures failure(s)"
exit "$failures"
