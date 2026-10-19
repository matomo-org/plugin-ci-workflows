import argparse
import re
import sys
from datetime import date
from pathlib import Path


DATE_PATTERN = re.compile(
    r"(?P<iso>(?<!\d)\d{4}-\d{2}-\d{2}(?!\d))"
    r"|(?P<slash>(?<!\d)\d{2}/\d{2}/\d{4}(?!\d))"
)
# A month name or abbreviation must end the word, so "Marketplace 5 compatibility" still gets a date.
MONTH_NAME = (
    r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?"
    r"|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?(?![a-z])"
)
WEEKDAY = r"(?:(?:mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?\.?,?\s+)?"
DATE_SEPARATOR = r"[\s./,-]+"
UNSUPPORTED_DATE_PATTERN = re.compile(
    rf"{WEEKDAY}\d{{1,4}}[./-]\d{{1,2}}[./-]\d{{1,4}}"
    # Month-name dates need a year, so prose such as "May 5 compatibility" still gets a date.
    rf"|{WEEKDAY}{MONTH_NAME}{DATE_SEPARATOR}(?:\d{{1,2}}(?:st|nd|rd|th)?{DATE_SEPARATOR})?\d{{4}}(?!\d)"
    rf"|{WEEKDAY}\d{{1,2}}(?:st|nd|rd|th)?{DATE_SEPARATOR}(?:of\s+)?{MONTH_NAME}{DATE_SEPARATOR}\d{{4}}(?!\d)"
    rf"|{WEEKDAY}\d{{4}}{DATE_SEPARATOR}{MONTH_NAME}",
    re.IGNORECASE,
)
# Emphasis is skipped so a bold or underlined date is rewritten, or refused, like a plain one.
DATE_LEAD = " -:([*_"
UNSUPPORTED_DATE_LEAD = " -:–—([*_"
UNRELEASED_PATTERN = re.compile(
    # The lookahead keeps free text such as "Unreleased features" from being read as the marker. It
    # applies only to the bare words: on a parenthesized marker, backtracking would leave the ")" behind.
    r"^(?P<prefix>\s*(?:-\s*)?)"
    r"(?:\((?:unreleased|not\s+yet\s+released|tb[ad])\)|(?:unreleased|not\s+yet\s+released|tb[ad])(?=\s*(?:$|[^\w\s])))"
    r"(?P<suffix>.*)$",
    re.IGNORECASE,
)
LIST_ITEM_PATTERN = re.compile(r"\s*[-*+]\s")
MAX_NOTES_LENGTH = 8000


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("changelog")
    parser.add_argument("version")
    parser.add_argument("release_date", nargs="?")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--read-date", action="store_true")
    parser.add_argument("--read-notes", action="store_true")
    parser.add_argument("--read-next-undated", action="store_true")
    parser.add_argument("--plugin-name")
    return parser.parse_args()


def version_line_pattern(version, plugin_name=None, version_pattern=None):
    labels = ["Version"] + ([re.escape(plugin_name)] if plugin_name else [])
    return re.compile(
        rf"^(?P<prefix>\s*(?:#{{1,6}}\s+|[-*+]\s+)?)(?P<label>(?:{'|'.join(labels)})\s+)?"
        rf"(?P<emphasis>_{{0,2}}|\*{{0,2}})(?P<bracket>\[)?(?P<v>v?)"
        rf"{version_pattern or re.escape(version)}(?![0-9.]|[-+][A-Za-z0-9])(?(bracket)\](?![(\[]))(?P=emphasis)(?P<rest>.*)$"
    )


def date_from_match(date_match, release_date=None):
    if date_match.group("iso"):
        return date.fromisoformat(date_match.group("iso")).isoformat()

    old_date = date_match.group("slash")
    first, second, year = (int(part) for part in old_date.split("/"))

    # Ambiguous slash dates use day-first, matching Matomo's existing changelog convention.
    if second > 12 and first <= 12:
        month, day = first, second
    else:
        day, month = first, second
    parsed_date = date(year, month, day)
    if release_date is not None:
        new_date = date.fromisoformat(release_date)
        if second > 12 and first <= 12:
            # A month-first date with a day of 12 or less would read back day-first.
            return new_date.strftime("%m/%d/%Y") if new_date.day > 12 else new_date.isoformat()
        return new_date.strftime("%d/%m/%Y")
    return parsed_date.isoformat()


def valid_date(date_match, version):
    try:
        return date_from_match(date_match)
    except ValueError:
        raise ValueError(
            f"The changelog entry for {version} has an invalid date: {date_match.group(0)}"
        ) from None


