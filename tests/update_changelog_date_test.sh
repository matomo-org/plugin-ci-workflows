#!/bin/bash
# Tests the release helper's supported changelog entry forms.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/python/update_changelog_date.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_contains() {
    local expected="$1" file="$2"
    grep -Fqx -- "$expected" "$file" || {
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

printf '## Changelog\n\n* 6.0.2 Unreleased - Fixes\n' > "$WORK/unreleased-separator.md"
python3 "$SCRIPT" "$WORK/unreleased-separator.md" 6.0.2 2026-09-21
assert_contains '* 6.0.2 - 2026-09-21 - Fixes' "$WORK/unreleased-separator.md"

printf '## Changelog\n\n* 6.0.2: 2026-09-20 - Fixes\n' > "$WORK/colon-date.md"
python3 "$SCRIPT" "$WORK/colon-date.md" 6.0.2 2026-09-21
assert_contains '* 6.0.2: 2026-09-21 - Fixes' "$WORK/colon-date.md"
[[ "$(python3 "$SCRIPT" --read-date "$WORK/colon-date.md" 6.0.2)" == 2026-09-21 ]] \
    || { echo 'A date after a colon must be read back' >&2; exit 1; }

printf '## Changelog\n\n* 6.0.2 Unreleased: Fixes\n' > "$WORK/unreleased-colon.md"
python3 "$SCRIPT" "$WORK/unreleased-colon.md" 6.0.2 2026-09-21
assert_contains '* 6.0.2 - 2026-09-21: Fixes' "$WORK/unreleased-colon.md"

printf '## Changelog\n\n* 6.0.2 (Unreleased) features\n' > "$WORK/unreleased-parenthesized-text.md"
python3 "$SCRIPT" "$WORK/unreleased-parenthesized-text.md" 6.0.2 2026-09-21
assert_contains '* 6.0.2 - 2026-09-21 features' "$WORK/unreleased-parenthesized-text.md"

printf '## Changelog\n\n* 6.0.2 Unreleased features for the new menu\n' > "$WORK/unreleased-text.md"
python3 "$SCRIPT" "$WORK/unreleased-text.md" 6.0.2 2026-09-21
assert_contains '* 6.0.2 - 2026-09-21 - Unreleased features for the new menu' "$WORK/unreleased-text.md"

printf '## Changelog\n\n## 6.0.2 (2026-09-20)\n' > "$WORK/parenthesized-date.md"
python3 "$SCRIPT" "$WORK/parenthesized-date.md" 6.0.2 2026-09-21
python3 "$SCRIPT" --check "$WORK/parenthesized-date.md" 6.0.2 2026-09-21
assert_contains '## 6.0.2 (2026-09-21)' "$WORK/parenthesized-date.md"
[[ "$(python3 "$SCRIPT" --read-date "$WORK/parenthesized-date.md" 6.0.2)" == '2026-09-21' ]]

printf '## Changelog\n\n## Version 6.0.2\n' > "$WORK/version-label.md"
python3 "$SCRIPT" "$WORK/version-label.md" 6.0.2 2026-09-21
assert_contains '## Version 6.0.2 - 2026-09-21' "$WORK/version-label.md"

printf '## Changelog\n\n#### LoginLdap 6.0.2\n\n#### LoginLdap 6.0.1 - 2026-09-14\n' > "$WORK/plugin-label.md"
if python3 "$SCRIPT" "$WORK/plugin-label.md" 6.0.2 2026-09-21 2> /dev/null; then
    echo 'A plugin-name label must only be recognised for the named plugin' >&2
    exit 1
fi
python3 "$SCRIPT" --plugin-name LoginLdap "$WORK/plugin-label.md" 6.0.2 2026-09-21
assert_contains '#### LoginLdap 6.0.2 - 2026-09-21' "$WORK/plugin-label.md"
python3 "$SCRIPT" --plugin-name LoginLdap "$WORK/plugin-label.md" 6.0.1 2026-09-15
assert_contains '#### LoginLdap 6.0.1 - 2026-09-15' "$WORK/plugin-label.md"
[[ "$(python3 "$SCRIPT" --read-date --plugin-name LoginLdap "$WORK/plugin-label.md" 6.0.2)" == '2026-09-21' ]]

printf '## Changelog\n\n- 6.0.0 Compatibility with Matomo 6\n' > "$WORK/free-text.md"
python3 "$SCRIPT" "$WORK/free-text.md" 6.0.0 2026-09-21
assert_contains '- 6.0.0 - 2026-09-21 - Compatibility with Matomo 6' "$WORK/free-text.md"
python3 "$SCRIPT" "$WORK/free-text.md" 6.0.0 2026-09-22
assert_contains '- 6.0.0 - 2026-09-22 - Compatibility with Matomo 6' "$WORK/free-text.md"

printf '## Changelog\n\n## 6.0.0 **Compatibility with Matomo 6**\n' > "$WORK/emphasised-free-text.md"
python3 "$SCRIPT" "$WORK/emphasised-free-text.md" 6.0.0 2026-09-21
python3 "$SCRIPT" "$WORK/emphasised-free-text.md" 6.0.0 2026-09-22
assert_contains '## 6.0.0 - 2026-09-22 - **Compatibility with Matomo 6**' "$WORK/emphasised-free-text.md"

printf '## Changelog\n\n* 6.0.2 - **2026-09-20**\n' > "$WORK/bold-date.md"
python3 "$SCRIPT" "$WORK/bold-date.md" 6.0.2 2026-09-21
assert_contains '* 6.0.2 - **2026-09-21**' "$WORK/bold-date.md"
[[ "$(python3 "$SCRIPT" --read-date "$WORK/bold-date.md" 6.0.2)" == '2026-09-21' ]]

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
python3 "$SCRIPT" "$WORK/us-slash-date.md" 6.0.2 2026-10-01
assert_contains '* **6.0.2** - 2026-10-01' "$WORK/us-slash-date.md"
[[ "$(python3 "$SCRIPT" --read-date "$WORK/us-slash-date.md" 6.0.2)" == '2026-10-01' ]]

printf '## Changelog\n\n* 6.0.2 - see PR 2026-01-01 backport\n' > "$WORK/embedded-date.md"
python3 "$SCRIPT" "$WORK/embedded-date.md" 6.0.2 2026-09-21
assert_contains '* 6.0.2 - 2026-09-21 - see PR 2026-01-01 backport' "$WORK/embedded-date.md"

for text in 'Marketplace 5 compatibility' 'Separate 2 reports' 'May contain fixes' 'May 5 compatibility'; do
    printf '## Changelog\n\n* 6.0.2 - %s\n' "$text" > "$WORK/month-like.md"
    python3 "$SCRIPT" "$WORK/month-like.md" 6.0.2 2026-09-21
    assert_contains "* 6.0.2 - 2026-09-21 - $text" "$WORK/month-like.md"
done

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

for release_date in 20260921 2026-W39-1 2026-9-21; do
    printf '## Changelog\n\n* 6.0.2\n' > "$WORK/non-iso-date.md"
    if python3 "$SCRIPT" "$WORK/non-iso-date.md" 6.0.2 "$release_date" 2> /dev/null; then
        echo "A release date given as '$release_date' must fail rather than be written as given" >&2
        exit 1
    fi
done

for heading in '## 6.0.2 – 2026-09-20' '## 6.0.2 - 20.09.2026' '## 6.0.2 - September 20, 2026' \
    '## 6.0.2 (20th Sept 2026)' '## 6.0.2 - 20th of September, 2026' '## 6.0.2 - Monday, September 20, 2026' \
    '## 6.0.2 - 20-Sep-2026' '## 6.0.2 - Sep-20-2026' '## 6.0.2 - 2026-Sep-20' \
    '## 6.0.2 - September 2026' '## 6.0.2 - Monday, 2026-09-20' '## 6.0.2 - Mon 20/09/2026' \
    '## 6.0.2 - Monday, 2026-Sep-20' '## 6.0.2 - **20.09.2026**' '## 6.0.2 - _September 20, 2026_'; do
    printf '## Changelog\n\n%s\n' "$heading" > "$WORK/unsupported-date.md"
    if python3 "$SCRIPT" "$WORK/unsupported-date.md" 6.0.2 2026-09-21 2> "$WORK/unsupported-date-error"; then
        echo "An unsupported date in '$heading' must fail rather than gain a second date" >&2
        exit 1
    fi
    grep -Fq 'unsupported format' "$WORK/unsupported-date-error"
    assert_contains "$heading" "$WORK/unsupported-date.md"
done

while IFS='|' read -r heading dated; do
    printf '## Changelog\n\n%s\n' "$heading" > "$WORK/heading-form.md"
    python3 "$SCRIPT" "$WORK/heading-form.md" 6.0.2 2026-09-21 > /dev/null
    assert_contains "$dated" "$WORK/heading-form.md"
    [[ "$(python3 "$SCRIPT" --read-date "$WORK/heading-form.md" 6.0.2)" == 2026-09-21 ]]
done <<'CASES'
## [6.0.2]|## [6.0.2] - 2026-09-21
## [6.0.2] - Fixes|## [6.0.2] - 2026-09-21 - Fixes
## v6.0.2|## v6.0.2 - 2026-09-21
* 6.0.2 - TBD|* 6.0.2 - 2026-09-21
## 6.0.2 (TBA)|## 6.0.2 - 2026-09-21
CASES

# An unmatched bracket is not the version heading, and a date after a linked one would break the link.
for heading in '## [6.0.2' '## [6.0.2](https://example.com/compare/6.0.1...6.0.2)' '## [6.0.2][compare]'; do
    printf '## Changelog\n\n%s\n' "$heading" > "$WORK/open-bracket.md"
    if python3 "$SCRIPT" "$WORK/open-bracket.md" 6.0.2 2026-09-21 2> /dev/null; then
        echo "The heading '$heading' must not be dated" >&2
        exit 1
    fi
done

for heading in '* 6.0.2 - 2026-13-45' '* 6.0.2 - 31/02/2026'; do
    printf '## Changelog\n\n%s\n' "$heading" > "$WORK/invalid-date.md"
    if python3 "$SCRIPT" "$WORK/invalid-date.md" 6.0.2 2026-09-21 2> "$WORK/invalid-date-error"; then
        echo "The impossible date in '$heading' must fail rather than be replaced" >&2
        exit 1
    fi
    grep -Fq 'has an invalid date' "$WORK/invalid-date-error"
    assert_contains "$heading" "$WORK/invalid-date.md"
    if python3 "$SCRIPT" --read-date "$WORK/invalid-date.md" 6.0.2 2> "$WORK/invalid-date-error"; then
        echo "The impossible date in '$heading' must not read as a date" >&2
        exit 1
    fi
    grep -Fq 'has an invalid date' "$WORK/invalid-date-error"
done

# Each changelog form must yield only its own entry's changes, as the release notes.
assert_notes() {
    local description="$1" changelog="$2" expected="$3"
    printf '%b' "$changelog" > "$WORK/notes.md"
    [[ "$(python3 "$SCRIPT" --read-notes --plugin-name LoginLdap "$WORK/notes.md" 6.0.2)" == "$(printf '%b' "$expected")" ]] || {
        echo "The release notes for $description were not read as expected" >&2
        exit 1
    }
}
assert_notes 'a plain entry' \
    '## Changelog\n\n6.0.3\n- Next\n\n6.0.2 - 2026-09-21\n- Fixed a report\n- Added a setting\n\n6.0.1 - 2026-09-14\n- Older\n' \
    '- Fixed a report\n- Added a setting'
assert_notes 'the last entry' '## Changelog\n\n__6.0.2__ - 2026-09-21\n* Fixed a report\n\n' '* Fixed a report'
assert_notes 'a heading entry' \
    '## Changelog\n\n### 6.0.2 - 2026-09-21\n\nFixed a report.\n\n#### Notes\n- Detail\n\n### 6.0.1\n- Older\n' \
    'Fixed a report.\n\n#### Notes\n- Detail'
assert_notes 'an entry before a thematic break' '### 6.0.2\n\nFixed a report.\n\n---\n\nFooter\n' 'Fixed a report.'
assert_notes 'one-line list entries' \
    '* 6.0.3 - 2026-09-28 - Next\n* 6.0.2 - 2026-09-21 - Fixed a report\n* 6.0.1 - Older\n' '* Fixed a report'
assert_notes 'items nested under a list entry' \
    '- 6.0.2 - 2026-09-21\n  - Fixed a report\n    - Detail\n- 6.0.1 - 2026-09-14\n  - Older\n' \
    '- Fixed a report\n  - Detail'
assert_notes 'an item naming a version' \
    '6.0.2 - 2026-09-21\n- 2.0.0 of a library is now bundled\n- Fixed a report\n\n6.0.1\n- Older\n' \
    '- 2.0.0 of a library is now bundled\n- Fixed a report'
assert_notes 'a nested item naming a version' \
    '- 6.0.2 - 2026-09-21\n  - Fixed a report\n  - 2.0.0 of a library is now bundled\n- 6.0.1\n' \
    '- Fixed a report\n- 2.0.0 of a library is now bundled'
assert_notes 'a plain entry with subheadings' \
    '## Changelog\n\n6.0.2 - 2026-09-21\n### Fixed\n- A report\n\n6.0.1\n- Older\n' '### Fixed\n- A report'
assert_notes 'a bold date' '## 6.0.2 **2026-09-21**\n- Fixed a report\n' '- Fixed a report'
assert_notes 'a bracketed date' '* 6.0.2 - [2026-09-21] Fixed a report\n* 6.0.1\n' '* Fixed a report'
assert_notes 'a parenthesized date' '## 6.0.2 (2026-09-21)\n- Fixed a report\n' '- Fixed a report'
assert_notes 'an undated one-line entry' '* 6.0.2 - [Fixed](https://example.com) a report 100%\n' \
    '* [Fixed](https://example.com) a report 100%'
assert_notes 'an entry before a prerelease entry' \
    '* 6.0.2 - 2026-09-21 - Fixed a report\n* 6.0.2-b1 - 2026-09-01 - Beta\n' '* Fixed a report'
assert_notes 'a heading entry with a paragraph naming a version' \
    '## 6.0.2 - 2026-09-21\n- Fixed a report\n\n6.0.1 compatibility is kept\n### 6.0.2-rc1 changes\n- More\n\n## 6.0.1\n' \
    '- Fixed a report\n\n6.0.1 compatibility is kept\n### 6.0.2-rc1 changes\n- More'
assert_notes 'an entry with a fenced code block' \
    '## 6.0.2 - 2026-09-21\n- Changed the config:\n```\n## setting\n---\n```\n- Fixed a report\n## 6.0.1\n' \
    '- Changed the config:\n```\n## setting\n---\n```\n- Fixed a report'
assert_notes 'the last entry before link reference definitions' \
    '## [6.0.2] - 2026-09-21\n### Fixed\n- A report\n\n[Unreleased]: https://example.com/compare\n[6.0.2]: https://example.com/6.0.2\n' \
    '### Fixed\n- A report'
assert_notes 'a heading entry above list entries' \
    '## 6.0.2 - 2026-09-21\n- Fixed a report\n\n* 6.0.1 - 2026-09-14 - Older\n* 6.0.0 - 2026-09-07 - Oldest\n' \
    '- Fixed a report'
assert_notes 'a plain entry above list entries' \
    '6.0.2 - 2026-09-21\n- Fixed a report\n\n* 6.0.1 - 2026-09-14 - Older\n' '- Fixed a report'
assert_notes 'a heading entry above undated list entries' \
    '## 6.0.2 - 2026-09-21\n- Fixed a report\n\n* 6.0.1\n  * Older\n* 6.0.0\n' '- Fixed a report'
assert_notes 'a heading entry above an undated bold entry' \
    '## 6.0.2 - 2026-09-21\n- Fixed a report\n\n**6.0.1**\n- Older\n' '- Fixed a report'
assert_notes 'a plain entry above an undated list entry' \
    '6.0.2 - 2026-09-21\n- Fixed a report\n\n* 6.0.1\n  * Older\n' '- Fixed a report'
assert_notes 'a plain entry above an undated plain entry with text' \
    '6.0.2 - 2026-09-21\n- Fixed a report\n\n6.0.1 Older change\n' '- Fixed a report'
assert_notes 'a plain entry with a line naming a version' \
    '6.0.2 - 2026-09-21\nFixed a report.\n2.0.0 compatibility was added.\n\n6.0.1\n- Older\n' \
    'Fixed a report.\n2.0.0 compatibility was added.'
assert_notes 'an entry with inline triple backticks' \
    '## 6.0.2 - 2026-09-21\n```x``` is now escaped\n## 6.0.1\n- Older\n' '```x``` is now escaped'
assert_notes 'a fence holding a line with an info string' \
    '## 6.0.2 - 2026-09-21\n````\n```php\n## not a heading\n````\n- Fixed a report\n## 6.0.1\n' \
    '````\n```php\n## not a heading\n````\n- Fixed a report'
{
    printf '## 6.0.2 - 2026-09-21\n'
    for i in $(seq 1 200); do printf -- '- Change %03d that is long enough to fill the notes past the limit\n' "$i"; done
} > "$WORK/notes-long.md"
if python3 "$SCRIPT" --read-notes "$WORK/notes-long.md" 6.0.2 > /dev/null 2> "$WORK/notes-long-error"; then
    echo 'Notes far longer than any one entry must not be read as an entry' >&2
    exit 1
fi
grep -Fq 'more than the 8000 expected of one entry' "$WORK/notes-long-error"
assert_notes 'a labelled entry' '## LoginLdap 6.0.2 - 2026-09-21\n- Fixed a report\n## LoginLdap 6.0.1\n- Older\n' '- Fixed a report'
assert_notes 'an entry with an indented code block' \
    '## 6.0.2 - 2026-09-21\nChanged the config:\n\n    # setting\n    ---\n\n- Fixed a report\n## 6.0.1\n' \
    'Changed the config:\n\n    # setting\n    ---\n\n- Fixed a report'
assert_notes 'a heading entry above undated one-line list entries' \
    '## 6.0.2 - 2026-09-21\n- Fixed a report\n\n* 6.0.1 - Older change\n* 6.0.0 - Oldest change\n' '- Fixed a report'
assert_notes 'a plain entry above undated one-line list entries' \
    '6.0.2 - 2026-09-21\n- Fixed a report\n\n* 6.0.1: Older change\n' '- Fixed a report'
assert_notes 'a plain entry with a line naming a version after a code block' \
    '6.0.2 - 2026-09-21\nFixed a report.\n\n```\ncode\n```\n2.0.0 compatibility was added.\n\n6.0.1\n- Older\n' \
    'Fixed a report.\n\n```\ncode\n```\n2.0.0 compatibility was added.'
assert_notes 'an underlined entry' \
    '6.0.2 - 2026-09-21\n------------------\n- Fixed a report\n\n6.0.1 - 2026-09-14\n------------------\n- Older\n' \
    '- Fixed a report'
assert_notes 'a double-underlined entry' '6.0.2 - 2026-09-21\n==================\n- Fixed a report\n\n6.0.1\n======\n' \
    '- Fixed a report'
assert_notes 'a heading entry with a remark' \
    '## 6.0.2 - 2026-09-21 (security release)\n- Fixed a report\n## 6.0.1\n' '(security release)\n\n- Fixed a report'
assert_notes 'an entry above a two-part version' '## 6.0.2 - 2026-09-21\n- Fixed a report\n\n6.0\n- Older\n' \
    '- Fixed a report'
assert_notes 'a list entry above a dated two-part version' \
    '* 6.0.2 - 2026-09-21\n  * Fixed a report\n* 6.0 - 2026-09-01\n  * Older\n' '* Fixed a report'
assert_notes 'the last entry in a version group' \
    '## Version 6\n6.0.2 - 2026-09-21\n- Fixed a report\n\n### Version 5\n5.4.0 - 2026-01-05\n' '- Fixed a report'
assert_notes 'a heading entry above undated plain entries' \
    '## 6.0.2 - 2026-09-21\n- Fixed a report\n\n6.0.1 - Older change\n- Older\n\n**6.0.0** - Oldest\n' '- Fixed a report'
assert_notes 'a plain entry with a paragraph naming its own version' \
    '6.0.2 - 2026-09-21\n- Fixed a report\n\n6.0.2 compatibility is retained.\n\n6.0.1\n- Older\n' \
    '- Fixed a report\n\n6.0.2 compatibility is retained.'
assert_notes 'an underlined entry with a remark' \
    '6.0.2 - 2026-09-21 (security release)\n-----\n- Fixed a report\n\n6.0.1\n-----\n' '(security release)\n\n- Fixed a report'
assert_notes 'an entry above an undated prerelease' \
    '## 6.0.2 - 2026-09-21\n- Fixed a report\n\n* 6.0.2-b1 - Beta\n' '- Fixed a report'
assert_notes 'an indented code block holding a fence' \
    '## 6.0.2 - 2026-09-21\nRun:\n\n    ```\n    php console\n\n- Fixed a report\n## 6.0.1\n' \
    'Run:\n\n    ```\n    php console\n\n- Fixed a report'
assert_notes 'a list item holding a fence' \
    '## 6.0.2 - 2026-09-21\n- Changed the config:\n    ```\n    ## setting\n    ```\n- Fixed a report\n## 6.0.1\n' \
    '- Changed the config:\n    ```\n    ## setting\n    ```\n- Fixed a report'
assert_notes 'an entry with reference-style links' \
    '## 6.0.2 - 2026-09-21\n- Fixed [#12][i12]\n## 6.0.1\n- Fixed [#11][i11]\n\n[i11]: https://example.com/11\n[i12]: https://example.com/12\n' \
    '- Fixed [#12][i12]\n\n[i12]: https://example.com/12'
assert_notes 'a one-line list entry with nested changes' \
    '  * 6.0.2 - 2026-09-21 - Fixed a report\n    * Added a setting\n      * Detail\n  * 6.0.1\n' \
    '* Fixed a report\n  * Added a setting\n    * Detail'
# Each malformed entry must fail with its reason, so the release links to the changelog instead.
assert_notes_error() {
    local description="$1" changelog="$2" reason="$3"
    printf '%b' "$changelog" > "$WORK/notes.md"
    if python3 "$SCRIPT" --read-notes "$WORK/notes.md" 6.0.2 > /dev/null 2> "$WORK/notes-error"; then
        echo "The release notes for $description must not be read" >&2
        exit 1
    fi
    grep -Fq "$reason" "$WORK/notes-error" || {
        echo "The error for $description must say: $reason" >&2
        exit 1
    }
}
assert_notes_error 'an entry with no changes' '6.0.2 - 2026-09-21\n\n6.0.1\n- Older\n' 'lists no changes'
assert_notes_error 'an entry with an unclosed code block' \
    '## 6.0.2 - 2026-09-21\n```\ncode\n## 6.0.1\n- Older\n' 'has a code block that is never closed'
printf '## Changelog\n\n6.0.1\n- Older\n' > "$WORK/notes-missing.md"
if python3 "$SCRIPT" --read-notes "$WORK/notes-missing.md" 6.0.2 2> /dev/null; then
    echo 'A version with no changelog entry must not read as having release notes' >&2
    exit 1
fi

echo 'All changelog date tests passed.'
