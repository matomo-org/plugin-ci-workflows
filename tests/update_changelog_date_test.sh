#!/bin/bash
# Tests the release helper's supported changelog entry forms.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/python/update_changelog_date.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_contains() {
    local expected="$1" file="$2"
    grep -Fqx "$expected" "$file" || {
        echo "Expected '$expected' in $file" >&2
        exit 1
    }
}

printf '## Changelog\n\n6.0.2 - 2026-09-20\n' > "$WORK/plain.md"
python3 "$SCRIPT" "$WORK/plain.md" 6.0.2 2026-09-21
assert_contains '6.0.2 - 2026-09-21' "$WORK/plain.md"

printf '## Changelog\n\n### 6.0.2\n' > "$WORK/heading.md"
python3 "$SCRIPT" "$WORK/heading.md" 6.0.2 2026-09-21
assert_contains '### 6.0.2 - 2026-09-21' "$WORK/heading.md"

printf '## Changelog\n\n* __6.0.2__ - 2026-09-20\n' > "$WORK/marked.md"
python3 "$SCRIPT" --check "$WORK/marked.md" 6.0.2 2026-09-20
python3 "$SCRIPT" "$WORK/marked.md" 6.0.2 2026-09-21
assert_contains '* __6.0.2__ - 2026-09-21' "$WORK/marked.md"

if python3 "$SCRIPT" --check "$WORK/plain.md" 9.9.9 2026-09-21; then
    echo 'Missing changelog entries must fail' >&2
    exit 1
fi

echo 'All changelog date tests passed.'