def read_date(changelog, version, plugin_name=None):
    version_line = version_line_pattern(version, plugin_name)
    with changelog.open("r", encoding="utf-8", newline="") as changelog_file:
        for line in changelog_file:
            content = line.rstrip("\r\n")
            match = version_line.match(content)
            if not match:
                continue
            rest = match.group("rest")
            date_match = DATE_PATTERN.match(rest.lstrip(DATE_LEAD))
            if not date_match:
                break
            return valid_date(date_match, version)
    raise ValueError(f"No release date found for version {version}")


# The version of the entry straight after this one when it is undated, found by where read_notes ends
# this one, so a note that starts with a version is not taken for an entry.
def read_next_undated(changelog, version, plugin_name=None):
    next_line = read_notes(changelog, version, plugin_name, next_entry=True)
    match = next_line is not None and version_line_pattern(None, plugin_name, r"(?P<number>\d+\.\d+\.\d+)").match(next_line)
    rest = match.group("rest") if match else ""
    # A date the release could not write is still a date, so that entry is not taken for an unreleased one.
    if match and not DATE_PATTERN.match(rest.lstrip(DATE_LEAD)) and not UNSUPPORTED_DATE_PATTERN.match(rest.lstrip(UNSUPPORTED_DATE_LEAD)):
        return match.group("number")
    return None


