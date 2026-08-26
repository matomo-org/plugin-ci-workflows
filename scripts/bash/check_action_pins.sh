#!/bin/bash

# Resolve every pinned action SHA against the GitHub API.
#
# A 40-hex ref looks pinned and lints clean while naming a commit that does not exist. One did:
# actions/github-script@373c709c... appeared in four places across two repositories and would have
# failed at preflight on every run. Shape checks cannot catch that, and the Codex review cannot
# either -- it runs read-only with no network by design. So it is checked here, deterministically,
# in ordinary pull request CI where a token is available and no privileged trigger is involved.

set -uo pipefail

API="${GITHUB_API_URL:-https://api.github.com}"
FAILURES=0
CHECKED=0

# 200 = exists. 404/422 = definitively absent, which is the bug this exists to catch. Anything
# else is a transport or rate-limit failure: retry, then fail closed rather than wave it through.
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

while IFS= read -r ref; do
  action="${ref%@*}"
  sha="${ref#*@}"
  # actions/cache/restore is pinned as a subpath of actions/cache, and the commit belongs to
  # the repository, not the path: ask for repos/actions/cache/commits/<sha>.
  repo="$(cut -d/ -f1,2 <<< "$action")"
  CHECKED=$((CHECKED + 1))

  resolve "$repo" "$sha"
  case $? in
    0) echo "ok - $ref" ;;
    1) echo "not ok - $ref does not exist"; FAILURES=$((FAILURES + 1)) ;;
    *) echo "not ok - $ref could not be resolved"; FAILURES=$((FAILURES + 1)) ;;
  esac
done < <(grep -rhoE "uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}" \
           --include='*.yml' --include='*.yaml' . \
         | sed -E 's/uses:[[:space:]]+//' | sort -u)

echo
if [ "$CHECKED" -eq 0 ]; then
  echo "no pinned actions found - the extraction pattern is probably wrong"
  exit 1
fi
if [ "$FAILURES" -ne 0 ]; then
  echo "$CHECKED pin(s) checked, $FAILURES unresolved"
  exit 1
fi
echo "$CHECKED pin(s) checked, all resolve"
