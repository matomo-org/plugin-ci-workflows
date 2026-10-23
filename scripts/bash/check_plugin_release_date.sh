#!/bin/bash
# Fails when plugin.json's unreleased version has a dated CHANGELOG.md entry, or one the release
# could not date, or follows an undated entry whose version was never tagged, in a plugin released
# by plugin-dev-release.yml. That workflow dates the entry the day it releases it, so a date written
# by hand is a guess it would overwrite.
# Checks N.x-dev and the release-branch a plugin passes to that workflow, and fails on every branch
# when that release-branch is not a literal branch name, since the branch it names is unknown here,
# or when a workflow cannot be read.
# Passes for any other plugin or branch, a prerelease version, or a version already tagged, which
# includes the release date pull request the workflow opens after tagging.
# Run from a checkout of the plugin.
# Usage: check_plugin_release_date.sh <branch>

set -euo pipefail

BRANCH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tests pin the day; the workflow always uses the real one.
TODAY="${PLUGIN_RELEASE_TODAY:-$(date -u +%F)}"
RELEASE_WORKFLOW='plugin-ci-workflows/.github/workflows/plugin-dev-release.yml@'

if [[ -z "$BRANCH" ]]; then
    echo "Usage: $0 <branch>" >&2
    exit 1
fi

error() {
    echo "::error file=$1::$2" >&2
    exit 1
}

shopt -s nullglob
workflow_files=(.github/workflows/*.yml .github/workflows/*.yaml)
# -P keeps the plugin checkout, the working directory, off the import path, so its yaml.py cannot stand in for the real module.
if ! python3 -P -c 'import yaml' 2>/dev/null; then
    echo "::error::PyYAML is not available, so the plugin's workflows cannot be read." >&2
    exit 1
fi
# Parsed, not grepped, so a commented-out call does not count. Exits 3 when no job calls it, so an
# unreadable workflow cannot pass as a plugin that does not. That holds on every branch, as the
# branch to check comes from the workflows. Prints each call's release-branch, or the error.
calls_status=0
calls_output=$(python3 -P - "$RELEASE_WORKFLOW" "${workflow_files[@]}" <<'PY'
import sys, yaml
target = sys.argv[1]
found = False
release_branches = []

def fail(message):
    # On stdout, the only stream the caller captures for its error.
    print(message)
    sys.exit(1)

for path in sys.argv[2:]:
    try:
        with open(path, encoding='utf-8') as handle:
            doc = yaml.safe_load(handle)
    except (OSError, UnicodeDecodeError, ValueError, yaml.YAMLError) as error:
        fail(f'{path}: {error}')
    jobs = doc.get('jobs') if isinstance(doc, dict) else None
    if not isinstance(jobs, dict):
        continue
    for job in jobs.values():
        uses = job.get('uses') if isinstance(job, dict) else None
        if isinstance(uses, str) and '@' in uses and (uses.split('@', 1)[0] + '@').endswith(target):
            found = True
            inputs = job.get('with')
            branch = inputs.get('release-branch') if isinstance(inputs, dict) else None
            if isinstance(branch, str) and '${{' in branch:
                fail(f'{path}: release-branch must be a literal branch name for the date check, not {branch}')
            if branch is not None and not isinstance(branch, str):
                # YAML reads 1.10 as the number 1.1, so the branch name is already lost.
                fail(f'{path}: quote release-branch, it is read as {branch!r}')
            # '*' cannot be a branch name, so it marks a call that releases from N.x-dev.
            release_branches.append(branch if isinstance(branch, str) and branch else '*')
if not found:
    sys.exit(3)
print('\n'.join(release_branches))
PY
) || calls_status=$?
if (( calls_status == 3 )); then
    echo "This plugin does not call plugin-dev-release.yml, so its changelog dates are its own."
    exit 0
elif (( calls_status != 0 )); then
    echo "::error::Could not read the plugin's workflows: $calls_output" >&2
    exit 1
fi

# A listed release branch wins over the N.x-dev pattern, as it does in the release itself.
if grep -qxF -- "$BRANCH" <<< "$calls_output"; then
    # Empty: a release branch's versions are not tied to a Matomo major.
    expected_major=""
elif [[ "$BRANCH" =~ ^([0-9]+)\.x-dev$ ]] && grep -qxF '*' <<< "$calls_output"; then
    expected_major="${BASH_REMATCH[1]}"
else
    echo "$BRANCH is not released by the weekly release, so the changelog date is not checked."
    exit 0
fi

# -P keeps the plugin checkout, the working directory, off the import path, so its json.py cannot stand in for the real module.
if ! metadata=$(python3 -P -c 'import json; p = json.load(open("plugin.json", encoding="utf-8")); print(p["version"]); print(p["name"])' 2>&1); then
    error plugin.json "Could not read the version and name from plugin.json: $metadata"
fi
mapfile -t metadata_lines <<< "$metadata"
VERSION="${metadata_lines[0]}"
PLUGIN_NAME="${metadata_lines[1]}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$VERSION is not a stable version, so it is not released and its date is not checked."
    exit 0
fi
if [[ -n "$expected_major" && "${VERSION%%.*}" != "$expected_major" ]]; then
    error plugin.json "Version $VERSION does not belong on $BRANCH."
fi

tag_status=0
git ls-remote --exit-code --tags origin "refs/tags/$VERSION" > /dev/null || tag_status=$?
if (( tag_status == 0 )); then
    echo "$VERSION is already released."
    exit 0
elif (( tag_status != 2 )); then
    echo "::error::Could not list the tags on origin." >&2
    exit 1
fi

# Dating a scratch copy proves the release will find the entry and can date it.
scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT
cp CHANGELOG.md "$scratch"
if ! dating_error=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
    --plugin-name "$PLUGIN_NAME" "$scratch" "$VERSION" "$TODAY" 2>&1); then
    error CHANGELOG.md "The weekly release could not date the $VERSION entry: $dating_error"
fi

if changelog_date=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
    --read-date --plugin-name "$PLUGIN_NAME" CHANGELOG.md "$VERSION" 2>/dev/null); then
    error CHANGELOG.md "The $VERSION entry is dated $changelog_date. Leave it undated or write Unreleased: the weekly release dates it on the day it releases."
fi

# The release only ever takes plugin.json's version, so one bumped past would never be tagged.
if ! earlier=$(python3 "$SCRIPT_DIR/../python/update_changelog_date.py" \
    --read-next-undated --plugin-name "$PLUGIN_NAME" CHANGELOG.md "$VERSION" 2> "$scratch"); then
    error CHANGELOG.md "Could not read the entry below $VERSION: $(tr '\n' ' ' < "$scratch")"
fi
if [[ -n "$earlier" && ( -z "$expected_major" || "${earlier%%.*}" == "$expected_major" ) ]]; then
    tag_status=0
    git ls-remote --exit-code --tags origin "refs/tags/$earlier" "refs/tags/v$earlier" > /dev/null || tag_status=$?
    if (( tag_status == 2 )); then
        error CHANGELOG.md "The $earlier entry is undated and $earlier has not been released, so the weekly release would skip it. Keep one unreleased entry: merge the $earlier entry into $VERSION's, or put the change in $earlier and set plugin.json back to it."
    elif (( tag_status != 0 )); then
        echo "::error::Could not list the tags on origin." >&2
        exit 1
    fi
fi

echo "$VERSION is undated, so the weekly release will date it."
