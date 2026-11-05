#!/bin/bash
# Tests re-running the release date check on open pull requests after a release, with a fake gh CLI
# that answers from JSON files and applies the script's own --jq filters.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/rerun_release_date_checks.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GITHUB_REPOSITORY=matomo-org/plugin-TestPlugin
export FAKE_API="$WORK/api"
export FAKE_GH_LOG="$WORK/gh.log"
mkdir -p "$FAKE_API/runs" "$FAKE_API/jobs" "$WORK/bin"

cat > "$WORK/bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
filter="${*: -1}"
if [[ "$1 $2" == "pr list" ]]; then
    [[ -z "${FAKE_PR_LIST_ERROR:-}" ]] || { echo "$FAKE_PR_LIST_ERROR" >&2; exit 1; }
    jq -r "$filter" "$FAKE_API/prs.json"
elif [[ "$*" == *'--method POST'* ]]; then
    args="$*"
    job="${args#*/actions/jobs/}"
    job="${job%%/*}"
    [[ " ${FAKE_RERUN_FAILS:-} " != *" $job "* ]] || { echo "rerun refused" >&2; exit 1; }
elif [[ "$2" == *'/actions/runs?head_sha='* ]]; then
    sha="${2#*head_sha=}"
    sha="${sha%%&*}"
    jq -r "$filter" "$FAKE_API/runs/$sha.json"
elif [[ "$2" == *'/jobs?'* ]]; then
    run="${2#*/actions/runs/}"
    run="${run%%/*}"
    jq -r "$filter" "$FAKE_API/jobs/$run.json"
fi
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

prs() {
    jq -nc '$ARGS.positional | map(split(":")) | map({number: (.[0] | tonumber), headRefOid: .[1]})' --args "$@" \
        > "$FAKE_API/prs.json"
}

# runs <sha> <id>:<status>..., newest first
runs() {
    local sha="$1"
    shift
    jq -nc '{workflow_runs: ($ARGS.positional | map(split(":")) | map({id: (.[0] | tonumber), status: .[1]}))}' \
        --args "$@" > "$FAKE_API/runs/$sha.json"
}

# jobs <run> <id>:<conclusion>:<name>...
jobs() {
    local run="$1"
    shift
    jq -nc '{jobs: ($ARGS.positional | map(split(":")) | map({id: (.[0] | tonumber), conclusion: .[1], name: .[2]}))}' \
        --args "$@" > "$FAKE_API/jobs/$run.json"
}

run() {
    : > "$FAKE_GH_LOG"
    bash "$SCRIPT" 6.x-dev > "$WORK/out" 2>&1
}

reran() {
    grep -q "actions/jobs/$1/rerun" "$FAKE_GH_LOG"
}

prs 11:aaa 12:bbb 13:ccc 14:ddd 15:eee
# #11: the newest run with the job is re-run, not an older one or a run without it.
runs aaa 103:completed 102:completed 101:completed
jobs 103 '901:success:Codex review'
jobs 102 '902:success:ci / release-date / Release date' '903:success:ci / phpcs / PHPCS'
jobs 101 '904:success:ci / release-date / Release date'
# #12: still running.
runs bbb 201:in_progress
jobs 201 '905::ci / release-date / Release date'
# #13: the plugin skips the check.
runs ccc 301:completed
jobs 301 '906:skipped:ci / release-date'
# #14: no run with the check.
runs ddd 401:completed
jobs 401 '907:success:Tests / PHPUnit'
# #15: the re-run is refused.
runs eee 501:completed
jobs 501 '908:failure:ci / release-date / Release date'
export FAKE_RERUN_FAILS=908

run || { cat "$WORK/out" >&2; fail "the script never fails the release"; }
reran 902 || { cat "$WORK/out" >&2; fail "the newest run's release date job is re-run"; }
if reran 904; then fail "an older run is not re-run"; fi
if reran 903; then fail "only the release date job is re-run"; fi
grep -Fq '#12 is still in progress' "$WORK/out" || { cat "$WORK/out" >&2; fail "a run in progress is warned about"; }
if reran 905; then fail "a run in progress is not re-run"; fi
grep -Fq '#13 skips the release date check' "$WORK/out" || fail "a skipped check is left alone"
if reran 906; then fail "a skipped check is not re-run"; fi
grep -Fq '#14 has no release date check' "$WORK/out" || fail "a pull request without the check is reported"
grep -Fq '::warning::Could not re-run the release date check on #15' "$WORK/out" || { cat "$WORK/out" >&2; fail "a refused re-run is warned about"; }

# A top-level "Release date" job, from a plugin calling plugin-release-date-check.yml directly.
prs 21:fff
runs fff 601:completed
jobs 601 '909:success:Release date'
run || fail "a direct caller's run passes"
reran 909 || { cat "$WORK/out" >&2; fail "a direct caller's release date job is re-run"; }

FAKE_PR_LIST_ERROR="HTTP 502" run || fail "a failed pull request listing does not fail the release"
grep -Fq '::warning::Could not list the open pull requests into 6.x-dev' "$WORK/out" || fail "a failed listing is warned about"

echo "All release date re-run checks passed."