def read_notes(changelog, version, plugin_name=None, next_entry=False):
    version_line = version_line_pattern(version, plugin_name)
    any_version_line = version_line_pattern(
        None, plugin_name, r"(?P<number>\d+\.\d+\.\d+)(?P<pre>-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"
    )
    # A two-part "6.0" entry ends the one above only when dated or bare, since "2.0 of a library" is prose.
    short_version_line = version_line_pattern(None, plugin_name, r"\d+\.\d+")
    entry_number = re.match(r"\d+\.\d+\.\d+", version)
    entry_number = tuple(map(int, entry_number.group(0).split("."))) if entry_number else None
    with changelog.open("r", encoding="utf-8", newline="") as changelog_file:
        lines = [line.rstrip("\r\n") for line in changelog_file]

    for index, content in enumerate(lines):
        match = version_line.match(content)
        if not match:
            continue

        heading = re.match(r"\s*(#{1,6})\s", content)
        # A plain entry has no level of its own, so a "## Older versions" ends it but a "### Fixed"
        # inside it does not.
        heading_level = len(heading.group(1)) if heading else 2
        list_item = LIST_ITEM_PATTERN.match(content)
        version_indent = len(content) - len(content.lstrip())
        body = lines[index + 1:]
        # An underlined (setext) version heading.
        setext = not heading and not list_item and body and re.fullmatch(r" {0,3}(?:=+|-+)\s*", body[0])
        if setext:
            heading_level = 1 if "=" in body[0] else 2
            body = body[1:]
        notes = []
        summary = []
        # A one-line entry such as "- 6.0.0 - 2026-08-09 - Compatibility with Matomo 6" keeps its
        # change on the version line.
        rest = match.group("rest")
        if date_match := DATE_PATTERN.match(rest.lstrip(DATE_LEAD)):
            # The emphasis or bracket closing a "**2026-09-21**" or "[2026-09-21]" date.
            rest = re.sub(r"^[*_\])]*", "", rest.lstrip(DATE_LEAD)[date_match.end():])
        rest = rest.lstrip(" -:–—").rstrip()
        if rest:
            # A heading's remark, such as "(security release)", is kept as text rather than made a change.
            summary = ([rest, ""] if heading or setext else [f"{content.lstrip()[0] if list_item else '-'} {rest}"])

        fence = None
        previous_blank = False
        indented_code = False
        ended_by = None
        for line in body:
            line_indent = len(line) - len(line.lstrip())
            # Indented four or more past the version line, it is code, not a heading or a break.
            code = line_indent >= version_indent + 4
            # An indented code block starts only after a blank line; otherwise the line continues a list item.
            indented_code = code and (previous_blank or indented_code) if line.strip() else indented_code
            if fence is None and not indented_code:
                # A backtick fence's info string cannot contain a backtick, so "```x``` is escaped" is text.
                if fence_match := re.match(r"\s*(`{3,}(?!.*`)|~{3,})", line):
                    fence = fence_match.group(1)
                    notes.append(line)
                    previous_blank = False
                    continue
            elif fence is not None:
                # Only a bare run of the fence's character, at least as long, closes it.
                if re.fullmatch(rf"\s*{re.escape(fence[0])}{{{len(fence)},}}\s*", line):
                    fence = None
                notes.append(line)
                indented_code = False
                continue
            next_heading = not code and re.match(r"\s*(#{1,6})\s", line)
            # A version line at the entry's depth starts the next entry when it is dated, bare, a
            # prerelease of the entry's version, or an older version written as the next entry would be.
            # So "- 2.0.0 of a library is now bundled" under a plain or heading entry, or "6.0.2
            # compatibility is retained" inside a plain one, stays part of the entry.
            next_version = any_version_line.match(line)
            next_rest = next_version.group("rest") if next_version else ""
            next_list_item = LIST_ITEM_PATTERN.match(line)
            next_number = tuple(map(int, next_version.group("number").split("."))) if next_version else None
            older = bool(next_version and entry_number and next_number < entry_number)
            short_version = short_version_line.match(line)
            short_rest = short_version.group("rest") if short_version else ""
            if (
                (
                    next_version
                    and line_indent <= version_indent
                    and (
                        DATE_PATTERN.match(next_rest.lstrip(DATE_LEAD))
                        or not next_rest.strip()
                        or UNRELEASED_PATTERN.match(next_rest)
                        # Not a deeper heading such as "### 6.0.2-rc1 changes", which is a subsection.
                        or (
                            next_version.group("pre")
                            and "-" not in version
                            and next_number == entry_number
                            and not next_heading
                        )
                        # Plugins write list entries as "* 5.0.1 Added plugin category", so a top-level
                        # item naming a version cannot be told from the next entry.
                        or (list_item and next_list_item)
                        # "6.0.1 Older change" after a blank line below a plain entry.
                        or (not heading and not list_item and not next_list_item and previous_blank and older)
                        # "* 6.0.1 - Older change", or "6.0.1 - Older change" after a blank line, below a
                        # heading or plain entry.
                        or (
                            not list_item
                            and (next_list_item or previous_blank)
                            and older
                            and re.match(r"\s*[-:–—]\s", next_rest)
                        )
                    )
                )
                or (
                    short_version
                    and line_indent <= version_indent
                    and (DATE_PATTERN.match(short_rest.lstrip(DATE_LEAD)) or not short_rest.strip())
                )
                or (not code and re.fullmatch(r"\s*(?:-{3,}|\*{3,}|_{3,})\s*", line))
                # Link reference definitions such as "[6.0.2]: https://..." close a Keep a Changelog file.
                or re.match(r" {0,3}\[[^\]]+\]:\s", line)
                or (next_heading and len(next_heading.group(1)) <= heading_level)
                # A grouping heading such as "### Version 5" ends an entry at any level.
                or (next_heading and re.fullmatch(r"\s*#+\s+\[?Version\s+v?\d+(?:\.\d+)?(?:\.x)?\]?\s*", line, re.I))
            ):
                ended_by = line
                break
            notes.append(line)
            previous_blank = not line.strip()

        if next_entry:
            return ended_by
        if fence is not None:
            raise ValueError(f"The changelog entry for {version} has a code block that is never closed")
        while notes and not notes[0].strip():
            notes.pop(0)
        # Items nested under a list-style version line would otherwise render as a code block. Under a
        # heading or plain entry, four or more spaces are the entry's own indented code block.
        indent = min((len(line) - len(line.lstrip()) for line in notes if line.strip()), default=0)
        if indent >= 4 and not (list_item or version_indent):
            indent = 0
        notes = [line[indent:] for line in notes]
        # Lines under a one-line entry's change stay nested under it, as in "- 1.2.1 New workaround:"
        # followed by its details.
        if summary and not (heading or setext) and notes:
            notes = [(" " * 2 + line if line.strip() else line) for line in notes]
        notes = summary + notes
        while notes and not notes[-1].strip():
            notes.pop()
        notes_text = "\n".join(notes)
        if not notes_text:
            raise ValueError(f"The changelog entry for {version} lists no changes")
        # Reference-style links such as "[#12][i12]" keep their targets, which end the file.
        definitions = []
        for line in lines:
            definition = re.match(r" {0,3}\[([^\]]+)\]:\s", line)
            if definition and f"[{definition.group(1).lower()}]" in notes_text.lower() and line.strip() not in definitions:
                definitions.append(line.strip())
        if definitions:
            notes_text += "\n\n" + "\n".join(definitions)
        # Several times the longest entry in any plugin changelog: more means the entry's end was
        # missed and later versions were read in.
        if len(notes_text) > MAX_NOTES_LENGTH:
            raise ValueError(
                f"The changelog entry for {version} read as {len(notes_text)} characters,"
                f" more than the {MAX_NOTES_LENGTH} expected of one entry"
            )
        return notes_text

    raise ValueError(f"No changelog entry found for version {version}")


