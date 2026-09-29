#!/bin/bash

# Fails unless the outcome markers the generated tests write show GeneratedAssetCompilationTest ran
# and GeneratedTwigCompilationTest ran or was skipped. github-action-tests fails a run in which
# PHPUnit executed nothing, but not one in which only one of the two classes was collected, which
# would leave the other check silently absent.
#
# The markers stand in for a JUnit log, which cannot be relied on: run_tests.sh appends its own
# --log-junit on push runs, and the last one wins.
#
# Usage: check_compatibility_results.sh <results-dir>

set -euo pipefail

RESULTS_DIR="$1"

if [ ! -d "$RESULTS_DIR" ]; then
  echo "::error::The compatibility results directory $RESULTS_DIR does not exist, so generate_compatibility_checks.sh did not run."
  exit 1
fi

missing=0
for cls in GeneratedAssetCompilationTest GeneratedTwigCompilationTest; do
  outcome="$(cat "$RESULTS_DIR/$cls" 2>/dev/null || true)"
  case "$cls:$outcome" in
    GeneratedAssetCompilationTest:ran | GeneratedTwigCompilationTest:ran | GeneratedTwigCompilationTest:skipped)
      echo "$cls: $outcome"
      ;;
    *)
      echo "::error::$cls did not run (${outcome:-no outcome recorded})."
      missing=1
      ;;
  esac
done

exit "$missing"
