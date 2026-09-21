#!/bin/bash
# Tests release metadata validation and tag ancestry decisions with small git fixtures.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/prepare_plugin_release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_output() {
    local expected="$1" output_file="$2"
    grep -Fqx "$expected" "$output_file" || {
        echo "Expected '$expected' in $output_file" >&2
        cat "$output_file" >&2
        exit 1
    }
}

new_repo() {
    local repo="$1"
    mkdir "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Test
    printf '{"name":"TestPlugin","version":"5.0.0"}\n' > "$repo/plugin.json"
    printf '## Changelog\n\n* 5.0.0 - 2026-09-20\n' > "$repo/CHANGELOG.md"
    git -C "$repo" add plugin.json CHANGELOG.md
    git -C "$repo" commit -q -m initial
    git -C "$repo" branch -M 5.x-prod
    git -C "$repo" update-ref refs/remotes/origin/5.x-prod HEAD
}

run_prepare() {
    local repo="$1" output_file="$2"
    : > "$output_file"
    (cd "$repo" && GITHUB_OUTPUT="$output_file" bash "$SCRIPT" plugin.json 5.x-prod)
}

new_repo "$WORK/new"
run_prepare "$WORK/new" "$WORK/new-output"
assert_output 'tag_exists=false' "$WORK/new-output"
assert_output 'release_needed=true' "$WORK/new-output"
assert_output 'version=5.0.0' "$WORK/new-output"
assert_output 'plugin_name=TestPlugin' "$WORK/new-output"

new_repo "$WORK/invalid-version"
printf '{"name":"TestPlugin","version":"6.0.0"}\n' > "$WORK/invalid-version/plugin.json"
if (cd "$WORK/invalid-version" && GITHUB_OUTPUT="$WORK/invalid-version-output" bash "$SCRIPT" plugin.json 5.x-prod) > "$WORK/invalid-version-error" 2>&1; then
    echo 'A version from another Matomo major must fail validation' >&2
    exit 1
fi
grep -Fq 'does not belong on 5.x-prod' "$WORK/invalid-version-error"

new_repo "$WORK/resume"
git -C "$WORK/resume" tag 5.0.0
run_prepare "$WORK/resume" "$WORK/resume-output"
assert_output 'tag_exists=true' "$WORK/resume-output"
assert_output 'release_needed=true' "$WORK/resume-output"

new_repo "$WORK/already-released"
printf 'later change\n' >> "$WORK/already-released/CHANGELOG.md"
git -C "$WORK/already-released" add CHANGELOG.md
git -C "$WORK/already-released" commit -q -m later
git -C "$WORK/already-released" update-ref refs/remotes/origin/5.x-prod HEAD
git -C "$WORK/already-released" tag 5.0.0 HEAD~1
run_prepare "$WORK/already-released" "$WORK/already-released-output"
assert_output 'tag_exists=true' "$WORK/already-released-output"
assert_output 'release_needed=false' "$WORK/already-released-output"

new_repo "$WORK/recover"
printf 'release date\n' >> "$WORK/recover/CHANGELOG.md"
git -C "$WORK/recover" add CHANGELOG.md
git -C "$WORK/recover" commit -q -m 'add release date'
RECOVERY_COMMIT=$(git -C "$WORK/recover" rev-parse HEAD)
git -C "$WORK/recover" update-ref refs/remotes/origin/5.x-prod "$RECOVERY_COMMIT"
git -C "$WORK/recover" tag 5.0.0 "$RECOVERY_COMMIT"
git -C "$WORK/recover" checkout -q --detach HEAD~1
run_prepare "$WORK/recover" "$WORK/recover-output"
assert_output 'tag_exists=true' "$WORK/recover-output"
assert_output 'release_needed=true' "$WORK/recover-output"
[[ "$(git -C "$WORK/recover" rev-parse HEAD)" == "$RECOVERY_COMMIT" ]]

new_repo "$WORK/advanced"
printf 'release date\n' >> "$WORK/advanced/CHANGELOG.md"
git -C "$WORK/advanced" add CHANGELOG.md
git -C "$WORK/advanced" commit -q -m 'add release date'
ADVANCED_COMMIT=$(git -C "$WORK/advanced" rev-parse HEAD)
git -C "$WORK/advanced" update-ref refs/remotes/origin/5.x-prod "$ADVANCED_COMMIT"
git -C "$WORK/advanced" checkout -q --detach HEAD~1
if (cd "$WORK/advanced" && GITHUB_OUTPUT="$WORK/advanced-output" bash "$SCRIPT" plugin.json 5.x-prod) > "$WORK/advanced-error" 2>&1; then
    echo 'An advanced production branch must require a fresh dispatch' >&2
    exit 1
fi
grep -Fq 'Dispatch the release workflow again' "$WORK/advanced-error"

new_repo "$WORK/conflict"
git -C "$WORK/conflict" checkout -q --orphan unrelated
git -C "$WORK/conflict" rm -q -rf .
printf '{"name":"TestPlugin","version":"5.0.0"}\n' > "$WORK/conflict/plugin.json"
printf '## Changelog\n\n* 5.0.0 - 2026-09-20\n' > "$WORK/conflict/CHANGELOG.md"
git -C "$WORK/conflict" add plugin.json CHANGELOG.md
git -C "$WORK/conflict" commit -q -m unrelated
CONFLICT_COMMIT=$(git -C "$WORK/conflict" rev-parse HEAD)
git -C "$WORK/conflict" tag 5.0.0 "$CONFLICT_COMMIT"
git -C "$WORK/conflict" checkout -q --detach 5.x-prod
if (cd "$WORK/conflict" && GITHUB_OUTPUT="$WORK/conflict-output" bash "$SCRIPT" plugin.json 5.x-prod) > "$WORK/conflict-error" 2>&1; then
    echo 'An unrelated tag must fail closed' >&2
    exit 1
fi
grep -Fq 'unrelated to the current production branch' "$WORK/conflict-error"

echo 'All plugin release preparation tests passed.'
