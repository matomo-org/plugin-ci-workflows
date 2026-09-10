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
python3 - "$WORKFLOW" "$WORK/sweep.sh" "$WORK/env.sh" <<'PY' || { echo "could not extract the step"; exit 1; }
import shlex, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
inputs = (doc['on'] if 'on' in doc else doc[True])['workflow_call']['inputs']
steps = doc['jobs']['sweep']['steps']
step = [s for s in steps if 'run' in s]
assert len(step) == 1, f"expected exactly one run step, found {len(step)}"
step = step[0]

open(sys.argv[2], 'w').write(step['run'])

# The step's own `env:` is read from the workflow rather than restated here. Restating it is how
# an earlier revision of this test passed while the workflow was missing GH_REPO entirely: the
# harness supplied what the workflow did not, so the suite proved the stub and not the workflow.
FAKE_REPO = 'matomo-org/plugin-Foo'
def resolve(value):
    v = str(value).strip()
    if not v.startswith('${{'):
        return v
    expr = v[3:-2].strip() if v.endswith('}}') else None
    if expr == 'github.token':
        return 'test-token'
    if expr == 'github.repository':
        return FAKE_REPO
    if expr and expr.startswith('inputs.'):
        name = expr[len('inputs.'):]
        assert name in inputs, f"env references undeclared input {name}"
        return str(inputs[name]['default'])
    # Failing here is deliberate: a new expression must be taught to the harness, not silently
    # resolved to an empty string that makes a case pass for the wrong reason.
    raise AssertionError(f"harness cannot resolve {v!r}")

with open(sys.argv[3], 'w') as fh:
    for key, value in (step.get('env') or {}).items():
        fh.write("export %s=%s\n" % (key, shlex.quote(resolve(value))))
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
# Only `gh workflow run` resolves a base repository, from GH_REPO or a git remote, never from
# GITHUB_REPOSITORY. The `gh api` calls pass fully-qualified paths and need none of it. Failing
# every subcommand here instead would send the missing-GH_REPO case down the retry-exhaustion
# path, so it would go red without ever reaching the dispatch it is meant to be about.
if [ "$1" = "workflow" ] && [ -z "${GH_REPO:-}" ]; then
  echo "failed to run git: fatal: not a git repository (or any of the parent directories): .git" >&2
  exit 1
