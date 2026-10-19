#!/bin/bash
# Tests GitHub Release lookup, publication, creation, and error classification with a fake gh CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/publish_plugin_release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
mkdir "$FAKE_BIN"
# FAKE_GH_MODE is the state of the 5.0.0 release, and FAKE_GH_AUTHOR who made it. FAKE_GH_LATEST
# is the latest release's tag: none when empty, and a server error when "error".
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_GH_LOG"
author="${FAKE_GH_AUTHOR:-github-actions[bot]}"
if [[ "$1" == api ]]; then
    if [[ "$*" == *'--method PATCH'* ]]; then
        exit 0
    fi
    if [[ "$*" == *releases/latest* ]]; then
        case "${FAKE_GH_LATEST:-}" in
            '') printf 'HTTP/2 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
            error) printf 'HTTP/2 500 Internal Server Error\r\n\r\n{"message":"Server error"}\n'; exit 1 ;;
            *) printf 'HTTP/2 200 OK\r\n\r\n{"id":99,"tag_name":"%s"}\n' "$FAKE_GH_LATEST"; exit 0 ;;
        esac
    fi
    # The release listing runs its real --jq filter, the last argument, over every release.
    if [[ "$*" == *'--paginate'* ]]; then
        releases='[{"id":121,"tag_name":"5.0.0","draft":false,"author":{"login":"github-actions[bot]"}},
            {"id":122,"tag_name":"4.9.0","draft":true,"author":{"login":"github-actions[bot]"}}]'
        if [[ "$FAKE_GH_MODE" == draft ]]; then
            releases=$(jq -c --arg a "$author" '. + [{id: 123, tag_name: "5.0.0", draft: true, author: {login: $a}}]' <<< "$releases")
        fi
        jq -r "${*: -1}" <<< "$releases"
        exit 0
    fi
    # Like GitHub, the tag lookup never returns a draft.
    if [[ "$FAKE_GH_MODE" == not-found || "$FAKE_GH_MODE" == draft ]]; then
        printf 'HTTP/2 404 Not Found\r\n\r\n{"message":"Not Found"}\n'
        exit 1
    fi
    if [[ "$FAKE_GH_MODE" == server-error ]]; then
        printf 'HTTP/2 500 Internal Server Error\r\n\r\n{"message":"Server error"}\n'
        exit 1
    fi
    prerelease=false
    if [[ "$FAKE_GH_MODE" == prerelease ]]; then
        prerelease=true
    fi
    printf 'HTTP/2 200 OK\r\n\r\n{"id":123,"draft":false,"prerelease":%s,"author":{"login":"%s"}}\n' "$prerelease" "$author"
    exit 0
fi

