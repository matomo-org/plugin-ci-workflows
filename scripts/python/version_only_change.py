"""Says whether a plugin.json change does nothing but set its version.

Usage: version_only_change.py <old plugin.json> <new plugin.json> [version]
Exits 0 when the two files differ only in "version", and the new one is <version> when it is given,
and 1 otherwise, including when either file cannot be read as a JSON object.
"""

import json
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if not isinstance(manifest, dict):
        raise ValueError("not a JSON object")
    return manifest


def main():
    if len(sys.argv) not in (3, 4):
        print("Usage: version_only_change.py <old plugin.json> <new plugin.json> [version]", file=sys.stderr)
        return 2
    try:
        old, new = load(sys.argv[1]), load(sys.argv[2])
    except (OSError, ValueError):
        return 1
    if len(sys.argv) == 4 and new.get("version") != sys.argv[3]:
        return 1
    if old.get("version") == new.get("version"):
        return 1
    old.pop("version", None)
    new.pop("version", None)
    return 0 if old == new else 1


if __name__ == "__main__":
    sys.exit(main())
