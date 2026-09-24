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

cleanup() {
  [ -z "$changed_diff_file" ] || rm -f "$changed_diff_file"
  [ -z "$changed_names_file" ] || rm -f "$changed_names_file"
  [ -z "$source_listing" ] || rm -f "$source_listing"
  [ -z "$suite_listing" ] || rm -f "$suite_listing"
  [ -z "$sanitized_dir" ] || rm -rf "$sanitized_dir"
}

trap cleanup EXIT

report() {
  local severity="$1" file="$2" line="$3" message="$4" end_line="${5:-$3}"
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
  if is_inline_comment_ignore "$(sed -n "${line}p" -- "$file")" \
    && { [ "$changed" -eq 0 ] || [ -n "${changed_lines["$file:$line"]+set}" ]; }; then
    return
  fi
  if [ "$line" -gt 1 ]; then
    previous_line=$((line - 1))
    if is_comment_ignore "$(sed -n "${previous_line}p" -- "$file")" \
      && [ -n "${changed_lines["$file:$previous_line"]+set}" ]; then
      previous_changed=1
    fi
    if is_comment_ignore "$(sed -n "${previous_line}p" -- "$file")" \
      && { [ -z "${deletion_points["$file:$line"]+set}" ] || [ "$previous_changed" -eq 1 ]; } \
      && { [ "$changed" -eq 0 ] || [ "$previous_changed" -eq 1 ]; }; then
      return
    fi
  fi
  local finding_key="$severity:$file:$line"
  if [ -n "${reported_findings[$finding_key]+set}" ]; then
    return
  fi
  reported_findings["$finding_key"]=1
  case "$severity" in
    error)
      errors=$((errors + 1))
      if [ "$ADVISORY" -eq 1 ]; then
        echo "::notice file=$annotation_file,line=$annotation_line::$annotation_message"
      elif [ "$changed" -eq 1 ]; then
        echo "::error file=$annotation_file,line=$annotation_line::Timezone finding on a changed production line: $annotation_message"
        changed_errors=$((changed_errors + 1))
      elif [ "$FAIL_ON_NEW_FINDINGS" -eq 1 ]; then
        echo "::notice file=$annotation_file,line=$annotation_line::$annotation_message"
      else
        echo "::error file=$annotation_file,line=$annotation_line::$annotation_message"
      fi
      ;;
    warning)
      warnings=$((warnings + 1))
      if [ "$ADVISORY" -eq 1 ]; then
        echo "::notice file=$annotation_file,line=$annotation_line::$annotation_message"
      elif [ "$changed" -eq 1 ]; then
        echo "::warning file=$annotation_file,line=$annotation_line::Timezone finding on a changed production line: $annotation_message"
        changed_warnings=$((changed_warnings + 1))
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

is_comment_ignore() {
  grep -Eq '^[[:space:]]*(//|#|/\*|\*|--).*timezone-safety-ignore' <<< "$1"
}

is_inline_comment_ignore() {
  local line="$1"
  is_comment_ignore "$line" || grep -Eq '(;|,|\(|\)|\]|\})[[:space:]]*(//|#|--|/\*).*timezone-safety-ignore' <<< "$line"
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
  if ! git merge-base "$BASE_REF" HEAD >/dev/null 2>&1; then
    echo "::error::The timezone check base revision '$BASE_REF' has no common ancestor with HEAD" >&2
    exit 2
  fi
  changed_diff_file=$(mktemp)
  changed_names_file=$(mktemp)
  if ! git -c core.quotePath=false diff --no-ext-diff --no-textconv --relative --src-prefix=a/ --dst-prefix=b/ --unified=0 --no-color --diff-filter=ACMRTUXB "$BASE_REF...HEAD" -- '*.php' '*.sql' > "$changed_diff_file"; then
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
  if ! git -c core.quotePath=false diff --no-ext-diff --no-textconv --relative --name-only -z --diff-filter=ACMRTUXB "$BASE_REF...HEAD" > "$changed_names_file"; then
    echo '::error::Unable to list changed files for the timezone check.' >&2
    exit 2
  fi
  while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue
    is_excluded "./$file" && continue
    case "$file" in
      *.php|*.sql) changed_source_files=$((changed_source_files + 1)) ;;
    esac
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
  local file="$1"
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


output = []
position = 0
state = "code"
quote = None
if not is_sql:
    first_php_tag = text.find("<?")
    if first_php_tag > 0:
        output.extend("\n" if character == "\n" else "" for character in text[:first_php_tag])
        position = first_php_tag
