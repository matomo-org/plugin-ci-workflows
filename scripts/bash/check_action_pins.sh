#!/bin/bash

# Check that every action this repository uses is pinned to a commit, and that the commit exists.
#
# Both halves have been wrong before, in the same way: the guard covered less than a reader would
# assume. A pinned SHA once named no commit at all (actions/github-script@373c709c..., in four
# places across two repositories, failing at preflight on every run). Then the extraction pattern
# required owner/repo@sha and skipped actions/cache/restore, verifying three of five pins while
# reporting success. Then a line-oriented pattern missed `uses: >-` folded onto the next line,
# which actionlint accepts. Then nothing asserted that an action was pinned at all.
#
# Hence three separate assertions below, each able to fail on its own: every action is pinned,
# every pin resolves, and the number parsed matches an independently counted total.

set -uo pipefail

API="${GITHUB_API_URL:-https://api.github.com}"
FAILURES=0

resolve() {
  local repo="$1" sha="$2" status attempt
  for attempt in 1 2 3; do
    status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
      ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
      -H 'Accept: application/vnd.github+json' \
      "$API/repos/$repo/commits/$sha" 2>/dev/null)

    case "$status" in
      200) return 0 ;;
      404|422) return 1 ;;
    esac

    [ "$attempt" -lt 3 ] && sleep $((attempt * 2))
  done

  echo "  could not determine whether $repo@$sha exists (last HTTP $status)"
  return 2
}

# Parsed, not grepped: a `uses:` value can be folded, quoted or block-scalared, and every
# line-oriented pattern tried here has missed at least one of those shapes.
EXTRACT=$(mktemp)
trap 'rm -f "$EXTRACT"' EXIT
python3 - > "$EXTRACT" <<'PYEOF'
import glob, json, os, re, yaml

PINNED = re.compile(r'^[^@\s]+@[0-9a-f]{40}$')
pinned, unpinned = [], []

def collect(node):
    uses = node.get('uses') if isinstance(node, dict) else None
    if not isinstance(uses, str):
        return
    uses = uses.strip()
    # A local action carries no ref of its own; the checkout that puts it on disk is pinned.
    if uses.startswith('./') or uses.startswith('docker://'):
        return
    if PINNED.match(uses):
        pinned.append(uses)
        return
    # A reusable workflow is not an action, and first-party ones track `main` deliberately -- see
    # the pinning section in the README. Only actions are required to be pinned here.
    if '/.github/workflows/' in uses:
        return
    unpinned.append(uses)

# os.walk, not glob: Python's `**` does not descend into dot-directories, so composite actions
# in .github/actions/ -- GitHub's own documented home for them -- were invisible to this parser.
paths = set(glob.glob('.github/workflows/*.y*ml'))
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', 'vendor')]
    for name in files:
        if re.fullmatch(r'action\.ya?ml', name):
            paths.add(os.path.join(root, name))
paths = sorted(paths)
for path in paths:
    try:
        doc = yaml.safe_load(open(path))
    except Exception:
        continue
    if not isinstance(doc, dict):
        continue
    for job in (doc.get('jobs') or {}).values():
        if isinstance(job, dict):
            collect(job)
            for step in job.get('steps') or []:
                collect(step)
    for step in ((doc.get('runs') or {}).get('steps') or []):
        collect(step)

print(json.dumps({'pinned': pinned, 'unpinned': sorted(set(unpinned))}))
PYEOF

mapfile -t OCCURRENCES < <(python3 -c "import json,sys; print('\n'.join(json.load(open(sys.argv[1]))['pinned']))" "$EXTRACT")
mapfile -t UNPINNED < <(python3 -c "import json,sys; print('\n'.join(json.load(open(sys.argv[1]))['unpinned']))" "$EXTRACT")

# A second count, arrived at completely differently: any @<40 hex> token anywhere in the YAML.
# If the parser missed a shape, these disagree and the run fails rather than verifying a subset.
SHA_TOKENS=$(grep -rhoE "@[0-9a-f]{40}" --include='*.yml' --include='*.yaml' . | wc -l)
CHECKED=${#OCCURRENCES[@]}

for ref in $(printf '%s\n' "${OCCURRENCES[@]}" | sort -u); do
  action="${ref%@*}"
  sha="${ref#*@}"
  # actions/cache/restore is pinned as a subpath of actions/cache, and the commit belongs to the
  # repository, not the path: ask for repos/actions/cache/commits/<sha>.
  repo="$(cut -d/ -f1,2 <<< "$action")"

  resolve "$repo" "$sha"
  case $? in
    0) echo "ok - $ref" ;;
    1) echo "not ok - $ref does not exist"; FAILURES=$((FAILURES + 1)) ;;
    *) echo "not ok - $ref could not be resolved"; FAILURES=$((FAILURES + 1)) ;;
  esac
done

for ref in "${UNPINNED[@]}"; do
  [ -z "$ref" ] && continue
  echo "not ok - $ref is not pinned to a commit SHA"
  FAILURES=$((FAILURES + 1))
done

echo
if [ "$CHECKED" -eq 0 ] && [ "${#UNPINNED[@]}" -eq 0 ]; then
  echo "no actions found - the extraction is probably broken"
  exit 1
fi
if [ "$CHECKED" -ne "$SHA_TOKENS" ]; then
  echo "parsed $CHECKED pinned uses: but found $SHA_TOKENS SHA reference(s) in the YAML"
  echo "the extraction is missing a pin shape - every pin must be resolved, not most"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  echo "$CHECKED pin(s) checked, $FAILURES problem(s)"
  exit 1
fi
echo "$CHECKED pin(s) checked, all pinned and all resolve"
