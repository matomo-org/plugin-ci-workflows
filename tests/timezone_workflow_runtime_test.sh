#!/bin/bash

# Runtime branch tests for scripts/bash/run_timezone_safety_workflow.sh.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/bash/run_timezone_safety_workflow.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=0

check() {
  local description="$1" expected_exit="$2" expected_output="$3" dir="$4"
  shift 4
  tests=$((tests + 1))
  local output actual
  output=$(cd "$dir" && env "$@" bash "$HELPER" "$WORK/checker" 2>&1)
  actual=$?
  if [ "$actual" -eq "$expected_exit" ] && { [ -z "$expected_output" ] || grep -qF -- "$expected_output" <<< "$output"; }; then
    echo "ok - $description"
  else
    failures=$((failures + 1))
    echo "FAIL - $description (exit $actual, expected $expected_exit)"
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<< "$output"
  fi
}

mkdir -p "$WORK/repo/src"
echo '<?php' > "$WORK/repo/src/Source.php"
git -C "$WORK/repo" init -q
git -C "$WORK/repo" config user.email test@example.invalid
git -C "$WORK/repo" config user.name 'Timezone test'
git -C "$WORK/repo" add .
git -C "$WORK/repo" commit -qm initial
git -C "$WORK/repo" update-ref refs/remotes/origin/main HEAD
initial_commit=$(git -C "$WORK/repo" rev-parse HEAD)

cat > "$WORK/checker" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CHECKER_LOG"
printf '%s\n' "$*"
exit "${CHECKER_EXIT:-0}"
SH
chmod +x "$WORK/checker"

: > "$WORK/calls"
check 'pull requests use the base branch and fail-on-new-findings' 0 '--base-ref origin/main --fail-on-new-findings .' "$WORK/repo" \
  BASE_BRANCH=main EVENT_BEFORE= CHECKER_LOG="$WORK/calls"

check 'checker failures propagate through the workflow runner' 1 '--base-ref origin/main --fail-on-new-findings .' "$WORK/repo" \
  BASE_BRANCH=main EVENT_BEFORE= CHECKER_LOG="$WORK/calls" CHECKER_EXIT=1

check 'missing pull request bases fail closed' 2 'unavailable in this checkout' "$WORK/repo" \
  BASE_BRANCH=missing EVENT_BEFORE= CHECKER_LOG="$WORK/calls"

check 'pushes use the previous commit when it is available' 0 "--base-ref $initial_commit --fail-on-new-findings ." "$WORK/repo" \
  BASE_BRANCH= EVENT_BEFORE="$initial_commit" CHECKER_LOG="$WORK/calls"

mkdir -p "$WORK/unrelated/src"
echo '<?php' > "$WORK/unrelated/src/Other.php"
git -C "$WORK/unrelated" init -q
git -C "$WORK/unrelated" config user.email test@example.invalid
git -C "$WORK/unrelated" config user.name 'Timezone test'
git -C "$WORK/unrelated" add .
git -C "$WORK/unrelated" commit -qm unrelated
unrelated_commit=$(git -C "$WORK/unrelated" rev-parse HEAD)
git -C "$WORK/repo" remote add origin "$WORK/unrelated"
check 'pushes with unrelated history fall back to advisory mode' 0 'no common history' "$WORK/repo" \
  BASE_BRANCH= EVENT_BEFORE="$unrelated_commit" CHECKER_LOG="$WORK/calls"

check 'unavailable push bases fall back to advisory mode' 0 'unavailable; treating this scan as advisory' "$WORK/repo" \
  BASE_BRANCH= EVENT_BEFORE=0000000000000000000000000000000000000001 CHECKER_LOG="$WORK/calls"

check 'runs without a comparison base use advisory mode' 0 '--advisory .' "$WORK/repo" \
  BASE_BRANCH= EVENT_BEFORE=0000000000000000000000000000000000000000 CHECKER_LOG="$WORK/calls"

mkdir -p "$WORK/no-source"
git -C "$WORK/no-source" init -q
check 'repositories without production source are skipped' 0 'not applicable' "$WORK/no-source" \
  BASE_BRANCH= EVENT_BEFORE= CHECKER_LOG="$WORK/calls"

echo "$tests test(s), $failures failure(s)"
exit "$failures"
