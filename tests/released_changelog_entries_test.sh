#!/bin/bash
# Tests the check that fails a pull request changing a released version's changelog entry, with a
# bare origin standing in for GitHub.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/bash/check_released_changelog_entries.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

CHANGELOG='## Changelog

### 6.0.3
* Three

### 6.0.2 - 2026-10-05
* Two
'

# Builds <name>/origin.git with 6.x-dev, 6.0.2 tagged, and a clone at <name>/clone on a pull request
# branch. A second argument replaces the changelog.
new_repo() {
    local name="$1" changelog="${2:-$CHANGELOG}"
    local seed="$WORK/$name/seed"
    mkdir -p "$seed"
    git init -q "$seed"
    printf '{"name":"TestPlugin","version":"6.0.3"}\n' > "$seed/plugin.json"
    printf '%s' "$changelog" > "$seed/CHANGELOG.md"
    printf '<?php\n' > "$seed/API.php"
    git -C "$seed" add .
    git -C "$seed" commit -q -m initial
    git -C "$seed" branch -M 6.x-dev
    git -C "$seed" tag 6.0.2
    git clone -q --bare "$seed" "$WORK/$name/origin.git"
    git clone -q --branch 6.x-dev "$WORK/$name/origin.git" "$WORK/$name/clone"
    git -C "$WORK/$name/clone" checkout -q -b feature
}

# Replaces <from> with <to> in the clone's CHANGELOG.md.
edit_changelog() {
    python3 - "$WORK/$1/clone/CHANGELOG.md" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
assert old in text, old
open(path, "w").write(text.replace(old, new, 1))
PY
}

touch_code() {
    printf '<?php // %s\n' "$RANDOM" > "$WORK/$1/clone/API.php"
}

commit() {
    git -C "$WORK/$1/clone" commit -q -am change
}

# Moves origin's 6.x-dev on with a commit that edits <file>, as a merged pull request would, and
# fetches it into the clone.
advance_base() {
    local name="$1" file="$2" from="${3:-}" to="${4:-}"
    local other="$WORK/$name/other"
    git clone -q --branch 6.x-dev "$WORK/$name/origin.git" "$other"
    if [[ -n "$from" ]]; then
        python3 -c 'import sys; p, o, n = sys.argv[1:]; t = open(p).read(); open(p, "w").write(t.replace(o, n, 1))' \
            "$other/$file" "$from" "$to"
    else
        printf '// %s\n' "$RANDOM" >> "$other/$file"
    fi
    git -C "$other" commit -q -am "base moves"
    git -C "$other" push -q origin 6.x-dev
    rm -rf "$other"
    git -C "$WORK/$name/clone" fetch -q origin
}

tag_origin() {
    git -C "$WORK/$1/origin.git" tag "$2" 6.x-dev
}

run() {
    local name="$1"
    (cd "$WORK/$name/clone" && bash "$CHECK" 6.x-dev "$(git rev-parse HEAD)") > "$WORK/$name/out" 2>&1
}

says() {
    grep -Fq "$2" "$WORK/$1/out"
}

new_repo released
edit_changelog released '* Two' $'* Two\n* Added later'
touch_code released
commit released
if run released; then fail "a change listed under a released version fails"; fi
says released 'changes the changelog entry of 6.0.2, already released' || { cat "$WORK/released/out" >&2; fail "the failure names the released version"; }

new_repo correction
edit_changelog correction '* Two' '* Two, corrected'
commit correction
run correction || { cat "$WORK/correction/out" >&2; fail "a pull request changing only CHANGELOG.md passes"; }

new_repo unreleased
edit_changelog unreleased '* Three' $'* Three\n* Four'
touch_code unreleased
commit unreleased
run unreleased || { cat "$WORK/unreleased/out" >&2; fail "a change listed under the unreleased version passes"; }

new_repo no-changelog
touch_code no-changelog
commit no-changelog
run no-changelog || fail "a pull request not changing CHANGELOG.md passes"
says no-changelog 'CHANGELOG.md is not changed' || fail "it says the changelog is untouched"

new_repo dated
edit_changelog dated '### 6.0.2 - 2026-10-05' '### 6.0.2 - 2026-10-06'
touch_code dated
commit dated
run dated || { cat "$WORK/dated/out" >&2; fail "a changed date on a released version line passes"; }

