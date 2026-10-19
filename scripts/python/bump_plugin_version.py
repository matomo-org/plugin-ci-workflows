"""Records a change in a plugin's plugin.json version and CHANGELOG.md, leaving the entry undated.

When the version in plugin.json is already released, it is bumped to the next patch and given a new
changelog entry in the style of the newest one. When it is not, the version stays and the entry is
added to its changelog section. Anything this cannot edit with confidence is left alone, so a
person makes the change instead of the script guessing at a changelog format.

Usage: bump_plugin_version.py <plugin-dir> <released|unreleased> <entry>
Prints one sentence saying what it did. Exits 0 when it did it, or found nothing to do, and 3,
having changed nothing, when it could not.
"""

import json
import re
import sys
from pathlib import Path

SKIPPED = 3

STABLE_VERSION = re.compile(r"\d+\.\d+\.\d+")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}|\d{2}/\d{2}/\d{4}")
BULLET = re.compile(r"(?P<indent>[ \t]*)(?P<marker>[-*+])[ \t]+(?P<text>\S.*)")
# What may follow a version heading's version for entries to sit below it: nothing, a date, or an
# Unreleased marker, with the separators changelogs put around them.
HEADING_REST = re.compile(
    r"[\s:()–—-]*"
    rf"(?:{DATE.pattern}|unreleased|not\s+yet\s+released|tb[ad])?"
    r"[\s()]*",
    re.IGNORECASE,
)


class Skip(Exception):
    pass


def version_line_pattern(plugin_name):
    # A heading, never a list item, so a one-line changelog ("* 6.0.1 - 2026-09-14 Fixed ...") does
    # not match and is left to a person. The plugin's own name is the only label allowed before the
    # version, so prose that mentions a version is not read as a heading.
    label = rf"(?:{re.escape(plugin_name)}[ \t]+)?" if plugin_name else ""
    return re.compile(
        rf"(?P<lead>(?:\#{{1,6}}[ \t]+)?{label}(?P<emphasis>\*\*|__)?(?P<bracket>\[)?v?)"
        r"(?P<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)"
        r"(?P<rest>.*)"
    )


def version_tuple(version):
    return tuple(int(part) for part in version.split("."))


def closing(match):
    rest = match.group("rest")
    end = ""
    if match.group("bracket") and rest.startswith("]"):
        end = "]"
    if match.group("emphasis") and rest[len(end):].startswith(match.group("emphasis")):
        end += match.group("emphasis")
    return end


def read_untranslated(path):
    # Line endings as they are, so a CRLF file is written back as CRLF.
    with path.open(encoding="utf-8", newline="") as handle:
        return handle.read()


def read_changelog(path):
    if not path.is_file():
        raise Skip("the plugin has no CHANGELOG.md")
    try:
        raw = read_untranslated(path)
    except (OSError, ValueError) as error:
        raise Skip(f"CHANGELOG.md could not be read ({error})") from None
    newline = "\r\n" if "\r\n" in raw else "\n"
    # Not splitlines(), which also breaks at form feeds and Unicode separators.
    lines = raw.split(newline)
    trailing = lines[-1] == ""
    if trailing:
        lines.pop()
    return lines, newline, trailing


def sections(lines, pattern):
    """Each version heading as (line index, match, index of the line after its section)."""
    headings = [(i, m) for i, line in enumerate(lines) if (m := pattern.fullmatch(line))]
    ends = [i for i, _ in headings[1:]] + [len(lines)]
    return [(i, m, end) for (i, m), end in zip(headings, ends)]


def check_section(lines, index, match, end, version):
    if not HEADING_REST.fullmatch(match.group("rest")[len(closing(match)):]):
        raise Skip(f"the {version} heading in CHANGELOG.md carries text beside the version and date")
    body = [line for line in lines[index + 1:end] if line.strip()]
    if any(line.lstrip().startswith("#") for line in body):
        raise Skip(f"the {version} section in CHANGELOG.md has headings of its own")
    if body and not BULLET.fullmatch(body[0]):
        raise Skip(f"the {version} section in CHANGELOG.md does not start with a list")
    return body


def bullet_for(entry, body, fallback_body):
    model = next((m for line in body + fallback_body if (m := BULLET.fullmatch(line))), None)
    if model is None:
        return f"- {entry}"
    return f"{model.group('indent')}{model.group('marker')} {entry}"


def add_to_section(lines, section, entry, version, fallback_body):
    index, match, end = section
    body = check_section(lines, index, match, end, version)
    if any(BULLET.fullmatch(line).group("text").strip().lower() == entry.lower()
           for line in body if BULLET.fullmatch(line)):
        return False
    # After the list's last item or continuation line, not after a footer such as a link definition.
    last = max((i for i in range(index + 1, end)
                if BULLET.fullmatch(lines[i]) or (lines[i][:1] in " \t" and lines[i].strip())),
               default=index)
    lines.insert(last + 1, bullet_for(entry, body, fallback_body))
    return True


