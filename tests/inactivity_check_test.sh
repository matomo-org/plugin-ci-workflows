#!/bin/bash
# Tests for the `activity` job in .github/workflows/plugin-branch-sweep.yml, which fails before
# GitHub disables a public repository's schedules for 60 days without activity.
# Usage: bash tests/inactivity_check_test.sh
#
# The job exists to make a silent stop loud, so an API failure has to go red too: reading it as
# "recent enough" would leave the run green on exactly the week it mattered.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/plugin-branch-sweep.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=()

python3 - "$WORKFLOW" "$WORK/check.sh" "$WORK/env.sh" <<'PY' || { echo "could not extract the step"; exit 1; }
import shlex, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
step = [s for s in doc['jobs']['activity']['steps'] if 'run' in s]
assert len(step) == 1, f"expected exactly one run step, found {len(step)}"
step = step[0]
open(sys.argv[2], 'w').write(step['run'])

def resolve(value):
    v = str(value).strip()
    if v == '${{ github.token }}':
        return 'test-token'
    if v.startswith('${{'):
        raise AssertionError(f"harness cannot resolve {v!r}")
    return v

with open(sys.argv[3], 'w') as fh:
    for key, value in (step.get('env') or {}).items():
        fh.write("export %s=%s\n" % (key, shlex.quote(resolve(value))))
PY

mkdir -p "$WORK/bin"

cat > "$WORK/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

# Stub gh. REPO_FAILS_N failures before the repository read succeeds, COMMIT_FAIL to fail the
# commit read, LAST_COMMIT for the committer date it returns, GH_WARNING for a line written to
# stderr alongside a successful answer.
cat > "$WORK/bin/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_WARNING:-}" ] && echo "$GH_WARNING" >&2
case "$2" in
  repos/*/commits/*)
    if [ -n "${COMMIT_FAIL:-}" ]; then
      echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1
    fi
    echo "$LAST_COMMIT"
    ;;
  repos/*)
    n=$(cat "$STUB_STATE/repo-attempts" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$STUB_STATE/repo-attempts"
    if [ "$n" -le "${REPO_FAILS_N:-0}" ]; then
      printf '{"message":"Server Error"}'
      echo "gh: Server Error (HTTP 502)" >&2; exit 1
    fi
    echo "${PRIVATE:-false} ${DEFAULT:-6.x-dev}"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/gh" "$WORK/bin/sleep"

days_ago() {
  date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%SZ
}

run_case() {
  local description="$1" expected="$2" want_output="$3"; shift 3
  local state="$WORK/state-$tests" output status
  tests=$((tests + 1))
  mkdir -p "$state"

  # GITHUB_REPOSITORY and GITHUB_REF_NAME are supplied by Actions rather than by the step, so
  # they are the only variables the harness invents. The single quotes expand in the inner shell.
  # shellcheck disable=SC2016
  output="$(env PATH="$WORK/bin:$PATH" STUB_STATE="$state" TZ=UTC \
    GITHUB_REPOSITORY='matomo-org/plugin-Foo' GITHUB_REF_NAME='6.x-dev' "$@" \
    bash --noprofile --norc -c 'set -a; . "$1"; set +a; exec bash --noprofile --norc -eo pipefail "$2"' \
    _ "$WORK/env.sh" "$WORK/check.sh" 2>&1)"
  status=$?

  if [ "$status" != "$expected" ]; then
    echo "FAIL - $description (expected exit $expected, got $status)"
    echo "$output"; failures+=("$description"); return
  fi
  if [[ "$output" != *"$want_output"* ]]; then
    echo "FAIL - $description (output did not contain '$want_output')"
    echo "$output"; failures+=("$description"); return
  fi
  echo "ok - $description"
}

run_case "a recent commit passes" 0 "was 10 days ago" \
  LAST_COMMIT="$(days_ago 10)"
run_case "one day under the threshold passes" 0 "was 44 days ago" \
  LAST_COMMIT="$(days_ago 44)"
run_case "the threshold fails" 1 "::error::The last commit on 6.x-dev was 45 days ago" \
  LAST_COMMIT="$(days_ago 45)"
run_case "a private repository is not checked" 0 "Private repository" \
  PRIVATE=true LAST_COMMIT="$(days_ago 90)"
run_case "a run on a non-default branch leaves it to the default" 0 "the run on 6.x-dev checks" \
  GITHUB_REF_NAME='5.x-dev' LAST_COMMIT="$(days_ago 90)"
run_case "a transient repository failure is retried" 0 "was 10 days ago" \
  REPO_FAILS_N=2 LAST_COMMIT="$(days_ago 10)"
run_case "an exhausted repository read fails" 1 "::error::Could not read the repository" \
  REPO_FAILS_N=3 LAST_COMMIT="$(days_ago 10)"
run_case "a failed commit read fails rather than passing" 1 "::error::Could not read the last commit" \
  COMMIT_FAIL=1 LAST_COMMIT="$(days_ago 10)"
run_case "an unreadable commit date fails" 1 "::error::Could not read the date" \
  LAST_COMMIT='null'
run_case "a gh warning on stderr is not read as the answer" 0 "was 10 days ago" \
  GH_WARNING='warning: GH_TOKEN takes precedence' LAST_COMMIT="$(days_ago 10)"
run_case "an unreadable default branch fails" 1 "::error::Could not read the default branch" \
  DEFAULT='null' LAST_COMMIT="$(days_ago 10)"

# The job's independence from the sweep is the point of it being a job: `needs: sweep` would skip
# the check on the week a dispatch failed.
yaml_output="$(python3 - "$WORKFLOW" <<'YAMLPY'
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
job = doc['jobs'].get('activity') or {}
step = [s for s in job.get('steps', []) if 'run' in s][0]
checks = [
    ("the check does not wait on the sweep", 'needs' not in job),
    ("the check is not conditional", 'if' not in job),
    # It only reads, so it should not inherit the sweep's actions: write.
    ("the check is granted contents: read alone", job.get('permissions') == {'contents': 'read'}),
    ("the step declares shell: bash", step.get('shell') == 'bash'),
]
for description, ok in checks:
    print(("ok - " if ok else "FAIL - ") + description)
sys.exit(0 if all(ok for _, ok in checks) else 1)
YAMLPY
)"
echo "$yaml_output"
tests=$((tests + $(printf '%s\n' "$yaml_output" | grep -c '^\(ok\|FAIL\) - ')))
while IFS= read -r line; do failures+=("${line#FAIL - }"); done \
  < <(printf '%s\n' "$yaml_output" | grep '^FAIL - ')
if ! printf '%s\n' "$yaml_output" | grep -q '^\(ok\|FAIL\) - '; then
  tests=$((tests + 1))
  echo "FAIL - the workflow invariants block ran to completion"
  failures+=("the workflow invariants block ran to completion")
fi

echo
echo "$tests tests, ${#failures[@]} failures"
[ ${#failures[@]} -eq 0 ] || exit 1