if [[ "$1" == release && "$2" == create ]]; then
    touch "$FAKE_GH_CREATED"
    while (( $# )); do
        [[ "$1" == --notes-file ]] && cp "$2" "$FAKE_GH_NOTES"
        shift
    done
    exit 0
fi

echo "Unexpected gh invocation: $*" >&2
exit 1
SH
chmod +x "$FAKE_BIN/gh"

# A plugin repository whose 5.0.0 tag has a changelog entry for the release notes.
PLUGIN_REPO="$WORK/plugin"
git init -q "$PLUGIN_REPO"
printf '## Changelog\n\n5.0.1\n- Not released yet\n\n5.0.0 - 2026-09-21\n- Fixed a report\n- Added a setting\n\n4.9.0 - 2026-09-14\n- Older change\n' \
    > "$PLUGIN_REPO/CHANGELOG.md"
git -C "$PLUGIN_REPO" add CHANGELOG.md
git -C "$PLUGIN_REPO" -c user.name=Test -c user.email=test@example.com commit -qm Release
git -C "$PLUGIN_REPO" tag 5.0.0
# The branch has moved on, so only the tag's changelog has the released wording.
sed -i 's/Fixed a report/Fixed a report later/' "$PLUGIN_REPO/CHANGELOG.md"
git -C "$PLUGIN_REPO" -c user.name=Test -c user.email=test@example.com commit -qam 'Reword after release'
NO_TAG_REPO="$WORK/no-tag"
git init -q "$NO_TAG_REPO"

run_publisher() {
    local mode="$1" log="$2"
    : > "$log"
    cd "${PUBLISH_FROM:-$PLUGIN_REPO}"
    PATH="$FAKE_BIN:$PATH" \
        FAKE_GH_MODE="$mode" \
        FAKE_GH_LATEST="${FAKE_GH_LATEST-4.9.0}" \
        FAKE_GH_LOG="$log" \
        FAKE_GH_CREATED="$WORK/created-$mode" \
        FAKE_GH_NOTES="$WORK/notes-$mode" \
        GH_TOKEN=test-token \
        GITHUB_REPOSITORY=matomo-org/TestPlugin \
        bash "$SCRIPT" TestPlugin 5.0.0 2026-09-21
}

run_publisher existing "$WORK/existing.log" > /dev/null 2> "$WORK/existing.err"
if grep -Fq 'release notes' "$WORK/existing.err"; then
    echo 'A run that writes no release notes must not warn about them' >&2
    exit 1
fi
if grep -Fq -- '--method PATCH' "$WORK/existing.log"; then
    echo 'A published release must be left unchanged' >&2
    exit 1
fi
test ! -e "$WORK/created-existing"

for mode in draft prerelease; do
    run_publisher "$mode" "$WORK/$mode.log"
    grep -Fq -- '--method PATCH repos/matomo-org/TestPlugin/releases/123 ' "$WORK/$mode.log"
    grep -Fq -- '--field draft=false' "$WORK/$mode.log"
    grep -Fq -- '--raw-field make_latest=true' "$WORK/$mode.log"
    test ! -e "$WORK/created-$mode"
    if grep -Fq -e '--raw-field name=' -e '--raw-field body=' "$WORK/$mode.log"; then
        echo "Publishing a $mode must keep its name and notes" >&2
        exit 1
    fi

    FAKE_GH_AUTHOR=a-maintainer run_publisher "$mode" "$WORK/$mode-other.log" > "$WORK/$mode-other.out"
    if grep -Fq -- '--method PATCH' "$WORK/$mode-other.log"; then
        echo "Someone else's $mode must be left for them to publish" >&2
        exit 1
    fi
    test ! -e "$WORK/created-$mode"
    grep -Fq 'was made by a-maintainer, so it was left for them to publish' "$WORK/$mode-other.out"
done

run_publisher not-found "$WORK/not-found.log"
test -f "$WORK/created-not-found"
if grep -Fq -- '--method PATCH' "$WORK/not-found.log"; then
    echo 'A newly created release must not use PATCH' >&2
    exit 1
fi
grep -Eq '^release create 5\.0\.0 .*--verify-tag .*--latest=true$' "$WORK/not-found.log" || {
    echo 'A new release must be made only from the existing tag, and as the latest when it is the highest version' >&2
    exit 1
}
CHANGELOG_LINK='See [CHANGELOG.md](https://github.com/matomo-org/TestPlugin/blob/5.0.0/CHANGELOG.md) for the full changelog.'
[[ "$(cat "$WORK/notes-not-found")" == "$(printf 'Released on 2026-09-21.\n\n- Fixed a report\n- Added a setting\n\n%s' "$CHANGELOG_LINK")" ]] || {
    echo "A new release must list the changes in its tag's changelog entry" >&2
    exit 1
}

PUBLISH_FROM="$NO_TAG_REPO" run_publisher not-found "$WORK/no-tag.log" 2> "$WORK/no-tag.err"
grep -Eq '^::warning::No changes were read .*\(.+\), so its release notes only link to CHANGELOG.md$' "$WORK/no-tag.err" || {
    echo 'A release whose notes fall back to the link must warn with the reason' >&2
    exit 1
}
[[ "$(cat "$WORK/notes-not-found")" == "$(printf 'Released on 2026-09-21.\n\n%s' "$CHANGELOG_LINK")" ]] || {
    echo 'Without a changelog entry to read, the release notes must link to the changelog' >&2
    exit 1
}

# An older major's patch must not take latest from a newer major, and with no latest release yet the
# new one takes it.
for latest in 6.0.0 v6.0.0 5.0.0 ''; do
    expected=false
    [[ "$latest" == '' ]] && expected=true
    FAKE_GH_LATEST="$latest" run_publisher not-found "$WORK/latest.log" > /dev/null
    grep -Eq -- "--latest=$expected\$" "$WORK/latest.log" || {
        echo "With ${latest:-no} latest release, 5.0.0 must be created with --latest=$expected" >&2
        exit 1
    }
    FAKE_GH_LATEST="$latest" run_publisher draft "$WORK/latest.log"
    grep -Fq -- "--raw-field make_latest=$expected" "$WORK/latest.log" || {
        echo "With ${latest:-no} latest release, the 5.0.0 draft must be published with make_latest=$expected" >&2
        exit 1
    }
done

rm -f "$WORK/created-not-found"
if FAKE_GH_LATEST=error run_publisher not-found "$WORK/latest-error.log" > /dev/null 2>&1; then
    echo 'A failed latest release lookup must fail instead of guessing' >&2
    exit 1
fi
test ! -e "$WORK/created-not-found"

if run_publisher server-error "$WORK/server-error.log" > "$WORK/server-error.out" 2>&1; then
    echo 'A GitHub API error must fail instead of creating a release' >&2
    exit 1
fi
test ! -e "$WORK/created-server-error"
grep -Fq '500 Internal Server Error' "$WORK/server-error.out"

echo 'All plugin release publishing tests passed.'
