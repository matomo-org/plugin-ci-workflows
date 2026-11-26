#!/bin/bash
# Merges the base branch into each approved pull request against it whose only conflict is one
# resolve_changelog_conflict.py can resolve, pushes the merge, and has the approver token approve it
# again, so a pull request that conflicts only on its changelog line can still be merged as approved.
# The approval carried forward must come from someone with write access.
#
# Only a pull request from a branch of this repository is touched, and only while its newest approval
# is on its current head and nobody has requested changes: that approval is what gets carried forward,
# so it is checked again just before the push and before approving. It is approved again only when,
# file by file, the lines it adds and removes are the same before and after the merge, apart from a
# version or blank line the base branch now has too. The merge is pushed with the workflow's token, so
# the approver is not the last pusher, and the pull_request runs that push leaves held are approved;
# a pull request that changes a workflow is left alone, so those runs only run the base branch's
# workflows. Anything else is left as it was, with a notice saying why.
# Usage: resolve_changelog_conflicts.sh <base-branch> [pull request number]

set -euo pipefail

BASE_BRANCH="${1:-}"
ONLY_PR="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/../python/resolve_changelog_conflict.py"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
RUNS_WAIT_SECONDS="${RUNS_WAIT_SECONDS:-120}"
RUNS_POLL_SECONDS="${RUNS_POLL_SECONDS:-15}"
HEAD_WAIT_SECONDS="${HEAD_WAIT_SECONDS:-30}"
HEAD_POLL_SECONDS="${HEAD_POLL_SECONDS:-3}"

if [[ ! "$BASE_BRANCH" =~ ^[0-9A-Za-z._/-]+$ ]]; then
    echo "Usage: resolve_changelog_conflicts.sh <base-branch> [pull request number]" >&2
    exit 1
