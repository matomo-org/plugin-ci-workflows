#!/bin/bash
# Fails when the workflow that called plugin-ci.yml declares a `concurrency` block of its own.
# Usage: check_caller_concurrency.sh <workflow-ref> <checkout-root>
#   workflow-ref   the run's GITHUB_WORKFLOW_REF, owner/repo/path@ref
#   checkout-root  directory the caller repository is checked out in
#
# plugin-ci.yml owns the group and runs two lanes, so a push supersedes a push while a description
# edit only supersedes an edit. A caller-level group spans both actions instead, and a called
# workflow cannot override it: concurrency governs the run, and the run belongs to the caller. So
# an `edited` run -- which does none of the code checks -- cancels the push's analysis and puts
# nothing in its place, which is how UsersFlow#135 came to report two red PHPStan checks that had
# never analysed a file. GitHub raises no deadlock error for it either, because the caller's group
# never matches the static prefix used here. A red check explained by nothing is the only symptom,
# which is why this is asserted rather than left to the README.
#
# Every plugin ships matomo-ai-checklist.yml carrying exactly such a block, rightly so while that
# file stands alone, and the fleet migration renames it to ci.yml. Whether the block was deleted on
# the way is what this checks.
set -u

WORKFLOW_REF="${1:-}"
CHECKOUT_ROOT="${2:-}"
UMBRELLA='plugin-ci-workflows/.github/workflows/plugin-ci.yml'

if [ -z "$WORKFLOW_REF" ] || [ -z "$CHECKOUT_ROOT" ]; then
  echo "Usage: $0 <workflow-ref> <checkout-root>" >&2
  exit 1
fi

# owner/repo/<path>@<ref>. Strip two segments for the slug, then everything from the FIRST `@`: a
# ref may legally contain one, a workflow path in practice never does.
path_and_ref="${WORKFLOW_REF#*/}"
path_and_ref="${path_and_ref#*/}"
CALLER_PATH="${path_and_ref%%@*}"

# Checked by shape rather than by whether anything was stripped: GitHub runs workflows only from
# .github/workflows/, and a ref that lost its slug leaves something plausible behind. `refs/heads/
# main` reduces to `main`, which would otherwise be reported as a workflow missing from the
# checkout -- true, and no help at all to whoever has to work out what went wrong.
case "$CALLER_PATH" in
  .github/workflows/?*) ;;
  *)
    echo "Could not read a workflow path out of '$WORKFLOW_REF'" >&2
    exit 1
    ;;
esac

CALLER_FILE="$CHECKOUT_ROOT/$CALLER_PATH"
if [ ! -f "$CALLER_FILE" ]; then
  echo "The calling workflow $CALLER_PATH is not in the checkout at $CHECKOUT_ROOT" >&2
  exit 1
fi

# Parsed, not grepped: a block this misses is a silently cancelled analysis, and both shapes of it
# -- a bare group string and a mapping -- have to count.
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "PyYAML is not available, so the caller's concurrency cannot be checked" >&2
  exit 1
fi

python3 - "$CALLER_FILE" "$CALLER_PATH" "$UMBRELLA" <<'PY'
import sys, yaml

caller_file, caller_path, umbrella = sys.argv[1], sys.argv[2], sys.argv[3]

# Fail closed on a caller that does not parse, and say so: an uncaught traceback exits non-zero
# too, but it reads as a broken guard rather than a broken workflow.
try:
    with open(caller_file) as handle:
        doc = yaml.safe_load(handle) or {}
except yaml.YAMLError as error:
    print(f"{caller_path} is not valid YAML, so its concurrency cannot be read: {error}", file=sys.stderr)
    sys.exit(1)

if not isinstance(doc, dict):
    print(f"{caller_path} does not parse as a workflow", file=sys.stderr)
    sys.exit(1)

offenders = []
if doc.get('concurrency'):
    offenders.append('the workflow itself')

# A group on the calling job cancels exactly what the workflow-level one would. A group on any
# other job in the file cancels only that job, so it is the caller's own business.
for name, job in (doc.get('jobs') or {}).items():
    if not isinstance(job, dict) or not job.get('concurrency'):
        continue
    if umbrella in str(job.get('uses', '')):
        offenders.append(f"the job '{name}', which calls Plugins CI")

if not offenders:
    print(f"ok - {caller_path} declares no concurrency of its own")
    sys.exit(0)

named = ' and '.join(offenders)
# Flushed, because the annotation and the explanation go to different streams and the log
# interleaves them in the order they arrive.
print(
    f"::error file={caller_path}::Delete the concurrency block on {named}."
    " Plugins CI declares the group itself, in two lanes; one caller-level group spans both"
    " actions, so a description edit either cancels a push's analysis or queues ahead of it.",
    flush=True,
)
print(f"""
{caller_path} declares its own concurrency on {named}.

Delete it. Plugins CI declares the group itself, in two lanes: a push supersedes an earlier push,
while a description edit only supersedes an earlier edit. A caller-level group spans both actions,
and this workflow cannot override it -- concurrency governs the run, and the run is yours. An
`edited` run does none of the code checks, so with cancel-in-progress it cancels the push's
analysis and replaces it with nothing -- checks that report red having never analysed a file, and
nothing on the pull request to say why. Without cancel-in-progress the edit queues behind the
analysis instead, and the checklist verdict waits on a run it has nothing to do with.

If the block arrived by renaming matomo-ai-checklist.yml to ci.yml, deleting it is the whole fix:
that file needs it while it stands alone, and Plugins CI replaces it. If another job in this file
needs a lane of its own, give that job its own workflow file.
""", file=sys.stderr)
sys.exit(1)
PY
