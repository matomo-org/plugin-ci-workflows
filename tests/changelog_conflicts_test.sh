#!/bin/bash
# Tests resolving a pull request's CHANGELOG.md conflict with its base branch and approving it again,
# with a bare origin standing in for GitHub and a fake gh.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/resolve_changelog_conflicts.sh"
RESOLVER="$ROOT/scripts/python/resolve_changelog_conflict.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
export GITHUB_REPOSITORY=matomo-org/plugin-Test RUNS_WAIT_SECONDS=0 RUNS_POLL_SECONDS=1

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

# --- The resolver on its own ---

resolve() {
    printf '%b' "$1" > "$WORK/conflicted.md"
    shift
    python3 -I "$RESOLVER" "$WORK/conflicted.md" "$@"
}

conflict='6.0.3\n<<<<<<< HEAD\n- PR\n||||||| 1\n=======\n- Base\n>>>>>>> base\n\n6.0.2 - 2026-10-05\n- Two\n'
[[ "$(resolve "$conflict" 6.0.2)" == "$(printf '6.0.3\n- Base\n- PR\n\n6.0.2 - 2026-10-05\n- Two')" ]] \
    || fail "the base branch's line should come first and the pull request's after it"
resolve "$conflict" 6.0.3 >/dev/null 2>&1 && fail "a tagged version should be left for a person"
resolve "${conflict/6.0.3/6.0.3 - 2026-11-01}" >/dev/null 2>&1 && fail "a dated version should be left for a person"
resolve "${conflict/6.0.3/6.0.3 (15/11/2026)}" >/dev/null 2>&1 && fail "a version dated another way should be left for a person"
resolve "${conflict/6.0.3/## 6.0.3 - Unreleased}" >/dev/null 2>&1 || fail "an Unreleased version should be resolved"
[[ "$(resolve "${conflict//\\n/\\r\\n}" | od -c)" == *'\r  \n'* ]] || fail "a changelog with CRLF line ends should be resolved"
resolve "${conflict/||||||| 1/||||||| 1\\n- Old}" >/dev/null 2>&1 && fail "a changed existing line should be left for a person"
resolve "${conflict/- PR/6.0.4\\n- PR}" >/dev/null 2>&1 && fail "a version line in the conflict should be left for a person"
resolve '- Two\n<<<<<<< HEAD\n- PR\n||||||| 1\n=======\n- Base\n>>>>>>> base\n' >/dev/null 2>&1 \
    && fail "a conflict under no version should be left for a person"
resolve '6.0.3\n- Two\n' >/dev/null 2>&1 && fail "a file with no conflict should not be printed as resolved"
reason=$(resolve "${conflict/- PR/PR prose}" 2>&1 >/dev/null) && fail "a line that is not a list item should be left"
[[ "$reason" == *'not a list item'* ]] || fail "the reason should be printed, got: $reason"

# --- The script, against a bare origin ---

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/bash
# FAKE_PRS is number:branch:decision:cross[:author] entries, read live from origin for each head.
# Every pull request has one approval, on its head unless FAKE_APPROVED_SHA names another commit,
# followed by a request for changes when FAKE_CHANGES_REQUESTED is set.
args="$*"
echo "$args" >> "$FAKE_GH_LOG"
filter() {
    local jq_filter='.'
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --jq ]]; then jq_filter="$2"; fi
        shift
    done
    jq -r "$jq_filter"
}
prs() {
    for entry in $FAKE_PRS; do
        IFS=: read -r number branch decision cross author <<< "$entry"
        jq -n --argjson n "$number" --arg b "$branch" --arg d "$decision" --argjson c "$cross" \
            --arg sha "$(git -C "$FAKE_ORIGIN" rev-parse "refs/heads/$branch")" --arg a "${author:-dev}" \
            '{number: $n, baseRefName: "6.x-dev", headRefName: $b, headRefOid: $sha, reviewDecision: $d,
              isCrossRepository: $c, state: "OPEN", author: {login: $a}}'
    done
}
case "$args" in
    'api user '*) [[ "$GH_TOKEN" == approver ]] && echo approver-user ;;
    'pr list '*) prs | jq -s . | filter "$@" ;;
    # FAKE_STALE_HEAD=n reports the head from before the resolved merge for the first n views after it.
    'pr view '*)
        # FAKE_TAG_ON_VIEW tags 6.x-dev with it on the first view, as a release made while the job runs.
        if [[ -n "${FAKE_TAG_ON_VIEW:-}" ]] && ! git -C "$FAKE_ORIGIN" rev-parse -q --verify "refs/tags/$FAKE_TAG_ON_VIEW" >/dev/null; then
            git -C "$FAKE_ORIGIN" tag "$FAKE_TAG_ON_VIEW" 6.x-dev
        fi
        view=$(prs | jq -s ".[] | select(.number == $3)")
        sha=$(jq -r .headRefOid <<< "$view")
        if [[ -n "${FAKE_STALE_HEAD:-}" ]] && git -C "$FAKE_ORIGIN" rev-parse -q --verify "$sha^2" >/dev/null \
            && (( $(wc -l < <(cat "$FAKE_ORIGIN.views" 2>/dev/null)) < FAKE_STALE_HEAD )); then
            echo >> "$FAKE_ORIGIN.views"
            view=$(jq --arg old "$(git -C "$FAKE_ORIGIN" rev-parse "$sha^1")" '.headRefOid = $old' <<< "$view")
        fi
        filter "$@" <<< "$view"
        ;;
    *'--method POST '*'/reviews '*) [[ "$GH_TOKEN" == approver ]] || exit 1 ;;
    *'/reviews?'*)
        [[ -z "${FAKE_REVIEWS_FAIL:-}" ]] || exit 1
        number="${args#*pulls/}" number="${number%%/*}"
        sha=$(prs | jq -r "select(.number == $number) | .headRefOid")
        cr="${FAKE_CHANGES_REQUESTED:-}"
        # FAKE_CHANGES_REQUESTED=after-push requests changes once the merge is on the branch.
        if [[ "$cr" == after-push ]] && ! git -C "$FAKE_ORIGIN" rev-parse -q --verify "$sha^2" >/dev/null; then
            cr=''
        fi
        # FAKE_APP_APPROVER adds an approval on the head from an app, whose permission cannot be read.
        jq -n --arg s "${FAKE_APPROVED_SHA:-$sha}" --arg h "$sha" --arg cr "$cr" --arg app "${FAKE_APP_APPROVER:-}" \
            '(if $app == "" then [] else [{user: {login: "app[bot]"}, state: "APPROVED", commit_id: $h}] end)
             + [{user: {login: "reviewer"}, state: "APPROVED", commit_id: $s}]
             + if $cr == "" then [] else [{user: {login: "other"}, state: "CHANGES_REQUESTED", commit_id: $h}] end' \
            | filter "$@"
        ;;
    # FAKE_PERMISSION is the reviewer's permission on the repository.
    # FAKE_PERMISSION_FAIL fails the reviewer's lookup too.
    *'/collaborators/app[bot]/permission'*) echo "HTTP 404" >&2; exit 1 ;;
    # FAKE_APPROVER_PERMISSION is the approver token's user's permission.
    *'/collaborators/approver-user/permission'*)
        jq -n --arg p "${FAKE_APPROVER_PERMISSION:-write}" '{permission: $p}' | filter "$@"
        ;;
    *'/collaborators/'*'/permission'*)
        [[ -z "${FAKE_PERMISSION_FAIL:-}" ]] || { echo "HTTP 502" >&2; exit 1; }
        jq -n --arg p "${FAKE_PERMISSION:-write}" '{permission: $p}' | filter "$@"
        ;;
    # Run 7 is of a workflow the base branch has; run 8, with FAKE_UNKNOWN_RUN, of one it does not.
    # FAKE_LIST_FAIL=once fails the first listing.
    *'/actions/runs?'*)
        if [[ -n "${FAKE_LIST_FAIL:-}" && ! -e "$FAKE_ORIGIN.listed" ]]; then
            touch "$FAKE_ORIGIN.listed"
            echo "HTTP 502" >&2
            exit 1
        fi
        jq -n --arg u "${FAKE_UNKNOWN_RUN:-}" '{workflow_runs: ([{id: 7, conclusion: "action_required", path: ".github/workflows/ci.yml@refs/pull/1/merge"}]
            + if $u == "" then [] else [{id: 8, conclusion: "action_required", path: ".github/workflows/added.yml@refs/pull/1/merge"}] end)}' \
            | filter "$@" ;;
    # FAKE_APPROVE_FAIL=always fails every held-run approval, =once only the first.
    *'/approve')
        case "${FAKE_APPROVE_FAIL:-}" in
            always) echo "HTTP 500" >&2; exit 1 ;;
            once) [[ -e "$FAKE_ORIGIN.failed" ]] || { touch "$FAKE_ORIGIN.failed"; echo "HTTP 500" >&2; exit 1; } ;;
        esac
        ;;
