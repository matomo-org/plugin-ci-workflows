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
check("the release job has a timeout", isinstance(release.get("timeout-minutes"), int))
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
    "release scripts are staged before conditional release steps",
    not steps_by_name.get("Stage release scripts", {}).get("if")
    and all(
        script in step_run("Stage release scripts")
        for script in (
            "update_changelog_date.py",
            "create_plugin_release_tag.sh",
            "publish_plugin_release.sh",
        )
    ),
)
check(
    "the GitHub release step runs when publication is needed",
    steps_by_name.get("Create GitHub release", {}).get("if")
    == "steps.prepare.outputs.publish_release == 'true'",
)
check(
    "tagging rechecks the production branch tip",
    "create_plugin_release_tag.sh" in step_run("Stage release scripts")
    and "create_plugin_release_tag.sh" in step_run("Create release tag"),
)
check(
    "the release publisher is shared and verifies the tag",
    "publish_plugin_release.sh" in step_run("Stage release scripts")
    and "$PUBLISH_SCRIPT" in step_run("Create GitHub release")
    and steps_by_name.get("Create GitHub release", {}).get("env", {}).get("PUBLISH_SCRIPT")
    == "${{ runner.temp }}/publish_plugin_release.sh"
    and "--verify-tag" in (workflow_root / "scripts/bash/publish_plugin_release.sh").read_text(),
)
check(
    "the shared release publisher uses a string latest field",
    "--raw-field make_latest=false" in (workflow_root / "scripts/bash/publish_plugin_release.sh").read_text(),
)

print()
print(f"{tests} tests, {len(failures)} failures")
if failures:
    sys.exit(1)
PY
