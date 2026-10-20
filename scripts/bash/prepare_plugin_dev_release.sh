#!/bin/bash
# Decides whether the development branch has an unreleased version to release: plugin.json's version
# is stable, belongs to the branch's major, has no tag yet, and has a CHANGELOG.md entry the release
# can date, and no push CI run on the branch's head has failed or is still running once
# RELEASE_CI_WAIT_MINUTES have passed. Writes
# release_needed, publish_needed, version, plugin_name, today, finish and ci_held to GITHUB_OUTPUT.
# ci_held says why CI held plugin.json's version back; the workflow fails on it once the versions in
# finish are done, so a release that did not happen is seen.
# A version this workflow tagged is resumed until its release is published and its date is on the
# branch, including one plugin.json has since moved on from. finish lists each version to publish
# and merge, as <version>:<release date>, earliest first; release_needed covers only plugin.json's.
# Usage: prepare_plugin_dev_release.sh <development-branch ref, refs/heads/N.x-dev>

set -euo pipefail

REF="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tests pin the day; the workflow always uses the real one.
TODAY="${PLUGIN_RELEASE_TODAY:-$(date -u +%F)}"
BOT_EMAIL="github-actions[bot]@users.noreply.github.com"
CI_WAIT_MINUTES="${RELEASE_CI_WAIT_MINUTES:-45}"
CI_POLL_SECONDS="${RELEASE_CI_POLL_SECONDS:-60}"
(( CI_POLL_SECONDS > 0 )) || CI_POLL_SECONDS=1
# The job's timeout-minutes is 90, and the release after the wait needs the rest of it.
# Bounded by its digits first, since bash arithmetic wraps a long enough number to anything.
if [[ ! "$CI_WAIT_MINUTES" =~ ^0*[0-9]{1,2}$ ]] || (( 10#$CI_WAIT_MINUTES > 45 )); then
    echo "::error::ci-wait-minutes must be a whole number of minutes from 0 to 45, not $CI_WAIT_MINUTES." >&2
    exit 1
fi
CI_WAIT_MINUTES=$(( 10#$CI_WAIT_MINUTES ))

# A tag named like the branch has the same ref_name, so only the full ref says a branch is running.
if [[ ! "$REF" =~ ^refs/heads/(([0-9]+)\.x-dev)$ ]]; then
    echo "::error::Unsupported release ref: $REF" >&2
    exit 1
fi
BRANCH="${BASH_REMATCH[1]}"
expected_major="${BASH_REMATCH[2]}"

emit() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    else
        printf '%s\n' "$1"
    fi
}

# -P keeps the plugin checkout, the working directory, off the import path, so its json.py cannot stand in for the real module.
if ! metadata=$(python3 -P -c 'import json; p = json.load(open("plugin.json", encoding="utf-8")); print(p["version"]); print(p["name"])' 2>&1); then
    echo "::error file=plugin.json::Could not read the version and name from plugin.json: $metadata" >&2
    exit 1
fi
mapfile -t metadata_lines <<< "$metadata"
VERSION="${metadata_lines[0]}"
PLUGIN_NAME="${metadata_lines[1]}"

if ! remote_refs=$(git ls-remote --tags --heads origin); then
    echo "::error::Could not list the tags and branches on origin." >&2
    exit 1
fi

tagged() {
    grep -qxF "refs/tags/$1" <<< "$(cut -f2 <<< "$remote_refs")"
}

# Only a tag this workflow made is resumed, so a version released another way is never published.
# Called only inside conditions, where set -e is off, so a failed fetch must exit by itself.
ours() {
    if ! git fetch --quiet --no-tags origin "+refs/tags/$1:refs/tags/$1"; then
        echo "::error::Could not fetch the $1 tag from origin." >&2
        exit 1
    fi
    local commit
    commit=$(git rev-parse "refs/tags/$1^{commit}") || return 1
    # Anyone who can push can forge the bot's identity, so the commit must also be what the workflow
    # makes: one dated CHANGELOG.md on top of a commit already on the branch.
    [[ "$(git log -1 --format='%ae%n%ce%n%s' "$commit")" \
        == "$(printf '%s\n%s\n%s' "$BOT_EMAIL" "$BOT_EMAIL" "Add release date for $1")" ]] || return 1
    if [[ "$(git rev-list --no-walk --parents "$commit" | wc -w)" == 2 ]] \
        && git merge-base --is-ancestor "$commit^" "refs/remotes/origin/$BRANCH" \
        && [[ "$(git diff --name-only "$commit^" "$commit")" == CHANGELOG.md ]]; then
        return 0
    fi
    echo "::warning::The $1 tag carries this workflow's identity but is not one dated CHANGELOG.md on $BRANCH, so it is not resumed." >&2
    return 1
}

# However the date pull request was merged, the branch then dates the version.
finished() {
    python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --read-date --plugin-name "$PLUGIN_NAME" CHANGELOG.md "$1" > /dev/null 2>&1 \
        && [[ "$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$1" --jq .prerelease 2>/dev/null || true)" == false ]]
}

tagged_date() {
    git show "refs/tags/$1:CHANGELOG.md" | python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --read-date --plugin-name "$PLUGIN_NAME" /dev/stdin "$1"
}

# Sets ci_runs to the newest push run of each workflow on head_sha, as tab-separated workflow, id,
# status, conclusion and name. stderr is kept apart, so a notice gh writes on success is not a run.
# On a failed read, sets ci_read_error and returns 1.
read_ci_runs() {
    local errors runs
    errors=$(mktemp)
    if ! runs=$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$head_sha&branch=$BRANCH&event=push&per_page=100" \
            --jq '.workflow_runs[] | [.workflow_id, .id, .status, .conclusion, .name] | @tsv' 2> "$errors"); then
        # One line, since it ends up in a GITHUB_OUTPUT value; partial pages of runs are dropped.
        ci_read_error=$(tr -s '\n' ' ' < "$errors")
        echo "::error::Could not read the CI runs on ${head_sha:0:12}: $ci_read_error" >&2
        rm -f "$errors"
        return 1
    fi
    rm -f "$errors"
    ci_runs=$(sort -t $'\t' -k1,1n -k2,2nr <<< "$runs" | awk -F '\t' '$0 != "" && !seen[$1]++')
}

# Names the runs in ci_runs that match the awk condition, with their conclusion or status.
list_ci_runs() {
    awk -F '\t' '$0 != "" && ('"$1"') {
        out = out (out == "" ? "" : ", ") $5 " (" ($3 == "completed" ? $4 : $3) ")"
    } END { print out }' <<< "$ci_runs"
}

finish=()
# The date branches name every version this workflow has released.
earlier_versions=$(sed -nE "s#^.*\trefs/heads/automated/release-date-(${expected_major}\.[0-9]+\.[0-9]+)\$#\1#p" \
    <<< "$remote_refs" | sort -V)
for earlier in $earlier_versions; do
    if [[ "$earlier" != "$VERSION" ]] && tagged "$earlier" && ! finished "$earlier" && ours "$earlier"; then
        echo "$earlier is tagged but not yet published or not yet merged into $BRANCH; resuming it."
        finish+=("$earlier:$(tagged_date "$earlier")")
    fi
done

release_needed=false
ci_held=""
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$VERSION is not a stable version, so nothing is released."
elif [[ "${VERSION%%.*}" != "$expected_major" ]]; then
    echo "::error file=plugin.json::Version $VERSION does not belong on $BRANCH." >&2
    exit 1
elif tagged "$VERSION"; then
    if ours "$VERSION" && ! finished "$VERSION"; then
        tagged_today=$(tagged_date "$VERSION")
        echo "$VERSION is tagged but not yet published or not yet merged into $BRANCH; resuming it, dated $tagged_today."
        finish+=("$VERSION:$tagged_today")
    else
        echo "$VERSION is already released; nothing new to release."
    fi
else
    # Dating a scratch copy proves the entry exists and can be dated, before anything is pushed.
    scratch=$(mktemp)
    cp CHANGELOG.md "$scratch"
    dating_status=0
    dating_error=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
        --plugin-name "$PLUGIN_NAME" "$scratch" "$VERSION" "$TODAY" 2>&1) || dating_status=$?
    rm -f "$scratch"
    if (( dating_status != 0 )); then
        echo "::error file=CHANGELOG.md::plugin.json is at $VERSION, but its changelog entry cannot be dated: $dating_error" >&2
        exit 1
    fi
    # Only push runs are read, so neither this run nor another scheduled or dispatched one counts.
    # The newest run of each workflow decides, and a rerun keeps its run's id, so a passing rerun
    # clears a failure. A commit with no push runs, such as a merge by GITHUB_TOKEN, is released.
    head_sha=$(git rev-parse HEAD)
    ci_failed=""
    if [[ "${RELEASE_SKIP_CI_CHECK:-false}" == true ]]; then
        echo "::warning::skip-ci-check is set, so $VERSION is released from ${head_sha:0:12} whatever its CI says."
    else
        # Polls are counted, as for the held runs in merge_plugin_release_date_pr.sh, and the
        # deadline also ends the wait, so slow API reads cannot stretch it past the job's timeout.
        ci_polls=$(( (CI_WAIT_MINUTES * 60 + CI_POLL_SECONDS - 1) / CI_POLL_SECONDS ))
        ci_deadline=$(( SECONDS + CI_WAIT_MINUTES * 60 ))
        ci_running=""
        ci_read_failed=false
        while :; do
            # Read as nothing to release, an outage would leave the run green and the release a
            # week late; exiting would also hold back the earlier versions in finish.
            if ! read_ci_runs; then
                ci_failed="its CI runs could not be read (${ci_read_error:-no error was given})"
                ci_read_failed=true
                break
            fi
            # shellcheck disable=SC2016 # awk conditions: $3 and $4 are fields, not shell expansions.
            ci_failed=$(list_ci_runs '$3 == "completed" && $4 !~ /^(success|skipped|neutral)$/')
            # shellcheck disable=SC2016 # awk condition, as above.
            ci_running=$(list_ci_runs '$3 != "completed"')
            # A failure is final until someone reruns it, so only running CI is waited on.
            if [[ -n "$ci_failed" || -z "$ci_running" ]] || (( ci_polls-- <= 0 || SECONDS >= ci_deadline )); then
                break
            fi
            echo "Waiting for CI on ${head_sha:0:12}: $ci_running."
            sleep "$CI_POLL_SECONDS"
        done
        if [[ "$ci_read_failed" == false ]]; then
            ci_failed="$ci_failed${ci_failed:+${ci_running:+, }}$ci_running"
            [[ -z "$ci_failed" ]] || ci_failed="CI has not passed on it: $ci_failed"
        fi
    fi
    if [[ -n "$ci_failed" ]]; then
        ci_held="$VERSION is not released from ${head_sha:0:12}, because $ci_failed. Rerun the CI and then this workflow, or run it by hand with skip-ci-check if the failure is not the release's concern."
        echo "$ci_held"
    else
        echo "Releasing $VERSION, dated $TODAY."
        release_needed=true
        finish+=("$VERSION:$TODAY")
    fi
fi

emit "release_needed=$release_needed"
if (( ${#finish[@]} > 0 )); then
    emit "publish_needed=true"
else
    emit "publish_needed=false"
fi
emit "version=$VERSION"
emit "plugin_name=$PLUGIN_NAME"
emit "today=$TODAY"
emit "finish=${finish[*]}"
emit "ci_held=$ci_held"