esac
SH
chmod +x "$FAKE_BIN/gh"
# FAKE_RESOLVER_CRASH makes the resolver fail as a crash would, not as a conflict left for a person.
cat > "$FAKE_BIN/python3" <<SH
#!/bin/bash
if [[ -n "\${FAKE_RESOLVER_CRASH:-}" && "\$*" == *resolve_changelog_conflict.py* ]]; then
    echo 'Traceback (most recent call last):' >&2
    exit 1
fi
exec $(command -v python3) "\$@"
SH
chmod +x "$FAKE_BIN/python3"
export PATH="$FAKE_BIN:$PATH"

CHANGELOG='## Changelog

6.0.3
- Three

6.0.2 - 2026-10-05
- Two
'

# Builds <name>/origin.git with 6.x-dev and 6.0.2 tagged, a pull request branch per further argument
# (name=line adds that changelog line, plus API.php if the name starts with "code"), then merges
# base=line into 6.x-dev, and leaves a clone at <name>/clone on 6.x-dev.
new_repo() {
    local name="$1" seed="$WORK/$1/seed"
    shift
    mkdir -p "$seed"
    git init -q -b 6.x-dev "$seed"
    printf '{"version":"6.0.3"}\n' > "$seed/plugin.json"
    printf '%s' "$CHANGELOG" > "$seed/CHANGELOG.md"
    printf '<?php\n' > "$seed/API.php"
    mkdir -p "$seed/.github/workflows"
    printf 'name: CI\n' > "$seed/.github/workflows/ci.yml"
    git -C "$seed" add .
    git -C "$seed" commit -q -m initial
    git -C "$seed" tag 6.0.2
    local spec branch line
    for spec in "$@"; do
        branch="${spec%%=*}" line="${spec#*=}"
        if [[ "$branch" == base ]]; then
            git -C "$seed" checkout -q 6.x-dev
        else
            git -C "$seed" checkout -q -b "$branch" 6.x-dev
            if [[ "$branch" == code* ]]; then printf '<?php\n// change\n' > "$seed/API.php"; fi
        fi
        sed -i "s/^- Three\$/- Three\n- $line/" "$seed/CHANGELOG.md"
        git -C "$seed" commit -q -am "$spec"
    done
    git -C "$seed" checkout -q 6.x-dev
    git clone -q --bare "$seed" "$WORK/$name/origin.git"
    git clone -q "$WORK/$name/origin.git" "$WORK/$name/clone"
    git -C "$WORK/$name/clone" fetch -q --tags
    export FAKE_ORIGIN="$WORK/$name/origin.git" FAKE_GH_LOG="$WORK/$name/gh.log"
    mkdir -p "$WORK/$name/tmp"
    export RUNNER_TEMP="$WORK/$name/tmp"
}

