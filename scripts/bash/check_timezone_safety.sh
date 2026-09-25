#!/bin/bash

# Finds the date and database patterns that have caused Matomo reports to use the server's day
# instead of the website's day. This is intentionally a static check: repositories without a
# timezone regression suite still get useful coverage, and repositories with one do not get a
# false pass merely because a test file exists.
#
# Usage: check_timezone_safety.sh [--base-ref <git-ref>] [--fail-on-warnings]
#        [--fail-on-new-findings] [--advisory] [repo-root]
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo '::error::The timezone safety check requires Bash 4 or newer.' >&2
  exit 2
fi

BASE_REF=''
FAIL_ON_WARNINGS=0
FAIL_ON_NEW_FINDINGS=0
ADVISORY=0
REPO_ROOT='.'

usage() {
  echo "Usage: $0 [--base-ref <git-ref>] [--fail-on-warnings] [--fail-on-new-findings] [--advisory] [repo-root]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-ref)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BASE_REF="$2"
      shift 2
      ;;
    --fail-on-warnings)
      FAIL_ON_WARNINGS=1
      shift
      ;;
    --fail-on-new-findings)
      FAIL_ON_NEW_FINDINGS=1
      shift
      ;;
    --advisory)
      ADVISORY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage
      exit 2
      ;;
    *)
      [ "$REPO_ROOT" = '.' ] || { usage; exit 2; }
      REPO_ROOT="$1"
      shift
      ;;
  esac
done

if [ "$FAIL_ON_NEW_FINDINGS" -eq 1 ] && [ -z "$BASE_REF" ]; then
  echo '::error::--fail-on-new-findings requires --base-ref' >&2
  exit 2
fi

REPO_ROOT=$(cd "$REPO_ROOT" && pwd)
cd "$REPO_ROOT"

if ! command -v python3 >/dev/null 2>&1; then
  echo '::error::The timezone safety check requires python3 for argument-aware PHP scanning.' >&2
  exit 2
fi

errors=0
warnings=0
scanned=0
changed_errors=0
changed_warnings=0
changed_source_files=0
parser_failures=0
changed_diff_file=''
changed_names_file=''
source_listing=''
suite_listing=''
sanitized_dir=''

declare -A changed_lines=()
declare -A deletion_points=()
declare -A reported_findings=()
declare -A sanitized_files=()
# Changed file => its path at the merge base, for comparing how class names resolve there.
declare -A base_paths=()
# file:line => whole-line or trailing, for a timezone-safety-ignore marker in real comment text.
declare -A ignore_comments=()

cleanup() {
  [ -z "$changed_diff_file" ] || rm -f "$changed_diff_file"
  [ -z "$changed_names_file" ] || rm -f "$changed_names_file"
  [ -z "$source_listing" ] || rm -f "$source_listing"
  [ -z "$suite_listing" ] || rm -f "$suite_listing"
  [ -z "$sanitized_dir" ] || rm -rf "$sanitized_dir"
}

trap cleanup EXIT

report() {
  local severity="$1" file="$2" line="$3" message="$4" end_line="${5:-$3}" context_start="${6:-0}" context_end="${7:-0}"
  local resolution_changed="${8:-0}"
  local annotation_line="$line" changed=0 candidate changed_line_key previous_line previous_changed=0
  local annotation_file annotation_message
  annotation_file=$(escape_annotation "$file")
  annotation_message=$(escape_annotation_message "$message")
  for ((candidate = line; candidate <= end_line; candidate++)); do
    changed_line_key="$file:$candidate"
    if [ -n "${changed_lines[$changed_line_key]+set}" ]; then
      changed=1
      break
    fi
  done
  if [ "$changed" -eq 0 ]; then
    # A deletion point is the first current line after the removed text. If it equals the
    # finding's first line, the deletion was immediately before the finding; only a point after
    # that first line can be part of the multiline expression being reported.
    for ((candidate = line + 1; candidate <= end_line; candidate++)); do
      changed_line_key="$file:$candidate"
      if [ -n "${deletion_points[$changed_line_key]+set}" ]; then
        changed=1
        break
      fi
    done
  fi
  # Context that changes what the finding means: an import that now names a different class, or
  # the rest of an SQL expression. Checked before the suppressions, so an old marker does not cover a finding whose meaning changed.
  if [ "$resolution_changed" -eq 1 ]; then
    changed=1
  fi
  for ((candidate = context_start; changed == 0 && candidate > 0 && candidate <= context_end; candidate++)); do
    if [ -n "${changed_lines["$file:$candidate"]+set}" ] \
      || { [ "$candidate" -gt "$context_start" ] && [ -n "${deletion_points["$file:$candidate"]+set}" ]; }; then
      changed=1
    fi
  done
  # A marker anywhere in an SQL expression covers a clock in it, because the lines between may all
  # be inside one string, where no comment can go.
  local suppress_start="$line" suppress_end="$end_line"
  if [ "$context_start" -gt 0 ]; then
    [ "$context_start" -ge "$suppress_start" ] || suppress_start="$context_start"
    [ "$context_end" -le "$suppress_end" ] || suppress_end="$context_end"
  fi
  for ((candidate = suppress_start; candidate <= suppress_end; candidate++)); do
    if [ -n "${ignore_comments["$file:$candidate"]+set}" ] \
      && { [ "$changed" -eq 0 ] || [ -n "${changed_lines["$file:$candidate"]+set}" ]; }; then
      return
    fi
  done
  if [ "$suppress_start" -gt 1 ]; then
    previous_line=$((suppress_start - 1))
    if [ "${ignore_comments["$file:$previous_line"]-}" = whole-line ] \
      && [ -n "${changed_lines["$file:$previous_line"]+set}" ]; then
      previous_changed=1
    fi
    if [ "${ignore_comments["$file:$previous_line"]-}" = whole-line ] \
      && { [ -z "${deletion_points["$file:$suppress_start"]+set}" ] || [ "$previous_changed" -eq 1 ]; } \
      && { [ "$changed" -eq 0 ] || [ "$previous_changed" -eq 1 ]; }; then
      return
    fi
  fi
  local finding_key="$severity:$file:$line:$end_line:$message"
  if [ -n "${reported_findings[$finding_key]+set}" ]; then
    return
  fi
  reported_findings["$finding_key"]=1
  case "$severity" in
    error)
      errors=$((errors + 1))
      if [ "$changed" -eq 1 ]; then
        echo "::$([ "$ADVISORY" -eq 1 ] && echo notice || echo error) file=$annotation_file,line=$annotation_line::Timezone finding on a changed production line: $annotation_message"
        changed_errors=$((changed_errors + 1))
      elif [ "$ADVISORY" -eq 1 ]; then
        echo "::notice file=$annotation_file,line=$annotation_line::$annotation_message"
      elif [ "$FAIL_ON_NEW_FINDINGS" -eq 1 ]; then
        echo "::notice file=$annotation_file,line=$annotation_line::$annotation_message"
      else
        echo "::error file=$annotation_file,line=$annotation_line::$annotation_message"
      fi
      ;;
    warning)
      warnings=$((warnings + 1))
      if [ "$changed" -eq 1 ]; then
        echo "::$([ "$ADVISORY" -eq 1 ] && echo notice || echo warning) file=$annotation_file,line=$annotation_line::Timezone finding on a changed production line: $annotation_message"
        changed_warnings=$((changed_warnings + 1))
      elif [ "$ADVISORY" -eq 1 ]; then
        echo "::notice file=$annotation_file,line=$annotation_line::$annotation_message"
      elif [ "$FAIL_ON_NEW_FINDINGS" -eq 1 ]; then
        echo "::notice file=$annotation_file,line=$annotation_line::$annotation_message"
      else
        echo "::warning file=$annotation_file,line=$annotation_line::$annotation_message"
      fi
      ;;
  esac
}

