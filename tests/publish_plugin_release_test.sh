#!/bin/bash
# Tests GitHub Release lookup, publication, creation, and error classification with a fake gh CLI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/bash/publish_plugin_release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
mkdir "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1" == api ]]; then
    if [[ "$*" == *'--method PATCH'* ]]; then
        exit 0
    fi
    # The release listing is the only call made with --jq, so this prints its filtered lines.
    if [[ "$*" == *'--paginate'* ]]; then
        printf '122 4.9.0\n'
        if [[ "$FAKE_GH_MODE" == draft ]]; then
            printf '123 5.0.0\n'
        fi
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
    if [[ "$FAKE_GH_MODE" == prerelease ]]; then
        printf 'HTTP/2 200 OK\r\n\r\n{"id":123,"draft":false,"prerelease":true}\n'
        exit 0
    fi
    printf 'HTTP/2 200 OK\r\n\r\n{"id":123,"draft":false,"prerelease":false}\n'
    exit 0
fi

if [[ "$1" == release && "$2" == create ]]; then
    touch "$FAKE_GH_CREATED"
    exit 0
fi

echo "Unexpected gh invocation: $*" >&2
exit 1
SH
chmod +x "$FAKE_BIN/gh"

run_publisher() {
    local mode="$1" log="$2"
    : > "$log"
    PATH="$FAKE_BIN:$PATH" \
        FAKE_GH_MODE="$mode" \
        FAKE_GH_LOG="$log" \
        FAKE_GH_CREATED="$WORK/created-$mode" \
        GH_TOKEN=test-token \
        GITHUB_REPOSITORY=matomo-org/TestPlugin \
        bash "$SCRIPT" TestPlugin 5.0.0 2026-09-21
}

run_publisher existing "$WORK/existing.log" > /dev/null
if grep -Fq -- '--method PATCH' "$WORK/existing.log"; then
    echo 'A published release must be left unchanged' >&2
    exit 1
fi
test ! -e "$WORK/created-existing"

for mode in draft prerelease; do
    run_publisher "$mode" "$WORK/$mode.log"
    grep -Fq -- '--method PATCH repos/matomo-org/TestPlugin/releases/123 ' "$WORK/$mode.log"
    grep -Fq -- '--field draft=false' "$WORK/$mode.log"
    grep -Fq -- '--raw-field make_latest=false' "$WORK/$mode.log"
    test ! -e "$WORK/created-$mode"
    if grep -Fq -e '--raw-field name=' -e '--raw-field body=' "$WORK/$mode.log"; then
        echo "Publishing a $mode must keep its name and notes" >&2
        exit 1
    fi
done

run_publisher not-found "$WORK/not-found.log"
test -f "$WORK/created-not-found"
if grep -Fq -- '--method PATCH' "$WORK/not-found.log"; then
    echo 'A newly created release must not use PATCH' >&2
    exit 1
fi

if run_publisher server-error "$WORK/server-error.log" > "$WORK/server-error.out" 2>&1; then
    echo 'A GitHub API error must fail instead of creating a release' >&2
    exit 1
fi
test ! -e "$WORK/created-server-error"
grep -Fq '500 Internal Server Error' "$WORK/server-error.out"

echo 'All plugin release publishing tests passed.'