run() {
    local name="$1"
    shift
    (cd "$WORK/$name/clone" && APPROVER_TOKEN=approver GH_TOKEN=workflow bash "$SCRIPT" 6.x-dev "$@") \
        > "$WORK/$name/out" 2>&1
}

# An approved pull request whose only conflict is its changelog line is merged, resolved, pushed and
# approved again, with its line after the base branch's.
new_repo resolved feature=Feature base=Base
export FAKE_PRS='1:feature:APPROVED:false'
FAKE_UNKNOWN_RUN=1 run resolved && fail "a run left held should fail the job"
grep -q 'Left held run 8' "$WORK/resolved/out" || fail "a run of a workflow the base lacks should be left held"
grep -q 'runs/8/approve' "$FAKE_GH_LOG" && fail "a run of a workflow the base lacks should not be approved"
[[ "$(git -C "$FAKE_ORIGIN" show feature:CHANGELOG.md | sed -n '4,6p')" == "$(printf -- '- Three\n- Base\n- Feature')" ]] \
    || fail "the pushed changelog should hold the base line then the pull request's"
git -C "$FAKE_ORIGIN" merge-base --is-ancestor 6.x-dev feature || fail "the push should be a merge of 6.x-dev"
grep -q 'runs/7/approve' "$FAKE_GH_LOG" || fail "the held run should be approved"
grep -q "commit_id=$(git -C "$FAKE_ORIGIN" rev-parse feature)" "$FAKE_GH_LOG" \
    || fail "the approval should be pinned to the pushed merge"
