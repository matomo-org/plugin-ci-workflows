#!/bin/bash

# Reports plugins whose production code depends on dates or the site timezone but which neither
# run the timezone regression suite nor record why they do not need it. The static scan finds known
# bad patterns; this check makes sure a plugin whose date logic the scan cannot prove correct is
# also exercised under a non-UTC timezone, or has consciously opted out.
#
# Usage: check_timezone_regression_coverage.sh [--enforce] [repo-root]
#
# TIMEZONE_REGRESSION_EXEMPT holds the caller's exemption reason; empty means not exempt.
set -euo pipefail
# Exit 1 is the enforced verdict; anything that stops the check itself is 2, "not checked".
trap 'exit 2' ERR

ENFORCE=0
REPO_ROOT=.

usage() {
  echo "Usage: $0 [--enforce] [repo-root]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --enforce)
      ENFORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      [ "$REPO_ROOT" = '.' ] || { usage; exit 2; }
      REPO_ROOT="$1"
      shift
      ;;
  esac
done

cd "$REPO_ROOT"

listing=$(mktemp)
trap 'rm -f "$listing"' EXIT

if ! git ls-files -z -- '*.php' > "$listing"; then
  echo '::error::Unable to list PHP files for the timezone regression coverage check.' >&2
  exit 2
fi

# Every python3 runs with -P: the working directory is the checked-out plugin, and without it a
# yaml.py or re.py there would be imported in place of the real module and could decide the verdict.
evidence_files=$(python3 -P - "$listing" <<'PY'
import os
import re
import sys

# Event-time columns of the log tables, period boundaries and the site's timezone: code touching
# any of them computes something per site day, which is where server-timezone bugs surface.
SENSITIVE = re.compile(r'\b(server_time|visit_(first|last)_action_time)\b|\bgetDate(Time)?(Start|End)(UTC)?\s*\(|\bgetTimezone(For)?\s*\(', re.I)
# Updates/ holds one-off migrations, which run once rather than per report.
EXCLUDED = re.compile(r'(^|/)([Tt]ests?|vendor|libs|node_modules|vue/dist|Updates)/')
# Comments describe date logic without running it. Strings and heredocs are matched first so a
# `//` or `/*` inside one is not taken for a comment; `#[` opens an attribute, not a comment.
# Inline HTML after `?>` is dropped too, so an apostrophe in it cannot open a string. A short `<? `
# tag ends it, but `<?xml` does not: PHP reads that as HTML when short tags are off.
TOKEN = re.compile(r'''
    (?P<keep> '(?:\\.|[^'\\])*' | "(?:\\.|[^"\\])*"
            | <<<[ \t]*(?P<quote>["']?)(?P<label>[A-Za-z_]\w*)(?P=quote)\n.*?\n[ \t]*(?P=label)\b )
  | (?P<comment> /\*.*?(?:\*/|\Z) | (?://|\#(?!\[)).*?(?=\?>|\n|\Z) | \?>.*?(?:<\?(?:(?i:php)|=|(?=\s))|\Z) )
''', re.S | re.X)

with open(sys.argv[1], 'rb') as handle:
    paths = [name.decode('utf-8', 'surrogateescape') for name in handle.read().split(b'\0') if name]


def shown(path):
    # The path is printed into the log, where a newline could start a workflow command.
    return path if path.isprintable() else path.encode('unicode_escape', 'backslashreplace').decode('ascii')


for path in paths:
    # A tracked symlink may dangle or name a directory; neither holds PHP to scan.
    if EXCLUDED.search(path) or not os.path.isfile(path):
        continue
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            source = handle.read()
    except OSError as error:
        print(f'::error::Unable to read {shown(path)} for the timezone regression coverage check: {error.strerror}', file=sys.stderr)
        sys.exit(2)
    code = TOKEN.sub(lambda match: match.group('keep') or ' ', source)
    if SENSITIVE.search(code):
        print(shown(path))
PY
) || {
  echo '::error::Unable to scan the PHP files for the timezone regression coverage check.' >&2
  exit 2
}

if [ -z "$evidence_files" ]; then
  echo 'Timezone regression coverage: no date or site-timezone logic found in production code; no regression suite is required.'
  exit 0
fi

echo "Timezone regression coverage: date or site-timezone logic found in $(wc -l <<< "$evidence_files") production file(s):"
# A dash rather than bare indentation: a line that starts with `::` is a workflow command.
head -n 10 <<< "$evidence_files" | sed 's/^/  - /'
if [ "$(wc -l <<< "$evidence_files")" -gt 10 ]; then
  echo '  ...'
fi

if ! python3 -P -c 'import yaml' 2>/dev/null; then
  echo '::error::PyYAML is not available, so the timezone regression coverage check cannot read the workflows.' >&2
  exit 2
fi

# Parsed rather than matched line by line: YAML spreads the same call over flow mappings, values
# on the next line and folded scalars. The call and its command must sit in one job that is not
# switched off; any other condition, and an expression command, is taken at face value.
enabled_by=$(python3 -P - <<'PY'
import glob
import re
import yaml

CALLER = re.compile(r'^matomo-org/plugin-ci-workflows/\.github/workflows/plugin-timezone-safety\.yml@')
# The gate judges pull requests, so a suite that only runs on push or dispatch does not cover them.
# pull_request_target does not count either: the regression job checks out the base branch there.
# A workflow_call caller is taken at face value rather than traced to its own triggers.
PR_TRIGGERS = {'pull_request', 'workflow_call'}
for path in sorted(glob.glob('.github/workflows/*.yml') + glob.glob('.github/workflows/*.yaml')):
    try:
        # Bytes, so PyYAML reports bad encoding as a YAMLError rather than raising UnicodeDecodeError.
        with open(path, 'rb') as handle:
            workflow = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError):
        continue
    if not isinstance(workflow, dict):
        continue
    # YAML 1.1 reads a bare `on` key as the boolean true.
    triggers = workflow.get('on', workflow.get(True))
    if isinstance(triggers, str):
        triggers = [triggers]
    if not isinstance(triggers, (list, dict)) or not PR_TRIGGERS.intersection(map(str, triggers)):
        continue
    jobs = workflow.get('jobs')
    if not isinstance(jobs, dict):
        continue
    for job in jobs.values():
        if not isinstance(job, dict) or not CALLER.match(str(job.get('uses', ''))):
            continue
        condition = job.get('if', True)
        if condition is False or str(condition).replace(' ', '') in ('false', '${{false}}'):
            continue
        inputs = job.get('with')
        command = inputs.get('timezone-test-command') if isinstance(inputs, dict) else None
        if command is not None and str(command).strip():
            print(path if path.isprintable() else path.encode('unicode_escape', 'backslashreplace').decode('ascii'))
            raise SystemExit(0)
PY
) || {
  echo '::error::Unable to read the workflows for the timezone regression coverage check.' >&2
  exit 2
}

if [ -n "$enabled_by" ]; then
  echo "Timezone regression suite: enabled by $enabled_by."
  exit 0
fi

# The reason is caller input printed into the log; flattening it keeps a newline from starting a
# workflow command.
exempt_reason=$(tr -s '\r\n\t ' ' ' <<< "${TIMEZONE_REGRESSION_EXEMPT:-}" | sed 's/^ //; s/ $//')
if [ -n "$exempt_reason" ]; then
  echo "Timezone regression suite: exempted by the caller: $exempt_reason"
  exit 0
fi

message='This plugin has date or site-timezone logic but no timezone regression suite. Call plugin-timezone-safety.yml with a timezone-test-command from a test workflow, or set timezone-regression-exempt on Plugins CI with the reason the suite is not needed.'
if [ "$ENFORCE" -eq 1 ]; then
  echo "::error::$message"
  exit 1
fi
echo "::warning::$message"
exit 0
