#!/bin/bash

# Prints the oldest PHP a plugin's scoped dependency tree has to run on.
#
# Emits either a literal version ("8.2") or one of the shared aliases ("matomo6_min_php"), so the
# caller can pipe the result through github-action-tests' resolve_php_version.sh -- which passes a
# literal through unchanged and turns an alias into a version. The floor table deliberately lives
# only in that resolver: a second copy drifts exactly when a floor moves.
#
# The lowest floor any manifest declares wins, not the first one found. composer.json says what
# the tree was resolved against and plugin.json says what the plugin claims to support, and when
# they disagree the gap is the defect. OAuth2 pins its composer platform to 8.2.0 while its
# plugin.json declares >=8.1.0: Matomo installs on the plugin.json floor, `platform-check` is
# false in that tree, so a user on 8.1 loads code resolved for 8.2 with nothing to stop them.
# Linting at 8.2 cannot see that; linting at 8.1 reports it, and the red is a true positive.
#
# Usage: resolve_plugin_min_php.sh [plugin-directory]

set -uo pipefail

PLUGIN_DIR="${1:-.}"

python3 - "$PLUGIN_DIR" <<'PY'
import json, os, re, sys

plugin_dir = sys.argv[1]


def load(name):
    path = os.path.join(plugin_dir, name)
    if not os.path.exists(path):
        return None
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        sys.stderr.write(f"Could not read {path}: {error}\n")
        sys.exit(1)


def floor_of(constraint):
    """The lower bound of a composer constraint, as 'X.Y'.

    A bare major ('>=8') means 8.0. Anything with no version at all -- '*', 'dev-main' -- has no
    floor, and returns None so the caller falls through rather than inventing one.
    """
    if not constraint:
        return None
    match = re.search(r'(\d+)(?:\.(\d+))?', str(constraint))
    if not match:
        return None
    return f"{match.group(1)}.{match.group(2) or '0'}"


composer = load('composer.json')
plugin = load('plugin.json')

if plugin is None and composer is None:
    sys.stderr.write(f"No composer.json or plugin.json in '{plugin_dir}'.\n")
    sys.exit(1)

composer_platform = ((composer or {}).get('config') or {}).get('platform') or {}
plugin_require = (plugin or {}).get('require') or {}

# Deliberately only these two. config.platform.php is what composer solved for, so it says
# what syntax the tree may contain; plugin.json require.php is the lowest PHP a user can reach,
# because that is what Matomo gates activation on. composer.json require.php is neither -- it
# only constrains the platform package, and absent a pinned platform composer resolves against
# whatever PHP the packaging machine had, so a stale value there would lower the floor on
# evidence that does not exist.
candidates = [
    ('composer.json config.platform.php', composer_platform.get('php')),
    ('plugin.json require.php', plugin_require.get('php')),
]
floors = [(floor_of(c), source, c) for source, c in candidates if floor_of(c)]

if floors:
    def as_tuple(entry):
        return tuple(int(part) for part in entry[0].split('.'))

    resolved, source, constraint = min(floors, key=as_tuple)

    # When the manifests disagree, say so: the gap is itself the defect. OAuth2 pins its
    # composer platform to 8.2.0 while plugin.json declares >=8.1.0, and Matomo installs on the
    # plugin.json floor -- so a user on 8.1 activates a tree resolved for 8.2, with
    # `platform-check: false` disabling the guard that would otherwise raise. Linting at the
    # higher floor cannot see that fatal, which is why the lowest wins rather than the first.
    distinct = {entry[0] for entry in floors}
    if len(distinct) > 1:
        listed = ', '.join(f"{s} {c} -> {f}" for f, s, c in floors)
        sys.stderr.write(f"Manifests disagree on the PHP floor ({listed}); taking the lowest.\n")

    sys.stderr.write(f"Floor from {source}: {constraint} -> {resolved}\n")
    print(resolved)
    sys.exit(0)

# Nothing declares a PHP floor, so the plugin inherits the one belonging to the oldest Matomo it
# supports. `piwik` is the pre-rename spelling and still present in older plugin.json files.
matomo = plugin_require.get('matomo') or plugin_require.get('piwik') or ''
match = re.search(r'>=\s*[^0-9]*(\d+)', str(matomo))
if match:
    alias = f"matomo{match.group(1)}_min_php"
    sys.stderr.write(f"No PHP floor declared; using the Matomo {match.group(1)} floor: {alias}\n")
    print(alias)
    sys.exit(0)

sys.stderr.write(
    f"Could not determine a minimum PHP version for '{plugin_dir}' "
    f"(no php constraint in composer.json or plugin.json, and no usable require.matomo).\n"
)
sys.exit(1)
PY
