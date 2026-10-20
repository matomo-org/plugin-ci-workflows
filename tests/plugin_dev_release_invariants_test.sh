#!/bin/bash
# Invariants for .github/workflows/plugin-dev-release.yml, the reusable weekly release workflow, and
# plugin-release-date-check.yml, the check Plugins CI runs for it.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL - PyYAML is not available, so these invariants cannot be checked"
  exit 1
fi

python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])


def load(name):
    with (root / ".github/workflows" / name).open() as handle:
        return yaml.safe_load(handle)


release_doc = load("plugin-dev-release.yml")
check_doc = load("plugin-release-date-check.yml")
release = (release_doc.get("jobs") or {}).get("release") or {}
steps = [step for step in release.get("steps") or [] if isinstance(step, dict)]
steps_by_name = {step.get("name"): step for step in steps if step.get("name")}
check_steps = [
    step for job in (check_doc.get("jobs") or {}).values()
    for step in (job.get("steps") or []) if isinstance(step, dict)
]


def step_run(name):
    return str(steps_by_name.get(name, {}).get("run", ""))


def script(path):
    return (root / path).read_text()


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


triggers = release_doc.get("on", release_doc.get(True)) or {}
check("the release workflow is reusable", "workflow_call" in triggers)
check("the release workflow grants nothing by default", release_doc.get("permissions") == {})
check("it has one job, the release", list(release_doc.get("jobs") or {}) == ["release"])
check("the release job has a timeout", isinstance(release.get("timeout-minutes"), int))
check(
    "the release job grants only what releasing and merging need",
    release.get("permissions")
    == {"actions": "write", "contents": "write", "pull-requests": "write"},
)
concurrency = release_doc.get("concurrency") or {}
check(
    "releases on one branch queue rather than cancel",
    concurrency.get("cancel-in-progress") is False and "github.ref_name" in str(concurrency.get("group")),
)
check(
    "the concurrency group does not use the caller's workflow name",
    "github.workflow" not in str(concurrency.get("group")),
)
check(
    "the release job checks caller concurrency for this workflow",
    "check_caller_concurrency.sh" in step_run("Check caller concurrency")
    and "plugin-ci-workflows/.github/workflows/plugin-dev-release.yml" in step_run("Check caller concurrency"),
)
checkouts = [step for step in steps if str(step.get("uses", "")).startswith("actions/checkout@")]
check_checkouts = [step for step in check_steps if str(step.get("uses", "")).startswith("actions/checkout@")]
check(
    "every checkout disables persisted credentials",
    len(checkouts) == 2 and len(check_checkouts) == 2
    and all((step.get("with") or {}).get("persist-credentials") is False for step in checkouts + check_checkouts),
)
check(
    "the scripts come from this repository at workflows-ref",
    all(
        (step.get("with") or {}).get("ref") == "${{ inputs.workflows-ref }}"
        for step in checkouts + check_checkouts if (step.get("with") or {}).get("repository")
    ),
)
check(
    "all inline shell steps select bash",
    all(step.get("shell") == "bash" for step in steps + check_steps if "run" in step),
)
check(
    "the shared checkout is removed before the release is recorded",
    'rm -rf "$WORKFLOWS_DIR"' in step_run("Stage release scripts")
    and list(steps_by_name).index("Stage release scripts") < list(steps_by_name).index("Date the release"),
)
check(
    "preparation decides whether anything is released",
    steps_by_name.get("Prepare release", {}).get("id") == "prepare"
    and "prepare_plugin_dev_release.sh" in step_run("Prepare release"),
)
ordered = ["Date the release", "Create release tag", "Create GitHub release", "Merge the release date"]
check(
    "the release is dated, tagged, published and then merged, in that order",
    [name for name in steps_by_name if name in ordered] == ordered,
)
check(
    "only a new release is dated and tagged, and a new or resumed one is published and merged",
    all(
        steps_by_name[name].get("if") == "steps.prepare.outputs.release_needed == 'true'" for name in ordered[:2]
    )
    and all(
        steps_by_name[name].get("if") == "steps.prepare.outputs.publish_needed == 'true'" for name in ordered[2:]
    ),
)
check(
    "the date pull request is opened only after tagging",
    "gh pr create" not in script("scripts/bash/push_plugin_release_date.sh")
    and "gh pr create" in script("scripts/bash/merge_plugin_release_date_pr.sh"),
)
check(
    "the tag is checked against the commit, not the working tree",
    "git show HEAD:CHANGELOG.md" in script("scripts/bash/tag_plugin_dev_release.sh"),
)
check(
    "the approver token reaches only the merge step",
    "secrets.approver-token" in str(steps_by_name.get("Merge the release date", {}).get("env"))
    and sum("secrets." in str(step) for step in steps if step.get("name") != "Check the approver token") == 1
    and steps_by_name.get("Check the approver token", {}).get("env")
    == {"HAS_APPROVER_TOKEN": "${{ secrets.approver-token != '' }}"},
)
check(
    "a CI hold fails the run last, after the versions being finished",
    steps[-1].get("name") == "Fail when CI held the release back"
    and str(steps[-1].get("if", "")).startswith("always() &&"),
)
check(
    "the approver token is checked only when the caller asks",
    steps_by_name.get("Check the approver token", {}).get("if") == "inputs.require-approver-token",
)
check(
    "nothing pushes to the development branch",
    not any("git push" in str(step.get("run", "")) for step in steps)
    and 'origin "HEAD:refs/heads/$BRANCH"' in script("scripts/bash/push_plugin_release_date.sh"),
)
check(
    "the merge only follows the head it checked",
    "--match-head-commit" in script("scripts/bash/merge_plugin_release_date_pr.sh"),
)
check(
    "the published release is only marked latest when it is the highest version",
    '"--latest=$make_latest"' in script("scripts/bash/publish_plugin_release.sh")
    and '--raw-field "make_latest=$make_latest"' in script("scripts/bash/publish_plugin_release.sh"),
)

