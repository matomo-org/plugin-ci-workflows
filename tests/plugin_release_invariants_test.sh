#!/bin/bash
# Invariants for .github/workflows/plugin-release.yml, the reusable production release workflow.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/plugin-release.yml"

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FAIL - PyYAML is not available, so these invariants cannot be checked"
  exit 1
fi

python3 - "$WORKFLOW" <<'PY'
import sys
from pathlib import Path

import yaml

workflow_path = Path(sys.argv[1])
workflow_root = workflow_path.parent.parent.parent
with workflow_path.open() as handle:
    document = yaml.safe_load(handle)

triggers = document.get("on", document.get(True)) or {}
jobs = document.get("jobs") or {}
release = jobs.get("release") or {}
check_date = jobs.get("check-date") or {}
date_pr = jobs.get("date-pr") or {}
steps = release.get("steps") or []
all_steps = [
    step for job in jobs.values() for step in (job.get("steps") or []) if isinstance(step, dict)
]
run_steps = [step for step in all_steps if "run" in step]
steps_by_name = {step.get("name"): step for step in steps if isinstance(step, dict) and step.get("name")}


def step_run(name, job_steps=steps):
    for step in job_steps:
        if isinstance(step, dict) and step.get("name") == name:
            return str(step.get("run", ""))
    return ""


def checkouts(job):
    return [
        step for step in job.get("steps") or []
        if isinstance(step, dict) and step.get("uses", "").startswith("actions/checkout@")
    ]


def script(path):
    return (workflow_root / path).read_text()

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


check("the release workflow is reusable", "workflow_call" in triggers)
check(
    "it declares the check-date, date-pr and release jobs",
    {"check-date", "date-pr", "release"} <= set(jobs),
)
check("the check job keeps the name callers require", check_date.get("name") == "Changelog date")
check(
    "every job has a timeout",
    all(isinstance(job.get("timeout-minutes"), int) for job in jobs.values()),
)
check("the workflow grants nothing by default", document.get("permissions") == {})
check("the check job only reads", check_date.get("permissions") == {"contents": "read"})
check(
    "each event runs its own job",
    "pull_request" in check_date.get("if", "")
    and "pull_request" in date_pr.get("if", "")
    and "head.repo.full_name == github.repository" in date_pr.get("if", "")
    and "!startsWith(github.event.pull_request.head.ref, 'automated/release-date-')" in date_pr.get("if", "")
    and "'push'" in release.get("if", "")
    and "pull_request" not in release.get("if", ""),
)
check(
    "workflow_dispatch picks a job with the task input",
    "inputs.task == 'changelog-check'" in check_date.get("if", "")
    and "inputs.task == 'changelog-date'" in date_pr.get("if", "")
    and "inputs.task == 'release'" in release.get("if", ""),
)
check(
    "the release concurrency group queues rather than cancels",
    (document.get("concurrency") or {}).get("cancel-in-progress") is False,
)
check(
    "the release job checks caller concurrency",
    "check_caller_concurrency.sh" in step_run("Check caller concurrency")
    and step_run("Check caller concurrency").count("plugin-release.yml") == 1,
)
check(
    "all inline shell steps select bash",
    all(step.get("shell") == "bash" for step in run_steps),
)
check(
    "every checkout disables persisted credentials",
    all(len(checkouts(job)) == 2 for job in (check_date, date_pr, release))
    and all(
        step.get("with", {}).get("persist-credentials") is False
        for job in jobs.values() for step in checkouts(job)
    ),
)
check(
    "the check job runs the shared check script",
    "check_plugin_changelog_date.sh"
    in step_run("Check the changelog date", check_date.get("steps") or []),
)
check(
    "the date-pr job dates the pull request's head branch",
    "open_plugin_changelog_date_pr.sh"
    in step_run("Open the release date pull request", date_pr.get("steps") or [])
    and "github.event.pull_request.head.ref" in (date_pr.get("env") or {}).get("TARGET_BRANCH", ""),
)
check(
    "the production branch is fetched before release preparation",
    "git fetch" in step_run("Fetch current production branch")
    and "refs/remotes/origin/" in step_run("Fetch current production branch"),
)
check(
    "metadata and tag decisions use the shared preparation script",
    steps_by_name.get("Prepare release", {}).get("id") == "prepare"
    and "scripts/bash/prepare_plugin_release.sh" in step_run("Prepare release"),
)
check(
    "release scripts are staged before conditional release steps",
    not steps_by_name.get("Stage release scripts", {}).get("if")
    and all(
        name in step_run("Stage release scripts")
        for name in (
            "update_changelog_date.py",
            "create_plugin_release_tag.sh",
            "publish_plugin_release.sh",
            "open_plugin_changelog_date_pr.sh",
        )
    ),
)
check(
    "a stale changelog date opens the date pull requests and fails the release",
    steps_by_name.get("Open release date pull requests", {}).get("if")
    == "steps.prepare.outputs.date_pr_needed == 'true'"
    and "open_plugin_changelog_date_pr.sh" in step_run("Open release date pull requests")
    and "exit 1" in step_run("Open release date pull requests"),
)
check(
    "the tag step runs only when a release is needed",
    steps_by_name.get("Create release tag", {}).get("if")
    == "steps.prepare.outputs.release_needed == 'true'",
)
check(
    "tagging rechecks the production branch tip",
    "create_plugin_release_tag.sh" in step_run("Create release tag"),
)
check(
    "the GitHub release step runs last, when publication is needed",
    steps[-1].get("name") == "Create GitHub release"
    and steps[-1].get("if") == "steps.prepare.outputs.publish_release == 'true'",
)
check(
    "the release publisher is shared and verifies the tag",
    "$PUBLISH_SCRIPT" in step_run("Create GitHub release")
    and steps_by_name.get("Create GitHub release", {}).get("env", {}).get("PUBLISH_SCRIPT")
    == "${{ runner.temp }}/release-scripts/bash/publish_plugin_release.sh"
    and "--verify-tag" in script("scripts/bash/publish_plugin_release.sh"),
)
check(
    "nothing pushes to a protected branch",
    not any("git push" in str(step.get("run", "")) for step in all_steps)
    and 'origin "HEAD:refs/heads/$BRANCH"' in script("scripts/bash/open_plugin_changelog_date_pr.sh"),
)
check(
    "the shared release publisher uses a string latest field",
    "--raw-field make_latest=false" in script("scripts/bash/publish_plugin_release.sh"),
)

print()
print(f"{tests} tests, {len(failures)} failures")
if failures:
    sys.exit(1)
PY
