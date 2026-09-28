#!/bin/bash
# Invariants for the shared timezone safety workflow and its Plugins CI wiring.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/plugin-timezone-safety.yml"
UMBRELLA="$ROOT/.github/workflows/plugin-ci.yml"

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL - PyYAML is not available, so timezone workflow invariants cannot be checked"
  exit 1
fi

python3 - "$WORKFLOW" "$UMBRELLA" <<'PY'
import sys
from pathlib import Path
import yaml

workflow_path, umbrella_path = sys.argv[1:]
tests = 0
failures = []


def check(description, condition):
    global tests
    tests += 1
    if condition:
        print(f"ok - {description}")
    else:
        print(f"FAIL - {description}")
        failures.append(description)


with open(workflow_path) as handle:
    workflow = yaml.safe_load(handle) or {}
with open(umbrella_path) as handle:
    umbrella = yaml.safe_load(handle) or {}
helper_path = Path(workflow_path).parents[2] / 'scripts/bash/run_timezone_safety_workflow.sh'
with helper_path.open() as handle:
    runtime_helper = handle.read()

triggers = workflow.get('on', workflow.get(True)) or {}
inputs = (triggers.get('workflow_call') or {}).get('inputs') or {}
jobs = workflow.get('jobs') or {}

check('timezone safety is a reusable workflow', 'workflow_call' in triggers)
for name in ('plugin-name', 'workflows-ref', 'timezone-test-command', 'skip-static-scan'):
    check(f'timezone workflow declares {name}', name in inputs)
check('timezone test command defaults to static-only mode', inputs.get('timezone-test-command', {}).get('default') == '')
check('static scan runs by default', inputs.get('skip-static-scan', {}).get('default') is False)
check('static timezone job exists', 'timezone-safety' in jobs)
check('static timezone check name separates event baselines', '${{ github.event_name }}' in str((jobs.get('timezone-safety') or {}).get('name', '')))
check('static scan can be skipped for regression-only calls', 'inputs.skip-static-scan' in str((jobs.get('timezone-safety') or {}).get('if', '')))
check('static timezone job receives the base branch', 'BASE_BRANCH' in str(jobs.get('timezone-safety')))
check('non-PR runs can use the previous commit as a base', 'EVENT_BEFORE' in str(jobs.get('timezone-safety')))
static_runs = '\n'.join(
    str(step.get('run', ''))
    for step in (jobs.get('timezone-safety') or {}).get('steps', [])
    if isinstance(step, dict)
)
check('static timezone job uses the shared runtime helper', 'run_timezone_safety_workflow.sh' in static_runs)
runtime_text = static_runs + runtime_helper
check('static scan uses the shared checker', 'check_timezone_safety.sh' in static_runs)
check('old workflow pins fail closed with a useful message', 'workflows-ref' in static_runs and 'exit 2' in static_runs and 'skip-timezone-safety' in static_runs)
check('repositories without PHP or SQL are skipped cleanly', 'No PHP or SQL source files are tracked' in runtime_text)
check('pull requests fail only on new findings', '--fail-on-new-findings' in runtime_text)
check('runs without a base treat findings as advisory', 'treating timezone findings as advisory' in runtime_text)
check('regression job is optional', 'inputs.timezone-test-command' in str((jobs.get('timezone-regression') or {}).get('if', '')))
regression_env = (jobs.get('timezone-regression') or {}).get('env') or {}
for name in ('TZ', 'MYSQL_TIMEZONE'):
    check(f'regression job sets {name}', regression_env.get(name) == 'Pacific/Auckland')
regression_runs = '\n'.join(
    str(step.get('run', ''))
    for step in (jobs.get('timezone-regression') or {}).get('steps', [])
    if isinstance(step, dict)
)
check('regression job runs the caller command', 'TIMEZONE_TEST_COMMAND' in regression_runs)

umbrella_triggers = umbrella.get('on', umbrella.get(True)) or {}
umbrella_inputs = (umbrella_triggers.get('workflow_call') or {}).get('inputs') or {}
umbrella_jobs = umbrella.get('jobs') or {}
timezone_job = umbrella_jobs.get('timezone-safety') or {}
check('Plugins CI has a timezone skip input', 'skip-timezone-safety' in umbrella_inputs)
check('timezone skip defaults to false', umbrella_inputs.get('skip-timezone-safety', {}).get('default') is False)
check('Plugins CI calls the timezone workflow', 'plugin-timezone-safety.yml' in str(timezone_job.get('uses', '')))
check('Plugins CI forwards workflows-ref', 'inputs.workflows-ref' in str(timezone_job.get('with', {})))

print(f"{tests} test(s), {len(failures)} failure(s)")
sys.exit(bool(failures))
PY