def add_section(lines, top, entry, version):
    index, match, end = top
    body = check_section(lines, index, match, end, match.group("version"))
    heading = match.group("lead") + version + closing(match)
    gap = [""] if body and index + 1 < end and not lines[index + 1].strip() else []
    lines[index:index] = [heading, *gap, bullet_for(entry, body, []), ""]


def write_lines(path, lines, newline, trailing):
    path.write_text(newline.join(lines) + (newline if trailing else ""), encoding="utf-8", newline="")


def bump(plugin_dir, released, entry):
    manifest_path = plugin_dir / "plugin.json"
    try:
        manifest_text = read_untranslated(manifest_path)
        manifest = json.loads(manifest_text)
    except (OSError, ValueError) as error:
        raise Skip(f"plugin.json could not be read ({error})") from None
    version = manifest.get("version") if isinstance(manifest, dict) else None
    if not isinstance(version, str) or not version:
        raise Skip("plugin.json has no version")
    name = manifest.get("name") if isinstance(manifest.get("name"), str) else ""

    changelog_path = plugin_dir / "CHANGELOG.md"
    lines, newline, trailing = read_changelog(changelog_path)
    pattern = version_line_pattern(name)
    found = sections(lines, pattern)
    if not found:
        raise Skip("no version heading was found in CHANGELOG.md")
    mine = next((s for s in found if s[1].group("version") == version), None)
    # Everything below takes the first heading to be the newest, which an oldest-first file breaks.
    first = found[0][1].group("version")
    stable = [version_tuple(s[1].group("version")) for s in found if STABLE_VERSION.fullmatch(s[1].group("version"))]
    if STABLE_VERSION.fullmatch(first) and version_tuple(first) < max(stable):
        raise Skip("CHANGELOG.md does not list its newest version first")

    if not released:
        if mine is None:
            top = found[0][1].group("version")
            if not STABLE_VERSION.fullmatch(version):
                raise Skip(f"CHANGELOG.md has no {version} entry, and {version} is not a stable version to place one for")
            if not (STABLE_VERSION.fullmatch(top) and version_tuple(top) < version_tuple(version)):
                raise Skip(f"CHANGELOG.md has no {version} entry, and its newest, {top}, is not older")
            add_section(lines, found[0], entry, version)
            write_lines(changelog_path, lines, newline, trailing)
            return f"{version} is not released yet, so the version is left as it is and a {version} changelog entry saying \"{entry}\" is added, undated."
        if mine is not found[0]:
            raise Skip(f"the newest entry in CHANGELOG.md, {found[0][1].group('version')}, is ahead of {version} in plugin.json")
        # Entries are dated at release, so a dated one has most likely shipped under a tag this
        # workflow does not know about.
        if DATE.search(mine[1].group("rest")):
            raise Skip(f"{version} has no tag, but its changelog entry is dated, so it may already be released")
        if not add_to_section(lines, mine, entry, version, lines):
            return f"{version} is not released yet and its changelog entry already says \"{entry}\", so neither is changed."
        write_lines(changelog_path, lines, newline, trailing)
        return f"{version} is not released yet, so the version is left as it is and \"{entry}\" is added to its changelog entry."

    if not STABLE_VERSION.fullmatch(version):
        raise Skip(f"{version} is not a stable version, so its next patch is not obvious")
    major, minor, patch = version_tuple(version)
    new_version = f"{major}.{minor}.{patch + 1}"
    top = found[0][1].group("version")
    if not STABLE_VERSION.fullmatch(top):
        raise Skip(f"the newest entry in CHANGELOG.md, {top}, is not a stable version to compare with")
    if version_tuple(top) > version_tuple(version):
        raise Skip(f"the newest entry in CHANGELOG.md, {top}, is ahead of {version} in plugin.json")

    # Edited as text so the file keeps its formatting; there must be exactly one place to edit.
    version_key = re.compile(r'("version"\s*:\s*")' + re.escape(version) + '"')
    if len(version_key.findall(manifest_text)) != 1:
        raise Skip(f"plugin.json does not hold \"{version}\" as its version exactly once")
    new_manifest_text = version_key.sub(lambda m: m.group(1) + new_version + '"', manifest_text)
    if json.loads(new_manifest_text).get("version") != new_version:
        raise Skip("plugin.json's version could not be edited in place")

    add_section(lines, found[0], entry, new_version)
    write_lines(changelog_path, lines, newline, trailing)
    manifest_path.write_text(new_manifest_text, encoding="utf-8", newline="")
    return f"{version} is released, so the version is bumped to {new_version} with a changelog entry saying \"{entry}\", undated."


def main():
    if len(sys.argv) != 4 or sys.argv[2] not in ("released", "unreleased") or not sys.argv[3].strip():
        print("Usage: bump_plugin_version.py <plugin-dir> <released|unreleased> <entry>", file=sys.stderr)
        return 1
    entry = " ".join(sys.argv[3].split())
    try:
        print(bump(Path(sys.argv[1]), sys.argv[2] == "released", entry))
    except Skip as reason:
        print(f"The version was not bumped, because {reason}.")
        return SKIPPED
    return 0


if __name__ == "__main__":
    sys.exit(main())
