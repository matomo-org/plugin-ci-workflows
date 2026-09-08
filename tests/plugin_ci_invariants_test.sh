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
export EDITED_CONSUMERS="ai-checklist caller-concurrency"

# Jobs that are not plugin checks and so carry no skip- input. The concurrency guard asserts the
# caller's half of a contract it can always satisfy by deleting a block, so it never needs a way
# out, and a switch to turn it off is the hole it exists to close.
export GUARD_JOBS="caller-concurrency"

# Jobs a caller has to ask for, and the input each one asks through. An opt-in check already has
# an off switch -- not asking -- so a skip- input beside it would be a second way to say the same
# thing, and the opt-out default that skip- exists to protect does not apply to a check that runs
# nowhere by default. The input is named here because the assertions below pin its polarity and its
# default, not merely that the job consults something.
export OPT_IN_JOBS="hook-check:verify-hook"

# The hook check has two placements while the fleet migrates -- a job here, a step in
# plugin-phpstan.yml for callers that still use it directly -- and the README promises the two
# cannot disagree because one script is behind both. That is a property of two workflow files.
export HOOK_SCRIPT="check_hook_sync.sh"

# The invariants parse YAML with PyYAML. It happens to be present on ubuntu-24.04 today, but a
# check that guards a fleet-wide workflow should not depend on what a runner image ships: it
# fails closed without it, and a job that reliably fails is no better than one that silently skips.
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL - PyYAML is not available, so these invariants cannot be checked"
  exit 1
fi

python3 - "$WORKFLOW" <<'PY'
import os, re, sys, yaml

workflow_path = sys.argv[1]
edited_consumers = set(os.environ['EDITED_CONSUMERS'].split())
guard_jobs = set(os.environ['GUARD_JOBS'].split())
opt_in_jobs = dict(pair.split(':') for pair in os.environ['OPT_IN_JOBS'].split())
hook_script = os.environ['HOOK_SCRIPT']

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

# An `edited` run skips every code check, so sharing one concurrency group with a push's run means
# it cancels analysis and puts nothing in its place. The group has to discriminate on the action.
concurrency = doc.get('concurrency') or {}
# Whitespace-insensitive, so the assertions pin the expression's meaning and not one spelling of
# it: `action=='edited'` behaves identically and should not be a failure.
group = str(concurrency.get('group', ''))
group_squashed = ''.join(group.split())
check("the umbrella declares a concurrency group", bool(group))
check(
    "the concurrency group separates edited runs from code runs",
    "github.event.action=='edited'" in group_squashed,
)
# github.workflow resolves to the caller's workflow name here, so a group built from it matches a
# caller's own group and GitHub kills the run for a concurrency deadlock rather than running it.
check(
    "the concurrency group uses a static prefix, not github.workflow",
    'github.workflow' not in group_squashed,
)
# Losing the per-pull-request scope is the worst regression available here: every open pull request
# in the repository would share one lane and cancel each other's checks.
check(
    "the concurrency group is scoped per pull request",
    'github.event.pull_request.number' in group_squashed,
)
# Without this the group queues instead of superseding, so the file still reads as intended while
# doing the opposite -- a stale run finishes last and its verdict is the one that sticks.
check(
    "the concurrency group supersedes rather than queues",
    concurrency.get('cancel-in-progress') is True,
)

# The lanes above are defeated by a caller declaring a group of its own, silently: it spans both
# actions, a called workflow cannot override it, and the name never matches the static prefix, so
# no deadlock error is raised. Deleting the job that catches that would restore the silence.
for name in sorted(guard_jobs):
    steps = (jobs.get(name) or {}).get('steps') or []
    runs_guard = any(
        'check_caller_concurrency.sh' in str(step.get('run', ''))
        for step in steps
        if isinstance(step, dict)
    )
    check(f"{name} runs the caller concurrency guard", runs_guard)

