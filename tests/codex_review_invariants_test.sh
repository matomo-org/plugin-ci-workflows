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

query() {
  python3 -c "
import sys, yaml
with open('$WORKFLOW') as handle:
    doc = yaml.safe_load(handle)
# PyYAML resolves the bare 'on' key to the boolean True.
doc['on'] = doc.pop(True, doc.get('on'))
$1
" 2>/dev/null
}

# Every job must gate on the label, or an unrelated label starts privileged work.
check "every job is gated on the trigger label or on preflight" \
  query "
jobs = doc['jobs']
for name, job in jobs.items():
    condition = str(job.get('if', ''))
    if 'trigger-label' not in condition and 'needs.preflight' not in condition:
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

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES invariant(s) failed"
  exit 1
fi
echo "all invariants hold"
