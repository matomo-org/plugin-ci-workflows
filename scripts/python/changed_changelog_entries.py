"""Prints each version whose CHANGELOG.md entry differs between two copies of the file, one per line.

Entries are found top down with the weekly release's own reading of where one ends, so a note inside
an entry that starts with a version, such as "- 6.0.2 compatibility", is not taken for that version's
entry. A date or an Unreleased, Not yet released, TBD or TBA marker on a version line is ignored, as
is trailing whitespace, and a whole new entry is not a change. An entry the release cannot read is
compared as written.
Usage: changed_changelog_entries.py [--plugin-name NAME] <old changelog> <new changelog>
"""
import argparse
import sys
import tempfile
from pathlib import Path

from update_changelog_date import (
    DATE_PATTERN,
    UNSUPPORTED_DATE_LEAD,
    UNSUPPORTED_DATE_PATTERN,
    UNRELEASED_PATTERN,
    read_notes,
    version_line_pattern,
)

VERSION = r"(?P<number>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+[0-9A-Za-z.-]+)?"


def entries(changelog, plugin_name):
    if not changelog.exists():
        return {}
    pattern = version_line_pattern(None, plugin_name, VERSION)
    with changelog.open("r", encoding="utf-8", newline="") as changelog_file:
        lines = [line.rstrip("\r\n") for line in changelog_file]

    found = {}
    index = next((i for i, line in enumerate(lines) if pattern.match(line)), None)
    with tempfile.TemporaryDirectory() as scratch:
        rest = Path(scratch) / "CHANGELOG.md"
        while index is not None:
            match = pattern.match(lines[index])
            version = match.group("number")
            # read_notes takes the first line naming the version, so it reads from this entry on.
            rest.write_text("\n".join([undated(lines[index], match)] + lines[index + 1:]) + "\n", encoding="utf-8")
            try:
                ended_by = read_notes(rest, version, plugin_name, next_entry=True)
                end = len(lines) if ended_by is None else next(
                    (i for i in range(index + 1, len(lines)) if lines[i] == ended_by), len(lines)
                )
            except ValueError:
                # The release cannot read this line as an entry, so the next version line ends it.
                end = next((i for i in range(index + 1, len(lines)) if pattern.match(lines[i])), len(lines))
            try:
                notes = read_notes(rest, version, plugin_name)
            except ValueError:
                # Compared as written, so an edit inside an entry the release cannot read still counts.
                notes = "\n".join([undated(lines[index], match, every=True)] + lines[index + 1:end])
            # Trailing whitespace is not a change, so an editor trimming it on save does not fail a PR.
            notes = "\n".join(line.rstrip() for line in notes.split("\n"))
            found[version] = found[version] + "\n" + notes if version in found else notes
            index = next((i for i in range(end, len(lines)) if pattern.match(lines[i])), None)
    return found


def undated(line, match, every=False):
    """The version line without an Unreleased, TBD or similar marker, which the release replaces with
    the date, and without a date the release cannot write, such as "October 5, 2026", which read_notes would
    otherwise keep as part of the entry, or without any date when every is set."""
    rest = match.group("rest")
    if unreleased_match := UNRELEASED_PATTERN.match(rest):
        return line[: len(line) - len(rest)] + unreleased_match.group("suffix")
    stripped = rest.lstrip(UNSUPPORTED_DATE_LEAD)
    date_match = UNSUPPORTED_DATE_PATTERN.match(stripped)
    if not date_match or (DATE_PATTERN.match(stripped) and not every):
        return line
    return line[: len(line) - len(rest)] + stripped[date_match.end():]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("old")
    parser.add_argument("new")
    parser.add_argument("--plugin-name")
    args = parser.parse_args()
    old = entries(Path(args.old), args.plugin_name)
    new = entries(Path(args.new), args.plugin_name)
    for version in dict.fromkeys([*new, *old]):
        # An entry only the new copy has is a correction or one merged forward from an older branch.
        if version in old and old[version] != new.get(version):
            print(version)


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeDecodeError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
