"""Resolves the conflicts in a CHANGELOG.md left by merging a plugin's base branch into a pull request
branch, when each one is two lists of changelog lines added at the same place, and prints the file.

The merge must be run with merge.conflictStyle=zdiff3, so a version line both sides added sits outside
the conflict. A conflict is resolved only when nothing was there before (an empty base section) and
both sides hold nothing but "-" or "*" list lines: the base branch's lines are kept first and the pull
request's follow them, as if it had been merged second. The version they land in must not be released,
that is tagged or followed by anything but an Unreleased, TBD or TBA marker, such as a date, or the
pull request's lines would join a release they are not part of.
Anything else is a conflict for a person, and the reason goes to stderr with exit status 2.
Usage: resolve_changelog_conflict.py <conflicted CHANGELOG.md> [released version ...]
"""
import re
import sys

LIST_LINE = re.compile(r"[-*][ \t]+\S")
VERSION_LINE = re.compile(r"#*[ \t]*v?(?P<number>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?P<rest>.*)$")
# Anything else after the version, a date in whatever form included, is read as released.
UNRELEASED_REST = re.compile(r"(?:[-–—:][ \t]*)?(?:\(?(?:unreleased|not yet released|tbd|tba)\)?)?$", re.I)


class Unresolvable(Exception):
    pass


def take_until(lines, start, marker):
    """Returns the lines from start up to the one starting with marker, and the index of that line."""
    for index in range(start, len(lines)):
        if lines[index].startswith(marker):
            return lines[start:index], index
    raise Unresolvable("a conflict is not closed")


def version_above(resolved):
    for line in reversed(resolved):
        match = VERSION_LINE.match(line.rstrip("\n"))
        if match:
            return match
    return None


def resolve(lines, released):
    resolved = []
    index = 0
    conflicts = 0
    while index < len(lines):
        line = lines[index]
        if not line.startswith("<<<<<<<"):
            if line.startswith(("|||||||", "=======", ">>>>>>>")):
                raise Unresolvable("a conflict marker stands outside a conflict")
            resolved.append(line)
            index += 1
            continue
        conflicts += 1
        ours, index = take_until(lines, index + 1, "|||||||")
        base, index = take_until(lines, index + 1, "=======")
        theirs, index = take_until(lines, index + 1, ">>>>>>>")
        index += 1
        if base:
            raise Unresolvable("both sides changed lines that were already there")
        for side in (ours, theirs):
            for side_line in side:
                if not LIST_LINE.match(side_line):
                    raise Unresolvable(f"a conflict holds a line that is not a list item: {side_line.rstrip()!r}")
        version = version_above(resolved)
        if version is None:
            raise Unresolvable("a conflict is not under a version line")
        if version.group("number") in released or not UNRELEASED_REST.match(version.group("rest").strip()):
            raise Unresolvable(f"the lines would land in {version.group('number')}, which is released")
        resolved.extend(theirs)
        resolved.extend(ours)
    if conflicts == 0:
        raise Unresolvable("it has no conflict to resolve")
    return resolved


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 1
    with open(argv[1], encoding="utf-8", newline="") as handle:
        lines = handle.readlines()
    try:
        resolved = resolve(lines, set(argv[2:]))
    except Unresolvable as reason:
        print(f"CHANGELOG.md was left for a person, because {reason}.", file=sys.stderr)
        return 2
    sys.stdout.write("".join(resolved))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
