#!/bin/bash

# Writes the compatibility tests into a Matomo checkout's copy of the plugin under test, for
# plugin-compatibility.yml to run. Handed to github-action-tests as its setup-script, which runs it
# from the Matomo root with no arguments, after the dependent plugins are cloned and before PHPUnit.
#
# The files land only in the runner's Matomo checkout; nothing here touches the plugin repository.
#
# Usage: PLUGIN_NAME=<Plugin> generate_compatibility_checks.sh   (from a Matomo root)

set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../php/templates" && pwd)"
PLUGIN_NAME="${PLUGIN_NAME:-}"

# Substituted into sed and into a PHP namespace below.
if [[ ! "$PLUGIN_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "::error::Invalid or missing PLUGIN_NAME: '$PLUGIN_NAME'"
  exit 1
fi

PLUGIN_DIR="plugins/$PLUGIN_NAME"
if [ ! -d "$PLUGIN_DIR" ]; then
  echo "::error::$PLUGIN_DIR does not exist in $(pwd); this must run from the Matomo root."
  exit 1
fi

# checkout_dependent_plugins.sh prints "Skipping." and exits 0 when a clone fails, which without a
# TESTS_ACCESS_TOKEN is every private one. The leg would then fail on the plugin not loading, or on
# a mixin the dependency defines, rather than saying what is wrong.
MISSING=""
for slug in ${DEPENDENT_PLUGINS:-}; do
  name=${slug##*/}
  name=${name#plugin-}
  [ -d "plugins/$name" ] || MISSING="$MISSING $slug"
done
if [ -n "$MISSING" ]; then
  echo "::error::These dependent plugins were not checked out:$MISSING. The most likely cause is a private repository and a missing or unscoped TESTS_ACCESS_TOKEN; without one the clone is unauthenticated."
  exit 1
fi

# github-action-tests leaves the checkout token in two places: the https://<token>:@github.com URL
# of every dependent plugin's .git/config, and composer's global github-oauth entry. PHPUnit then
# executes the pull request's code, so neither may still be on disk. This script is the only hook
# between those writes and the test run, and nothing downstream needs plugin git metadata.
find plugins -mindepth 2 -maxdepth 2 -name .git -exec rm -rf {} +
# grep exits 2 on any read error even when it also matched, so fail on anything it printed: a
# matching file, or a config it could not read and so cannot vouch for.
LEFTOVER="$(grep -rIl "x-access-token\|@github.com" plugins --include=config 2>&1 || true)"
if [ -n "$LEFTOVER" ]; then
  echo "$LEFTOVER"
  echo "::error::Credential material still present, or a config unreadable, under plugins/ after scrubbing."
  exit 1
fi
if command -v composer >/dev/null 2>&1; then
  # --unset exits 0 whether or not the key exists; reading it back exits 1 once it is gone.
  composer config --global --unset github-oauth.github.com
  if composer config --global github-oauth.github.com >/dev/null 2>&1; then
    echo "::error::composer's global github-oauth entry is still set after unsetting it."
    exit 1
  fi
fi

# The same precedence run_tests.sh uses to pick the directory it hands PHPUnit, so the files are
# always somewhere that run collects. With neither present it falls back to `--group <Plugin>`
# over the whole suite, which these tests do not carry, so create tests/ for it to find instead.
TEST_ROOT="tests"
if [ -d "$PLUGIN_DIR/Test" ]; then
  TEST_ROOT="Test"
fi

TARGET_DIR="$PLUGIN_DIR/$TEST_ROOT/Integration"
mkdir -p "$TARGET_DIR"

for template in "$TEMPLATE_DIR"/Generated*.php.tpl; do
  target="$TARGET_DIR/$(basename "$template" .tpl)"
  if [ -e "$target" ]; then
    echo "::error::$target already exists, so the plugin ships a file of that name; refusing to overwrite it."
    exit 1
  fi
done

GENERATED=0
for template in "$TEMPLATE_DIR"/Generated*.php.tpl; do
  [ -f "$template" ] || continue
  target="$TARGET_DIR/$(basename "$template" .tpl)"
  sed -e "s/{{PLUGIN_NAME}}/$PLUGIN_NAME/g" -e "s/{{TEST_ROOT}}/$TEST_ROOT/g" "$template" > "$target"
  echo "Generated $target"
  GENERATED=$((GENERATED + 1))
done

if [ "$GENERATED" -ne 2 ]; then
  echo "::error::Expected to generate 2 compatibility tests from $TEMPLATE_DIR, generated $GENERATED."
  exit 1
fi