(( $(grep -n 'POST .*/reviews' "$FAKE_GH_LOG" | cut -d: -f1) < $(grep -n '/actions/runs?' "$FAKE_GH_LOG" | head -1 | cut -d: -f1) )) \
    || fail "the pull request should be approved again straight after the push, before the wait for held runs"

# The same, when the pull request also changes code that merges cleanly.
new_repo code code=Code base=Base
export FAKE_PRS='1:code:APPROVED:false'
run code || fail "the run with a code change failed: $(cat "$WORK/code/out")"
git -C "$FAKE_ORIGIN" merge-base --is-ancestor 6.x-dev code || fail "a code change should not stop the resolve"

# Both sides opening the same new version: the pull request's version line is now the base branch's,
# which is not a change to what was approved.
new_repo bump feature=Feature
seed="$WORK/bump/seed"
for side in feature 6.x-dev; do
    git -C "$seed" checkout -q "$side"
    git -C "$seed" reset -q --hard "$(git -C "$seed" rev-list --max-parents=0 HEAD)"
    sed -i "s/^## Changelog\$/## Changelog\n\n6.0.4\n- $side/" "$seed/CHANGELOG.md"
    git -C "$seed" commit -q -am "$side"
done
git -C "$FAKE_ORIGIN" fetch -q "$seed" '+refs/heads/*:refs/heads/*'
export FAKE_PRS='1:feature:APPROVED:false'
run bump || fail "the run with a shared new version failed: $(cat "$WORK/bump/out")"
[[ "$(git -C "$FAKE_ORIGIN" show feature:CHANGELOG.md | sed -n '3,5p')" == "$(printf -- '6.0.4\n- 6.x-dev\n- feature')" ]] \
    || fail "a shared new version should hold both lines"
grep -q 'POST .*/reviews' "$FAKE_GH_LOG" || fail "a shared new version should be approved again"

