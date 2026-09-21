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
with workflow_path.open() as handle:
    document = yaml.safe_load(handle)

triggers = document.get("on", document.get(True)) or {}
jobs = document.get("jobs") or {}
release = jobs.get("release") or {}
steps = release.get("steps") or []
run_steps = [step for step in steps if isinstance(step, dict) and "run" in step]
checkout_steps = [
    step for step in steps
    if isinstance(step, dict) and step.get("uses", "").startswith("actions/checkout@")
]
steps_by_name = {step.get("name"): step for step in steps if isinstance(step, dict) and step.get("name")}


def step_run(name):
    return str(steps_by_name.get(name, {}).get("run", ""))

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
check("it declares a release job", "release" in jobs)
check("the release job has a timeout", release.get("timeout-minutes") == 15)
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
    "both checkouts disable persisted credentials",
    len(checkout_steps) == 2
    and all(step.get("with", {}).get("persist-credentials") is False for step in checkout_steps),
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
    "the changelog step runs only when a release is needed",
    steps_by_name.get("Add release date to changelog", {}).get("if")
    == "steps.prepare.outputs.release_needed == 'true'",
)
check(
    "the tag step runs only when a release is needed",
    steps_by_name.get("Create release tag", {}).get("if")
    == "steps.prepare.outputs.release_needed == 'true'",
)
check(
    "the GitHub release step runs only when a release is needed",
    steps_by_name.get("Create GitHub release", {}).get("if")
    == "steps.prepare.outputs.release_needed == 'true'",
)
check(
    "the release verifies the pushed tag",
    "--verify-tag" in step_run("Create GitHub release"),
)
check(
    "the release is explicitly not marked repository-wide latest",
    "--latest=false" in step_run("Create GitHub release")
    and "--raw-field make_latest=false" in step_run("Create GitHub release"),
)
check(
    "the release can create or update after a partial failure",
    "gh release create" in step_run("Create GitHub release")
    and "gh release view" in step_run("Create GitHub release")
    and "--method PATCH" in step_run("Create GitHub release"),
)
check(
    "the old third-party release action is gone",
    not any("ncipollo/release-action" in str(step) for step in steps),
)

print()
print(f"{tests} tests, {len(failures)} failures")
if failures:
    sys.exit(1)
PY
