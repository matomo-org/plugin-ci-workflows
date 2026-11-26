"""Resolves the conflicts in a CHANGELOG.md left by merging a plugin's base branch into a pull request
branch, when each one is two lists of changelog lines added at the same place, and prints the file.

The merge must be run with merge.conflictStyle=zdiff3, so a version line both sides added sits outside
the conflict. A conflict is resolved only when nothing was there before (an empty base section) and
both sides hold nothing but "-" or "*" list lines: the base branch's lines are kept first and the pull
request's follow them, as if it had been merged second. The version they land in must not be released,
that is tagged or followed by anything but an Unreleased, TBD or TBA marker, such as a date, or the
pull request's lines would join a release they are not part of.
One-line entries such as "* 6.0.4 - Fixed X" are the other case: where both sides only appended text
to the same such line, its old text is kept with the base branch's addition and then the pull
request's. That entry must not be released either: tagged, or carrying a date after its version.
Each line extended that way is written to the --extended file, so that --restore can map a diff's
lines back for the check that the pull request still adds and removes what it did.
Anything else is a conflict for a person, and the reason goes to stderr with exit status 2.
Usage: resolve_changelog_conflict.py [--extended <file>] <conflicted CHANGELOG.md> [released version ...]
       resolve_changelog_conflict.py --restore <extended file> < changed lines
"""
import json
import re
import sys

LIST_LINE = re.compile(r"[-*][ \t]+\S")
VERSION_LINE = re.compile(r"#*[ \t]*v?(?P<number>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?P<rest>.*)$")
# Anything else after the version, a date in whatever form included, is read as released.
UNRELEASED_REST = re.compile(r"(?:[-–—:][ \t]*)?(?:\(?(?:unreleased|not yet released|tbd|tba)\)?)?$", re.I)
ONE_LINE_ENTRY = re.compile(
    r"[ \t]*[-*][ \t]+v?(?P<number>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?P<rest>[ \t]*[-–—:][ \t]*\S.*)$"
)
# Reads as a date what update_changelog_date.py does, broadly: anything starting with a number, or a
# month name with a year, either after an optional weekday. Reading too much as a date only leaves a conflict for a person.
MONTH = r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"
WEEKDAY = r"(?:(?:mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?\.?,?[ \t]+)?"
DATED_REST = re.compile(
    rf"[ \t\-–—:(\[*_]*{WEEKDAY}(?:\d|{MONTH}[ \t./,-]+(?:\d{{1,2}}[a-z]*[ \t./,-]+)?\d{{4}})",
    re.I,
)


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


def append_both(base, ours, theirs, released):
    """Returns the base branch's text, the joined text, the old text and the pull request's text, then the
    joined line, when both sides only appended to one one-line entry, or None when the conflict is
    anything else."""
    if len(base) != 1 or len(ours) != 1 or len(theirs) != 1:
        return None
    old, ours_text, theirs_text = (side[0].rstrip("\r\n") for side in (base, ours, theirs))
    entry = ONE_LINE_ENTRY.match(old)
    if entry is None or len(ours_text) <= len(old) or len(theirs_text) <= len(old):
        return None
    if not ours_text.startswith(old) or not theirs_text.startswith(old):
        return None
    # One side's text holding the other's would repeat it once joined.
    if theirs_text.startswith(ours_text) or ours_text.startswith(theirs_text):
        return None
    # Text added mid-word changes the last word rather than appending, as "Fixed A" to "Fixed API".
    if old[-1].isalnum() and (ours_text[len(old)].isalnum() or theirs_text[len(old)].isalnum()):
        return None
    if entry.group("number") in released or DATED_REST.match(entry.group("rest")):
        raise Unresolvable(f"both sides added to the {entry.group('number')} entry, which is released")
    joined = theirs_text + ours_text[len(old):]
    return (theirs_text, joined, old, ours_text), joined + theirs[0][len(theirs_text):]


def resolve(lines, released, extended):
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
            appended = append_both(base, ours, theirs, released)
            if appended is None:
                raise Unresolvable("both sides changed lines that were already there")
            extended.append(appended[0])
            resolved.append(appended[1])
            continue
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


def restore(extended_file):
    """Reads a changed_lines listing on stdin and maps each extended entry's lines back to what the pull
    request had: the base branch's line removed becomes the old line, and the joined line added becomes
    the pull request's. Prints the listing sorted as LC_ALL=C sort does. It works on bytes, split only on
    newlines, so that every other line passes through as changed_lines printed it."""
    with open(extended_file, encoding="utf-8") as handle:
        mapping = {}
        for theirs_text, joined, old, ours_text in json.load(handle):
            mapping[b"CHANGELOG.md\t-" + theirs_text.encode()] = b"CHANGELOG.md\t-" + old.encode()
            mapping[b"CHANGELOG.md\t+" + joined.encode()] = b"CHANGELOG.md\t+" + ours_text.encode()
    lines = sys.stdin.buffer.read().split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    restored = []
    for line in lines:
        text = line.rstrip(b"\r")
        restored.append(mapping.get(text, text) + line[len(text):])
    sys.stdout.buffer.write(b"".join(line + b"\n" for line in sorted(restored)))
    return 0


def main(argv):
    usage = "\n".join(__doc__.strip().splitlines()[-2:])
    if argv[1:2] == ["--restore"]:
        if len(argv) != 3:
            print(usage, file=sys.stderr)
            return 1
        return restore(argv[2])
    extended_file = None
    if "--extended" in argv:
        at = argv.index("--extended")
        if at + 1 == len(argv):
            print(usage, file=sys.stderr)
            return 1
        extended_file, argv = argv[at + 1], argv[:at] + argv[at + 2:]
    if len(argv) < 2:
        print(usage, file=sys.stderr)
        return 1
    with open(argv[1], encoding="utf-8", newline="") as handle:
        lines = handle.readlines()
    extended = []
    try:
        resolved = resolve(lines, set(argv[2:]), extended)
    except Unresolvable as reason:
        print(f"CHANGELOG.md was left for a person, because {reason}.", file=sys.stderr)
        return 2
    if extended_file is not None:
        with open(extended_file, "w", encoding="utf-8") as handle:
            json.dump(extended, handle)
    sys.stdout.write("".join(resolved))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
