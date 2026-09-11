#!/bin/bash
# Invariants for .github/workflows/plugin-ci.yml, the umbrella every plugin calls.
# Usage: bash tests/plugin_ci_invariants_test.sh
#
# The property these protect: every run of this workflow on a commit checks the same things, so no
# run can supersede another while having checked less.
#
# It is worth stating why, because the obvious shortcut breaks it. The umbrella subscribes to the
# `edited` pull request action so the checklist gate re-runs when a description is fixed, and it is
# tempting to skip the code checks on that action since an edit changes no file. But a run whose
# checks are all skipped concludes `success`, and GitHub resolves a commit's verdict from the
# newest check suite per workflow, ordered by suite CREATION time -- so the edited run's green
# suite replaces the code run's verdict, even while the code run is still going, and even when it
# later fails. Measured on a probe; nine of the fleet's migration pull requests had a red license
# check hidden that way.
#
# Hence: no job may condition itself on github.event.action. Conditioning on an INPUT is fine, and
# is not the same thing -- an input is fixed for the commit, so every run makes the same decision.
# The second rule, that a job carrying any `if:` must be a called workflow, covers the remaining
# legitimate skips: a called workflow's skip reports as `<caller job>` while a real run reports as
# `<caller job>/<job name>`, so the two can never collide by name.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/plugin-ci.yml"

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

# The hook check's one home. Gutting the job's step would leave `verify-hook: true` silently
# checking nothing, which is worse than the misplacement this replaced.
export HOOK_SCRIPT="check_hook_sync.sh"

# Jobs that cannot run outside a pull request. Callers subscribe to push and workflow_dispatch so
# that one badge on their workflow reports the default branch, and the checklist gate reads a
# description that only a pull request has -- so losing this condition fails every push run, on
# the very badge the triggers exist to make trustworthy.
export PULL_REQUEST_ONLY_JOBS="ai-checklist"

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
guard_jobs = set(os.environ['GUARD_JOBS'].split())
opt_in_jobs = dict(pair.split(':') for pair in os.environ['OPT_IN_JOBS'].split())
hook_script = os.environ['HOOK_SCRIPT']
pull_request_only = set(os.environ['PULL_REQUEST_ONLY_JOBS'].split())

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


def conditions_on_event_action(job):
    """Rule one: does this job run in some runs of a commit and not others?"""
    return 'github.event.action' in ''.join(str((job or {}).get('if', '')).split())


def can_be_skipped(job):
    """Rule two's trigger. `needs:` counts -- a job whose dependency is skipped is skipped too."""
    job = job or {}
    return bool(job.get('if')) or bool(job.get('needs'))


def called_workflow_file(job):
    """The workflow in this repository that a job calls, or '' when it calls none."""
    uses = str((job or {}).get('uses', ''))
    if 'plugin-ci-workflows/.github/workflows/' not in uses:
        return ''
    return uses.split('@')[0].split('/.github/workflows/')[-1]


check("the umbrella is a reusable workflow", 'workflow_call' in triggers)
check("it declares at least one job", bool(jobs))

