#!/bin/bash
# Tests for scripts/bash/check_hook_sync.sh, the vendored pre-push hook drift check.
# Usage: bash tests/hook_sync_test.sh
#
# The point of moving this out of the PHPStan job is that its failures say what they are, so the
# messages are as much the contract as the exit statuses -- a check whose red is indistinguishable
# from a PHPStan finding is the defect this replaced.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/bash/check_hook_sync.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=()

# Asserts the check exits $2 and, when $3 is given, that its output mentions it.
run_case() {
  local description="$1" expected="$2" expected_message="${3:-}"
  local output status
  tests=$((tests + 1))

  output="$(bash "$CHECK" "$CANONICAL" "$PLUGIN_HOOK" 2>&1)"
  status=$?
  if [ "$status" != "$expected" ]; then
    echo "FAIL - $description (expected exit $expected, got $status)"
    echo "$output"
    failures+=("$description")
  elif [ -n "$expected_message" ] && [[ "$output" != *"$expected_message"* ]]; then
    echo "FAIL - $description (message did not mention '$expected_message')"
    echo "$output"
    failures+=("$description")
  else
    echo "ok - $description"
  fi
}

CANONICAL="$WORK/canonical/hooks/pre-push"
PLUGIN_HOOK="$WORK/plugin/.git-hooks-matomo/pre-push"
mkdir -p "$(dirname "$CANONICAL")" "$(dirname "$PLUGIN_HOOK")"
printf '#!/bin/bash\necho canonical\n' > "$CANONICAL"

cp "$CANONICAL" "$PLUGIN_HOOK"
run_case "an identical hook passes" 0 "matches the canonical copy"

printf '#!/bin/bash\necho drifted\n' > "$PLUGIN_HOOK"
run_case "a drifted hook fails and annotates the plugin's file" 1 \
  "::error file=$PLUGIN_HOOK::"
run_case "the drift message names the canonical source" 1 "plugin-ci-workflows"

# A plugin that ships no hook at all is a caller error rather than drift, and telling it that its
# absent file differs from the canonical copy is advice about nothing.
rm -f "$PLUGIN_HOOK"
run_case "a plugin shipping no hook fails as a missing hook, not as drift" 1 "ships no"

# The other direction: a broken shared checkout must not read as the plugin's fault.
cp "$CANONICAL" "$PLUGIN_HOOK"
mv "$CANONICAL" "$CANONICAL.moved"
run_case "a missing canonical copy blames the shared workflow" 1 \
  "fault in the shared workflow"
mv "$CANONICAL.moved" "$CANONICAL"

# A trailing-newline difference is a real difference to git and to a checksum, so it must not pass.
printf '#!/bin/bash\necho canonical' > "$PLUGIN_HOOK"
run_case "a hook differing only in its trailing newline fails" 1 "differs from the canonical copy"

# The context sentence is how the placement inside PHPStan stays comprehensible, so it has to
# reach every failure -- and has to leave no trace when the umbrella omits it.
printf '#!/bin/bash\necho drifted\n' > "$PLUGIN_HOOK"
tests=$((tests + 1))
with_context="$(bash "$CHECK" "$CANONICAL" "$PLUGIN_HOOK" "It is not a PHPStan finding." 2>&1)"
without_context="$(bash "$CHECK" "$CANONICAL" "$PLUGIN_HOOK" 2>&1)"
if [[ "$with_context" == *"repository. It is not a PHPStan finding."* ]] \
  && [[ "$without_context" == *"at that repository." ]]; then
  echo "ok - a caller's context sentence is appended, and omitting it leaves no gap"
else
  echo "FAIL - a caller's context sentence is appended, and omitting it leaves no gap"
  echo "$with_context"
  echo "$without_context"
  failures+=("a caller's context sentence is appended, and omitting it leaves no gap")
fi

rm -f "$PLUGIN_HOOK"
tests=$((tests + 1))
if bash "$CHECK" "$CANONICAL" "$PLUGIN_HOOK" "Trailing context." 2>&1 | grep -q "instead. Trailing context."; then
  echo "ok - the context sentence reaches the missing-hook failure too"
else
  echo "FAIL - the context sentence reaches the missing-hook failure too"
  failures+=("the context sentence reaches the missing-hook failure too")
fi

echo
echo "$tests tests, ${#failures[@]} failures"
[ ${#failures[@]} -eq 0 ] || exit 1