# Not approved, from a fork, opened by the approver, approved on an older commit, or with changes
# requested: nothing is pushed or approved.
for case in 'unapproved:REVIEW_REQUIRED:false' 'fork:APPROVED:true' 'own:APPROVED:false:approver-user' \
    'stale:APPROVED:false' 'changes:APPROVED:false'; do
    IFS=: read -r name decision cross author <<< "$case"
    new_repo "$name" feature=Feature base=Base
    before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
    export FAKE_PRS="1:feature:$decision:$cross:$author"
    FAKE_APPROVED_SHA='' FAKE_CHANGES_REQUESTED=''
    [[ "$name" == stale ]] && FAKE_APPROVED_SHA=$(git -C "$FAKE_ORIGIN" rev-parse 6.x-dev)
    [[ "$name" == changes ]] && FAKE_CHANGES_REQUESTED=1
    export FAKE_APPROVED_SHA FAKE_CHANGES_REQUESTED
    run "$name" || fail "the $name run failed: $(cat "$WORK/$name/out")"
    [[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "the $name pull request should be left alone"
done
unset FAKE_APPROVED_SHA FAKE_CHANGES_REQUESTED

# Approved on its head only by someone without write access: nothing is pushed or approved.
new_repo readonly feature=Feature base=Base
export FAKE_PRS='1:feature:APPROVED:false'
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
FAKE_PERMISSION='read' run readonly || fail "the readonly run failed: $(cat "$WORK/readonly/out")"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "an approval without write access should not be carried forward"
grep -q 'from someone with write access' "$WORK/readonly/out" || fail "the notice should mention write access"

# An app's approval whose permission cannot be read does not stop a write-access approval counting.
new_repo app feature=Feature base=Base
FAKE_APP_APPROVER=1 run app || fail "the app run failed: $(cat "$WORK/app/out")"
git -C "$FAKE_ORIGIN" merge-base --is-ancestor 6.x-dev feature || fail "a write-access approval beside an app's should be carried forward"

# No approver's permission can be read: nothing is pushed, and the job fails.
new_repo nopermission feature=Feature base=Base
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
FAKE_PERMISSION_FAIL=1 run nopermission && fail "an unreadable permission should fail the job"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a pull request whose approver's permission cannot be read should be left alone"

# GitHub showing the old head for a moment after the push: the approval waits for the new one.
new_repo lag feature=Feature base=Base
FAKE_STALE_HEAD=2 HEAD_POLL_SECONDS=1 HEAD_WAIT_SECONDS=5 run lag || fail "the lag run failed: $(cat "$WORK/lag/out")"
grep -q 'POST .*/reviews' "$FAKE_GH_LOG" || fail "the approval should wait for GitHub to show the pushed head"

# A pull request from a development branch is never merged into from its base.
new_repo devbranch 5.x-dev=Feature base=Base
export FAKE_PRS='1:5.x-dev:APPROVED:false'
before=$(git -C "$FAKE_ORIGIN" rev-parse 5.x-dev)
run devbranch || fail "the devbranch run failed: $(cat "$WORK/devbranch/out")"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse 5.x-dev)" == "$before" ]] || fail "a development branch should be left alone"
grep -q 'is a development branch' "$WORK/devbranch/out" || fail "the notice should say it is a development branch"

# The resolver crashing fails the job instead of passing as a conflict left for a person.
new_repo crash feature=Feature base=Base
export FAKE_PRS='1:feature:APPROVED:false'
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
FAKE_RESOLVER_CRASH=1 run crash && fail "a resolver crash should fail the job"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a pull request the resolver crashed on should be left alone"
grep -q 'resolver failed on #1' "$WORK/crash/out" || fail "the warning should say the resolver failed"

# A run listing that fails once and then succeeds does not fail the job.
new_repo listing feature=Feature base=Base
FAKE_LIST_FAIL=once RUNS_WAIT_SECONDS=1 run listing || fail "a run listing that recovers should not fail the job: $(cat "$WORK/listing/out")"
grep -q 'runs/7/approve' "$FAKE_GH_LOG" || fail "the held run should be approved once the listing recovers"

# A line both sides added elsewhere drops out of the pull request's diff, so it is not approved again.
new_repo same feature=Feature base=Base
seed="$WORK/same/seed"
for side in feature 6.x-dev; do
    git -C "$seed" checkout -q "$side" && printf '<?php\n// same\n' > "$seed/API.php" && git -C "$seed" commit -q -am same
done
git -C "$FAKE_ORIGIN" fetch -q "$seed" '+refs/heads/*:refs/heads/*'
export FAKE_PRS='1:feature:APPROVED:false'
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
run same || fail "the run with a shared line failed"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a changed diff should be left alone"
grep -q 'would change what it adds or removes' "$WORK/same/out" || fail "the notice should say the diff would change"

# The same for an added line that reads like a diff file header.
new_repo header feature=Feature base=Base
seed="$WORK/header/seed"
for side in feature 6.x-dev; do
    git -C "$seed" checkout -q "$side" && printf '<?php\n++ same\n' > "$seed/API.php" && git -C "$seed" commit -q -am same
done
git -C "$FAKE_ORIGIN" fetch -q "$seed" '+refs/heads/*:refs/heads/*'
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
run header || fail "the run with a header-like line failed"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a changed diff of header-like lines should be left alone"

# A pull request that changes a workflow would have its own workflow code run, so it is left alone.
new_repo workflow feature=Feature base=Base
seed="$WORK/workflow/seed"
git -C "$seed" checkout -q feature && printf 'name: Changed\n' > "$seed/.github/workflows/ci.yml" && git -C "$seed" commit -q -am workflow
git -C "$FAKE_ORIGIN" fetch -q "$seed" '+refs/heads/*:refs/heads/*'
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
run workflow || fail "the run with a workflow change failed"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a workflow change should be left alone"
grep -q 'it changes workflows' "$WORK/workflow/out" || fail "the notice should say it changes workflows"

# Changes requested after the push: resolved, but not approved again.
new_repo late feature=Feature base=Base
FAKE_CHANGES_REQUESTED=after-push run late && fail "a pull request not approved again should fail the job"
git -C "$FAKE_ORIGIN" merge-base --is-ancestor 6.x-dev feature || fail "the merge should still be pushed"
grep -q 'POST .*/reviews' "$FAKE_GH_LOG" && fail "changes requested after the push should stop the approval"

# The reviews cannot be read: nothing is pushed, and the job fails rather than passing as a skip.
new_repo unreadable feature=Feature base=Base
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
FAKE_REVIEWS_FAIL=1 run unreadable && fail "unreadable reviews should fail the job"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a pull request whose reviews cannot be read should be left alone"

# A held-run approval that fails once is tried again on the next poll; one that never goes through
# fails the job with GitHub's error.
new_repo retry feature=Feature base=Base
FAKE_APPROVE_FAIL=once RUNS_WAIT_SECONDS=1 run retry || fail "a held-run approval should be tried again: $(cat "$WORK/retry/out")"
new_repo held feature=Feature base=Base
FAKE_APPROVE_FAIL=always run held && fail "a held run never approved should fail the job"
grep -q 'Could not approve held run 7: HTTP 500' "$WORK/held/out" || fail "the warning should carry GitHub's error"

new_repo clean feature=Feature
export FAKE_PRS='1:feature:APPROVED:false'
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
run clean || fail "the clean run failed"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a pull request with no conflict should be left alone"
grep -q 'POST .*/reviews' "$FAKE_GH_LOG" && fail "a pull request with no conflict should not be approved"

# A conflict beyond CHANGELOG.md is left for a person, with a notice.
new_repo plugin feature=Feature base=Base
seed="$WORK/plugin/seed"
git -C "$seed" checkout -q feature && printf '{"version":"6.0.4"}\n' > "$seed/plugin.json" && git -C "$seed" commit -q -am bump
git -C "$seed" checkout -q 6.x-dev && printf '{"version":"6.0.5"}\n' > "$seed/plugin.json" && git -C "$seed" commit -q -am bump
git -C "$FAKE_ORIGIN" fetch -q "$seed" '+refs/heads/*:refs/heads/*'
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
run plugin || fail "the run with a plugin.json conflict failed"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a plugin.json conflict should be left alone"
grep -q 'does not conflict in CHANGELOG.md alone: CHANGELOG.md plugin.json' "$WORK/plugin/out" || fail "the notice should name the files"

# A conflict landing in a released version is left for a person.
new_repo released feature=Feature base=Base
git -C "$FAKE_ORIGIN" tag 6.0.3 6.x-dev
git -C "$WORK/released/clone" fetch -q --tags
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
run released || fail "the run against a released version failed"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a line landing in a released version should be left alone"
grep -q 'which is released' "$WORK/released/out" || fail "the notice should say the version is released"

# A version tagged after the job started is still treated as released.
new_repo tagged feature=Feature base=Base
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
FAKE_TAG_ON_VIEW=6.0.3 run tagged || fail "the run with a version tagged meanwhile failed: $(cat "$WORK/tagged/out")"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "a line landing in a version tagged meanwhile should be left alone"
grep -q 'which is released' "$WORK/tagged/out" || fail "the notice should say the version is released"

# Without the approver token nothing is resolved.
new_repo noapprover feature=Feature base=Base
export FAKE_PRS='1:feature:APPROVED:false'
(cd "$WORK/noapprover/clone" && GH_TOKEN=workflow bash "$SCRIPT" 6.x-dev) >/dev/null 2>&1 \
    && fail "a run without the approver token should fail"

# An approver token whose user cannot write: nothing is pushed, and the job fails.
new_repo readapprover feature=Feature base=Base
before=$(git -C "$FAKE_ORIGIN" rev-parse feature)
FAKE_APPROVER_PERMISSION='read' run readapprover && fail "an approver without write access should fail the job"
[[ "$(git -C "$FAKE_ORIGIN" rev-parse feature)" == "$before" ]] || fail "nothing should be pushed when the approver cannot write"
grep -q 'needs write access' "$WORK/readapprover/out" || fail "the error should say the approver needs write access"

# The workflow files: a nested call gets no more permissions than its caller job grants, and a
# failed push run would hold the weekly release.
problems=$(python3 - "$ROOT/.github/workflows" <<'EOF'
import sys, yaml
def load(name):
    with open(f"{sys.argv[1]}/{name}") as handle:
        return yaml.safe_load(handle)
umbrella = load("plugin-after-merge.yml").get("jobs", {}).get("changelog-conflicts") or {}
called = load("plugin-changelog-conflicts.yml").get("jobs", {}).get("resolve") or {}
if not umbrella.get("uses", "").startswith("matomo-org/plugin-ci-workflows/.github/workflows/plugin-changelog-conflicts.yml@"):
    print("the after-merge job does not call plugin-changelog-conflicts.yml")
if umbrella.get("with", {}).get("workflows-ref") != "${{ inputs.workflows-ref }}":
    print("the after-merge job does not pass workflows-ref")
if umbrella.get("secrets", {}).get("approver-token") != "${{ secrets.approver-token }}":
    print("the after-merge job does not pass approver-token")
for scope, level in called.get("permissions", {}).items():
    if umbrella.get("permissions", {}).get(scope) != level:
        print(f"the after-merge job does not grant {scope}: {level}, which the resolve job needs")
if called.get("continue-on-error") != "${{ github.event_name == 'push' }}":
    print("the resolve job can fail a push run")
EOF
) || fail "the workflow files could not be read"
[[ -z "$problems" ]] || fail "$problems"

echo "PASS - changelog conflict resolution"