fi
if [[ -n "$ONLY_PR" && ! "$ONLY_PR" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::'$ONLY_PR' is not a pull request number." >&2
    exit 1
fi
if [[ -z "${APPROVER_TOKEN:-}" ]]; then
    # Resolving without approving again would dismiss the approval, which is no better than by hand.
    echo "::error::No approver token, so no conflict was resolved. Pass approver-token under secrets:." >&2
    exit 1
fi
if ! approver=$(GH_TOKEN="$APPROVER_TOKEN" gh api user --jq .login 2>&1); then
    echo "::error::Could not look up the approver token's user: $approver" >&2
    exit 1
fi
# GitHub accepts an approval from a user without write access but does not count it, so the push
# would dismiss the real approval for nothing.
if ! approver_permission=$(gh api "repos/$GITHUB_REPOSITORY/collaborators/$approver/permission" --jq .permission 2>&1); then
    echo "::error::Could not look up $approver's permission on $GITHUB_REPOSITORY: $approver_permission" >&2
    exit 1
fi
if [[ "$approver_permission" != admin && "$approver_permission" != write ]]; then
    echo "::error::The approver token's user $approver has $approver_permission access to $GITHUB_REPOSITORY, so its approval would not count, and no conflict was resolved. It needs write access." >&2
    exit 1
fi

git config user.name "$BOT_NAME"
git config user.email "$BOT_EMAIL"
git config merge.conflictStyle zdiff3
git fetch --quiet --tags origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH"
base_sha=$(git rev-parse "refs/remotes/origin/$BASE_BRANCH")
# Held runs are approved only for these, so a run is never approved for a workflow the branch lacks.
base_workflows=" $(git ls-tree --name-only "$base_sha" .github/workflows/ | paste -sd' ') "

# Prints "file<TAB>+line" or "file<TAB>-line" for each line a diff adds or removes, sorted.
changed_lines() {
    git diff --no-color --no-ext-diff --no-renames -U0 "$@" \
        | awk '/^diff --git / { file = substr($4, 3); header = 1; next }
               /^@@ / { header = 0; next }
               header { next }
               /^[+-]/ { print file "\t" $0 }' \
        | LC_ALL=C sort
}

skip() {
    echo "::notice::#$pr was left as it is, because $1"
}

# Succeeds while the pull request is open against the base, from the same head, with no reviewer whose
# newest decisive review requests changes and, unless decision is "any", an approval on that head from
# someone with write access. Returns 1 when it is not, and 2 when GitHub could not be asked.
still_approved() {
    local pr="$1" sha="$2" decision="${3:-APPROVED}" state user permission unreadable=0
    state=$(gh pr view "$pr" --json state,baseRefName,headRefOid,reviewDecision \
        --jq '"\(.state) \(.baseRefName) \(.headRefOid) \(.reviewDecision)"') || return 2
    [[ "$state" == "OPEN $BASE_BRANCH $sha "* ]] || return 1
    [[ "$decision" == any || "$state" == *" APPROVED" ]] || return 1
    state=$(gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$pr/reviews?per_page=100" \
        --jq '.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | "\(.user.login) \(.state) \(.commit_id)"') \
        || return 2
    # Prints the reviewers whose newest decisive review approves sha, or fails if any requests changes.
    state=$(awk -v sha="$sha" '{ last[$1] = $2 " " $3 } END {
            for (u in last) { split(last[u], s, " "); if (s[1] == "CHANGES_REQUESTED") exit 1 }
            for (u in last) { split(last[u], s, " "); if (s[2] == sha) print u } }' <<< "$state") || return 1
    [[ "$decision" != any ]] || return 0
    # Sorted, so the order approvers are looked up in does not depend on awk.
    state=$(LC_ALL=C sort <<< "$state")
    # An approval from someone without write access does not count towards merging, so it is not carried forward.
    # A login whose permission cannot be read, such as an app's, does not stop another approver counting.
    while read -r user; do
        [[ -n "$user" ]] || continue
        if ! permission=$(gh api "repos/$GITHUB_REPOSITORY/collaborators/$user/permission" --jq .permission 2>/dev/null); then
            unreadable=1
            continue
        fi
        [[ "$permission" != admin && "$permission" != write ]] || return 0
    done <<< "$state"
    return $(( unreadable ? 2 : 1 ))
}

# Skips the pull request with a notice when still_approved fails, and fails the job when GitHub could
# not be asked, since that is not a decision about the pull request.
check_approved() {
    local result=0
    still_approved "$@" || result=$?
    if (( result == 2 )); then
        echo "::warning::Could not read #$pr's state or reviews, so it was left as it is."
        status=1
    elif (( result == 1 )); then
        skip "it is no longer open against $BASE_BRANCH on the same head, has no approval on that head from someone with write access, or changes are requested."
    fi
    return "$result"
}

# Approves the pushed merge straight away, since an approval a person withdraws between the push and
# this cannot be told apart from the one the push dismissed. Checks the pull request is still as pushed
# and nobody has requested changes since.
approve_again() {
    local pr="$1" sha="$2" pushed_over="$3" out waited=0
    # GitHub moves the pull request's head a moment after the push, not with it.
    while (( waited < HEAD_WAIT_SECONDS )) \
        && [[ "$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null)" == "$pushed_over" ]]; do
        sleep "$HEAD_POLL_SECONDS"
        waited=$(( waited + HEAD_POLL_SECONDS ))
    done
    if ! still_approved "$pr" "$sha" any; then
        echo "::warning::Resolved #$pr, but did not approve it again, since it changed, changes were requested, or it could not be read."
        status=1
        return
    fi
    # With commit_id, GitHub refuses (422) once someone has pushed on top of the merge.
    if ! out=$(GH_TOKEN="$APPROVER_TOKEN" gh api --method POST "repos/$GITHUB_REPOSITORY/pulls/$pr/reviews" \
        -f event=APPROVE -f "commit_id=$sha" \
        -f "body=Merged $BASE_BRANCH and resolved the CHANGELOG.md conflict; the pull request's own changes are as approved before, so the approval stands." \
        2>&1 >/dev/null); then
        echo "::warning::Resolved #$pr, but could not approve it again, so it needs a new review: $out"
        status=1
    fi
}

status=0
filter='.[] | select(.isCrossRepository == false and .reviewDecision == "APPROVED")
    | "\(.number) \(.headRefOid) \(.author.login) \(.headRefName)"'
if [[ -n "$ONLY_PR" ]]; then
    candidates=$(gh pr view "$ONLY_PR" --json number,baseRefName,headRefOid,headRefName,isCrossRepository,reviewDecision,state,author \
        --jq "[select(.state == \"OPEN\" and .baseRefName == \"$BASE_BRANCH\")] | $filter")
    if [[ -z "$candidates" ]]; then
        echo "::notice::#$ONLY_PR is not an open, approved pull request from this repository against $BASE_BRANCH. Run this on the branch it targets."
    fi
else
    # Far beyond the open pull requests any plugin has; gh pages through them.
    open_prs=$(gh pr list --base "$BASE_BRANCH" --state open --limit 1000 \
        --json number,headRefOid,headRefName,isCrossRepository,reviewDecision,author)
    if [[ "$(jq length <<< "$open_prs")" -ge 1000 ]]; then
        echo "::warning::Only the first 1000 open pull requests against $BASE_BRANCH were checked."
        status=1
    fi
    candidates=$(jq -r "$filter" <<< "$open_prs")
fi

pushed=()
while read -r pr head_sha author head_ref; do
    [[ -n "$pr" ]] || continue
    if [[ "$author" == "$approver" ]]; then
        skip "the approver token's user opened it, and GitHub refuses an approval of one's own pull request."
        continue
    fi
    if [[ "$head_ref" =~ ^[0-9]+\.x-dev$ ]]; then
        skip "its branch $head_ref is a development branch, which $BASE_BRANCH is not merged into."
        continue
    fi
    if ! git fetch --quiet --no-tags origin "+refs/heads/$head_ref:refs/remotes/origin/$head_ref" 2>/dev/null \
        || [[ "$(git rev-parse "refs/remotes/origin/$head_ref")" != "$head_sha" ]]; then
        skip "its branch moved on or went away while this ran."
        continue
    fi
    check_approved "$pr" "$head_sha" || continue
    git checkout --quiet --detach "$head_sha"
    if git merge --quiet --no-edit "$base_sha" >/dev/null 2>&1; then
        # A clean merge is GitHub's Update branch, which needs nothing from this.
        git reset --quiet --hard "$head_sha"
        continue
    fi
    conflicted=$(git diff --name-only --diff-filter=U)
    if [[ "$conflicted" != CHANGELOG.md ]]; then
        git merge --abort 2>/dev/null || git reset --quiet --hard "$head_sha"
        skip "it does not conflict in CHANGELOG.md alone: $(echo "${conflicted:-the merge failed without a conflict}" | paste -sd' ')."
        continue
    fi
    # Tags again for each pull request, since the weekly release may tag a version while this runs.
    if ! out=$(git fetch --quiet --no-tags origin '+refs/tags/*:refs/tags/*' 2>&1); then
        git merge --abort
        echo "::warning::Could not fetch the tags, so #$pr was left as it is: $out"
        status=1
        continue
    fi
    mapfile -t released < <(git tag -l | sed 's/^v//')
    resolver_status=0
    reason=$(python3 -I "$RESOLVER" CHANGELOG.md "${released[@]}" 2>&1 >"$RUNNER_TEMP/CHANGELOG.md") || resolver_status=$?
    if (( resolver_status == 2 )); then
        git merge --abort
        skip "${reason#CHANGELOG.md was left for a person, because }"
        continue
    elif (( resolver_status != 0 )); then
        git merge --abort
        echo "::warning::The CHANGELOG.md resolver failed on #$pr, so it was left as it is: $reason"
        status=1
        continue
    fi
    cp "$RUNNER_TEMP/CHANGELOG.md" CHANGELOG.md
    git add CHANGELOG.md
    git commit --quiet --no-edit -m "Merge $BASE_BRANCH into $head_ref, resolving the CHANGELOG.md conflict"
    merge_sha=$(git rev-parse HEAD)

    # Lines the pull request no longer adds may only be version or blank lines the base branch now has too.
    before=$(changed_lines "$base_sha...$head_sha")
    after=$(changed_lines "$base_sha" "$merge_sha")
    gained=$(LC_ALL=C comm -13 <(echo "$before") <(echo "$after"))
    lost=$(LC_ALL=C comm -23 <(echo "$before") <(echo "$after") \
        | grep -vxF -f <(git show "$base_sha:CHANGELOG.md" | grep -E '^(#*[[:blank:]]*v?[0-9]+\.[0-9]+\.[0-9]+|[[:space:]]*$)' \
            | sed 's/^/CHANGELOG.md\t+/') || true)
    if [[ -n "$gained" || -n "$lost" ]]; then
        skip "resolving the conflict would change what it adds or removes."
        git reset --quiet --hard "$head_sha"
        continue
    fi
    # The workflow's token cannot push a commit that changes a workflow.
    if [[ -n "$(git diff --name-only "$head_sha" "$merge_sha" -- .github/workflows/)" ]]; then
        skip "the merge brings in workflow changes from $BASE_BRANCH, which this token cannot push. Use Update branch first."
        git reset --quiet --hard "$head_sha"
        continue
    fi
    # Its held runs would run the pull request's own workflow code, which is not this job's to approve.
    if [[ -n "$(git diff --name-only "$base_sha" "$merge_sha" -- .github/workflows/)" ]]; then
        skip "it changes workflows, and the runs they would hold are not approved by this."
        git reset --quiet --hard "$head_sha"
        continue
    fi

    check_approved "$pr" "$head_sha" || continue
    if ! out=$(git push --quiet origin "$merge_sha:refs/heads/$head_ref" 2>&1); then
        # A plain push fails rather than overwrite anything pushed since the fetch.
        if git fetch --quiet --no-tags origin "+refs/heads/$head_ref:refs/remotes/origin/$head_ref" 2>/dev/null \
            && [[ "$(git rev-parse "refs/remotes/origin/$head_ref")" != "$head_sha" ]]; then
            skip "its branch moved on while this ran."
        else
            echo "::warning::Could not push the resolved merge to #$pr: $out"
            status=1
        fi
        continue
    fi
    echo "Resolved the CHANGELOG.md conflict on #$pr with ${merge_sha:0:12}."
    pushed+=("$pr $merge_sha")
    approve_again "$pr" "$merge_sha" "$head_sha"
done <<< "$candidates"

if (( ${#pushed[@]} == 0 )); then
    exit "$status"
fi

# One wait for every push, approving each held pull_request run of a workflow the base branch has.
polls=$(( RUNS_WAIT_SECONDS / RUNS_POLL_SECONDS ))
approved=" "
# The last error of each held run whose approval failed and is tried again on the next poll.
declare -A failed_runs=()
# The error of each head whose runs could not be listed on the latest poll.
declare -A failed_lists=()
while :; do
    for entry in "${pushed[@]}"; do
        sha="${entry#* }"
        if ! runs=$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$sha&event=pull_request&per_page=100" \
            --jq '.workflow_runs[] | "\(.id) \(.conclusion) \(.path)"' 2>&1); then
            failed_lists[$sha]="$runs"
            continue
        fi
        unset "failed_lists[$sha]"
        while read -r run_id conclusion path; do
            if [[ -n "$run_id" && "$conclusion" != action_required ]]; then
                # Approved or cancelled by someone else since.
                unset "failed_runs[$run_id]"
            fi
            if [[ -z "$run_id" || "$conclusion" != action_required || "$approved" == *" $run_id "* ]]; then
                continue
            fi
            if [[ "$base_workflows" != *" ${path%%@*} "* ]]; then
                approved+="$run_id "
                echo "::warning::Left held run $run_id of $path, which $BASE_BRANCH does not have."
                status=1
            elif out=$(gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runs/$run_id/approve" 2>&1); then
                approved+="$run_id "
                unset "failed_runs[$run_id]"
                echo "Approved held run $run_id."
            else
                failed_runs[$run_id]="$out"
            fi
        done <<< "$runs"
    done
    if (( polls-- <= 0 )); then
        break
    fi
    sleep "$RUNS_POLL_SECONDS"
done
for run_id in "${!failed_runs[@]}"; do
    echo "::warning::Could not approve held run $run_id: ${failed_runs[$run_id]}"
    status=1
done
for sha in "${!failed_lists[@]}"; do
    echo "::warning::Could not list the runs on ${sha:0:12}: ${failed_lists[$sha]}"
    status=1
done
exit "$status"