check_jobs = check_doc.get("jobs") or {}
check_job = next(iter(check_jobs.values()), {})
check("the date check is one job", len(check_jobs) == 1)
check("the date check only reads", check_job.get("permissions") == {"contents": "read"})
check("the date check has a timeout", isinstance(check_job.get("timeout-minutes"), int))
check("the date check declares no concurrency", not check_doc.get("concurrency"))
check(
    "the date check runs the shared script on the pull request's base",
    any("check_plugin_release_date.sh" in str(step.get("run", "")) for step in check_steps)
    and any("github.base_ref" in str(step.get("env")) for step in check_steps),
)
check(
    "the date check recognises the release workflow by its path",
    "plugin-ci-workflows/.github/workflows/plugin-dev-release.yml@" in script("scripts/bash/check_plugin_release_date.sh"),
)

# A skipped calling job reports as `ai-checklist`, never as the gate's own check, so a branch that
# requires the gate would hold the release date pull request forever. Names are pushable, a tag at
# the head is not, so the date pull request is passed inside the gate, on its tag.
ci_checklist = (load("plugin-ci.yml").get("jobs") or {}).get("ai-checklist") or {}
checklist_jobs = load("plugin-ai-checklist.yml").get("jobs") or {}
gate_job = next(iter(checklist_jobs.values()), {})
gate_steps = [step for step in gate_job.get("steps") or [] if isinstance(step, dict)]
recognise = next((step for step in gate_steps if step.get("id") == "release-date"), {})
check(
    "Plugins CI does not skip the checklist on branch or author names",
    not any(name in str(ci_checklist.get("if", "")) for name in ("head_ref", "user.login", "release-date")),
)
check("the checklist gate job itself is never skipped", len(checklist_jobs) == 1 and "if" not in gate_job)
check(
    "the date pull request is recognised by its head being the release tag",
    "git/ref/tags/" in str(recognise.get("run", ""))
    and "pull_request.head.sha" in str(recognise.get("env", "")),
)
check(
    "only the gate step is passed over for it",
    any("checklist-gate" in str(step.get("uses", "")) and "steps.release-date.outputs.tagged" in str(step.get("if", ""))
        for step in gate_steps),
)
check(
    "Plugins CI grants the checklist the contents scope its tag lookup needs",
    (ci_checklist.get("permissions") or {}).get("contents") == "read",
)

print()
print(f"{tests} tests, {len(failures)} failures")
if failures:
    sys.exit(1)
PY
