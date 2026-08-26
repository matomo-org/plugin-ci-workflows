#!/bin/bash

# The Codex review workflow runs under pull_request_target with OPENAI_API_KEY,
# TESTS_ACCESS_TOKEN and write access to the calling repository's pull requests. The
# controls that make that safe live partly here and partly in composite actions in
# innocraft/github-action-tests-private, whose own tests cannot see this file. These
# assertions pin the half that lives here, so a refactor cannot quietly drop one.

set -uo pipefail

WORKFLOW="$(dirname "$0")/../.github/workflows/plugin-codex-review.yml"
FAILURES=0

check() {
  local description="$1"
  shift
  if "$@"; then
    echo "ok - $description"
  else
    echo "not ok - $description"
    FAILURES=$((FAILURES + 1))
  fi
}

require_pyyaml() {
  if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "not ok - PyYAML is not installed, so no invariant below can be checked"
    exit 1
  fi
}

query() {
  python3 -c "
import sys, yaml
with open('$WORKFLOW') as handle:
    doc = yaml.safe_load(handle)
# PyYAML resolves the bare 'on' key to the boolean True.
doc['on'] = doc.pop(True, doc.get('on'))
$1
"
}

require_pyyaml

# Every job must gate on the label, or an unrelated label starts privileged work. Assert the whole
# condition, not a substring: `trigger-label` appearing somewhere is satisfied by
# `if: inputs.trigger-label != ''`, which gates on nothing at all.
#
# The `action == 'labeled'` half matters independently. On an `unlabeled` event
# github.event.label.name is still the trigger label, so a caller subscribed to
# `types: [labeled, unlabeled]` would start a privileged run every time the label is removed --
# including by this workflow's own cleanup job.
check "every job gates on a labeled event with the trigger label, or on preflight" \
  query "
LABEL_GATE = \"github.event.action == 'labeled'\"
NAME_GATE = 'github.event.label.name == inputs.trigger-label'
for name, job in doc['jobs'].items():
    condition = ' '.join(str(job.get('if', '')).split())
    if 'needs.preflight' in condition:
        continue
    if LABEL_GATE not in condition or NAME_GATE not in condition:
        sys.exit(1)
"

# preflight decides whether the review may run at all; nothing may run before it.
check "codex and post-review both wait for preflight" \
  query "
jobs = doc['jobs']
for name in ('codex', 'post-review'):
    needs = jobs[name].get('needs')
    needs = [needs] if isinstance(needs, str) else (needs or [])
    if 'preflight' not in needs:
        sys.exit(1)
"

check "the codex job runs only when preflight says so" \
  query "
if \"needs.preflight.outputs.should_run == 'true'\" not in str(doc['jobs']['codex'].get('if', '')):
    sys.exit(1)
"

# The job holding the OpenAI key must never be able to write to the repository.
check "the codex job has read-only permissions" \
  query "
perms = doc['jobs']['codex'].get('permissions') or {}
if sorted(perms.items()) != [('contents', 'read')]:
    sys.exit(1)
"

# The stated property is "the job holding the OpenAI key can never write". Asserting that the
# codex job is read-only only checks one direction: it says nothing about the key turning up in a
# job that *can* write, or in a workflow-level env visible to all of them.
check "the OpenAI key is confined to the read-only codex job" \
  query "
import json
WRITEABLE = {
    name for name, job in doc['jobs'].items()
    if 'write' in json.dumps(job.get('permissions') or {})
}
if json.dumps(doc.get('env') or {}).find('OPENAI_API_KEY') != -1:
    sys.exit(1)
for name, job in doc['jobs'].items():
    body = json.dumps(job)
    if 'OPENAI_API_KEY' not in body:
        continue
    if name != 'codex' or name in WRITEABLE:
        sys.exit(1)
"

# `permissions: contents: none` at workflow level is the floor. Without it a job that declares no
# permissions block inherits the caller's grant, which the README example sets to issues: write
# and pull-requests: write -- and the per-job check below only inspects declared blocks.
check "a workflow-level permission floor exists and grants no write" \
  query "
import json
top = doc.get('permissions')
if top is None:
    for name, job in doc['jobs'].items():
        if job.get('permissions') is None:
            sys.exit(1)
elif 'write' in json.dumps(top):
    sys.exit(1)
"

check "only post-review and cleanup may write" \
  query "
