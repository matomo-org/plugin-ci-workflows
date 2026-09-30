#!/bin/bash
# Scopes a plugin's installed dependencies into vendor/prefixed, transpiles them down to the PHP the
# plugin supports, and checks the result.
#
# The same steps as DevPluginCommands' process-dependencies command, without Matomo's console:
# matomo-scoper and Rector are both standalone. Run composer install or composer update in the
# plugin first; the scoper prefixes whatever the unprefixed vendor/ tree holds. The
# scope-dependencies action runs this script, so a local run and CI produce the same tree.
#
# Usage: scope_plugin_dependencies.sh [options] [plugin-dir]
#
#   --downgrade-php=TARGET  auto (default) reads it from plugin.json: 8.1 when the plugin requires
#                           Matomo 6 or later, 7.3 otherwise. none skips Rector. Or 7.3 or 8.1.
#   --scoper-dir=PATH       Use an existing matomo-scoper checkout instead of fetching one.
#   --scoper-ref=REF        Ref of matomo-org/matomo-scoper to fetch. Defaults to the commit pinned
#                           below. Only the pinned commit has its php-scoper.phar checked against a
#                           known hash; either option leaves the scoper to fetch its own.
#   --allow-namespace=NS    A namespace allowed to stay outside Matomo\Dependencies\<plugin> in
#                           vendor/prefixed, besides Composer\Autoload, which the scoper leaves
#                           for Composer's generated autoloader. Repeatable.
#   --tools-dir=PATH        Where matomo-scoper and Rector are installed and kept between runs.
#                           Defaults to ${XDG_CACHE_HOME:-~/.cache}/matomo-scope-dependencies.
#   --dry-run               Print the plugin and the downgrade target, and stop.
#
# Needs php 8.1 or later, composer, jq, git and curl on PATH. The plugin directory must be a git checkout, because
# the tree check compares composer.lock against HEAD.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_SOURCE="$ROOT/actions/scope-dependencies"
SCOPER_URL=https://github.com/matomo-org/matomo-scoper.git
# The scoper's output is committed as code the plugin ships, and nobody reads a vendor/prefixed diff
# line by line, so what runs is pinned rather than taken from a branch. The phar is the build the
# pinned scoper downloads (its ScopeCommand::PHP_SCOPER_URL); move all three together.
SCOPER_PINNED_REF=45ab803e32a44cde075cb64b552e2401a5d532b4
PHP_SCOPER_URL=https://github.com/matomo-org/php-scoper/releases/download/custom-build-2/php-scoper.phar
PHP_SCOPER_SHA256=0a130dacec0845f43225bcf4dba6c492b8257081089533723dd39fde130db3da

downgrade_input=auto
scoper_dir=''
scoper_ref=''
allowed=('Composer\Autoload')
tools_dir="${XDG_CACHE_HOME:-$HOME/.cache}/matomo-scope-dependencies"
dry_run=0
plugin_path=''

for arg in "$@"; do
  case "$arg" in
    --downgrade-php=*) downgrade_input="${arg#*=}" ;;
    --scoper-dir=*) scoper_dir="${arg#*=}" ;;
    --scoper-ref=*) scoper_ref="${arg#*=}" ;;
    --allow-namespace=*) allowed+=("${arg#*=}") ;;
    --tools-dir=*) tools_dir="${arg#*=}" ;;
    --dry-run) dry_run=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "::error::Unknown option $arg. Run with --help for usage." >&2
      exit 2
      ;;
    *)
      if [ -n "$plugin_path" ]; then
        echo "::error::Only one plugin directory can be scoped at a time." >&2
        exit 2
      fi
      plugin_path="$arg"
      ;;
  esac
done
plugin_path="${plugin_path:-.}"
scoper_ref="${scoper_ref:-$SCOPER_PINNED_REF}"

# Xdebug's nesting limit makes php-scoper copy deeply nested files through unprefixed while still
# reporting success.
export XDEBUG_MODE=off

for tool in php composer jq git curl; do
  if ! command -v "$tool" >/dev/null; then
    echo "::error::$tool is not on PATH." >&2
    exit 1
  fi
done

if [ ! -f "$plugin_path/plugin.json" ]; then
  echo "::error::No plugin.json in $plugin_path." >&2
  exit 1
fi
plugin_dir="$(cd "$plugin_path" && pwd)"
plugin_name=$(jq -r '.name // empty' "$plugin_dir/plugin.json")
if [ -z "$plugin_name" ]; then
  echo "::error file=plugin.json::plugin.json has no name, and matomo-scoper builds the namespace prefix from it." >&2
  exit 1
fi