while position < len(text):
    if state in ("single", "double"):
        character = text[position]
        if is_sql:
            output.append("\n" if character == "\n" else " ")
        else:
            output.append(character)
        if is_sql and character == quote and position + 1 < len(text) and text[position + 1] == quote:
            output.append(" ")
            position += 2
            continue
        if character == "\\" and position + 1 < len(text):
            if is_sql:
                output.append("\n" if text[position + 1] == "\n" else " ")
            else:
                output.append(text[position + 1])
            position += 2
            continue
        if character == quote:
            state = "code"
            quote = None
        position += 1
        continue
    if state == "line":
        if text[position] == "\n":
            output.append("\n")
            state = "code"
        position += 1
        continue
    if state == "block":
        if text.startswith("*/", position):
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
        quote = text[position]
        state = "single" if quote == "\x27" else "double"
        output.append(text[position])
        position += 1
        continue
    if text.startswith("//", position) or (
        text[position] == "#" and not text.startswith("#[", position)
    ):
        state = "line"
        position += 2 if text.startswith("//", position) else 1
        continue
    if text.startswith("/*", position):
        state = "block"
        position += 2
        continue
    if is_sql and text.startswith("--", position) and (position == 0 or text[position - 1].isspace()):
        state = "line"
        position += 2
        continue
    output.append(text[position])
    position += 1

sanitized = "".join(output)
if not is_sql:
    sanitized = re.sub(r"\b(function|const)([ \t]+)[A-Za-z_][A-Za-z0-9_]*", r"\1\2_", sanitized)
sys.stdout.buffer.write(sanitized.encode("utf-8"))
' "$file" < "$file"
}

sanitized_dir=$(mktemp -d)
sanitized_index=0
for file in "${files[@]}"; do
  sanitized_path="$sanitized_dir/$sanitized_index"
  sanitized_index=$((sanitized_index + 1))
  if ! sanitize_scan_input "$file" > "$sanitized_path"; then
    parser_failures=$((parser_failures + 1))
    annotation_file=$(escape_annotation "${file#./}")
    echo "::error file=$annotation_file::Unable to sanitize source before scanning."
    rm -f "$sanitized_path"
    continue
  fi
  sanitized_files["$file"]="$sanitized_path"
done

scan_php_calls() {
  local file="$1"
  python3 - "$file" <<'PY'
import re
import sys

path = sys.argv[1]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError as error:
    print(f"Unable to scan PHP source: {error}", file=sys.stderr)
    sys.exit(1)
relative_dates = {"today", "yesterday", "yesterdaySameTime".lower()}


def line_number(position):
    return text.count("\n", 0, position) + 1


def skip_quoted(position, quote):
    position += 1
    while position < len(text):
        if text[position] == "\\":
            position += 2
            continue
        if text[position] == quote:
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
        if character in ("'", '"'):
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


factory_aliases = {"Period\\Factory"}
if re.search(r"^\s*namespace\s+Piwik\\Period\s*[;{]", text, re.MULTILINE):
    factory_aliases.add("Factory")
for imported_alias in re.findall(
    r"^\s*use\s+Piwik\\Period\\Factory(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*;",
    text,
    re.MULTILINE,
):
    factory_aliases.add(imported_alias or "Factory")
for import_statement in re.findall(r"^\s*use\s+([^;{}]+);", text, re.MULTILINE):
    for imported_name in import_statement.split(","):
        parts = re.split(r"\s+as\s+", imported_name.strip(), maxsplit=1, flags=re.IGNORECASE)
        qualified_name = parts[0].strip()
        alias = parts[1].strip() if len(parts) == 2 else qualified_name.rsplit("\\", 1)[-1]
        if qualified_name == "Piwik\\Period\\Factory":
            factory_aliases.add(alias)
for grouped_import in re.findall(
    r"^\s*use\s+Piwik\\Period\\\{([^}]+)\}\s*;",
    text,
    re.MULTILINE,
):
    for imported_name in grouped_import.split(","):
        parts = re.split(r"\s+as\s+", imported_name.strip(), maxsplit=1, flags=re.IGNORECASE)
        if parts[0].strip() == "Factory":
            factory_aliases.add(parts[1].strip() if len(parts) == 2 else "Factory")

date_aliases = {"Date", "Piwik\\Date"}
for import_statement in re.findall(r"^\s*use\s+([^;{}]+);", text, re.MULTILINE):
    for imported_name in import_statement.split(","):
        parts = re.split(r"\s+as\s+", imported_name.strip(), maxsplit=1, flags=re.IGNORECASE)
        qualified_name = parts[0].strip()
        alias = parts[1].strip() if len(parts) == 2 else qualified_name.rsplit("\\", 1)[-1]
        if qualified_name == "Piwik\\Date":
            date_aliases.add(alias)
for imported_alias in re.findall(
    r"^\s*use\s+Piwik\\Date(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*;",
    text,
    re.MULTILINE,
):
    date_aliases.add(imported_alias or "Date")

patterns = []
for factory_alias in sorted(factory_aliases):
    escaped_alias = re.escape(factory_alias)
    boundary = r"(?<![A-Za-z0-9_])" if "\\" in factory_alias else r"(?<![A-Za-z0-9_\\])"
    patterns.append(
        (re.compile(boundary + escaped_alias + r"::makePeriodFromQueryParams\b"), "make_period")
    )
    patterns.append(
        (re.compile(boundary + escaped_alias + r"::build\b"), "build")
    )
for date_alias in sorted(date_aliases):
    boundary = r"(?<![A-Za-z0-9_])" if "\\" in date_alias else r"(?<![A-Za-z0-9_\\])"
    patterns.append(
        (re.compile(boundary + re.escape(date_alias) + r"::factory\b(?!InTimezone)"), "date")
    )
    patterns.append(
        (re.compile(boundary + re.escape(date_alias) + r"::(?:today|yesterday(?:SameTime)?)\b"), "date_marker")
    )
range_aliases = {"Period\\Range", "Piwik\\Period\\Range", "\\Piwik\\Period\\Range"}
if re.search(r"^\s*namespace\s+Piwik\\Period\s*[;{]", text, re.MULTILINE):
    range_aliases.add("Range")
for imported_alias in re.findall(
    r"^\s*use\s+Piwik\\Period\\Range(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*;",
    text,
    re.MULTILINE,
):
    range_aliases.add(imported_alias or "Range")
for grouped_import in re.findall(
    r"^\s*use\s+Piwik\\Period\\\{([^}]+)\}\s*;",
    text,
    re.MULTILINE,
):
    for imported_name in grouped_import.split(","):
        parts = re.split(r"\s+as\s+", imported_name.strip(), maxsplit=1, flags=re.IGNORECASE)
        if parts[0].strip() == "Range":
            range_aliases.add(parts[1].strip() if len(parts) == 2 else "Range")
for range_alias in sorted(range_aliases):
    patterns.append((re.compile(r"new\s+" + re.escape(range_alias) + r"\b"), "range"))


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

position = 0
first_php_tag = text.find("<?")
if first_php_tag > 0 and text[:first_php_tag].strip():
    position = first_php_tag
while position < len(text):
    if text.startswith("?>", position):
        next_php_tag = text.find("<?", position + 2)
        position = len(text) if next_php_tag == -1 else next_php_tag
        continue
    heredoc_end = skip_heredoc(position)
    if heredoc_end is None:
        print(f"Unable to find the closing heredoc label in {path}", file=sys.stderr)
        sys.exit(1)
    if heredoc_end != position:
        position = heredoc_end
        continue
    character = text[position]
    if character in ("'", '"'):
        position = skip_quoted(position, character)
        continue
    comment_end = skip_comment(position)
    if comment_end != position:
        position = comment_end
        continue

    for pattern, kind in patterns:
        match = pattern.match(text, position)
        if not match:
            continue
        open_position = match.end()
        while open_position < len(text) and text[open_position].isspace():
            open_position += 1
        if open_position >= len(text) or text[open_position] != "(":
            break
        parsed_arguments = parse_arguments(open_position)
        if parsed_arguments is None:
            break
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
            print(f"{severity}\t{line_number(position)}\t{line_number(closing_position)}\t{message}")
        break

    position += 1
PY
}