escape_annotation() {
  local value="$1"
  value=${value//%/%25}
  value=${value//$'\r'/%0D}
  value=${value//$'\n'/%0A}
  value=${value//:/%3A}
  value=${value//,/%2C}
  printf '%s' "$value"
}

escape_annotation_message() {
  local value="$1"
  value=${value//%/%25}
  value=${value//$'\r'/%0D}
  value=${value//$'\n'/%0A}
  printf '%s' "$value"
}

is_excluded() {
  case "$1" in
    ./.git/*|*/.git/*|./vendor/*|*/vendor/*|./node_modules/*|*/node_modules/*|./libs/*|*/libs/*|./tests/*|*/tests/*|./test/*|*/test/*|./vue/dist/*|*/vue/dist/*)
      return 0
      ;;
  esac
  return 1
}

files=()
if [ -n "$BASE_REF" ]; then
  if ! git rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1; then
    echo "::error::The timezone check base revision '$BASE_REF' does not exist" >&2
    exit 2
  fi
  if ! merge_base=$(git merge-base "$BASE_REF" HEAD 2>/dev/null); then
    echo "::error::The timezone check base revision '$BASE_REF' has no common ancestor with HEAD" >&2
    exit 2
  fi
  changed_diff_file=$(mktemp)
  changed_names_file=$(mktemp)
  # Against the working tree rather than HEAD, because the files scanned are the ones on disk.
  if ! git -c core.quotePath=false diff --no-ext-diff --no-textconv --relative --src-prefix=a/ --dst-prefix=b/ --unified=0 --no-color --diff-filter=ACMRTUXB "$merge_base" -- '*.php' '*.sql' > "$changed_diff_file"; then
    echo '::error::Unable to build the timezone check changed-line map.' >&2
    exit 2
  fi
  changed_line_output=''
  if ! changed_line_output=$(python3 -c '
import re
import sys

sys.stdin.reconfigure(errors="surrogateescape")
sys.stdout.reconfigure(errors="surrogateescape")
current_file = None
new_line = None
hunk_new_start = None
hunk_new_count = None
pending_suppression = None

def flush_pending_suppression():
    global pending_suppression
    if pending_suppression is not None:
        file, line = pending_suppression
        print(f"S\t{file}\t{line}")
        pending_suppression = None

for raw_line in sys.stdin:
    line = raw_line.rstrip("\n")
    if line.startswith("diff --git "):
        flush_pending_suppression()
        current_file = None
        new_line = None
        hunk_new_start = None
        hunk_new_count = None
        continue
    if line.startswith("+++ b/") and new_line is None:
        flush_pending_suppression()
        current_file = line[6:].rstrip("\t")
        new_line = None
        continue
    if line.startswith("+++ /dev/null") and new_line is None:
        flush_pending_suppression()
        current_file = None
        new_line = None
        continue
    if line.startswith("+++") and new_line is None:
        raise SystemExit(1)
    if line.startswith("@@"):
        flush_pending_suppression()
        match = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if match:
            new_line = int(match.group(1))
            hunk_new_start = new_line
            hunk_new_count = int(match.group(2) or "1")
        continue
    if current_file is None or new_line is None or line.startswith("\\"):
        continue
    if line.startswith("+"):
        flush_pending_suppression()
        print(f"A\t{current_file}\t{new_line}")
        new_line += 1
    elif line.startswith("-"):
        pending_suppression = None
        deletion_point = hunk_new_start + (hunk_new_count if hunk_new_count else 1)
        print(f"D\t{current_file}\t{deletion_point}")
        if re.search(r"^\s*(//|#|/\*|\*|--).*timezone-safety-ignore", line[1:]):
            suppression_line = hunk_new_start + (hunk_new_count if hunk_new_count else 1)
            pending_suppression = (current_file, suppression_line)
    else:
        flush_pending_suppression()
        new_line += 1
flush_pending_suppression()
' < "$changed_diff_file"); then
    echo '::error::Unable to parse the timezone check changed-line map.' >&2
    exit 2
  fi
  while IFS=$'\t' read -r change_type file line; do
    [ -n "$file" ] || continue
    case "$change_type" in
      A|S) changed_lines["$file:$line"]=1 ;;
      D) deletion_points["$file:$line"]=1 ;;
    esac
  done <<< "$changed_line_output"
  if ! git -c core.quotePath=false diff --no-ext-diff --no-textconv --relative --name-status -z --diff-filter=ACMRTUXB "$merge_base" > "$changed_names_file"; then
    echo '::error::Unable to list changed files for the timezone check.' >&2
    exit 2
  fi
  while IFS= read -r -d '' change_status && IFS= read -r -d '' file; do
    base_path="$file"
    case "$change_status" in
      R*|C*) IFS= read -r -d '' file ;;
      A*) base_path='' ;;
    esac
    [ -f "$file" ] || continue
    is_excluded "./$file" && continue
    case "$file" in
      *.php|*.sql) changed_source_files=$((changed_source_files + 1)) ;;
    esac
    [ -z "$base_path" ] || base_paths["$file"]="$base_path"
  done < "$changed_names_file"
  if ! git -c core.quotePath=false ls-files --others --exclude-standard -z -- '*.php' '*.sql' > "$changed_names_file"; then
    echo '::error::Unable to list untracked files for the timezone check.' >&2
    exit 2
  fi
  while IFS= read -r -d '' file; do
    is_excluded "./$file" && continue
    changed_source_files=$((changed_source_files + 1))
    line_count=$(wc -l < "$file")
    for ((line = 1; line <= line_count + 1; line++)); do
      changed_lines["$file:$line"]=1
    done
  done < "$changed_names_file"
fi

# Always scan the complete current tree. A base revision adds context about changed lines; it must
# not hide older findings elsewhere in the repository.
source_listing=$(mktemp)
if ! find . \( -name .git -o -name vendor -o -name node_modules -o -name libs -o -path './tests' -o -path './test' -o -path './vue/dist' \) -prune \
  -o -type f \( -name '*.php' -o -name '*.sql' \) -print0 > "$source_listing"; then
  echo '::error::Unable to list PHP and SQL source files for the timezone check.' >&2
  exit 2
fi
while IFS= read -r -d '' file; do
  is_excluded "$file" && continue
  files+=("$file")
done < "$source_listing"

scan_pattern() {
  local severity="$1" regex="$2" message="$3" file_kind="${4:-all}" grep_case="${5:-sensitive}" file match line sanitized_file matches grep_status
  local -a grep_args=(-anE)
  if [ "$file_kind" = sql ] || [ "$grep_case" = insensitive ]; then
    grep_args=(-aniE)
  fi
  for file in "${files[@]}"; do
    case "$file_kind:$file" in
      php:*.php|sql:*.sql|all:*) ;;
      *) continue ;;
    esac
    sanitized_file="${sanitized_files[$file]-}"
    [ -n "$sanitized_file" ] || continue
    grep_status=0
    matches=$(LC_ALL=C grep "${grep_args[@]}" "$regex" "$sanitized_file") || grep_status=$?
    if [ "$grep_status" -gt 1 ]; then
      parser_failures=$((parser_failures + 1))
      annotation_file=$(escape_annotation "${file#./}")
      echo "::error file=$annotation_file::Unable to scan sanitized source for timezone patterns."
      continue
    fi
    [ -n "$matches" ] || continue
    while IFS= read -r match; do
      line="${match%%:*}"
      report "$severity" "${file#./}" "$line" "$message"
    done <<< "$matches"
  done
}

scanned=${#files[@]}

sanitize_scan_input() {
  local file="$1" ignore_path="$2"
  # shellcheck disable=SC2016,SC2094 # the $ is Python source; python only reads the name of $file.
  LC_ALL=C python3 -c '
import re
import sys

text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
is_sql = sys.argv[1].endswith(".sql")


def heredoc_end(position):
    line_end = text.find("\n", position)
    if line_end == -1:
        line_end = len(text)
    match = re.match(r"<<<[ \t]*-?[\"\x27]?([A-Za-z_][A-Za-z0-9_]*)[\"\x27]?", text[position:line_end])
    if not match:
        return position
    label = re.escape(match.group(1))
    closing = re.search(r"(?m)^[ \t]*" + label + r"(?![A-Za-z0-9_\x80-\uffff])", text[line_end + 1:])
    if not closing:
        return len(text)
    return line_end + 1 + closing.end()


# PHP expands {$...} and ${...} inside double quotes and backticks, and the expression can hold
# quotes of its own, so the string only ends at a quote outside every interpolation.
def php_quoted_end(position):
    quote = text[position]
    position += 1
    depth = 0
    while position < len(text):
        character = text[position]
        if depth:
            if character in ("\x27", "\""):
                position = php_quoted_end(position)
                continue
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
        elif character == "\\":
            position += 2
            continue
        elif quote != "\x27" and (text.startswith("{$", position) or text.startswith("${", position)):
            depth = 1
            position += 2
            continue
        elif character == quote:
            return position + 1
        position += 1
    return position


output = []
comments = []
comment_start = None
position = 0
state = "code"
quote = None
if not is_sql:
    first_php_tag = text.find("<?")
    if first_php_tag > 0:
        output.extend("\n" if character == "\n" else "" for character in text[:first_php_tag])
        position = first_php_tag
while position < len(text):
    if state == "quoted":
        character = text[position]
        output.append("\n" if character == "\n" else " ")
        if character == quote and position + 1 < len(text) and text[position + 1] == quote:
            output.append(" ")
            position += 2
            continue
        if character == "\\" and position + 1 < len(text):
            output.append("\n" if text[position + 1] == "\n" else " ")
            position += 2
            continue
        if character == quote:
            state = "code"
            quote = None
        position += 1
        continue
    if state == "line":
        if text[position] == "\n":
            comments.append((comment_start, position))
            output.append("\n")
            state = "code"
        position += 1
        continue
    if state == "block":
        if text.startswith("*/", position):
            comments.append((comment_start, position + 2))
            state = "code"
            position += 2
        else:
            if text[position] == "\n":
                output.append("\n")
            position += 1
        continue

    if not is_sql and text.startswith("?>", position):
        next_php_tag = text.find("<?", position + 2)
        end = len(text) if next_php_tag == -1 else next_php_tag
        output.extend("\n" if character == "\n" else "" for character in text[position:end])
        position = end
        continue

    heredoc_end_position = heredoc_end(position) if text.startswith("<<<", position) else position
    if heredoc_end_position != position:
        output.append(text[position:heredoc_end_position])
        position = heredoc_end_position
        continue
    if text[position] in ("\x27", "\"", "`"):
        if not is_sql:
            end = php_quoted_end(position)
            output.append(text[position:end])
            position = end
            continue
        quote = text[position]
        state = "quoted"
        output.append(text[position])
        position += 1
        continue
    if text.startswith("//", position) or (
        text[position] == "#" and not text.startswith("#[", position)
    ):
        comment_start = position
        state = "line"
        position += 2 if text.startswith("//", position) else 1
        continue
    if text.startswith("/*", position):
        comment_start = position
        state = "block"
        position += 2
        continue
    # MySQL starts a comment at `--` followed by whitespace, whatever precedes it; `1--1` is arithmetic.
    if is_sql and text.startswith("--", position) and (position + 2 == len(text) or text[position + 2].isspace()):
        comment_start = position
        state = "line"
        position += 2
        continue
    output.append(text[position])
    position += 1
if state in ("line", "block"):
    comments.append((comment_start, len(text)))

sys.stdout.buffer.write("".join(output).encode("utf-8"))

in_comment = bytearray(len(text))
for start, end in comments:
    in_comment[start:end] = b"\x01" * (end - start)
with open(sys.argv[2], "w") as ignores:
    line_start = 0
    for number, line in enumerate(text.split("\n"), 1):
        if "timezone-safety-ignore" in line:
            comment = "".join(c for i, c in enumerate(line) if in_comment[line_start + i])
            if "timezone-safety-ignore" in comment:
                has_code = any(not in_comment[line_start + i] and not c.isspace() for i, c in enumerate(line))
                kind = "trailing" if has_code else "whole-line"
                ignores.write(f"{number}\t{kind}\n")
        line_start += len(line) + 1
' "$file" "$ignore_path" < "$file"
}

sanitized_dir=$(mktemp -d)
sanitized_index=0
for file in "${files[@]}"; do
  sanitized_path="$sanitized_dir/$sanitized_index"
  sanitized_index=$((sanitized_index + 1))
  if ! sanitize_scan_input "$file" "$sanitized_path.ignores" > "$sanitized_path"; then
    parser_failures=$((parser_failures + 1))
    annotation_file=$(escape_annotation "${file#./}")
    echo "::error file=$annotation_file::Unable to sanitize source before scanning."
    rm -f "$sanitized_path" "$sanitized_path.ignores"
    continue
  fi
  sanitized_files["$file"]="$sanitized_path"
  while IFS=$'\t' read -r ignore_line ignore_kind; do
    ignore_comments["${file#./}:$ignore_line"]="$ignore_kind"
  done < "$sanitized_path.ignores"
done

scan_php_calls() {
  local file="$1" base_file="${2-}"
  python3 - "$file" "$base_file" <<'PY'
import re
import sys

path, base_path = sys.argv[1], sys.argv[2]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
    base_text = open(base_path, encoding="utf-8", errors="replace").read() if base_path else None
except OSError as error:
    print(f"Unable to scan PHP source: {error}", file=sys.stderr)
    sys.exit(1)
relative_dates = {"today", "yesterday", "yesterdaySameTime".lower()}


def line_number(position):
    return text.count("\n", 0, position) + 1


# Same interpolation rule as the sanitizer's php_quoted_end.
def skip_quoted(position, quote):
    position += 1
    depth = 0
    while position < len(text):
        character = text[position]
        if depth:
            if character in ("'", '"'):
                position = skip_quoted(position, character)
                continue
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
        elif character == "\\":
            position += 2
            continue
        elif quote != "'" and (text.startswith("{$", position) or text.startswith("${", position)):
            depth = 1
            position += 2
            continue
        elif character == quote:
            return position + 1
        position += 1
    return position


def skip_heredoc(position):
    if not text.startswith("<<<", position):
        return position
    line_end = text.find("\n", position)
    if line_end == -1:
        line_end = len(text)
    opener = text[position:line_end]
    match = re.match(r"<<<[ \t]*-?[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?", opener)
    if not match:
        return position
    label = re.escape(match.group(1))
    closing = re.search(r"(?m)^[ \t]*" + label + r"(?![A-Za-z0-9_\x80-\uffff])", text[line_end + 1:])
    if not closing:
        return None
    return line_end + 1 + closing.end()


def skip_comment(position):
    if text.startswith("//", position) or (
        text.startswith("#", position) and not text.startswith("#[", position)
    ):
        newline = text.find("\n", position)
        return len(text) if newline == -1 else newline + 1
    if text.startswith("/*", position):
        end = text.find("*/", position + 2)
        return len(text) if end == -1 else end + 2
    return position


def parse_arguments(open_position):
    arguments = []
    argument_start = open_position + 1
    position = argument_start
    depth = 1
    square_depth = 0
    curly_depth = 0

    while position < len(text):
        character = text[position]
        if character in ("'", '"', "`"):
            position = skip_quoted(position, character)
            continue
        heredoc_end = skip_heredoc(position)
        if heredoc_end is None:
            return None
        if heredoc_end != position:
            position = heredoc_end
            continue
        comment_end = skip_comment(position)
        if comment_end != position:
            position = comment_end
            continue
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                arguments.append(text[argument_start:position])
                if arguments and not arguments[-1].strip():
                    arguments.pop()
                return arguments, position
        elif character == "[":
            square_depth += 1
        elif character == "]":
            square_depth -= 1
        elif character == "{":
            curly_depth += 1
        elif character == "}":
            curly_depth -= 1
        elif character == "," and depth == 1 and square_depth == 0 and curly_depth == 0:
            arguments.append(text[argument_start:position])
            argument_start = position + 1
        position += 1

    return None


# Namespace and use statements only count in code, not in strings, heredocs or comments.
def code_only():
    code = list(text)
    position = 0
    while position < len(text):
        if text.startswith("?>", position):
            next_php_tag = text.find("<?", position + 2)
            end = len(text) if next_php_tag == -1 else next_php_tag
        else:
            end = skip_heredoc(position)
            if end is None:
                end = len(text)
            elif end == position and text[position] in ("'", '"', "`"):
                end = skip_quoted(position, text[position])
            elif end == position:
                end = skip_comment(position)
        if end == position:
            position += 1
            continue
        for blank in range(position, end):
            if code[blank] != "\n":
                code[blank] = " "
        position = end
    return "".join(code)


name_pattern = r"\\?[A-Za-z_][A-Za-z0-9_]*(?:\\[A-Za-z_][A-Za-z0-9_]*)*"
matomo_classes = {"piwik\\period\\factory", "piwik\\date", "piwik\\period\\range"}


# Returns each namespace block of the current text as (start, name, imports), and whether it
# declares any namespace.
def read_scopes():
    code_text = code_only()
    namespaces = [
        (match.start(), (match.group(1) or "").strip("\\"), {})
        for match in re.finditer(r"(?m)^[ \t]*namespace(?:[ \t]+(" + name_pattern + r"))?[ \t]*[;{]", code_text)
    ]
    declares_namespace = bool(namespaces)
    namespaces = namespaces or [(0, "", {})]
    for statement in re.finditer(r"(?m)^[ \t]*use[ \t]+(?!function\b|const\b)([^;]+);", code_text):
        imports = namespaces[namespace_index(namespaces, statement.start())][2]
        body = statement.group(1)
        group = re.fullmatch(r"\s*(" + name_pattern + r")\\\s*\{([^}]*)\}\s*", body)
        prefix = group.group(1).strip("\\") if group else ""
        for entry in re.finditer(r"[^,]+", group.group(2) if group else body):
            if not entry.group().strip() or re.match(r"\s*(?:function|const)\s", entry.group()):
                continue
            parts = re.split(r"\s+as\s+", entry.group().strip(), maxsplit=1, flags=re.IGNORECASE)
            name = (prefix + "\\" + parts[0] if prefix else parts[0]).strip().strip("\\")
            if not re.fullmatch(name_pattern, name):
                continue
            alias = parts[1].strip() if len(parts) == 2 else name.rsplit("\\", 1)[-1]
            imports[alias.lower()] = name
    return namespaces, declares_namespace


def namespace_index(namespaces, position):
    current = 0
    for index, namespace in enumerate(namespaces):
        if namespace[0] <= position:
            current = index
    return current


scopes = read_scopes()
base_scopes = None
if base_text is not None:
    # The skip helpers read the global text.
    text, base_text = base_text, text
    base_scopes = read_scopes()
    text, base_text = base_text, text


# PHP resolves a class name through the imports and namespace in force where it is written.
def resolve_in(name, namespace, declares_namespace):
    if name.startswith("\\"):
        return name[1:]
    _, namespace_name, imports = namespace
    first, _, rest = name.partition("\\")
    if first.lower() == "namespace" and rest:
        return (namespace_name + "\\" + rest).strip("\\")
    if first.lower() in imports:
        return imports[first.lower()] + ("\\" + rest if rest else "")
    # A snippet with no namespace at all is read as Matomo code, so Date and Period\Factory keep
    # meaning Matomo's classes there; plugin sources always declare one.
    if not declares_namespace and ("piwik\\" + name).lower() in matomo_classes:
        return "Piwik\\" + name
    return (namespace_name + "\\" + name).strip("\\")


# Returns the class a name means here, and whether it meant a different one in the base revision.
# An unchanged call counts as changed only then, so tidying imports leaves old findings alone.
def resolve(name, position):
    namespaces, declares_namespace = scopes
    index = namespace_index(namespaces, position)
    qualified_name = resolve_in(name, namespaces[index], declares_namespace)
    if base_scopes is None:
        return qualified_name, False
    base_namespaces, base_declares_namespace = base_scopes
    namespace_name = namespaces[index][1].lower()
    same_name = [namespace for namespace in base_namespaces if namespace[1].lower() == namespace_name]
    occurrence = sum(1 for namespace in namespaces[:index] if namespace[1].lower() == namespace_name)
    if occurrence < len(same_name):
        base_namespace = same_name[occurrence]
    else:
        base_namespace = base_namespaces[min(index, len(base_namespaces) - 1)]
    base_name = resolve_in(name, base_namespace, base_declares_namespace)
    return qualified_name, base_name.lower() != qualified_name.lower()


static_calls = {
    "piwik\\period\\factory": {"makeperiodfromqueryparams": "make_period", "build": "build"},
    "piwik\\date": {
        "factory": "date",
        "today": "date_marker",
        "yesterday": "date_marker",
        "yesterdaysametime": "date_marker",
    },
}
static_call_pattern = re.compile(r"(?<![A-Za-z0-9_\\$>:])(" + name_pattern + r")::([A-Za-z_][A-Za-z0-9_]*)\b")
new_range_pattern = re.compile(r"(?<![A-Za-z0-9_\\$>:])new\s+(" + name_pattern + r")(?![A-Za-z0-9_\\])")


def call_at(position):
    match = new_range_pattern.match(text, position)
    if match:
        qualified_name, resolution_changed = resolve(match.group(1), position)
        if qualified_name.lower() == "piwik\\period\\range":
            return "range", match.end(), resolution_changed
        return None
    match = static_call_pattern.match(text, position)
    if not match:
        return None
    qualified_name, resolution_changed = resolve(match.group(1), position)
    kind = static_calls.get(qualified_name.lower(), {}).get(match.group(2).lower())
    return (kind, match.end(), resolution_changed) if kind else None


def argument_value(arguments, index, names):
    for argument in arguments:
        named = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)\Z", argument, re.DOTALL)
        if named and named.group(1) in names:
            return named.group(2)
    return arguments[index] if len(arguments) > index else None


def strip_argument_comments(value):
    output = []
    position = 0
    quote = None
    while position < len(value):
        character = value[position]
        if quote is not None:
            output.append(character)
            if character == "\\" and position + 1 < len(value):
                output.append(value[position + 1])
                position += 2
                continue
            if character == quote:
                quote = None
            position += 1
            continue
        if character in ("'", '"'):
            quote = character
            output.append(character)
            position += 1
            continue
        if value.startswith("/*", position):
            end = value.find("*/", position + 2)
            position = len(value) if end == -1 else end + 2
            continue
        if value.startswith("//", position) or character == "#":
            newline = value.find("\n", position)
            position = len(value) if newline == -1 else newline + 1
            continue
        output.append(character)
        position += 1
    return "".join(output).strip()


# Case-sensitive, because prose writes these words in lower or sentence case; lowercase SQL is
# recognised by its clauses, or by a literal that opens with a lowercase statement verb.
sql_keyword = re.compile(
    r"(?<![A-Za-z0-9_$])(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DEFAULT|SET|WHERE|VALUES|FROM|AND|OR)(?![A-Za-z0-9_])"
)
sql_statement = re.compile(r"(?:<<<[^\n]*\n|['\"])\s*(?:select|insert|update|delete|replace)\s")
sql_clause = re.compile(
    r"(?<![A-Za-z0-9_$])(?:select\s[\s\S]*?\sfrom\s|insert\s+into\s|delete\s+from\s|update\s+[\w`.]+\s+set\s"
    r"|(?:create|alter)\s+table\s|set\s+[\w`.]+\s*=|where\s+[\w`.]+\s*(?:[=<>!]|in\s*\(|is\s+(?:not\s+)?null|(?:like|between)\s)|values\s*\()",
    re.IGNORECASE,
)
sql_clock = re.compile(
    r"(?<![A-Za-z0-9_$>:.])(?:(?:NOW|CURDATE|SYSDATE|CURTIME)\(|(?:CURRENT_(?:DATE|TIMESTAMP|TIME)|LOCALTIME(?:STAMP)?)(?![A-Za-z0-9_]))",
    re.IGNORECASE,
)
# Unambiguous on its own: uppercase, and called with nothing or only a precision.
sql_clock_call = re.compile(r"(?<![A-Za-z0-9_$>:.])(?:NOW|CURDATE|SYSDATE|CURTIME)\(\s*[0-9]*\s*\)")


# Any other clock name in a PHP string is only SQL when it shares an expression with SQL: one
# literal, which may span lines, or literals joined by `.`. Punctuation that ends an operand list
# ends the expression, except inside a call or cast opened after it started.
sql_expression = []
sql_depth = 0


def literal_characters(start, end):
    """Yield (position, character) for the characters a PHP literal or heredoc evaluates to."""
    if text[start] in "'\"":
        quote, position, end = text[start], start + 1, end - 1
    else:
        quote = "'" if re.match(r"<<<[ \t]*'", text[start:end]) else '"'
        position = text.find("\n", start) + 1
        end = text.rfind("\n", position, end) + 1 or position
    escapes = "\\'" if quote == "'" else "\\\""
    while position < end:
        if text[position] == "\\" and position + 1 < end and text[position + 1] in escapes:
            yield position, text[position + 1]
            position += 2
            continue
        yield position, text[position]
        position += 1


def sql_quoted_positions():
    """Source positions inside a SQL string, identifier or comment, which may span literals."""
    characters = [pair for start, end in sql_expression for pair in literal_characters(start, end)]
    skipped = set()
    state = None
    index = 0
    while index < len(characters):
        position, character = characters[index]
        following = characters[index + 1][1] if index + 1 < len(characters) else ""
        after = characters[index + 2][1] if index + 2 < len(characters) else " "
        if state in ("'", '"', "`"):
            if character == "\\" and state != "`":
                skipped.add(position)
                index += 1
            elif character == state:
                state = None
                index += 1
                continue
        elif state == "line":
            if character == "\n":
                state = None
        elif state == "block":
            if character == "*" and following == "/":
                state = None
                index += 2
                continue
        elif character in "'\"`":
            state = character
        elif character == "#" or (character == "-" and following == "-" and after.isspace()):
            state = "line"
        elif character == "/" and following == "*":
            state = "block"
        if state:
            skipped.add(position)
        index += 1
    return skipped


def end_sql_expression():
    global sql_depth
    sql_depth = 0
    expression = " ".join(text[start:end] for start, end in sql_expression)
    is_sql = (
        sql_keyword.search(expression)
        or sql_clause.search(expression)
        or any(sql_statement.match(text, start, end) for start, end in sql_expression)
    )
    clock = sql_clock if is_sql else sql_clock_call
    # The whole expression is context: adding SQL to one literal makes a clock in another SQL.
    context = f"{line_number(sql_expression[0][0])}\t{line_number(sql_expression[-1][1])}" if sql_expression else ""
    quoted = sql_quoted_positions() if is_sql else set()
    for start, end in sql_expression:
        for match in clock.finditer(text, start, end):
            if match.start() in quoted:
                continue
            line = line_number(match.start())
            print(f"error\t{line}\t{line}\t{context}\t0\tA database server-clock date is used; Matomo dates are stored in UTC and must not depend on the database timezone.")
    sql_expression.clear()


def check_call(position):
    call = call_at(position)
    if not call:
        return
    kind, open_position, resolution_changed = call
    while open_position < len(text) and text[open_position].isspace():
        open_position += 1
    if open_position >= len(text) or text[open_position] != "(":
        return
    parsed_arguments = parse_arguments(open_position)
    if parsed_arguments is None:
        return
    arguments, closing_position = parsed_arguments

    severity = None
    message = None
    timezone = argument_value(arguments, 0, {"timezone"})
    normalized_timezone = strip_argument_comments(timezone).lower() if timezone is not None else None
    if kind == "make_period" and normalized_timezone in ("''", '""', "null", "false"):
        severity = "error"
        message = "A period is being constructed with an empty timezone; resolve the website timezone explicitly."
    elif kind == "date":
        first_value = argument_value(arguments, 0, {"date", "dateString", "date_string"})
        first_argument = strip_argument_comments(first_value).strip("'\"").lower() if first_value is not None else ""
        timezone = argument_value(arguments, 1, {"timezone"})
        timezone = strip_argument_comments(timezone).lower() if timezone is not None else ""
        if (
            first_argument in relative_dates
        ) and (argument_value(arguments, 1, {"timezone"}) is None or timezone in ("''", '""', "null", "false")):
            severity = "warning"
            message = "Review this relative date for website-timezone handling; calendar-day markers and non-report code may be intentional."
    elif kind == "date_marker":
        severity = "warning"
        message = "Review this relative date for website-timezone handling; calendar-day markers and non-report code may be intentional."
    elif kind == "build":
        timezone_value = argument_value(arguments, 2, {"timezone"})
        timezone = strip_argument_comments(timezone_value).lower() if timezone_value is not None else None
        if timezone is None or timezone in ("''", '""', "null", "false"):
            severity = "warning"
            message = "Review this period construction for an explicit website timezone when the date can be relative."
    elif kind == "range":
        timezone_value = argument_value(arguments, 2, {"timezone"})
        timezone = strip_argument_comments(timezone_value).lower() if timezone_value is not None else None
        if timezone is None or timezone in ("''", '""', "null", "false"):
            severity = "warning"
            message = "Review this date range for an explicit website timezone when the endpoints can be relative."

    if severity:
        print(f"{severity}\t{line_number(position)}\t{line_number(closing_position)}\t0\t0\t{int(resolution_changed)}\t{message}")


position = 0
first_php_tag = text.find("<?")
if first_php_tag > 0 and text[:first_php_tag].strip():
    position = first_php_tag
while position < len(text):
    if text.startswith("?>", position):
        end_sql_expression()
        next_php_tag = text.find("<?", position + 2)
        position = len(text) if next_php_tag == -1 else next_php_tag
        continue
    heredoc_end = skip_heredoc(position)
    if heredoc_end is None:
        print(f"Unable to find the closing heredoc label in {path}", file=sys.stderr)
        sys.exit(1)
    if heredoc_end != position:
        sql_expression.append((position, heredoc_end))
        position = heredoc_end
        continue
    character = text[position]
    if character == "`":
        position = skip_quoted(position, character)
        continue
    if character in ("'", '"'):
        literal_end = skip_quoted(position, character)
        sql_expression.append((position, literal_end))
        position = literal_end
        continue
    comment_end = skip_comment(position)
    if comment_end != position:
        position = comment_end
        continue
    if sql_expression and character in "([":
        sql_depth += 1
    elif sql_depth and character in ")]":
        sql_depth -= 1
    elif character == ":" and (text.startswith("::", position) or text.startswith("::", max(position - 1, 0))):
        pass
    elif character in ";{}" or (not sql_depth and character in ",()[]=?:"):
        end_sql_expression()
    check_call(position)
    position += 1
end_sql_expression()
PY
}

for file in "${files[@]}"; do
  case "$file" in
    *.php) ;;
    *) continue ;;
  esac
  # Already counted as a failure by the sanitizer loop.
  [ -n "${sanitized_files[$file]-}" ] || continue
  base_file=''
  if [ -n "${base_paths[${file#./}]-}" ]; then
    base_file="${sanitized_files[$file]}.base"
    if ! git show "$merge_base:./${base_paths[${file#./}]}" > "$base_file"; then
      parser_failures=$((parser_failures + 1))
      annotation_file=$(escape_annotation "${file#./}")
      echo "::error file=$annotation_file::Unable to read this file at the base revision."
      continue
    fi
  fi
  if ! scan_output=$(scan_php_calls "$file" "$base_file"); then
    parser_failures=$((parser_failures + 1))
    annotation_file=$(escape_annotation "${file#./}")
    echo "::error file=$annotation_file::Unable to scan PHP source because the argument-aware parser failed."
    continue
  fi
  while IFS=$'\t' read -r severity line end_line context_start context_end resolution_changed message; do
    [ -n "$severity" ] || continue
    report "$severity" "${file#./}" "$line" "$message" "$end_line" "$context_start" "$context_end" "$resolution_changed"
  done <<< "$scan_output"
done

scan_pattern error \
  "(^|[^[:alnum:]_])(NOW|CURDATE|SYSDATE|CURTIME|LOCALTIME|LOCALTIMESTAMP)\\(|(^|[^[:alnum:]_])(CURRENT_(DATE|TIMESTAMP|TIME)|LOCALTIME(STAMP)?)([^[:alnum:]_=]|$)" \
  'A database server-clock date is used; Matomo dates are stored in UTC and must not depend on the database timezone.' \
  sql


suite_files=()
suite_listing=$(mktemp)
if ! find . \( -name .git -o -name vendor -o -name node_modules -o -name libs -o -path './vue/dist' \) -prune \
  -o -type f \( -path '*/tests/*' -o -path './.github/workflows/*' \) -print0 > "$suite_listing"; then
  echo '::error::Unable to list timezone suite files for the timezone check.' >&2
  exit 2
fi
while IFS= read -r -d '' file; do
  if [[ "$file" == ./.github/workflows/* ]] \
    && grep -Eq 'plugin-(ci|timezone-safety)\.yml' "$file" \
    && ! grep -Eqi '(^|[^[:alnum:]_])TZ[[:space:]]*[=:]|MYSQL_TIMEZONE|timezone[-_ ]+(test|suite)|timezone_test' "$file"; then
    continue
  fi
  # shellcheck disable=SC2016 # $now is part of the literal source pattern being searched.
  if grep -Eqi 'timezone|mysql-timezone|Date::\$now|factoryInTimezone|UTC[+-][0-9]+|(^|[^[:alnum:]_])TZ[[:space:]]*[=:]' "$file"; then
    suite_files+=("${file#./}")
  fi
done < "$suite_listing"

if [ "${#suite_files[@]}" -eq 0 ]; then
  echo 'Timezone coverage: no timezone-specific suite or workflow configuration found; static scan completed.'
else
  echo 'Timezone coverage files:'
  printf '  %s\n' "${suite_files[@]}"
fi

echo "Scanned $scanned production source file(s): $errors error(s), $warnings warning(s)"

if [ -n "$BASE_REF" ]; then
  if [ "$changed_source_files" -eq 0 ]; then
    echo 'No changed PHP or SQL source files were selected; the complete repository scan still ran.'
  else
    echo "Changed production source files since $BASE_REF: $changed_source_files"
    echo "Findings on changed production lines: $changed_errors error(s), $changed_warnings warning(s)"
  fi
fi

if [ "$scanned" -eq 0 ]; then
  echo '::error::No PHP or SQL source files were scanned; the repository layout or scan exclusions need review.'
  exit 2
fi
if [ "$parser_failures" -gt 0 ]; then
  echo "::error::Source scanning failed for $parser_failures source file(s); the timezone scan is incomplete."
  exit 2
fi
if [ "$ADVISORY" -eq 1 ]; then
  exit 0
fi
if [ "$FAIL_ON_NEW_FINDINGS" -eq 1 ]; then
  if [ "$changed_errors" -gt 0 ]; then
    echo "::error::Timezone errors on changed production lines: $changed_errors" >&2
    exit 1
  fi
fi
if [ "$FAIL_ON_WARNINGS" -eq 1 ]; then
  warning_failures="$warnings"
  if [ "$FAIL_ON_NEW_FINDINGS" -eq 1 ]; then
    warning_failures="$changed_warnings"
  fi
  if [ "$warning_failures" -gt 0 ]; then
    echo "::error::Strict timezone warning mode found $warning_failures warning(s) in the selected findings." >&2
    exit 1
  fi
fi
if [ "$FAIL_ON_NEW_FINDINGS" -eq 1 ]; then
  exit 0
fi
if [ "$errors" -gt 0 ]; then
  exit 1
fi