fi
if [ "$1" = "api" ]; then
  case "$2" in
    repos/*/branches/*)
      if [ "${2##*/}" = "${FAIL_BRANCH:-}" ]; then
        echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1
      fi
      n=$(cat "$STUB_STATE/branch-attempts" 2>/dev/null || echo 0)
      n=$((n + 1)); echo "$n" > "$STUB_STATE/branch-attempts"
      if [ "$n" -le "${BRANCH_FAILS_N:-0}" ]; then
        echo "gh: Server Error (HTTP 502)" >&2; exit 1
      fi
      case "${BRANCH_STATUS:-200}" in
        404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
        500) echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1 ;;
        *) echo "${2##*/}"; exit 0 ;;
      esac ;;
    repos/*)
      n=$(cat "$STUB_STATE/attempts" 2>/dev/null || echo 0)
      n=$((n + 1)); echo "$n" > "$STUB_STATE/attempts"
      if [ "$n" -le "${DEFAULT_FAILS_N:-0}" ]; then
        printf '{"message":"Server Error","status":"502"}'
        echo "gh: Server Error (HTTP 502)" >&2
        exit 1
      fi
      echo "${DEFAULT_BRANCH:-6.x-dev}"; exit 0 ;;
  esac
fi
if [ "$1" = "workflow" ]; then
  if [ -n "${DISPATCH_FAILS:-}" ]; then echo "gh: dispatch refused" >&2; exit 1; fi
  if [ -n "${DISPATCH_422:-}" ]; then
    echo "gh: HTTP 422: Workflow does not have workflow_dispatch trigger" >&2; exit 1
  fi
  n=$(cat "$STUB_STATE/dispatch-attempts" 2>/dev/null || echo 0)
  n=$((n + 1)); echo "$n" > "$STUB_STATE/dispatch-attempts"
  if [ "$n" -le "${DISPATCH_FAILS_N:-0}" ]; then
    echo "gh: Server Error (HTTP 502)" >&2; exit 1
  fi
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
  # GITHUB_REPOSITORY is supplied by Actions itself rather than by the step, so it is the one
  # variable the harness is entitled to invent. Everything else comes from the workflow's env.
  # Single quotes are the point: these expand in the inner shell, after env.sh is sourced.
  # shellcheck disable=SC2016
  output="$(env PATH="$WORK/bin:$PATH" STUB_STATE="$state" \
    GITHUB_REPOSITORY='matomo-org/plugin-Foo' "$@" \
    bash --noprofile --norc -eo pipefail -c \
    'set -a; . "$1"; eval "${OVERRIDE_ENV:-:}"; set +a; exec bash --noprofile --norc -eo pipefail "$2"' \
    _ "$WORK/env.sh" "$WORK/sweep.sh" 2>&1)"
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
  if [ -n "${WANT_ABSENT:-}" ] && [[ "$output" == *"${WANT_ABSENT}"* ]]; then
    echo "FAIL - $description (output unexpectedly contained '${WANT_ABSENT}')"
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

WANT_ABSENT='Attempt 1 of 3 failed' \
  run_case "an absent branch is skipped without retrying" 0 '' '::notice::Skipping 5.x-dev' \
  BRANCH_STATUS=404

# The case that matters: an API failure must never read as "nothing to do".
run_case "an API failure on the branch check goes red" 1 '' '::error::Could not check whether 5.x-dev exists' \
  BRANCH_STATUS=500

run_case "a transient default-branch lookup failure is retried" 0 '5.x-dev' 'Attempt 2 of 3 failed' \
  DEFAULT_FAILS_N=2

# Medium 1 of the third review round: the retry was on the lookup only, so a transient failure on
# either call that carries the weekly cost dropped that branch for the week.
run_case "a transient branch-probe failure is retried" 0 '5.x-dev' 'branches/5.x-dev' \
  BRANCH_FAILS_N=2
run_case "a transient dispatch failure is retried" 0 '5.x-dev' 'Dispatched matomo-tests.yml on 5.x-dev' \
  DISPATCH_FAILS_N=2

# Dispatching against a default branch read as empty would target the wrong ref, so it stops.
run_case "an exhausted default-branch lookup goes red" 1 '' '::error::Could not read the default branch' \
  DEFAULT_FAILS_N=3

run_case "a refused dispatch goes red" 1 '' '::error::Could not dispatch matomo-tests.yml on 5.x-dev' \
  DISPATCH_FAILS=1

# A stale branch list is the way this silently stops working fleet-wide, so it warns rather than
# passing quietly. A warning and not an error: one maintained line is a legitimate state.
OVERRIDE_ENV="MAINTAINED_BRANCHES='6.x-dev'" \
  run_case "a list naming only the default warns" 0 '' '::warning::No non-default maintained branch was dispatched'

WANT_ABSENT='::warning::No non-default maintained branch was dispatched' \
  run_case "one maintained line does not warn every week" 0 '' '::notice::Skipping 6.x-dev' \
  DEFAULT_BRANCH=5.x-dev BRANCH_STATUS=404

# The sweep runs without a checkout, so gh has no git remote to infer a repository from. This is
# the case that would have caught the dispatch failing in every repository at once.
OVERRIDE_ENV='unset GH_REPO' \
  run_case "a missing GH_REPO fails the dispatch loudly" 1 '' '::error::Could not dispatch'

# `gh api --jq` prints the string "null" for a field the response does not carry, which an
# emptiness check does not catch. Dispatching against a default read as "null" would build every
# maintained branch including the real default, which is the double build the sweep must not cause.
run_case "a null default branch is refused" 1 '' '::error::Could not read the default branch' \
  DEFAULT_BRANCH=null

# The input is a string and a caller writing it as a YAML block scalar is natural, so the list has
# to split on newlines too. `read -ra` took only the first line of a here-string, silently dropping
# every branch after it -- a branch quietly not built, through this workflow's own input.
OVERRIDE_ENV=$'MAINTAINED_BRANCHES=\'5.x-dev\n4.x-dev\'' \
  run_case "a newline-separated branch list is split" 0 '5.x-dev 4.x-dev' 'on 4.x-dev'

# gh writes a failed response body to stdout with no trailing newline, so emitting every attempt's
# output would splice the error into the real answer on one line. A default branch read as that
# garbage matches no branch, and the real default gets dispatched along with the rest.
run_case "a failed attempt does not contaminate the default branch" 0 '5.x-dev' \
  'Default branch is 6.x-dev' DEFAULT_FAILS_N=1

# A ref carrying no workflow_dispatch trigger will never come good, so it must not burn three
# backoffs and two misleading retry lines before reporting the real error.
WANT_ABSENT='Attempt 1 of 3 failed' \
  run_case "a 422 dispatch is not retried" 1 '' '::error::Could not dispatch' DISPATCH_422=1

# The invariant the workflow calls its reason for existing. Every other case has at most one
# non-default branch, so a `continue` silently becoming a `break` would leave them all green.
OVERRIDE_ENV="MAINTAINED_BRANCHES='5.x-dev 4.x-dev'" \
  run_case "a failure on one branch does not starve the next" 1 '4.x-dev' \
  '::error::Could not check whether 5.x-dev exists' FAIL_BRANCH=5.x-dev

# The harness above extracts only the step's shell, so the workflow-level guarantees the design
# rests on are invisible to it: deleting the concurrency block or the actions: write grant leaves
# every case above green. This repository's convention is that a load-bearing workflow property is
# a test rather than a comment.
yaml_output="$(python3 - "$WORKFLOW" <<'YAMLPY'
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
failed = []


def check(description, condition):
    print(("ok - " if condition else "FAIL - ") + description)
    if not condition:
        failed.append(description)


triggers = doc['on'] if 'on' in doc else doc[True]
check("the sweep is a reusable workflow", 'workflow_call' in triggers)

perms = doc.get('permissions') or {}
# Without this the dispatch is unauthorised and the whole workflow is decorative.
check("actions: write is granted", perms.get('actions') == 'write')
# The branch probe calls GET /repos/{owner}/{repo}/branches/{branch}, which needs Contents read.
check("contents: read is granted", perms.get('contents') == 'read')

conc = doc.get('concurrency') or {}
group = str(conc.get('group', ''))
check("a concurrency group is declared", bool(group))
# github.workflow resolves to the CALLER's workflow name here, which deadlocks against a caller
# group of the same name and GitHub cancels the run rather than running it.
check("the concurrency group carries no expression", '${{' not in group)
# Superseding a queued sweep drops it, and a dropped sweep is a week of builds for that branch.
check("the concurrency group queues rather than cancels", conc.get('cancel-in-progress') is False)

step = [s for s in doc['jobs']['sweep']['steps'] if 'run' in s][0]
# The harness runs the block under `bash -eo pipefail`. Without this the step gets plain `bash -e`,
# and the harness would be proving different semantics from the ones production uses.
check("the step declares shell: bash", step.get('shell') == 'bash')

sys.exit(1 if failed else 0)
YAMLPY
)"
yaml_status=$?
echo "$yaml_output"
tests=$((tests + $(printf '%s\n' "$yaml_output" | grep -c '^\(ok\|FAIL\) - ')))
if [ "$yaml_status" != 0 ]; then
  while IFS= read -r line; do failures+=("${line#FAIL - }"); done \
    < <(printf '%s\n' "$yaml_output" | grep '^FAIL - ')
fi

echo
echo "$tests tests, ${#failures[@]} failures"
[ ${#failures[@]} -eq 0 ] || exit 1
