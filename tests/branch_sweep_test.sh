#!/bin/bash
# Tests for the shell in .github/workflows/plugin-branch-sweep.yml, which dispatches a plugin's
# build for each maintained branch that is not its default.
# Usage: bash tests/branch_sweep_test.sh
#
# The failure this sweep exists to remove is a branch quietly ceasing to be built, so the cases
# that matter most are the ones where nothing is dispatched: each has to be loud in its own way.
# An absent branch is fine and stays green, an API failure is not and must go red -- and an
# earlier revision of this script conflated the two, reporting a 500 as "the branch does not
# exist here" and exiting 0. A run that dispatches nothing at all warns, because it is otherwise
# indistinguishable from a working one.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/plugin-branch-sweep.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=()

# Read the step's shell out of the YAML rather than slicing the file by indentation: an awk
# range over `run: |` silently extracts nothing the day the block moves a level.
python3 - "$WORKFLOW" "$WORK/sweep.sh" <<'PY' || { echo "could not extract the run block"; exit 1; }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc['jobs']['sweep']['steps']
run = [s['run'] for s in steps if 'run' in s]
assert len(run) == 1, f"expected exactly one run step, found {len(run)}"
open(sys.argv[2], 'w').write(run[0])
PY

mkdir -p "$WORK/bin"

# The retry sleeps would otherwise make the exhausted-lookup case take 15 seconds.
cat > "$WORK/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

# Stub gh. DEFAULT_FAILS_N failures before the default-branch lookup succeeds, BRANCH_STATUS for
# the branch probe, DISPATCH_FAILS to refuse the dispatch. Dispatched refs are recorded so a case
# can assert which branch was built, not merely that something was.
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "api" ]; then
  case "$2" in
    repos/*/branches/*)
      case "${BRANCH_STATUS:-200}" in
        404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
        500) echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1 ;;
        *) echo "${2##*/}"; exit 0 ;;
      esac ;;
    repos/*)
      n=$(cat "$STUB_STATE/attempts" 2>/dev/null || echo 0)
      n=$((n + 1)); echo "$n" > "$STUB_STATE/attempts"
      if [ "$n" -le "${DEFAULT_FAILS_N:-0}" ]; then
        echo "gh: Server Error (HTTP 502)" >&2; exit 1
      fi
      echo "${DEFAULT_BRANCH:-6.x-dev}"; exit 0 ;;
  esac
fi
if [ "$1" = "workflow" ]; then
  if [ -n "${DISPATCH_FAILS:-}" ]; then echo "gh: dispatch refused" >&2; exit 1; fi
  # `gh workflow run <file> --ref <branch>`, so the ref is the fifth argument
  shift 4; echo "$1" >> "$STUB_STATE/dispatched"; exit 0
fi
exit 0
EOF
chmod +x "$WORK/bin/sleep" "$WORK/bin/gh"

# Runs the step's shell under the same options GitHub uses for `shell: bash`, and asserts the
# exit status, the branches dispatched, and any annotation the case names.
run_case() {
  local description="$1" expected="$2" want_dispatched="$3" want_output="$4"; shift 4
  local state="$WORK/state-$tests"
  tests=$((tests + 1))
  mkdir -p "$state"

  local output status dispatched
  output="$(env PATH="$WORK/bin:$PATH" STUB_STATE="$state" \
    GITHUB_REPOSITORY='matomo-org/plugin-Foo' WORKFLOW_FILE='matomo-tests.yml' \
    MAINTAINED_BRANCHES="${MAINTAINED_BRANCHES:-6.x-dev 5.x-dev}" "$@" \
    bash --noprofile --norc -eo pipefail "$WORK/sweep.sh" 2>&1)"
  status=$?
  dispatched=""
  if [ -f "$state/dispatched" ]; then
    dispatched="$(tr '\n' ' ' < "$state/dispatched" | sed 's/ *$//')"
  fi

  if [ "$status" != "$expected" ]; then
    echo "FAIL - $description (expected exit $expected, got $status)"
    echo "$output"; failures+=("$description"); return
  fi
  if [ "$dispatched" != "$want_dispatched" ]; then
    echo "FAIL - $description (dispatched '$dispatched', expected '$want_dispatched')"
    echo "$output"; failures+=("$description"); return
  fi
  if [ -n "$want_output" ] && [[ "$output" != *"$want_output"* ]]; then
    echo "FAIL - $description (output did not contain '$want_output')"
    echo "$output"; failures+=("$description"); return
  fi
  echo "ok - $description"
}

run_case "the non-default maintained branch is dispatched" 0 '5.x-dev' 'Dispatched matomo-tests.yml on 5.x-dev'

# The default is built by its own schedule; dispatching it again would double every weekly run.
run_case "the default branch is never dispatched" 0 '6.x-dev' 'Dispatched matomo-tests.yml on 6.x-dev' \
  DEFAULT_BRANCH=5.x-dev

run_case "an absent branch is skipped and stays green" 0 '' 'Skipping 5.x-dev' \
  BRANCH_STATUS=404

# The case that matters: an API failure must never read as "nothing to do".
run_case "an API failure on the branch check goes red" 1 '' '::error::Could not check whether 5.x-dev exists' \
  BRANCH_STATUS=500

run_case "a transient default-branch lookup failure is retried" 0 '5.x-dev' 'attempt 2 of 3' \
  DEFAULT_FAILS_N=2

# Dispatching against a default branch read as empty would target the wrong ref, so it stops.
run_case "an exhausted default-branch lookup goes red" 1 '' '::error::Could not read the default branch' \
  DEFAULT_FAILS_N=3

run_case "a refused dispatch goes red" 1 '' '::error::Could not dispatch matomo-tests.yml on 5.x-dev' \
  DISPATCH_FAILS=1

# A stale branch list is the way this silently stops working fleet-wide, so it warns rather than
# passing quietly. A warning and not an error: one maintained line is a legitimate state.
MAINTAINED_BRANCHES='6.x-dev' \
  run_case "a run that dispatches nothing warns" 0 '' '::warning::No non-default maintained branch was dispatched'

echo
echo "$tests tests, ${#failures[@]} failures"
[ ${#failures[@]} -eq 0 ] || exit 1
