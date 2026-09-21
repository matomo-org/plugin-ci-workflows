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
workflow_text = workflow_path.read_text()
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
check(
    "the release concurrency group queues rather than cancels",
    (document.get("concurrency") or {}).get("cancel-in-progress") is False,
)
check(
    "the release job checks caller concurrency",
    "check_caller_concurrency.sh" in workflow_text
    and "plugin-release.yml" in workflow_text,
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
    "the branch guard only accepts production branches",
    r"^([0-9]+)\.x-prod$" in workflow_text,
)
check(
    "the version must be a stable semantic version",
    r"^[0-9]+\.[0-9]+\.[0-9]+$" in workflow_text,
)
check(
    "an existing tag is compared with HEAD before reuse",
    'refs/tags/$VERSION^{commit}' in workflow_text
    and 'tag_commit" != "$head_commit"' in workflow_text,
)
check(
    "a matching existing tag is reused",
    'TAG_EXISTS' in workflow_text and 'Reusing existing tag' in workflow_text,
)
check(
    "the release can create or update after a partial failure",
    "gh release create" in workflow_text
    and "gh release view" in workflow_text
    and "--method PATCH" in workflow_text,
)
check(
    "the release verifies the pushed tag",
    "--verify-tag" in workflow_text,
)
check(
    "the release is explicitly not marked repository-wide latest",
    "--latest=false" in workflow_text and "make_latest=false" in workflow_text,
)
check(
    "the old third-party release action is gone",
    "ncipollo/release-action" not in workflow_text,
)

print()
print(f"{tests} tests, {len(failures)} failures")
if failures:
    sys.exit(1)
PY
