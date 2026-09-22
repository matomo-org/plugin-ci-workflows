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
if python3 "$SCRIPT" --check "$WORK/plain.md" 6.0.2 2026-09-20; then
    echo 'A stale changelog date must fail validation' >&2
    exit 1
fi

printf '## Changelog\n\n### 6.0.2\n' > "$WORK/heading.md"
python3 "$SCRIPT" "$WORK/heading.md" 6.0.2 2026-09-21
assert_contains '### 6.0.2 - 2026-09-21' "$WORK/heading.md"

printf '## Changelog\n\n## 6.0.2 (unreleased)\n' > "$WORK/unreleased.md"
python3 "$SCRIPT" "$WORK/unreleased.md" 6.0.2 2026-09-21
assert_contains '## 6.0.2 - 2026-09-21' "$WORK/unreleased.md"

printf '## Changelog\n\n## 6.0.2 (not yet released)\n' > "$WORK/not-yet-released.md"
python3 "$SCRIPT" "$WORK/not-yet-released.md" 6.0.2 2026-09-21
assert_contains '## 6.0.2 - 2026-09-21' "$WORK/not-yet-released.md"

printf '## Changelog\n\n## 6.0.2 (2026-09-20)\n' > "$WORK/parenthesized-date.md"
python3 "$SCRIPT" "$WORK/parenthesized-date.md" 6.0.2 2026-09-21
python3 "$SCRIPT" --check "$WORK/parenthesized-date.md" 6.0.2 2026-09-21
assert_contains '## 6.0.2 (2026-09-21)' "$WORK/parenthesized-date.md"
[[ "$(python3 "$SCRIPT" --read-date "$WORK/parenthesized-date.md" 6.0.2)" == '2026-09-21' ]]

printf '## Changelog\n\n## Version 6.0.2\n' > "$WORK/version-label.md"
python3 "$SCRIPT" "$WORK/version-label.md" 6.0.2 2026-09-21
assert_contains '## Version 6.0.2 - 2026-09-21' "$WORK/version-label.md"

printf '## Changelog\n\n* __6.0.2__ - 2026-09-20\n' > "$WORK/marked.md"
python3 "$SCRIPT" --check "$WORK/marked.md" 6.0.2 2026-09-20
python3 "$SCRIPT" "$WORK/marked.md" 6.0.2 2026-09-21
assert_contains '* __6.0.2__ - 2026-09-21' "$WORK/marked.md"

printf '## Changelog\n\n* **6.0.2** - 20/09/2026\n' > "$WORK/slash-date.md"
python3 "$SCRIPT" "$WORK/slash-date.md" 6.0.2 2026-09-21
python3 "$SCRIPT" --check "$WORK/slash-date.md" 6.0.2 2026-09-21
assert_contains '* **6.0.2** - 21/09/2026' "$WORK/slash-date.md"
[[ "$(python3 "$SCRIPT" --read-date "$WORK/slash-date.md" 6.0.2)" == '2026-09-21' ]]

printf '## Changelog\n\n* **6.0.2** - 09/20/2026\n' > "$WORK/us-slash-date.md"
python3 "$SCRIPT" "$WORK/us-slash-date.md" 6.0.2 2026-09-21
assert_contains '* **6.0.2** - 09/21/2026' "$WORK/us-slash-date.md"
[[ "$(python3 "$SCRIPT" --read-date "$WORK/us-slash-date.md" 6.0.2)" == '2026-09-21' ]]

printf '## Changelog\n\n* 6.0.2 - see PR 2026-01-01 backport\n' > "$WORK/embedded-date.md"
python3 "$SCRIPT" "$WORK/embedded-date.md" 6.0.2 2026-09-21
assert_contains '* 6.0.2 - 2026-09-21 - see PR 2026-01-01 backport' "$WORK/embedded-date.md"

printf '## Changelog\n\n### 6.0.2-rc1\n\n### 6.0.2\n' > "$WORK/prerelease.md"
python3 "$SCRIPT" "$WORK/prerelease.md" 6.0.2 2026-09-21
assert_contains '### 6.0.2-rc1' "$WORK/prerelease.md"
assert_contains '### 6.0.2 - 2026-09-21' "$WORK/prerelease.md"

printf '## Changelog\n\n## 6.0.20 - 2026-09-20\n\n## 6.0.2 - 2026-09-19\n' > "$WORK/prefix.md"
python3 "$SCRIPT" "$WORK/prefix.md" 6.0.2 2026-09-21
python3 "$SCRIPT" --check "$WORK/prefix.md" 6.0.2 2026-09-21
assert_contains '## 6.0.20 - 2026-09-20' "$WORK/prefix.md"
assert_contains '## 6.0.2 - 2026-09-21' "$WORK/prefix.md"

printf '## Changelog\r\n\r\n6.0.2 - 2026-09-20\r\n' > "$WORK/crlf.md"
python3 "$SCRIPT" "$WORK/crlf.md" 6.0.2 2026-09-21
python3 - "$WORK/crlf.md" <<'PY'
from pathlib import Path
import sys

content = Path(sys.argv[1]).read_bytes()
assert b"6.0.2 - 2026-09-21\r\n" in content
assert b"\r\n" in content
assert b"\n" not in content.replace(b"\r\n", b"")
PY

if python3 "$SCRIPT" --check "$WORK/plain.md" 9.9.9 2026-09-21; then
    echo 'Missing changelog entries must fail' >&2
    exit 1
fi

echo 'All changelog date tests passed.'
