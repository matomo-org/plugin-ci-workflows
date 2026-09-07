#!/bin/bash
# Tests for scripts/bash/check_caller_concurrency.sh, the guard that fails a Plugin CI run when
# the calling workflow declares a `concurrency` block of its own.
# Usage: bash tests/caller_concurrency_test.sh
#
# The guard runs on every plugin's pull requests, so both directions matter: a caller-level block
# has to fail the run, and a caller that is doing nothing wrong has to stay green. A guard that
# false-positives reddens the fleet, and one that false-negatives leaves the failure it exists to
# catch as invisible as it was before.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/bash/check_caller_concurrency.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=()

# Writes $3 as the caller's workflow and asserts the guard's exit status is $2.
run_case() {
  local description="$1" expected="$2" body="$3"
  local root="$WORK/case-$tests"
  tests=$((tests + 1))
  mkdir -p "$root/.github/workflows"
  printf '%s' "$body" > "$root/.github/workflows/ci.yml"

  local output status
  output="$(bash "$GUARD" 'matomo-org/plugin-Foo/.github/workflows/ci.yml@refs/pull/1/merge' "$root" 2>&1)"
  status=$?
  if [ "$status" = "$expected" ]; then
    echo "ok - $description"
  else
    echo "FAIL - $description (expected exit $expected, got $status)"
    echo "$output"
    failures+=("$description")
  fi
}

# Asserts the guard's exit status is $3 for workflow ref $2 against an empty checkout.
run_ref_case() {
  local description="$1" workflow_ref="$2" expected="$3"
  local root="$WORK/ref-case-$tests"
  tests=$((tests + 1))
  mkdir -p "$root/.github/workflows"

  local status
  bash "$GUARD" "$workflow_ref" "$root" >/dev/null 2>&1
  status=$?
  if [ "$status" = "$expected" ]; then
    echo "ok - $description"
  else
    echo "FAIL - $description (expected exit $expected, got $status)"
    failures+=("$description")
  fi
}

CALL="    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-ci.yml@main"

run_case "a caller declaring no concurrency passes" 0 "\
name: CI
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]
jobs:
  ci:
$CALL
    with:
      plugin-name: Foo
"

# The shape every plugin's matomo-ai-checklist.yml ships today, and so the shape a rename to
# ci.yml carries over unnoticed. This is the case the guard exists for.
run_case "a workflow-level concurrency mapping fails" 1 "\
name: CI
on: pull_request
concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true
jobs:
  ci:
$CALL
"

# `concurrency: some-group` is legal and means the same thing, so matching only the mapping shape
# would leave an equivalent block through.
run_case "a workflow-level concurrency written as a bare group fails" 1 "\
name: CI
on: pull_request
concurrency: plugin-ci
jobs:
  ci:
$CALL
"

run_case "a concurrency block on the job that calls Plugin CI fails" 1 "\
name: CI
on: pull_request
jobs:
  ci:
$CALL
    concurrency:
      group: ci-\${{ github.ref }}
      cancel-in-progress: true
"

# It cancels that job and nothing of ours, so it is the caller's business. Failing it would redden
# a plugin for a lane that cannot touch a Plugin CI run.
run_case "a concurrency block on an unrelated job passes" 0 "\
name: CI
on: pull_request
jobs:
  ci:
$CALL
  something-else:
    runs-on: ubuntu-24.04
    concurrency:
      group: something-else-\${{ github.ref }}
    steps:
      - run: 'true'
"

# A caller pinning the umbrella to a SHA is the same caller.
run_case "a concurrency block on a job calling a pinned Plugin CI fails" 1 "\
name: CI
on: pull_request
jobs:
  ci:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-ci.yml@3d3c42e5aac5ba805825da76410c181273ba90b1
    concurrency:
      group: ci-\${{ github.ref }}
"

# Fail closed on anything that stops it reading the file it is meant to judge: a guard that cannot
# see the caller has proved nothing, and passing there is how it would come to be trusted wrongly.
run_ref_case "a workflow ref naming a file that is not checked out fails" \
  'matomo-org/plugin-Foo/.github/workflows/absent.yml@refs/pull/1/merge' 1
run_ref_case "a workflow ref carrying no path fails" 'refs/heads/main' 1

# Refs may contain `@`, so the path is taken up to the first one rather than the last.
tests=$((tests + 1))
AT_ROOT="$WORK/at-ref"
mkdir -p "$AT_ROOT/.github/workflows"
printf 'name: CI\non: pull_request\njobs:\n  ci:\n%s\n' "$CALL" > "$AT_ROOT/.github/workflows/ci.yml"
if bash "$GUARD" 'matomo-org/plugin-Foo/.github/workflows/ci.yml@refs/heads/feature@2' "$AT_ROOT" >/dev/null 2>&1; then
  echo "ok - a ref containing an @ still resolves the workflow path"
else
  echo "FAIL - a ref containing an @ still resolves the workflow path"
  failures+=("a ref containing an @ still resolves the workflow path")
fi

echo
echo "$tests tests, ${#failures[@]} failures"
[ ${#failures[@]} -eq 0 ] || exit 1
