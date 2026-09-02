#!/bin/bash
# Invariants for .github/workflows/plugin-ci.yml, the umbrella every plugin calls.
# Usage: bash tests/plugin_ci_invariants_test.sh
#
# The umbrella subscribes to the `edited` pull request action so the checklist gate re-runs when a
# description is fixed. Every other check should ignore that action rather than re-analyse an
# unchanged tree -- and should do so by default, so a check added later is safe when its author
# writes nothing. That is a property of the file, not of anyone remembering, which is what this
# enforces.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/plugin-ci.yml"

# Jobs allowed to run on a description edit. Adding a name here is the opt-in, and it should be
# a deliberate, reviewed act -- which is the point of it living in a test rather than a comment.
EDITED_CONSUMERS=("ai-checklist")

# The invariants parse YAML with PyYAML. It happens to be present on ubuntu-24.04 today, but a
# check that guards a fleet-wide workflow should not depend on what a runner image ships: it
# fails closed without it, and a job that reliably fails is no better than one that silently skips.
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL - PyYAML is not available, so these invariants cannot be checked"
  exit 1
fi

python3 - "$WORKFLOW" "${EDITED_CONSUMERS[@]}" <<'PY'
import sys, yaml

workflow_path = sys.argv[1]
edited_consumers = set(sys.argv[2:])

with open(workflow_path) as handle:
    doc = yaml.safe_load(handle)

# PyYAML resolves the bare `on:` key to the boolean True.
triggers = doc.get('on', doc.get(True)) or {}
jobs = doc.get('jobs') or {}

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


check("the umbrella is a reusable workflow", 'workflow_call' in triggers)
check("it declares at least one job", bool(jobs))

# Every job either ignores `edited` or is a declared consumer of it.
for name, job in jobs.items():
    condition = str(job.get('if', ''))
    ignores_edited = "github.event.action != 'edited'" in condition
    if name in edited_consumers:
        check(
            f"{name} is a declared consumer of the edited action",
            not ignores_edited,
        )
    else:
        check(
            f"{name} ignores the edited action",
            ignores_edited,
        )

# A consumer named in the allowlist but absent from the workflow means the list has gone stale,
# and a stale allowlist quietly widens what is permitted.
for name in sorted(edited_consumers - set(jobs)):
    check(f"declared edited consumer {name} still exists in the workflow", False)

# Every check has to be switchable off, or a plugin that cannot run one has no way out but to
# stop calling the umbrella entirely.
workflow_call = triggers.get('workflow_call') or {}
inputs = workflow_call.get('inputs') or {}
for name in jobs:
    check(f"{name} has a skip- input", f"skip-{name}" in inputs)

# Opt-out, not opt-in: a skip- input defaulting to true would leave a check running nowhere.
for name, spec in inputs.items():
    if name.startswith('skip-'):
        check(f"{name} defaults to running the check", spec.get('default') is False)

print()
print(f"{tests} tests, {len(failures)} failures")
sys.exit(1 if failures else 0)
PY
