#!/bin/bash

# Runs the "Check timezone regression coverage" step of plugin-timezone-safety.yml against stubs.
# The step cannot hand its logic to a staged helper like the scan does: a pin too old to carry the
# coverage script would lack the helper too, and that is one of the cases the step must report.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL - PyYAML is not available, so the coverage step cannot be read from the workflow"
  exit 1
fi

# Extracted by step name rather than by line range, so a reformat of the workflow cannot make the
# test run something other than the step.
python3 - "$ROOT/.github/workflows/plugin-timezone-safety.yml" "$WORK/step.sh" <<'PY'
import sys
import yaml

workflow = yaml.safe_load(open(sys.argv[1]))
steps = [
    step for step in workflow['jobs']['timezone-safety']['steps']
    if step.get('name') == 'Check timezone regression coverage'
]
assert len(steps) == 1, f"expected exactly one coverage step, found {len(steps)}"
open(sys.argv[2], 'w').write(steps[0]['run'])
PY

mkdir -p "$WORK/runner" "$WORK/no-yaml"
cat > "$WORK/coverage-stub.sh" <<'SH'
echo "coverage called with: $*"
exit "${STUB_STATUS:-0}"
SH
# The runner lacks PyYAML and cannot install it.
printf '#!/bin/sh\nexit 1\n' > "$WORK/no-yaml/python3"
printf '#!/bin/sh\nexit 1\n' > "$WORK/no-yaml/sudo"
chmod +x "$WORK/no-yaml/python3" "$WORK/no-yaml/sudo"

tests=0
failures=0

# check <description> <exit> <output> <staged: yes|no> [VAR=value ...]
check() {
  local description="$1" expected_exit="$2" expected_output="$3" staged="$4"
  shift 4
  tests=$((tests + 1))
  rm -f "$WORK/runner/check_timezone_regression_coverage.sh"
  if [ "$staged" = yes ]; then
    cp "$WORK/coverage-stub.sh" "$WORK/runner/check_timezone_regression_coverage.sh"
  fi
  local output actual
  # The shell GitHub Actions uses for `shell: bash`.
  output=$(cd "$WORK" && env RUNNER_TEMP="$WORK/runner" WORKFLOWS_REF=v1 COVERAGE_MODE=warn BASE_BRANCH=main "$@" \
    bash --noprofile --norc -eo pipefail "$WORK/step.sh" 2>&1)
  actual=$?
  if [ "$actual" -eq "$expected_exit" ] && { [ -z "$expected_output" ] || grep -qF -- "$expected_output" <<< "$output"; }; then
    echo "ok - $description"
  else
    failures=$((failures + 1))
    echo "FAIL - $description (exit $actual, expected $expected_exit)"
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<< "$output"
  fi
}

check 'warn mode runs the check without enforcing' 0 'coverage called with: .' yes
check 'enforce mode enforces on a pull request' 0 'coverage called with: --enforce .' yes COVERAGE_MODE=enforce
check 'enforce mode stays advisory outside a pull request' 0 'coverage called with: .' yes COVERAGE_MODE=enforce BASE_BRANCH=
check 'an enforced verdict fails the step' 1 'coverage called with: --enforce .' yes COVERAGE_MODE=enforce STUB_STATUS=1

check 'a missing script warns in warn mode' 0 "::warning::Timezone regression coverage was not checked: the scan step did not stage" no
check 'a missing script names the pinned ref' 0 "workflows-ref 'v1' predates the script" no
check 'a pinned ref cannot start a workflow command' 0 "workflows-ref 'v1 ::error::injected' predates" no WORKFLOWS_REF=$'v1\n::error::injected'
check 'a missing script fails an enforced pull request' 2 '::error::Timezone regression coverage was not checked' no COVERAGE_MODE=enforce
check 'a missing script warns outside a pull request' 0 '::warning::' no COVERAGE_MODE=enforce BASE_BRANCH=

check 'a check that cannot run warns in warn mode' 0 '::warning::Timezone regression coverage was not checked: the check could not run' yes STUB_STATUS=2
check 'a check that cannot run fails an enforced pull request' 2 '::error::Timezone regression coverage was not checked: the check could not run' yes COVERAGE_MODE=enforce STUB_STATUS=2

check 'a runner without PyYAML warns in warn mode' 0 '::warning::Timezone regression coverage was not checked: PyYAML could not be installed.' yes PATH="$WORK/no-yaml:$PATH"
check 'a runner without PyYAML fails an enforced pull request' 2 '::error::Timezone regression coverage was not checked: PyYAML could not be installed.' yes PATH="$WORK/no-yaml:$PATH" COVERAGE_MODE=enforce

echo "$tests test(s), $failures failure(s)"
exit "$failures"
