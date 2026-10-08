#!/bin/bash
# Tags HEAD as the release once it carries plugin.json's version and a changelog entry dated the
# release date. HEAD is normally the release date commit, which is not on the development branch
# until its pull request merges.
# Usage: tag_plugin_dev_release.sh <version> <release-date>

set -euo pipefail

VERSION="${1:-}"
RELEASE_DATE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$VERSION" || -z "$RELEASE_DATE" ]]; then
    echo "Usage: $0 <version> <release-date>" >&2
    exit 1
fi

error() {
    echo "::error::$*" >&2
    exit 1
}

# Read from the commit being tagged, not the working tree, which may hold a date that was never pushed.
head_files=$(mktemp -d)
trap 'rm -rf "$head_files"' EXIT
git show HEAD:plugin.json > "$head_files/plugin.json"
git show HEAD:CHANGELOG.md > "$head_files/CHANGELOG.md"

metadata=$(python3 -c 'import json, sys; p = json.load(open(sys.argv[1], encoding="utf-8")); print(p["version"]); print(p["name"])' "$head_files/plugin.json")
mapfile -t metadata_lines <<< "$metadata"
if [[ "${metadata_lines[0]}" != "$VERSION" ]]; then
    error "HEAD is at version ${metadata_lines[0]}, not $VERSION."
fi
# The dating script leaves HEAD undated when it refuses to touch the date branch.
changelog_date=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
    --read-date --plugin-name "${metadata_lines[1]}" "$head_files/CHANGELOG.md" "$VERSION" 2>&1) || changelog_date=""
if [[ "$changelog_date" != "$RELEASE_DATE" ]]; then
    error "HEAD does not date $VERSION as $RELEASE_DATE, so it was not tagged; see the step above."
fi

tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$VERSION" > /dev/null || tag_status=$?
if (( tag_status == 0 )); then
    error "A tag for $VERSION already exists; refusing to create it again."
elif (( tag_status != 2 )); then
    error "Could not list the tags on origin."
fi
git tag "$VERSION"
git push origin "refs/tags/$VERSION"
echo "Tagged $(git rev-parse --short HEAD) as $VERSION."
