#!/bin/bash
# Tests merging a production branch back into its development branch after a release.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/backmerge_plugin_release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "$*" >&2
    exit 1
}

# Builds a remote whose 6.x-dev and 6.x-prod share a changelog, then a clone of it on 6.x-prod.
setup() {
    local name="$1"
    REMOTE="$WORK/$name.git"
    REPO="$WORK/$name"
    git init --bare -q "$REMOTE"
    git init -q -b 6.x-prod "$REPO"
    git -C "$REPO" config user.email test@example.com
    git -C "$REPO" config user.name Test
    printf '## Changelog\n\n* 6.0.1 Fixed a bug\n* 6.0.0 - 2026-09-01 Initial\n' > "$REPO/CHANGELOG.md"
    git -C "$REPO" add CHANGELOG.md
    git -C "$REPO" commit -q -m initial
    git -C "$REPO" remote add origin "$REMOTE"
    git -C "$REPO" push -q origin 6.x-prod 6.x-prod:6.x-dev
}

commit_on() {
    local branch="$1" message="$2" script="$3"
    git -C "$REPO" fetch -q origin
    git -C "$REPO" checkout -q -B "work-$branch" "origin/$branch"
    sed -i "$script" "$REPO/CHANGELOG.md"
    git -C "$REPO" commit -q -am "$message"
    git -C "$REPO" push -q origin "HEAD:refs/heads/$branch"
    git -C "$REPO" fetch -q origin
}

date_on_prod() {
    commit_on 6.x-prod "Add release date for 6.0.1" 's/^\* 6\.0\.1 /* 6.0.1 - 2026-10-05 - /'
    git -C "$REPO" tag 6.0.1
    git -C "$REPO" push -q origin refs/tags/6.0.1
}

reject_dev_pushes() {
    cat > "$REMOTE/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read -r old new ref; do [ "$ref" != refs/heads/6.x-dev ] || exit 1; done
EOF
    chmod +x "$REMOTE/hooks/pre-receive"
}

run_backmerge() {
    git -C "$REPO" checkout -q --detach origin/6.x-prod
    (cd "$REPO" && bash "$SCRIPT" 6.0.1 6.x-prod) > "$WORK/out" 2>&1
}

prod_in_dev() {
    git -C "$REMOTE" merge-base --is-ancestor refs/heads/6.x-prod refs/heads/6.x-dev
}

# A development branch with nothing new is fast-forwarded, without a merge commit.
setup fast-forward
date_on_prod
run_backmerge || fail "fast-forward: $(cat "$WORK/out")"
test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$(git -C "$REMOTE" rev-parse 6.x-prod)" \
    || fail 'fast-forward: 6.x-dev should point at the released commit'

# Running again once dev contains prod is a no-op, so a resumed release can repeat the step.
dev_before=$(git -C "$REMOTE" rev-parse 6.x-dev)
run_backmerge || fail "repeat: $(cat "$WORK/out")"
grep -Fq 'nothing to merge back' "$WORK/out" || fail 'repeat: expected a no-op'
test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$dev_before" || fail 'repeat: 6.x-dev must not move'

# Dev moved on elsewhere in the file: a merge commit brings the date across.
setup diverged
commit_on 6.x-dev "Document the next fix" "\$a * 5.9.9 - 2026-01-01 Old entry kept at the bottom"
date_on_prod
dev_before=$(git -C "$REMOTE" rev-parse 6.x-dev)
run_backmerge || fail "diverged: $(cat "$WORK/out")"
prod_in_dev || fail 'diverged: 6.x-dev should contain 6.x-prod'
test "$(git -C "$REMOTE" rev-list --parents -n 1 6.x-dev | wc -w)" = 3 \
    || fail 'diverged: 6.x-dev should end in a merge commit'
test "$(git -C "$REMOTE" rev-parse '6.x-dev^1')" = "$dev_before" \
    || fail 'diverged: the first parent should be the previous 6.x-dev'
