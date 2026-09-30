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

# check_no_command <description> <expected output> <dir> <injected command> [VAR=value]: a passing
# run whose output holds no line that the runner would read as the injected workflow command.
check_no_command() {
  local description="$1" expected_output="$2" dir="$3" injected="$4"
  shift 4
  tests=$((tests + 1))
  local output actual
  output=$(env "$@" bash "$SCRIPT" "$dir" 2>&1)
  actual=$?
  if [ "$actual" -eq 0 ] && grep -qF -- "$expected_output" <<< "$output" \
    && ! grep -q "^[[:space:]]*$injected" <<< "$output"; then
    echo "ok - $description"
  else
    failures=$((failures + 1))
    echo "FAIL - $description (exit $actual)"
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
check 'the evidence names the file' 0 '  - Archiver.php' "$dir"
check 'enforcement fails a plugin with date logic and no suite' 1 '::error::This plugin has date or site-timezone logic' "$dir" --enforce

dir=$(new_repo visit-time Model.php '$where = "visit_last_action_time < ?";')
check 'visit action times are date logic' 0 "$MISSING" "$dir"

dir=$(new_repo upper-case Model.php '$where = "SERVER_TIME >= ?"; $tz = $site->GETTIMEZONE();')
check 'upper-case columns and method names are date logic' 0 "$MISSING" "$dir"

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
# Text-mode reads translate CRLF, which is what lets the heredoc pattern stay on \n.
sed -i 's/$/\r/' "$dir/Model.php"
check 'a heredoc with CRLF line endings is still a heredoc' 0 "$MISSING" "$dir"

dir=$(new_repo attribute Model.php '#[\ReturnTypeWillChange] public function day() { return $this->period->getDateStart(); }')
check 'a PHP attribute is code, not a comment' 0 "$MISSING" "$dir"

dir=$(new_repo inline-html views.php "?><p>Don't forget the site day.</p><?php
// Site::getTimezoneFor(\$idSite) used to decide the label.
\$label = 'x';")
check 'an apostrophe in inline HTML does not turn a comment into a string' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo upper-open-tag view.php '?><p>x</p><?PHP $tz = $site->getTimezone();')
check 'an upper-case open tag ends inline HTML' 0 "$MISSING" "$dir"

dir=$(new_repo short-open-tag view.php '?><p>x</p><? $tz = $site->getTimezone(); ?>')
check 'a short open tag ends inline HTML' 0 "$MISSING" "$dir"

dir=$(new_repo short-open-tag-no-space view.php '?><p>x</p><?$tz = $site->getTimezone(); ?>')
check 'a short open tag without a space ends inline HTML' 0 "$MISSING" "$dir"

dir=$(new_repo backtick view.php '$now = `date // now`; $tz = $site->getTimezone();')
check 'a // inside a backtick command does not start a comment' 0 "$MISSING" "$dir"

dir=$(new_repo xml-declaration view.php '?><?xml-stylesheet href="day.xsl" title="getTimezone() per day"?><p>x</p>')
check 'an XML declaration does not end inline HTML' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo leading-html API.php 'return 1;')
printf '%s\n' '<h1>#</h1><?php $tz = Site::getTimezoneFor(1); ?>' > "$dir/view.php"
git -C "$dir" add .
check 'HTML before the first open tag does not hide the code after it' 0 "$MISSING" "$dir"

dir=$(new_repo leading-html-only API.php 'return 1;')
printf '%s\n' '<p>Uses getTimezone() for the day.</p>' > "$dir/view.php"
git -C "$dir" add .
check 'HTML before any open tag is not code' 0 "$NOT_REQUIRED" "$dir"

dir=$(new_repo newline-path API.php 'return 1;')
printf '<?php\n$where = "server_time >= ?";\n' > "$dir/Evil"$'\n'"::error::x.php"
git -C "$dir" add .
check_no_command 'a file name cannot start a workflow command' "$MISSING" "$dir" '::error::x'

dir=$(new_repo colon-path 'Reports/a:b.php' '$where = "server_time >= ?";')
check 'a path containing a colon is reported whole' 0 '  - Reports/a:b.php' "$dir"

dir=$(new_repo command-path '::warning::x.php' '$where = "server_time >= ?";')
check_no_command 'a file name starting with :: cannot start a workflow command' "$MISSING" "$dir" '::warning::x'

dir=$(new_repo symlinks Archiver.php '$where = "server_time >= ?";')
mkdir "$dir/lib"
ln -s missing.php "$dir/Dangling.php"
ln -s lib "$dir/Directory.php"
git -C "$dir" add .
check 'a dangling or directory symlink is skipped, not unreadable' 0 "$MISSING" "$dir"