def update_date(changelog, version, release_date, plugin_name=None):
    version_line = version_line_pattern(version, plugin_name)

    with changelog.open("r", encoding="utf-8", newline="") as changelog_file:
        lines = changelog_file.read().splitlines(keepends=True)
    updated_lines = list(lines)

    for index, line in enumerate(lines):
        content = line.rstrip("\r\n")
        match = version_line.match(content)
        if not match:
            continue

        rest = match.group("rest")
        date_match = DATE_PATTERN.match(rest.lstrip(DATE_LEAD))
        if date_match:
            # Replacing an impossible date would hide that the entry was dated by hand.
            valid_date(date_match, version)
            date_offset = len(rest) - len(rest.lstrip(DATE_LEAD))
            replacement_date = release_date
            if date_match.group("slash"):
                replacement_date = date_from_match(date_match, release_date)
            updated_rest = (
                rest[:date_offset]
                + replacement_date
                + rest[date_offset + date_match.end():]
            )
        elif unreleased_match := UNRELEASED_PATTERN.match(rest):
            separator = (
                unreleased_match.group("prefix")
                if "-" in unreleased_match.group("prefix")
                else " - "
            )
            updated_rest = (
                f"{separator}{release_date}"
                f"{unreleased_match.group('suffix')}"
            )
        elif UNSUPPORTED_DATE_PATTERN.match(rest.lstrip(UNSUPPORTED_DATE_LEAD)):
            # Prepending here would ship a heading with two dates. A date later in free text is kept.
            raise ValueError(
                f"The changelog entry for {version} has a date in an unsupported format: {rest.strip()}"
            )
        elif rest[:1].isspace() and rest.lstrip().lstrip("*_")[:1].isalnum():
            # Free text straight after the version needs its own separator after the date.
            updated_rest = f" - {release_date} - {rest.lstrip()}"
        else:
            updated_rest = f" - {release_date}{rest}"

        updated_content = (
            match.group("prefix")
            + (match.group("label") or "")
            + match.group("emphasis")
            + (match.group("bracket") or "")
            + match.group("v")
            + version
            + ("]" if match.group("bracket") else "")
            + match.group("emphasis")
            + updated_rest
        )
        line_ending = line[len(content):]
        updated_lines[index] = updated_content + line_ending
        # The first matching heading is the authoritative entry in newest-first changelogs.
        changed = updated_lines[index] != line
        return changed, updated_lines

    raise ValueError(f"No changelog entry found for version {version}")


def main():
    args = parse_args()

    changelog = Path(args.changelog)
    if args.read_notes:
        if args.release_date is not None or args.check or args.read_date or args.read_next_undated:
            print("--read-notes cannot be combined with a release date, --check, --read-date or --read-next-undated", file=sys.stderr)
            return 1
        try:
            print(read_notes(changelog, args.version, args.plugin_name))
        except (OSError, ValueError) as error:
            print(error, file=sys.stderr)
            return 1
        return 0

    if args.read_next_undated:
        if args.release_date is not None or args.check or args.read_date:
            print("--read-next-undated cannot be combined with a release date, --check or --read-date", file=sys.stderr)
            return 1
        try:
            print(read_next_undated(changelog, args.version, args.plugin_name) or "")
        except (OSError, ValueError) as error:
            print(error, file=sys.stderr)
            return 1
        return 0

    if args.read_date:
        if args.release_date is not None or args.check:
            print("--read-date cannot be combined with a release date or --check", file=sys.stderr)
            return 1
        try:
            print(read_date(changelog, args.version, args.plugin_name))
        except (OSError, ValueError) as error:
            print(error, file=sys.stderr)
            return 1
        return 0

    if args.release_date is None:
        print("a release date is required unless --read-date or --read-notes is used", file=sys.stderr)
        return 1

    # Python 3.11+ also accepts 20261006 and 2026-W41-2, which would be written as given and never read back.
    try:
        valid_date = date.fromisoformat(args.release_date).isoformat() == args.release_date
    except ValueError:
        valid_date = False
    if not valid_date:
        print(f"Invalid release date: {args.release_date}", file=sys.stderr)
        return 1

    try:
        changed, updated_lines = update_date(
            changelog, args.version, args.release_date, args.plugin_name
        )
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    if args.check:
        if changed:
            print(
                f"Changelog entry for {args.version} does not contain "
                f"the release date {args.release_date}.",
                file=sys.stderr,
            )
            return 1
        print(f"Changelog entry for {args.version} has release date {args.release_date}.")
        return 0

    if changed:
        with changelog.open("w", encoding="utf-8", newline="") as changelog_file:
            changelog_file.write("".join(updated_lines))
        print(f"Updated changelog entry for {args.version} to {args.release_date}.")
    else:
        print(f"Changelog entry for {args.version} already has release date {args.release_date}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