new_repo removed
edit_changelog removed $'### 6.0.2 - 2026-10-05\n* Two\n' ''
touch_code removed
commit removed
if run removed; then fail "removing a released entry fails"; fi
says removed 'entry of 6.0.2, already released' || { cat "$WORK/removed/out" >&2; fail "removing fails as a released entry"; }

new_repo v-tag
git -C "$WORK/v-tag/origin.git" tag -d 6.0.2 > /dev/null
git -C "$WORK/v-tag/origin.git" tag v6.0.2 6.x-dev
edit_changelog v-tag '* Two' $'* Two\n* Added later'
touch_code v-tag
commit v-tag
if run v-tag; then fail "a version released as v6.0.2 counts as released"; fi
says v-tag 'entry of 6.0.2, already released' || { cat "$WORK/v-tag/out" >&2; fail "v6.0.2 fails as a released entry"; }

new_repo named $'## Changelog\n\nTestPlugin 6.0.3\n* Three\n\nTestPlugin 6.0.2 - 2026-10-05\n* Two\n'
edit_changelog named '* Two' $'* Two\n* Added later'
touch_code named
commit named
if run named; then fail "an entry headed with the plugin name is read"; fi
says named 'entry of 6.0.2, already released' || { cat "$WORK/named/out" >&2; fail "a named entry fails as a released entry"; }

# A released version's entry corrected on 6.x-dev after the pull request branched is not the pull
# request's change.
new_repo base-moved
edit_changelog base-moved '* Three' $'* Three\n* Four'
touch_code base-moved
commit base-moved
advance_base base-moved CHANGELOG.md '* Two' '* Two, corrected'
run base-moved || { cat "$WORK/base-moved/out" >&2; fail "a released entry changed only on the base branch passes"; }

# 6.0.3 is released while the pull request adding to it is open: the run before passes, the run after
# fails, whether or not the release moved 6.x-dev.
new_repo released-later
edit_changelog released-later '* Three' $'* Three\n* Four'
touch_code released-later
commit released-later
run released-later || { cat "$WORK/released-later/out" >&2; fail "a change under 6.0.3 passes before 6.0.3 is released"; }
tag_origin released-later 6.0.3
if run released-later; then fail "a change under 6.0.3 fails once 6.0.3 is tagged"; fi
advance_base released-later CHANGELOG.md '### 6.0.3' '### 6.0.3 - 2026-10-12'
if run released-later; then fail "a change under 6.0.3 fails once 6.0.3 is tagged and dated"; fi
says released-later 'entry of 6.0.3, already released' || { cat "$WORK/released-later/out" >&2; fail "the late release fails as a released entry"; }

new_repo version-led
edit_changelog version-led '* Three' $'* Three\n* 6.0.2 compatibility is kept'
touch_code version-led
commit version-led
run version-led || { cat "$WORK/version-led/out" >&2; fail "a new note starting with a released version is not taken for its entry"; }

new_repo bad-plugin-json
edit_changelog bad-plugin-json '* Three' $'* Three\n* Four'
printf '{not json' > "$WORK/bad-plugin-json/clone/plugin.json"
commit bad-plugin-json
if run bad-plugin-json; then fail "an unreadable plugin.json fails rather than dropping the plugin name"; fi
says bad-plugin-json 'Could not read the plugin name' || { cat "$WORK/bad-plugin-json/out" >&2; fail "an unreadable plugin.json says so"; }

# --- after a push ---

run_push() {
    local name="$1" before="$2"
    (cd "$WORK/$name/clone" && bash "$CHECK" --push "$before" "$(git rev-parse HEAD)") > "$WORK/$name/out" 2>&1
}

new_repo push-released
edit_changelog push-released '* Two' $'* Two\n* Added later'
touch_code push-released
commit push-released
if run_push push-released "$(git -C "$WORK/push-released/clone" rev-parse 6.x-dev)"; then fail "a push changing a released entry fails"; fi
says push-released 'entry of 6.0.2, already released' || { cat "$WORK/push-released/out" >&2; fail "the push fails as a released entry"; }

new_repo push-correction
edit_changelog push-correction '* Two' '* Two, corrected'
commit push-correction
run_push push-correction "$(git -C "$WORK/push-correction/clone" rev-parse 6.x-dev)" \
    || { cat "$WORK/push-correction/out" >&2; fail "a push changing only CHANGELOG.md passes"; }

