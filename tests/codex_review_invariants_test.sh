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

# Every job must gate on the label, or an unrelated label starts privileged work.
#
# Equality, not containment. A substring check is satisfied by a condition that has been weakened
# rather than removed: appending `|| true`, or `|| github.event_name == \'workflow_dispatch\'`,
# keeps every substring intact while the gate stops gating.
check "every job gates on exactly the labeled-with-trigger-label condition, or on preflight" \
  query "
GATE = \"github.event.action == 'labeled' && github.event.label.name == inputs.trigger-label\"
ALLOWED = {GATE, '!cancelled() && ' + GATE}
PREFLIGHT = \"needs.preflight.outputs.should_run == 'true'\"
import re
for name, job in doc['jobs'].items():
    condition = ' '.join(str(job.get('if', '')).split())
    # GitHub accepts a job condition with or without the \${{ }} wrapper; compare the expression.
    condition = re.sub(r'^\\\${{\\s*|\\s*}}$', '', condition).strip()
    if condition == PREFLIGHT:
        continue
    if condition not in ALLOWED:
        print('  ' + name + ': ' + condition, file=sys.stderr)
        sys.exit(1)
"

# Only the trusted review actions and two pinned first-party actions may execute. Pinning proves a
# SHA exists, not that the action is one we chose -- a real third-party action has a real SHA, and
# without this it can be dropped into the job holding issues: write and pull-requests: write.
check "every step runs a trusted action" \
  query "
LOCAL = {
    './github-action-tests/review/actions/preflight',
    './github-action-tests/review/actions/codex',
    './github-action-tests/review/actions/post-review',
}
PINNED = {
    'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
    'actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3',
}
for name, job in doc['jobs'].items():
    for step in job.get('steps') or []:
        uses = str(step.get('uses', '')).split('#')[0].strip()
        if not uses:
            continue
        if uses not in LOCAL and uses not in PINNED:
            print('  ' + name + ': ' + uses, file=sys.stderr)
            sys.exit(1)
"

# TESTS_ACCESS_TOKEN is named in this file's header as one of the three things that make this
# workflow dangerous. It reads a private repository, so it may reach exactly two places: the
# `token:` of a trusted checkout, and the one step that checks it is set at all. "Any step with a
# run: and the token in env" is not good enough -- that also describes piping it to curl.
check "the access token is only ever a checkout token or the configured-check" \
  query "
import json
VERIFIER = 'Verify review actions token is configured'
if 'TESTS_ACCESS_TOKEN' in json.dumps(doc.get('env') or {}):
    sys.exit(1)
for name, job in doc['jobs'].items():
    if 'TESTS_ACCESS_TOKEN' in json.dumps(job.get('env') or {}):
        sys.exit(1)
    for step in job.get('steps') or []:
        if 'TESTS_ACCESS_TOKEN' not in json.dumps(step):
            continue
        uses = str(step.get('uses', ''))
        token = str((step.get('with') or {}).get('token', ''))
        if uses.startswith('actions/checkout') and 'TESTS_ACCESS_TOKEN' in token:
            continue
        if step.get('name') == VERIFIER:
            continue
        print('  ' + name + ': ' + str(step.get('name')), file=sys.stderr)
        sys.exit(1)
"

# The action allowlist says nothing about shell. This workflow has exactly one run: step, and a
# second one could use the write-capable token in post-review or cleanup, or exfiltrate a secret,
# without touching a single `uses:`.
# Pinned by exact content, not by name and not normalised. An allowlist keyed on the step name
# lets the body be rewritten; a whitespace-normalised hash lets the *semantics* be rewritten --
# joining `echo ...` and `exit 1` onto one line keeps the hash and turns the exit into an argument
# to echo, silently disabling the fail-closed check. Whitespace is significant in shell, so the
# hash is over the exact string. Editing this step means updating this hash deliberately.
#
# `with.script` counts as a body too. github-script runs arbitrary JavaScript with whatever the job
# grants it, and cleanup holds issues: write and pull-requests: write -- enough to approve a pull
# request, comment, or close an issue. Covering only `run:` left that body pinned by nothing but
# the no-interpolation check, so a rewrite of it passed every invariant.
check "every executable step body is pinned, byte for byte" \
  query "
import hashlib
ALLOWED = {
    ('preflight', 'Verify review actions token is configured'): '013d1ad152ee5c0e96bd7cfe865ed3fa81caa83101fbf8d21e1f9ceb6777acde',
    ('cleanup', 'Remove trigger label'): 'f06a83c68cd8f036a9089e02291a4066d961c253147a3c55d56350ac338c8036',
}
for name, job in doc['jobs'].items():
    for step in job.get('steps') or []:
        # Not \`or\`: an empty run: is a body that exists and must still be accounted for.
        body = step['run'] if 'run' in step else (step.get('with') or {}).get('script')
        if body is None:
            continue
        expected = ALLOWED.get((name, step.get('name')))
        digest = hashlib.sha256(str(body).encode()).hexdigest()
        if expected is None or digest != expected:
            print('  ' + name + ': ' + str(step.get('name')) + ' ' + digest, file=sys.stderr)
            sys.exit(1)
"

# The gate is only a gate if it carries preflight's actual verdict. `should_run: 'true'` satisfies
# a check that merely looks for the output name in the condition.
check "the preflight verdict is wired from the preflight step" \
  query "
outputs = (doc['jobs']['preflight'].get('outputs') or {})
if outputs.get('should_run') != '\${{ steps.preflight.outputs.should_run }}':
    print('  should_run is ' + str(outputs.get('should_run')), file=sys.stderr)
    sys.exit(1)
"

# An assertion that the key is not in the wrong place says nothing about it being in the right one.
check "the codex action receives the OpenAI key" \
  query "
step = [
    s for s in doc['jobs']['codex']['steps']
    if 'review/actions/codex' in str(s.get('uses', ''))
][0]
if (step.get('with') or {}).get('openai-api-key') != '\${{ secrets.OPENAI_API_KEY }}':
    sys.exit(1)
"

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

# Scope: this asserts what *this file* checks out, not what the whole review does. The trusted
# composite actions do check out the pull request head -- preflight into pr-preflight, codex into
# pr -- deliberately and under their own fork refusal. What must never happen is this workflow
# checking out caller or PR code itself, where none of that protection applies.
check "no checkout in this file targets anything but the trusted actions repository" \
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