for name, job in doc['jobs'].items():
    perms = job.get('permissions') or {}
    writes = {k for k, v in perms.items() if v == 'write'}
    if writes and name not in ('post-review', 'cleanup'):
        sys.exit(1)
"

# A checkout of pull request head code under this trigger would be the classic
# pull_request_target compromise. Only the trusted actions repository may be checked out.
check "no job checks out the calling repository or pull request code" \
  query "
for name, job in doc['jobs'].items():
    for step in job.get('steps') or []:
        uses = str(step.get('uses', ''))
        if not uses.startswith('actions/checkout'):
            continue
        with_ = step.get('with') or {}
        if with_.get('repository') != 'innocraft/github-action-tests-private':
            sys.exit(1)
        if 'ref' in with_ and 'review-actions-ref' not in str(with_['ref']):
            sys.exit(1)
"

# For a pull_request_target workflow, an inline ${{ }} inside a run: or script: body is the
# classic injection route -- pull request title, branch name and body are all attacker-controlled.
# Every value here goes through env:, and this keeps it that way.
check "no run: or script: body interpolates a workflow expression" \
  query "
for name, job in doc['jobs'].items():
    for step in job.get('steps') or []:
        for key in ('run',):
            if '\${{' in str(step.get(key, '')):
                sys.exit(1)
        script = ((step.get('with') or {}).get('script'))
        if script and '\${{' in str(script):
            sys.exit(1)
"

# Every steps-based assertion above skips a job that is itself a reusable-workflow call, because
# such a job has no steps. Without this, an unpinned third-party job-level `uses:` handed both
# secrets passes the entire suite.
check "no job is a bare reusable-workflow call" \
  query "
for name, job in doc['jobs'].items():
    if 'uses' in job:
        sys.exit(1)
"

check "no run: step clones or checks out pull request code" \
  query "
import re
BAD = re.compile(r'git\\s+clone|gh\\s+pr\\s+checkout|git\\s+fetch[^\\n]*pull/')
for name, job in doc['jobs'].items():
    for step in job.get('steps') or []:
        if BAD.search(str(step.get('run', ''))):
            sys.exit(1)
"

check "checkouts do not persist credentials" \
  query "
for name, job in doc['jobs'].items():
    for step in job.get('steps') or []:
        if not str(step.get('uses', '')).startswith('actions/checkout'):
            continue
        if (step.get('with') or {}).get('persist-credentials') is not False:
            sys.exit(1)
"

# The review must see the commit preflight resolved, not whatever the branch points at
# by the time the job starts.
# allowed-owners restricts which repositories may run a review at all, and automation-paths is
# what stops a pull request that edits the reviewer's own configuration from being reviewed by it.
# Both are enforced inside preflight, so dropping either from the call silently removes a control
# while every other invariant here still passes.
check "preflight receives the owner allowlist and the automation-path guard" \
  query "
step = [
    s for s in doc['jobs']['preflight']['steps']
    if 'review/actions/preflight' in str(s.get('uses', ''))
][0]
with_ = step.get('with') or {}
for key in ('allowed-owners', 'automation-paths'):
    if 'inputs.' + key not in str(with_.get(key, '')):
        sys.exit(1)
"

check "codex reviews the SHAs preflight froze" \
  query "
step = [s for s in doc['jobs']['codex']['steps'] if 'review/actions/codex' in str(s.get('uses', ''))][0]
with_ = step.get('with') or {}
for key in ('base-sha', 'head-sha'):
    if 'needs.preflight.outputs' not in str(with_.get(key, '')):
        sys.exit(1)
"

check "third-party actions are pinned to a full commit SHA" \
  query "
import re
for name, job in doc['jobs'].items():
    for step in job.get('steps') or []:
        uses = str(step.get('uses', ''))
        if not uses or uses.startswith('./'):
            continue
        ref = uses.split('@')[-1]
        if not re.fullmatch(r'[0-9a-f]{40}', ref):
            sys.exit(1)
"

check "every pinned action carries its version in a trailing comment" \
  bash -c '
    grep -nE "^[[:space:]]*-?[[:space:]]*uses:" "'"$WORKFLOW"'" \
      | grep -v "uses:[[:space:]]*\./" \
      | grep -qv "#" && exit 1
    exit 0
  '

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES invariant(s) failed"
  exit 1
fi
echo "all invariants hold"