# One lane. Splitting it by event action was the previous answer to an edited run cancelling the
# analysis, and it traded that for the worse failure described at the top of this file. With every
# run doing the whole check set, a run that supersedes another is telling the truth.
concurrency = doc.get('concurrency') or {}
# Whitespace-insensitive, so the assertions pin the expression's meaning and not one spelling of it.
group = str(concurrency.get('group', ''))
group_squashed = ''.join(group.split())
check("the umbrella declares a concurrency group", bool(group))
check(
    "the concurrency group does not split runs by event action",
    'github.event.action' not in group_squashed,
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

# The lane above is defeated by a caller declaring a group of its own, silently: a called workflow
# cannot override it, and the name never matches the static prefix, so no deadlock error is raised.
# Deleting the job that catches that would restore the silence.
for name in sorted(guard_jobs):
    steps = (jobs.get(name) or {}).get('steps') or []
    runs_guard = any(
        'check_caller_concurrency.sh' in str(step.get('run', ''))
        for step in steps
        if isinstance(step, dict)
    )
    check(f"{name} runs the caller concurrency guard", runs_guard)

# The two rules that keep every run of a commit equivalent. See the top of this file for why.
for name, job in jobs.items():
    condition = str(job.get('if', ''))

    # Rule one. A job conditioned on the event action runs in some runs of a commit and not
    # others, and the run that skipped it still concludes and still supersedes.
    check(
        f"{name} does not condition itself on the event action",
        not conditions_on_event_action(job),
    )

    # Rule two. A job that can be skipped at all -- on an input, or on the event name -- has to be
    # a called workflow. A skipped job still publishes a check run, and one defined in this file
    # publishes it under the same name whether it ran or was skipped, so the skip lands on top of
    # whatever an earlier run concluded and a skipped required check counts as a passing one. A
    # called workflow cannot: its skip reports as `<caller job>` and a real run as
    # `<caller job>/<job name>`. Seen on plugin-LogViewer b0506a2b, where `ci / Hook check` went
    # success and then skipped on one commit while `ci / phpcs / PHPCS` came through untouched.
    #
    # `needs:` counts too: a job whose dependency is skipped is skipped with it, and inline it
    # publishes that skip under the name it uses when it runs. No job here declares one today, so
    # this is a guard on the shape rather than on the current file.
    #
    # Exempt only on being unskippable, which is what actually makes an inline job safe.
    if can_be_skipped(job):
        check(
            f"{name} is a called workflow, so skipping it cannot overwrite a real verdict",
            bool(job.get('uses')),
        )

    # A job-level group can supersede on a different key from the workflow-level one, which is how
    # two runs of a commit end up disagreeing again by a side door. One lane governs all of them.
    check(
        f"{name} declares no concurrency group of its own",
        not (job.get('concurrency') or {}),
    )

for name in sorted(guard_jobs - set(jobs)):
    check(f"declared guard job {name} still exists in the workflow", False)

# The lanes are also defeated one level down. A workflow the umbrella calls that declared its own
# group would claim it against the umbrella's -- deadlocking where the names match, and spanning
# both actions where they do not. Today none of them declares one, and that is exactly the kind of
# fact this file exists to stop being a comment.
called_locally = sorted({f for f in (called_workflow_file(job) for job in jobs.values()) if f})
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


# Keyed on the job by name rather than looped over every opt-in job, since a second opt-in job
# would have nothing to do with this script. The steps live in the called workflow now, so follow
# the `uses:` to them: asserting against the umbrella job would pass vacuously, and an empty list
# fails this closed if the call goes missing.
hook_called = called_workflow_file(jobs.get('hook-check'))
hook_path = os.path.join(os.path.dirname(workflow_path), hook_called) if hook_called else ''
hook_steps = []
if hook_path and os.path.isfile(hook_path):
    with open(hook_path) as handle:
        hook_doc = yaml.safe_load(handle) or {}
    for hook_job in (hook_doc.get('jobs') or {}).values():
        hook_steps.extend(
            step for step in ((hook_job or {}).get('steps') or []) if isinstance(step, dict)
        )
check(
    f"hook-check runs {hook_script}",
    any(hook_script in str(step.get('run', '')) for step in hook_steps),
)

# And the umbrella's `with:` block is the only thing carrying a caller's workflows-ref pin into
# that workflow, which defaults it to main. Lose the line and the check silently compares a
# plugin's vendored hook against main's canonical copy rather than the pinned one -- so a plugin
# that pinned the ref precisely to hold an older hook steady goes red against a copy it
# deliberately did not take. The seam is new: the ref used to be inline in this file.
hook_with = ''.join(str(((jobs.get('hook-check') or {}).get('with') or {}).get('workflows-ref', '')).split())
check(
    "hook-check forwards workflows-ref to the called workflow",
    re.search(r'(?<![!\w.-])inputs\.workflows-ref(?![\w-])', hook_with) is not None,
)

for name in sorted(pull_request_only):
    if name not in jobs:
        check(f"declared pull-request-only job {name} still exists in the workflow", False)
        continue
    condition = ''.join(str((jobs.get(name) or {}).get('if', '')).split())
    check(
        f"{name} runs only on a pull request",
        "github.event_name=='pull_request'" in condition,
    )

# Opt-out, not opt-in: a skip- input defaulting to true would leave a check running nowhere.
for name, spec in inputs.items():
    if name.startswith('skip-'):
        check(f"{name} defaults to running the check", spec.get('default') is False)

# The rules above only ever meet a document that complies, so an inverted or dead version of
# either would pass in silence. These drive them in both directions, the way the sibling guard
# tests drive theirs.
for label, job, expected in [
    ("an edited-action condition", {'if': "${{ !inputs.skip-phpcs && github.event.action != 'edited' }}"}, True),
    ("an action condition with other spacing", {'if': "${{ github.event.action=='edited' }}"}, True),
    ("an input-only condition", {'if': '${{ !inputs.skip-phpcs }}'}, False),
    ("an event-name condition", {'if': "${{ github.event_name == 'pull_request' }}"}, False),
    ("no condition at all", {}, False),
]:
    check(
        f"rule one flags {label}" if expected else f"rule one passes {label}",
        conditions_on_event_action(job) is expected,
    )

for label, job, expected in [
    ("a job carrying an if:", {'if': '${{ inputs.verify-hook }}'}, True),
    ("a job carrying only needs:", {'needs': ['phpcs']}, True),
    ("a job carrying both", {'if': '${{ inputs.verify-hook }}', 'needs': ['phpcs']}, True),
    ("an unconditional job", {'runs-on': 'ubuntu-24.04'}, False),
]:
    check(
        f"rule two catches {label}" if expected else f"rule two exempts {label}",
        can_be_skipped(job) is expected,
    )

print()
print(f"{tests} tests, {len(failures)} failures")
sys.exit(1 if failures else 0)
PY
