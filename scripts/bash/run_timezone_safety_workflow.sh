#!/bin/bash

# Resolve the comparison base for plugin-timezone-safety.yml and run the checker.
set -euo pipefail

CHECKER="${1:?usage: run_timezone_safety_workflow.sh <checker> }"
BASE_BRANCH="${BASE_BRANCH:-}"
EVENT_BEFORE="${EVENT_BEFORE:-}"

source_count=$(git ls-files '*.php' '*.sql' | awk '
  /(^|\/)(tests?|vendor|libs|node_modules|vue\/dist)\// { next }
  { count++ }
  END { print count + 0 }
')
if [ "$source_count" -eq 0 ]; then
  echo '::notice::No PHP or SQL source files are tracked; timezone static analysis is not applicable.'
  exit 0
fi

base_ref=''
advisory_notice=0
if [ -n "$BASE_BRANCH" ]; then
  base_ref="origin/$BASE_BRANCH"
elif [ -n "$EVENT_BEFORE" ] && [ "$EVENT_BEFORE" != "0000000000000000000000000000000000000000" ]; then
  base_ref="$EVENT_BEFORE"
fi

run_with_base() {
  local ref="$1"
  if [ -z "$BASE_BRANCH" ] && ! git merge-base "$ref" HEAD >/dev/null 2>&1; then
    echo '::warning::The previous push commit has no common history with HEAD; treating this scan as advisory.'
    base_ref=''
    advisory_notice=1
    return 0
  fi
  bash "$CHECKER" --base-ref "$ref" --fail-on-new-findings .
}

if [ -n "$base_ref" ]; then
  if git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; then
    run_with_base "$base_ref"
  elif [ -z "$BASE_BRANCH" ] && git fetch --no-tags origin "$EVENT_BEFORE" >/dev/null 2>&1; then
    run_with_base "$EVENT_BEFORE"
  elif [ -n "$BASE_BRANCH" ]; then
    echo "::error::The timezone check base revision '$base_ref' is unavailable in this checkout."
    exit 2
  else
    echo "::warning::The timezone check base revision '$base_ref' is unavailable; treating this scan as advisory."
    base_ref=''
    advisory_notice=1
  fi
fi

if [ -z "$base_ref" ]; then
  if [ "$advisory_notice" -eq 0 ]; then
    echo '::warning::No comparison base was available; treating timezone findings as advisory.'
  fi
  bash "$CHECKER" --advisory .
fi