for file in "${files[@]}"; do
  case "$file" in
    *.php) ;;
    *) continue ;;
  esac
  if ! scan_output=$(scan_php_calls "$file"); then
    parser_failures=$((parser_failures + 1))
    annotation_file=$(escape_annotation "${file#./}")
    echo "::error file=$annotation_file::Unable to scan PHP source because the argument-aware parser failed."
    continue
  fi
  while IFS=$'\t' read -r severity line end_line message; do
    [ -n "$severity" ] || continue
    report "$severity" "${file#./}" "$line" "$message" "$end_line"
  done <<< "$scan_output"
done

scan_pattern error \
  "(^|[^[:alnum:]_\$>:.])(NOW|CURDATE|SYSDATE|CURTIME)\\(" \
  'A database server-clock date is used; Matomo dates are stored in UTC and must not depend on the database timezone.' \
  php insensitive
scan_pattern error \
  "(^|[^[:alnum:]_\$>:.])((CURRENT_(DATE|TIMESTAMP|TIME)|LOCALTIME(STAMP)?)([^[:alnum:]_=\$]|$))" \
  'A database server-clock date is used; Matomo dates are stored in UTC and must not depend on the database timezone.' \
  php
scan_pattern error \
  "(^|[^[:alnum:]_\$])(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DEFAULT|ON[[:space:]]+UPDATE)([^[:alnum:]_][^;]*)?(^|[^[:alnum:]_\$>:.])(CURRENT_(DATE|TIMESTAMP|TIME)|LOCALTIME(STAMP)?)([^[:alnum:]_]|$)" \
  'A database server-clock date is used; Matomo dates are stored in UTC and must not depend on the database timezone.' \
  php insensitive
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
    && ! grep -Eqi 'TZ=|MYSQL_TIMEZONE|timezone[-_ ]+(test|suite)|timezone_test' "$file"; then
    continue
  fi
  # shellcheck disable=SC2016 # $now is part of the literal source pattern being searched.
  if grep -Eqi 'timezone|mysql-timezone|Date::\$now|factoryInTimezone|UTC[+-][0-9]+' "$file"; then
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
  echo "::error::The argument-aware PHP parser failed for $parser_failures source file(s); the timezone scan is incomplete."
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
