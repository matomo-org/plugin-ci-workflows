#!/bin/bash
# Fails when a plugin's vendored pre-push hook differs from the canonical copy in this repository.
# Usage: check_hook_sync.sh <canonical-hook> <plugin-hook>
#
# Copying a file into N repositories means it starts rotting the moment the source changes, so
# this check turns that silent drift into a failure -- through Plugins CI that is `verify-hook`. What it must not do is look like a finding
# about the plugin's code: it used to run inside the PHPStan job, before the analysis started, so a
# drifted hook both reported as red PHPStan on two matrix legs and suppressed the analysis that
# would have told you something real. Hence its own workflow, and hence the annotations below.
set -u

CANONICAL="${1:-}"
PLUGIN_HOOK="${2:-}"

if [ -z "$CANONICAL" ] || [ -z "$PLUGIN_HOOK" ]; then
  echo "Usage: $0 <canonical-hook> <plugin-hook>" >&2
  exit 1
fi

if [ ! -f "$CANONICAL" ]; then
  echo "::error::The canonical hook is missing from the plugin-ci-workflows checkout at $CANONICAL. That is a fault in the shared workflow, not in this plugin."
  exit 1
fi

# diff exits 2 rather than 1 for a missing operand, and every non-zero status takes the same
# branch, so without this the drift message below would describe a file that is not there.
if [ ! -f "$PLUGIN_HOOK" ]; then
  echo "::error::The hook check is running but this plugin ships no $PLUGIN_HOOK. Either copy hooks/pre-push from matomo-org/plugin-ci-workflows into place, or stop running the check -- through Plugins CI that is verify-hook -- and point core.hooksPath at that repository instead."
  exit 1
fi

if diff_output="$(diff -u "$CANONICAL" "$PLUGIN_HOOK")"; then
  echo "$PLUGIN_HOOK matches the canonical copy."
  exit 0
fi

# The annotation goes first and the diff after it, because the diff quotes a file a contributor
# controls: a line in it reading `::stop-commands::<token>` would otherwise make GitHub print the
# annotation below as literal text, and this check's whole purpose is a failure that explains
# itself.
echo "::error file=$PLUGIN_HOOK::This plugin's $PLUGIN_HOOK differs from the canonical copy in matomo-org/plugin-ci-workflows (diff below). Copy hooks/pre-push over it, or delete the file and point core.hooksPath at that repository."
echo "$diff_output"
exit 1