# Every job either ignores `edited` or is a declared consumer of it.
for name, job in jobs.items():
    condition = str(job.get('if', ''))
    ignores_edited = "github.event.action != 'edited'" in condition
    if name in edited_consumers:
        check(
            f"{name} is a declared consumer of the edited action",
            not ignores_edited,
        )
        job_concurrency = job.get('concurrency') or {}
        job_group = ''.join(str(job_concurrency.get('group', '')).split())
        if name in guard_jobs:
            # A guard reads a file the commit fixes, so both lanes' runs reach the same verdict
            # and a lane would trade twenty seconds of runner time for a cancelled job in the
            # run that lost -- a check in a state nothing on the pull request explains.
            check(f"{name} takes no lane of its own", not job_group)
        else:
            # Running in both lanes means racing itself on one commit, and the loser's verdict
            # sticks if it lands last. Its own lane has to span both, so it must NOT discriminate
            # on the action the way the workflow-level group does.
            check(
                f"{name} has its own concurrency lane spanning both workflow lanes",
                bool(job_group) and 'github.event.action' not in job_group,
            )
            check(
                f"{name}'s lane supersedes rather than queues",
                job_concurrency.get('cancel-in-progress') is True,
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

for name in sorted(guard_jobs - set(jobs)):
    check(f"declared guard job {name} still exists in the workflow", False)

# The lanes are also defeated one level down. A workflow the umbrella calls that declared its own
# group would claim it against the umbrella's -- deadlocking where the names match, and spanning
# both actions where they do not. Today none of them declares one, and that is exactly the kind of
# fact this file exists to stop being a comment.
called_locally = sorted({
    str(job.get('uses', '')).split('@')[0].split('/.github/workflows/')[-1]
    for job in jobs.values()
    if 'plugin-ci-workflows/.github/workflows/' in str(job.get('uses', ''))
})
for called in called_locally:
    path = os.path.join(os.path.dirname(workflow_path), called)
    if not os.path.isfile(path):
        check(f"{called} is a workflow in this repository", False)
        continue
    with open(path) as handle:
        check(
            f"{called} declares no concurrency of its own",
            not (yaml.safe_load(handle) or {}).get('concurrency'),
        )

# Every check has to be switchable off, or a plugin that cannot run one has no way out but to
# stop calling the umbrella entirely. A guard is the exception in both directions: it asserts a
# contract the caller can always satisfy, so it needs no way out, and offering one would let a
# caller keep the misconfiguration the guard exists to surface.
workflow_call = triggers.get('workflow_call') or {}
inputs = workflow_call.get('inputs') or {}
for name in jobs:
    if name in guard_jobs:
        check(f"{name} has no skip- input, being a guard and not a check", f"skip-{name}" not in inputs)
    elif name in opt_in_jobs:
        check(f"{name} has no skip- input, being opt in already", f"skip-{name}" not in inputs)
    else:
        check(f"{name} has a skip- input", f"skip-{name}" in inputs)

# An opt-in job that stopped consulting its input would run everywhere, which for verify-hook means
# failing every plugin that has not synced its hook -- most of them.
for name, input_name in sorted(opt_in_jobs.items()):
    if name not in jobs:
        check(f"declared opt-in job {name} still exists in the workflow", False)
        continue

    condition = str((jobs.get(name) or {}).get('if', ''))
    # Not a substring test: `!inputs.verify-hook` references the input and inverts the job, which
    # is the fleet-wide failure this is here to stop.
    check(
        f"{name} runs only when the caller sets {input_name}",
        re.search(r'(?<![!\w.-])inputs\.' + re.escape(input_name) + r'(?![\w-])', condition) is not None,
    )
    # And a default of true would redden every caller without a pull request against any of them.
    check(
        f"{input_name} defaults to not running {name}",
        (inputs.get(input_name) or {}).get('default') is False,
    )

    steps = (jobs.get(name) or {}).get('steps') or []
    check(
        f"{name} runs the shared hook sync script",
        any(hook_script in str(step.get('run', '')) for step in steps if isinstance(step, dict)),
    )

# The other placement of the same check. Two copies of a ten-line comparison is how the hook this
# checks came to drift in the first place.
phpstan_path = os.path.join(os.path.dirname(workflow_path), 'plugin-phpstan.yml')
with open(phpstan_path) as handle:
    phpstan_jobs = (yaml.safe_load(handle) or {}).get('jobs') or {}
phpstan_runs = [
    str(step.get('run', ''))
    for job in phpstan_jobs.values() if isinstance(job, dict)
    for step in (job.get('steps') or []) if isinstance(step, dict)
]
check(
    f"plugin-phpstan.yml runs the same {hook_script}",
    any(hook_script in run for run in phpstan_runs),
)

# Opt-out, not opt-in: a skip- input defaulting to true would leave a check running nowhere.
for name, spec in inputs.items():
    if name.startswith('skip-'):
        check(f"{name} defaults to running the check", spec.get('default') is False)

print()
print(f"{tests} tests, {len(failures)} failures")
sys.exit(1 if failures else 0)
PY