git -C "$REMOTE" show 6.x-dev:CHANGELOG.md | grep -Fqx '* 6.0.1 - 2026-10-05 - Fixed a bug' \
    || fail 'diverged: the release date should reach 6.x-dev'
git -C "$REMOTE" show 6.x-dev:CHANGELOG.md | grep -Fqx '* 5.9.9 - 2026-01-01 Old entry kept at the bottom' \
    || fail "diverged: 6.x-dev's own change should survive"

# The next entry was already added next to the dated line: fail loudly and leave dev untouched.
setup conflict
commit_on 6.x-dev "Add 6.0.2" 's/^\* 6\.0\.1 /* 6.0.2 Next fix\n&/'
date_on_prod
dev_before=$(git -C "$REMOTE" rev-parse 6.x-dev)
if run_backmerge; then
    fail 'conflict: a conflicting back-merge must fail'
fi
grep -Fq '::error::6.0.1 is released, but could not be merged back into 6.x-dev: the merge conflicts in CHANGELOG.md' "$WORK/out" \
    || fail "conflict: unexpected output: $(cat "$WORK/out")"
test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$dev_before" || fail 'conflict: 6.x-dev must not move'
test -z "$(git -C "$REPO" status --porcelain)" || fail 'conflict: the workspace must be left untouched'

# Production moved on after the tag: only the released commit reaches dev.
setup moved-on
date_on_prod
commit_on 6.x-prod "Start 6.0.2" 's/^## Changelog$/&\n\n* 6.0.2 Unreleased/'
run_backmerge || fail "moved-on: $(cat "$WORK/out")"
test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$(git -C "$REMOTE" rev-parse '6.0.1^{commit}')" \
    || fail 'moved-on: 6.x-dev should stop at the release tag'

# Histories git refuses to merge fail the step with an error rather than a git usage message.
setup unrelated
git -C "$REPO" checkout -q --orphan orphan
git -C "$REPO" commit -q -m 'Unrelated history'
git -C "$REPO" push -q -f origin HEAD:refs/heads/6.x-dev
date_on_prod
if run_backmerge; then
    fail 'unrelated: merging unrelated histories must fail'
fi
grep -Fq '::error::6.0.1 is released, but could not be merged back into 6.x-dev: 6.x-dev and 6.0.1 share no history' "$WORK/out" \
    || fail "unrelated: unexpected output: $(cat "$WORK/out")"

# A rejected push, as from a protection rule, fails the step and leaves dev where it was.
setup rejected
commit_on 6.x-dev "Document the next fix" "\$a * 5.9.9 - 2026-01-01 Old entry kept at the bottom"
date_on_prod
reject_dev_pushes
dev_before=$(git -C "$REMOTE" rev-parse 6.x-dev)
if run_backmerge; then
    fail 'rejected: a rejected push must fail'
fi
grep -Fq 'the push failed. Merge it by hand.' "$WORK/out" \
    || fail "rejected: unexpected output: $(cat "$WORK/out")"
test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$dev_before" || fail 'rejected: 6.x-dev must not move'

# The same rejection on the fast-forward path.
setup rejected-ff
date_on_prod
reject_dev_pushes
dev_before=$(git -C "$REMOTE" rev-parse 6.x-dev)
if run_backmerge; then
    fail 'rejected-ff: a rejected fast-forward must fail'
fi
grep -Fq 'the push failed. Merge it by hand.' "$WORK/out" \
    || fail "rejected-ff: unexpected output: $(cat "$WORK/out")"
test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$dev_before" || fail 'rejected-ff: 6.x-dev must not move'