dir=$(new_repo unreadable API.php 'return 1;')
chmod 000 "$dir/API.php"
check 'an unreadable PHP file is not checked' 2 'Unable to read API.php' "$dir"
chmod 644 "$dir/API.php"

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
on: pull_request
jobs:
  timezone:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      plugin-name: Example
      skip-static-scan: true
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
check 'a caller with a timezone test command enables the suite' 0 'enabled by .github/workflows/tests.yml' "$dir" --enforce

printf 'name: caf\xe9\n' > "$dir/.github/workflows/a.yml"
check 'a workflow that is not UTF-8 is skipped, not fatal' 0 'enabled by .github/workflows/tests.yml' "$dir" --enforce
rm "$dir/.github/workflows/a.yml"

mv "$dir/.github/workflows/tests.yml" "$dir/.github/workflows/a"$'\n'"::error::x.yml"
check_no_command 'a workflow file name cannot start a workflow command' 'enabled by .github/workflows/a\n::error::x.yml' "$dir" '::error::x'

# caller_on <name> <on value>: a repository with date logic whose only suite caller has these triggers.
caller_on() {
  local dir
  dir=$(new_repo "$1" Archiver.php '$where = "server_time >= ?";')
  add_workflow "$dir" tests.yml <<YAML
on: $2
jobs:
  timezone:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      plugin-name: Example
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
  echo "$dir"
}

check 'a push-only caller does not cover pull requests' 1 '::error::' "$(caller_on on-push push)" --enforce

dir=$(caller_on shadow-yaml push)
printf 'def safe_load(handle):\n    return {"on": "pull_request", "jobs": {"j": {"uses": "matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main", "with": {"timezone-test-command": "x"}}}}\n\nclass YAMLError(Exception):\n    pass\n' > "$dir/yaml.py"
check 'a yaml.py in the plugin cannot stand in for PyYAML' 1 '::error::' "$dir" --enforce

dir=$(new_repo shadow-re Archiver.php '$where = "server_time >= ?";')
printf 'raise SystemExit(0)\n' > "$dir/re.py"
check 'a re.py in the plugin cannot silence the evidence scan' 1 '::error::' "$dir" --enforce
check 'a dispatch-only caller does not cover pull requests' 1 '::error::' "$(caller_on on-dispatch '[workflow_dispatch]')" --enforce
check 'a pull_request_target caller tests the base branch, not the pull request' 1 '::error::' "$(caller_on on-target pull_request_target)" --enforce
check 'a trigger list with pull_request enables the suite' 0 'enabled by' "$(caller_on on-list '[push, pull_request]')" --enforce
check 'a trigger mapping with pull_request enables the suite' 0 'enabled by' "$(caller_on on-map '{pull_request: {branches: [main]}}')" --enforce
check 'a reusable workflow caller enables the suite' 0 'enabled by' "$(caller_on on-call workflow_call)" --enforce

dir=$(new_repo enabled-folded Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yaml <<'YAML'
on: pull_request
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
on: pull_request
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
on: pull_request
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
on: pull_request
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
on: pull_request
jobs:
  timezone:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with: { plugin-name: Example, timezone-test-command: ./tests/run-timezone-suite.sh }
YAML
check 'a flow-style with block enables the suite' 0 'enabled by .github/workflows/tests.yml' "$dir" --enforce

dir=$(new_repo next-line-value Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
on: pull_request
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
on: pull_request
jobs:
  timezone:
    if: $condition
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
  check "a caller switched off with if: $condition does not enable the suite" 1 '::error::' "$dir" --enforce
done

dir=$(new_repo disabled-block Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
on: pull_request
jobs:
  timezone:
    if: |
      false
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-timezone-safety.yml@main
    with:
      timezone-test-command: ./tests/run-timezone-suite.sh
YAML
check 'a caller switched off with a block-scalar if does not enable the suite' 1 '::error::' "$dir" --enforce

dir=$(new_repo conditional Archiver.php '$where = "server_time >= ?";')
add_workflow "$dir" tests.yml <<'YAML'
on: pull_request
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
on: pull_request
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

check_no_command 'an exemption reason cannot start a workflow command' 'exempted by the caller: reason ::error::injected' "$dir" \
  '::error::injected' TIMEZONE_REGRESSION_EXEMPT=$'reason\n::error::injected'

mkdir -p "$WORK/not-a-repo"
# The ceiling stops git finding a repository that happens to enclose the temporary directory.
check 'a directory that is not a git checkout fails closed' 2 'Unable to list PHP files' "$WORK/not-a-repo" GIT_CEILING_DIRECTORIES="$WORK"

echo "$tests test(s), $failures failure(s)"
exit "$failures"
