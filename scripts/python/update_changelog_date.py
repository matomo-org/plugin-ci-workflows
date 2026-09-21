#!/usr/bin/env python3

import argparse
import re
import sys
from datetime import date
from pathlib import Path


DATE_PATTERN = re.compile(r"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("changelog")
    parser.add_argument("version")
    parser.add_argument("release_date")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def update_date(changelog, version, release_date):
    version_line = re.compile(
        rf"^(?P<prefix>\s*(?:#{{1,6}}\s+|[-*+]\s+)?)(?P<emphasis>_{{0,2}})"
        rf"{re.escape(version)}(?![0-9.])(?P=emphasis)(?P<rest>.*)$"
    )

    with changelog.open("r", encoding="utf-8", newline="") as changelog_file:
        lines = changelog_file.read().splitlines(keepends=True)
    updated_lines = list(lines)

    for index, line in enumerate(lines):
        content = line.rstrip("\r\n")
        match = version_line.match(content)
        if not match:
            continue

        rest = match.group("rest")
        date_match = DATE_PATTERN.search(rest)
        if date_match:
            updated_rest = (
                rest[:date_match.start()]
                + release_date
                + rest[date_match.end():]
            )
        else:
            updated_rest = f" - {release_date}{rest}"

        updated_content = (
            match.group("prefix")
            + match.group("emphasis")
            + version
            + match.group("emphasis")
            + updated_rest
        )
        line_ending = line[len(content):]
        updated_lines[index] = updated_content + line_ending
        changed = updated_lines != lines
        return changed, updated_lines

    raise ValueError(f"No changelog entry found for version {version}")


def main():
    args = parse_args()

    try:
        date.fromisoformat(args.release_date)
    except ValueError:
        print(f"Invalid release date: {args.release_date}", file=sys.stderr)
        return 1

    changelog = Path(args.changelog)
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