new_repo push-merge
edit_changelog push-merge '* Two' $'* Two\n* Added later'
touch_code push-merge
commit push-merge
git -C "$WORK/push-merge/clone" checkout -q 6.x-dev
printf 'x\n' > "$WORK/push-merge/clone/other.txt"
git -C "$WORK/push-merge/clone" add other.txt
git -C "$WORK/push-merge/clone" commit -q -m other
before=$(git -C "$WORK/push-merge/clone" rev-parse HEAD)
git -C "$WORK/push-merge/clone" merge -q --no-edit feature
run_push push-merge "$before" || { cat "$WORK/push-merge/out" >&2; fail "a push holding a merge commit is not checked"; }
says push-merge 'holds a merge commit' || fail "it says the merge is not checked"

new_repo push-new-branch
touch_code push-new-branch
commit push-new-branch
run_push push-new-branch 0000000000000000000000000000000000000000 || fail "a push creating a branch passes"

new_repo push-forced
edit_changelog push-forced '* Two' $'* Two\n* Added later'
touch_code push-forced
commit push-forced
run_push push-forced 1234567890123456789012345678901234567890 || { cat "$WORK/push-forced/out" >&2; fail "a force push whose before is gone passes"; }

new_repo no-base
touch_code no-base
commit no-base
if (cd "$WORK/no-base/clone" && bash "$CHECK" 7.x-dev HEAD) > "$WORK/no-base/out" 2>&1; then
    fail "a base branch that cannot be found fails"
fi
says no-base 'Could not find where the pull request branched' || { cat "$WORK/no-base/out" >&2; fail "a missing base says so"; }

# An entry the release cannot read, here one with an unclosed fence, is compared as written.
new_repo unclosed-fence $'## Changelog\n\n### 6.0.3\n* Three\n\n### 6.0.2 - 2026-10-05\n* Two\n```\nexample\n'
edit_changelog unclosed-fence 'example' 'example changed'
touch_code unclosed-fence
commit unclosed-fence
if run unclosed-fence; then fail "an edit inside a released entry the release cannot read fails"; fi
says unclosed-fence 'entry of 6.0.2' || { cat "$WORK/unclosed-fence/out" >&2; fail "an unreadable released entry is named"; }

new_repo no-tags
edit_changelog no-tags '* Two' $'* Two\n* Added later'
touch_code no-tags
commit no-tags
git -C "$WORK/no-tags/clone" remote set-url origin "$WORK/no-tags/missing.git"
if run no-tags; then fail "tags that cannot be listed fail rather than reading as none released"; fi
says no-tags 'Could not list the tags on origin' || { cat "$WORK/no-tags/out" >&2; fail "unlistable tags say so"; }

new_repo missing-blob
edit_changelog missing-blob '* Two' $'* Two\n* Added later'
touch_code missing-blob
commit missing-blob
blob=$(git -C "$WORK/missing-blob/clone" rev-parse HEAD:CHANGELOG.md)
rm -f "$WORK/missing-blob/clone/.git/objects/${blob:0:2}/${blob:2}"
if run missing-blob; then fail "a changelog that cannot be read fails rather than reading as missing"; fi
says missing-blob 'Could not read CHANGELOG.md' || { cat "$WORK/missing-blob/out" >&2; fail "an unreadable changelog says so"; }

# Merging an older branch forward brings whole entries for versions it already released.
new_repo merge-forward
git -C "$WORK/merge-forward/origin.git" tag 5.0.4 6.x-dev
edit_changelog merge-forward '### 6.0.2 - 2026-10-05' $'### 5.0.4 - 2026-09-01\n* Older fix\n\n### 6.0.2 - 2026-10-05'
touch_code merge-forward
commit merge-forward
run merge-forward || { cat "$WORK/merge-forward/out" >&2; fail "a whole entry for a released version merged forward passes"; }

# Dating an entry the release cannot read is not a change to it.
new_repo dated-unreadable $'## Changelog\n\n### 6.0.3\n* Three\n\n### 6.0.2\n* Two\n```\nexample\n'
edit_changelog dated-unreadable '### 6.0.2' '### 6.0.2 - 2026-10-05'
touch_code dated-unreadable
commit dated-unreadable
run dated-unreadable || { cat "$WORK/dated-unreadable/out" >&2; fail "dating a released entry the release cannot read passes"; }

echo "All released changelog entry checks passed."