# A change made only on production, beyond the changelog, is left for a person on both merge paths.
for path in fast-forward diverged; do
    setup "prod-only-$path"
    if [[ "$path" = diverged ]]; then
        commit_on 6.x-dev "Document the next fix" "\$a * 5.9.9 - 2026-01-01 Old entry kept at the bottom"
    fi
    git -C "$REPO" checkout -q --detach origin/6.x-prod
    echo '<?php // hotfix' > "$REPO/Controller.php"
    git -C "$REPO" add Controller.php
    git -C "$REPO" commit -q -m 'Hotfix made on production'
    git -C "$REPO" push -q origin HEAD:refs/heads/6.x-prod
    date_on_prod
    dev_before=$(git -C "$REMOTE" rev-parse 6.x-dev)
    if run_backmerge; then
        fail "prod-only-$path: a change beyond the changelog must not be merged back"
    fi
    grep -Fq 'it changes more than CHANGELOG.md (Controller.php). Merge it by hand.' "$WORK/out" \
        || fail "prod-only-$path: unexpected output: $(cat "$WORK/out")"
    test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$dev_before" || fail "prod-only-$path: 6.x-dev must not move"
done

# Code changes only on dev, or a hotfix applied to both branches, do not stop the merge.
for case in dev-code both-branches; do
    setup "$case"
    branches=6.x-dev
    [[ "$case" = both-branches ]] && branches='6.x-dev 6.x-prod'
    for branch in $branches; do
        git -C "$REPO" fetch -q origin
        git -C "$REPO" checkout -q --detach "origin/$branch"
        echo '<?php // fix' > "$REPO/Controller.php"
        git -C "$REPO" add Controller.php
        git -C "$REPO" commit -q -m "Fix on $branch"
        git -C "$REPO" push -q origin "HEAD:refs/heads/$branch"
    done
    date_on_prod
    run_backmerge || fail "$case: $(cat "$WORK/out")"
    prod_in_dev || fail "$case: 6.x-dev should contain 6.x-prod"
done

# A local tag that disagrees with the remote one is not trusted.
setup tag-mismatch
date_on_prod
git -C "$REPO" tag -f 6.0.1 HEAD~1 >/dev/null
dev_before=$(git -C "$REMOTE" rev-parse 6.x-dev)
if run_backmerge; then
    fail 'tag-mismatch: a local tag that differs from the remote must fail'
fi
grep -Fq 'the release tag and 6.x-dev could not be fetched' "$WORK/out" \
    || fail "tag-mismatch: unexpected output: $(cat "$WORK/out")"
test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$dev_before" || fail 'tag-mismatch: 6.x-dev must not move'

# A release tag that never reached the remote fails rather than merging the branch tip.
setup no-tag
date_on_prod
git -C "$REPO" push -q origin --delete refs/tags/6.0.1
git -C "$REPO" tag -d 6.0.1 >/dev/null
dev_before=$(git -C "$REMOTE" rev-parse 6.x-dev)
if run_backmerge; then
    fail 'no-tag: a missing release tag must fail'
fi
grep -Fq 'the release tag and 6.x-dev could not be fetched' "$WORK/out" \
    || fail "no-tag: unexpected output: $(cat "$WORK/out")"
test "$(git -C "$REMOTE" rev-parse 6.x-dev)" = "$dev_before" || fail 'no-tag: 6.x-dev must not move'

# A plugin without the matching development branch has nothing to merge into.
setup no-dev
git -C "$REPO" push -q origin --delete 6.x-dev
date_on_prod
run_backmerge || fail "no-dev: $(cat "$WORK/out")"
grep -Fq '::notice::6.x-dev does not exist' "$WORK/out" || fail 'no-dev: expected a notice'

# A remote that cannot be reached fails the step rather than reading as a missing branch.
setup unreachable
date_on_prod
git -C "$REPO" remote set-url origin "$WORK/missing.git"
if run_backmerge; then
    fail 'unreachable: a failed lookup must fail the step'
fi
grep -Fq '6.x-dev could not be looked up' "$WORK/out" \
    || fail "unreachable: an unreachable remote must not read as a missing branch: $(cat "$WORK/out")"

if (cd "$REPO" && bash "$SCRIPT" 6.0.1 6.x-dev) > "$WORK/out" 2>&1; then
    fail 'A development branch must not be accepted as the production branch'
fi
grep -Fq 'Unsupported release branch' "$WORK/out" || fail 'expected the unsupported branch error'

echo 'All plugin release back-merge tests passed.'
