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
UNRELEASED_PATTERN = re.compile(
    r"^(?P<prefix>\s*(?:-\s*)?)(?:\(?unreleased\)?|\(?not\s+yet\s+released\)?)(?P<suffix>.*)$",
    re.IGNORECASE,
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("changelog")
    parser.add_argument("version")
    parser.add_argument("release_date", nargs="?")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--read-date", action="store_true")
    return parser.parse_args()


def version_line_pattern(version):
    return re.compile(
        rf"^(?P<prefix>\s*(?:#{{1,6}}\s+|[-*+]\s+)?)(?P<label>Version\s+)?"
        rf"(?P<emphasis>_{{0,2}}|\*{{0,2}})"
        rf"{re.escape(version)}(?![0-9.]|[-+][A-Za-z0-9])(?P=emphasis)(?P<rest>.*)$"
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


def read_date(changelog, version):
    version_line = version_line_pattern(version)
    with changelog.open("r", encoding="utf-8", newline="") as changelog_file:
        for line in changelog_file:
            content = line.rstrip("\r\n")
            match = version_line.match(content)
            if not match:
                continue
            rest = match.group("rest")
            date_match = DATE_PATTERN.match(rest.lstrip(" -(["))
            if not date_match:
                break
            return date_from_match(date_match)
    raise ValueError(f"No release date found for version {version}")


def update_date(changelog, version, release_date):
    version_line = version_line_pattern(version)

    with changelog.open("r", encoding="utf-8", newline="") as changelog_file:
        lines = changelog_file.read().splitlines(keepends=True)
    updated_lines = list(lines)

    for index, line in enumerate(lines):
        content = line.rstrip("\r\n")
        match = version_line.match(content)
        if not match:
            continue

        rest = match.group("rest")
        date_match = DATE_PATTERN.match(rest.lstrip(" -(["))
        if date_match:
            date_offset = len(rest) - len(rest.lstrip(" -(["))
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
        elif UNSUPPORTED_DATE_PATTERN.match(rest.lstrip(" -–—([")):
            # Prepending here would ship a heading with two dates. A date later in free text is kept.
            raise ValueError(
                f"The changelog entry for {version} has a date in an unsupported format: {rest.strip()}"
            )
        else:
            updated_rest = f" - {release_date}{rest}"

        updated_content = (
            match.group("prefix")
            + (match.group("label") or "")
            + match.group("emphasis")
            + version
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
    if args.read_date:
        if args.release_date is not None or args.check:
            print("--read-date cannot be combined with a release date or --check", file=sys.stderr)
            return 1
        try:
            print(read_date(changelog, args.version))
        except (OSError, ValueError) as error:
            print(error, file=sys.stderr)
            return 1
        return 0

    if args.release_date is None:
        print("a release date is required unless --read-date is used", file=sys.stderr)
        return 1

    try:
        date.fromisoformat(args.release_date)
    except ValueError:
        print(f"Invalid release date: {args.release_date}", file=sys.stderr)
        return 1

    try:
        changed, updated_lines = update_date(changelog, args.version, args.release_date)
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