case "$downgrade_input" in
  none) downgrade='' ;;
  7.3|8.1) downgrade="$downgrade_input" ;;
  auto)
    # Only the lowest bound matters: it is the oldest Matomo, so the oldest PHP, the plugin runs on.
    # DevPluginCommands takes the first bound instead, which is the same for every constraint
    # without an ||.
    constraint=$(jq -r '.require.matomo // empty' "$plugin_dir/plugin.json")
    major=$(printf '%s' "$constraint" | grep -oE '(>=|\^|~)[[:space:]]*[0-9]+\.' | grep -oE '[0-9]+' | sort -n | head -1 || true)
    if [ -z "$major" ]; then
      echo "::warning::No >=, ^ or ~ lower bound in the Matomo requirement '$constraint', so transpiling to the lowest target. Pass --downgrade-php to choose one." >&2
      downgrade=7.3
    elif [ "$major" -ge 6 ]; then
      downgrade=8.1
    else
      downgrade=7.3
    fi
    echo "Transpiling down to PHP $downgrade, from the Matomo requirement '$constraint'."
    ;;
  *)
    echo "::error::--downgrade-php must be auto, none, 7.3 or 8.1, not '$downgrade_input'." >&2
    exit 2
    ;;
esac

echo "Scoping $plugin_name in $plugin_dir. Allowed outside its prefix: ${allowed[*]}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "plugin-name=$plugin_name"
    echo "downgrade=$downgrade"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$dry_run" -eq 1 ]; then
  exit 0
fi

rector_dir="$tools_dir/rector"
mkdir -p "$tools_dir" "$rector_dir"
own_scoper="$scoper_dir"
if [ -z "$scoper_dir" ]; then
  scoper_dir="$tools_dir/matomo-scoper"
  if [ ! -d "$scoper_dir/.git" ]; then
    git init -q "$scoper_dir"
  fi
  git -C "$scoper_dir" fetch -q --depth 1 "$SCOPER_URL" "$scoper_ref"
  git -C "$scoper_dir" checkout -q --detach FETCH_HEAD
  composer install --working-dir="$scoper_dir" --no-dev --no-interaction --no-progress
fi
if [ ! -f "$scoper_dir/bin/matomo-scoper" ]; then
  echo "::error::$scoper_dir is not a matomo-scoper checkout." >&2
  exit 1
fi
# A developer's own checkout is left for them to install, since --no-dev would uninstall its dev
# packages.
if [ ! -f "$scoper_dir/vendor/autoload.php" ]; then
  echo "::error::$scoper_dir has no vendor/. Run composer install in it first." >&2
  exit 1
fi
echo "matomo-scoper at $(git -C "$scoper_dir" rev-parse HEAD 2>/dev/null || echo "$scoper_dir, not a git checkout")"

cp "$TOOLS_SOURCE/tools/composer.json" "$TOOLS_SOURCE/tools/composer.lock" "$rector_dir/"
composer install --working-dir="$rector_dir" --no-interaction --no-progress

# The scoper uses any php-scoper.phar already in its root and downloads one only when there is none,
# without checking it. An empty phar, from a download that failed partway, runs as a no-op that
# exits 0, after the scoper has already deleted the unprefixed packages. Hence the -s: php exits 0
# on an empty file even with --version.
phar="$scoper_dir/php-scoper.phar"
phar_runs() {
  [ -s "$phar" ] && php "$phar" --version >/dev/null 2>&1
}
phar_intact() {
  # shellcheck disable=SC2016 # $argv is PHP's, not the shell's.
  [ -f "$1" ] && [ "$(php -r 'echo hash_file("sha256", $argv[1]);' "$1")" = "$PHP_SCOPER_SHA256" ]
}
if [ -z "$own_scoper" ] && [ "$(git -C "$scoper_dir" rev-parse HEAD)" = "$SCOPER_PINNED_REF" ]; then
  # The pinned build is put there here, checked, before the scoper can run it.
  if ! phar_intact "$phar"; then
    download="$phar.download"
    curl -fsSL --retry 3 -o "$download" "$PHP_SCOPER_URL"
    if ! phar_intact "$download"; then
      rm -f "$download"
      echo "::error::The php-scoper.phar downloaded from $PHP_SCOPER_URL does not have the pinned sha256 $PHP_SCOPER_SHA256." >&2
      exit 1
    fi
    mv "$download" "$phar"
  fi
elif [ -n "$own_scoper" ]; then
  echo "::warning::The php-scoper.phar in $scoper_dir is left as it is, so it is not checked against a known hash."
  if [ -e "$phar" ] && ! phar_runs; then
    echo "Removing a php-scoper.phar that does not run, so the scoper downloads it again."
    rm -f "$phar"
  fi
else
  echo "::warning::matomo-scoper is not the pinned commit, so the php-scoper.phar it runs is not checked against a known hash."
  # Another ref may download another build, so a kept copy, perhaps the pinned one, is not reused.
  rm -f "$phar"
fi

php "$scoper_dir/bin/matomo-scoper" scope "$plugin_dir" --yes --ignore-platform-check

if ! phar_runs; then
  echo "::error::php-scoper.phar did not download intact, so nothing was scoped. Restore vendor/ with composer install before running again." >&2
  exit 1
fi

if [ -n "$downgrade" ]; then
  RECTOR_DOWNGRADE_PHP_VERSION="$downgrade" "$rector_dir/vendor/bin/rector" process "$plugin_dir/vendor/prefixed" \
    --config="$TOOLS_SOURCE/rector.php" --no-progress-bar
fi

bash "$ROOT/scripts/bash/check_scoped_tree.sh" "$plugin_dir" "$plugin_name" "${allowed[@]}"
