import argparse
import re
import sys
from datetime import date
from pathlib import Path


DATE_PATTERN = re.compile(
    r"(?P<iso>(?<!\d)\d{4}-\d{2}-\d{2}(?!\d))"
    r"|(?P<slash>(?<!\d)\d{2}/\d{2}/\d{4}(?!\d))"
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
        if second > 12 and first <= 12:
            return date.fromisoformat(release_date).strftime("%m/%d/%Y")
        return date.fromisoformat(release_date).strftime("%d/%m/%Y")
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
