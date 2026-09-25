#!/bin/bash

# Regression tests for scripts/bash/check_timezone_safety.sh.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/bash/check_timezone_safety.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

tests=0
failures=0

print_indented() {
  while IFS= read -r line; do
    printf '    %s\n' "$line"
  done <<< "$1"
}

check() {
  local description="$1" expected_exit="$2" expected_output="$3" dir="$4"
  shift 4
  tests=$((tests + 1))
  local output actual
  output=$(env "$@" bash "$SCRIPT" "$dir" 2>&1)
  actual=$?
  local ok=1
  [ "$actual" -eq "$expected_exit" ] || ok=0
  if [ -n "$expected_output" ] && ! grep -qF "$expected_output" <<< "$output"; then
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    echo "ok - $description"
  else
    failures=$((failures + 1))
    echo "FAIL - $description (exit $actual, expected $expected_exit)"
    print_indented "$output"
  fi
}

new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/src"
  echo '<?php' > "$dir/src/Source.php"
  echo "$dir"
}

dir=$(new_repo safe)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

$period = PeriodFactory::build($period, $date, $timezone);
$periodWithNamespace = Period\Factory::build($period, $date, $timezone);
$periodWithImport = Factory::build($period, $date, $timezone);
$range = new Range('range', $date, $timezone);
$qualifiedRange = new \Piwik\Period\Range('range', $date, $timezone);
$shortQualifiedRange = new Period\Range('range', $date, $timezone);
$today = Date::factoryInTimezone('today', $timezone);
$alsoToday = Date::factory('today', $timezone);
PHP
check 'explicit timezone handling passes' 0 '0 error(s)' "$dir"

dir=$(new_repo relative-date)
echo "Date::factory('today');" > "$dir/src/Source.php"
check 'relative server date is advisory' 0 '1 warning(s)' "$dir"
output=$(bash "$SCRIPT" --fail-on-warnings "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'relative date' <<< "$output"; then
  echo 'ok - relative date warnings can be made strict'
else
  failures=$((failures + 1))
  echo "FAIL - relative date warnings can be made strict (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo relative-instant)
echo "Date::factory('now');" > "$dir/src/Source.php"
check 'relative instants are not calendar-date warnings' 0 '0 warning(s)' "$dir"
dir=$(new_repo date-markers)
printf '%s\n' 'Date::today();' 'Date::yesterday();' > "$dir/src/Source.php"
check 'calendar date helpers are reviewed' 0 '2 warning(s)' "$dir"
dir=$(new_repo date-same-time)
echo 'Date::yesterdaySameTime();' > "$dir/src/Source.php"
check 'yesterdaySameTime date helper is reviewed' 0 '1 warning(s)' "$dir"

dir=$(new_repo comments)
echo "// Date::factory('today');" > "$dir/src/Source.php"
check 'comment-only matches are ignored' 0 '0 error(s), 0 warning(s)' "$dir"

dir=$(new_repo empty-timezone)
cat > "$dir/src/Source.php" <<'PHP'
Period\Factory::makePeriodFromQueryParams('', 'day', $date);
Period\Factory::makePeriodFromQueryParams(null, 'day', $date);
Period\Factory::makePeriodFromQueryParams(false, 'day', $date);
PHP
check 'empty, null, and false period timezones are errors' 1 '3 error(s)' "$dir"

dir=$(new_repo nested-arguments)
# shellcheck disable=SC2016 # the $ is literal PHP fixture source.
echo 'Period\Factory::build($period, [$date, $fallback][0]);' > "$dir/src/Source.php"
check 'nested array arguments do not hide missing timezones' 0 '1 warning(s)' "$dir"

dir=$(new_repo named-arguments)
cat > "$dir/src/Source.php" <<'PHP'
<?php
Period\Factory::makePeriodFromQueryParams(timezone: null, period: 'day', date: $date);
Period\Factory::build(period: $period, date: $date, timezone: '');
PHP
check 'named timezone arguments are reviewed' 1 '1 error(s), 1 warning(s)' "$dir"

dir=$(new_repo commented-arguments)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

Factory::makePeriodFromQueryParams(null /* timezone */, 'day', $date);
Factory::build($period, $date, null /* timezone */);
Date::factory('today' /* date */, null /* timezone */);
PHP
check 'comments do not hide unsafe argument values' 1 '1 error(s), 2 warning(s)' "$dir"

dir=$(new_repo namespace-factory)
cat > "$dir/src/Source.php" <<'PHP'
<?php
namespace Piwik\Period;

Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
check 'same-namespace Factory calls are reviewed' 1 '1 error(s)' "$dir"

dir=$(new_repo unrelated-period-namespaces)
cat > "$dir/src/Source.php" <<'PHP'
<?php
\Vendor\Period\Factory::makePeriodFromQueryParams('', 'day', $date);
\Vendor\Piwik\Date::today();
\Piwik\Period\Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
check 'only Matomo-qualified Factory and Date calls are reviewed' 1 '1 error(s), 0 warning(s)' "$dir"

dir=$(new_repo namespaced-local-classes)
cat > "$dir/src/Source.php" <<'PHP'
<?php
namespace Piwik\Plugins\Example;

use Vendor\Calendar\Date;

Date::today();
Period\Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
check 'names in a plugin namespace resolve to the plugin, not Matomo' 0 '0 error(s), 0 warning(s)' "$dir"

dir=$(new_repo namespace-aliases)
cat > "$dir/src/Source.php" <<'PHP'
<?php
namespace Piwik\Plugins\Example;

use Piwik\Period as SitePeriod;
use Piwik\{Date as MatomoDate, Period\Range};

SitePeriod\Factory::makePeriodFromQueryParams('', 'day', $date);
MatomoDate::today();
$range = new Range('day', 'last7');
PHP
check 'namespace aliases and Piwik-rooted grouped imports are reviewed' 1 '1 error(s), 2 warning(s)' "$dir"

dir=$(new_repo comma-import)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory, Piwik\Period\Range;

Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
check 'comma-separated Factory imports are reviewed' 1 '1 error(s)' "$dir"

dir=$(new_repo comma-range-import)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Range, Piwik\Date;

$range = new Range('day', 'last7');
PHP
check 'comma-separated Range imports are reviewed' 0 '1 warning(s)' "$dir"

dir=$(new_repo leading-backslash-imports)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use \Piwik\Period\Factory;
use \Piwik\Period\{Range as R};

Factory::makePeriodFromQueryParams('', 'day', $date);
$range = new R('day', 'last7');
PHP
check 'leading-backslash imports are reviewed' 1 '1 error(s), 1 warning(s)' "$dir"

dir=$(new_repo database-clock)
cat > "$dir/src/query.sql" <<'SQL'
SELECT now() AS created_at;
SELECT SYSDATE(), CURTIME(), CURRENT_TIME, LOCALTIME, LOCALTIMESTAMP;
SELECT LOCALTIMESTAMP;
SELECT 1 /* NOW() in an inline block comment */;
SELECT 'CURRENT_TIMESTAMP', "NOW()";
/* NOW() in a
   multiline block comment */
SQL
check 'database server clock functions are errors' 1 'database server-clock' "$dir"
database_dir="$dir"

dir=$(new_repo sql-double-dash)
cat > "$dir/src/query.sql" <<'SQL'
SELECT 1;-- NOW()
SELECT 5--1, NOW();
SQL
check 'a double dash is a SQL comment only when whitespace follows it' 1 '1 error(s)' "$dir"

dir=$(new_repo sql-string-literals)
cat > "$dir/src/query.sql" <<'SQL'
INSERT INTO labels (value) VALUES ('CURRENT_TIMESTAMP'), ("NOW()"), (`CURRENT_TIMESTAMP`);
SQL
check 'SQL string literals are not clock findings' 0 '0 error(s)' "$dir"

dir=$(new_repo quoted-database-clock)
echo "<?php \$query = new \\Zend\\Db\\Expr('NOW()'); \$other = 'SYSDATE()'; \$current = 'CURRENT_TIMESTAMP()'; \$lower = \"SELECT now() current_timestamp\";" > "$dir/src/Source.php"
check 'database clocks embedded in PHP strings are errors' 1 'database server-clock' "$dir"

dir=$(new_repo comment-like-string)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$files = glob($dir . '/*.php');
$query = "SELECT NOW()";
PHP
check 'comment-like text in PHP strings does not hide later clocks' 1 'database server-clock' "$dir"

dir=$(new_repo string-suppression)
echo "<?php Period\\Factory::makePeriodFromQueryParams('', 'day', \$date); \$label = 'timezone-safety-ignore';" > "$dir/src/Source.php"
check 'suppression text in a PHP string is not a suppression' 1 '1 error(s)' "$dir"
dir=$(new_repo comment-marker-in-string)
echo "<?php \$label = 'timezone-safety-ignore'; \$query = \"SELECT NOW()\";" > "$dir/src/Source.php"
check 'comment markers in strings are not suppressions' 1 '1 error(s)' "$dir"

dir=$(new_repo duplicate-database-clock)
# shellcheck disable=SC2016 # the $ is literal PHP fixture source.
echo '<?php $query = "SELECT NOW(), CURRENT_TIMESTAMP";' > "$dir/src/Source.php"
check 'overlapping database-clock rules report one finding per line' 1 '1 error(s)' "$dir"

dir=$(new_repo multiline-lowercase-database-clock)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$query = "UPDATE log_visit
    SET visit_last_action_time = current_timestamp
    WHERE idsite = ?
    AND visit_first_action_time < current_date";
$values = "INSERT INTO t (a, b)
    VALUES (?, localtimestamp)";
$select = <<<SQL
SELECT idvisit,
    current_date AS day
FROM log_visit
SQL;
PHP
check 'lowercase database clocks on SQL continuation lines are reported' 1 '4 error(s)' "$dir"

dir=$(new_repo concatenated-database-clock)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$query = 'SELECT idvisit, '
    . 'current_date AS day';
$label = sprintf('Select the %s column', 'current_date');
PHP
check 'lowercase database clocks in concatenated SQL are reported' 1 '1 error(s)' "$dir"

dir=$(new_repo clock-names-in-prose)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$help = 'Show times in localtime or UTC';
$label = 'Default: localtime';
$note = 'Select a date, and current_date is used where none is set';
$sql = "select idvisit from log_visit where visit_last_action_time > current_date";
PHP
check 'clock names in prose are not SQL, but lowercase SQL clauses are' 1 '1 error(s)' "$dir"

dir=$(new_repo sql-around-calls)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$insert = "INSERT INTO t (a, ts) VALUES (" . (int) $a . ", CURRENT_TIMESTAMP)";
$select = "select x from t where b = " . $db->quote($x) . "
    and c < now()";
$db->query('SELECT a FROM t WHERE b = ?', ['current_date']);
PHP
check 'a call or cast inside a concatenated SQL expression does not split it' 1 '2 error(s)' "$dir"

dir=$(new_repo lowercase-statements)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$today = $db->fetchOne("select current_date");
$now = $db->fetchOne(' select now()');
$sql = <<<SQL
update t set ts = localtime
SQL;
$help = 'Select to use localtime';
PHP
check 'a literal opening with a lowercase statement verb is SQL' 1 '3 error(s)' "$dir"

dir=$(new_repo sql-around-static-calls)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$sql = "select * from " . Common::prefixTable('t') . " t join u on t.d = current_date";
$other = "SELECT a FROM " . self::TABLE . " WHERE b < now()";
PHP
check 'a static call or constant inside a concatenated SQL expression does not split it' 1 '2 error(s)' "$dir"

dir=$(new_repo column-defaults)
cat > "$dir/src/Model.php" <<'PHP'
<?php
$sql = "CREATE TABLE t (ts_created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)";
PHP
cat > "$dir/src/schema.sql" <<'SQL'
ALTER TABLE t ADD COLUMN ts_updated DATETIME DEFAULT CURRENT_TIMESTAMP;
SQL
check 'a server-clock column default is reported' 1 '2 error(s)' "$dir"

dir=$(new_repo php-sql-string-values)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$a = $db->fetchAll("SELECT 'CURRENT_TIMESTAMP' AS label FROM t");
$b = $db->fetchAll('SELECT \'NOW()\', "O\'Brien", NOW() FROM t');
$c = "SELECT a FROM t WHERE b = '" . $b . "' AND c < CURRENT_DATE";
PHP
check 'a clock name inside a SQL string value in PHP is not a finding' 1 '2 error(s)' "$dir"

dir=$(new_repo php-sql-comments)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$a = "SELECT a -- the user's note
    FROM t WHERE d = CURRENT_DATE";
$b = 'SELECT 1 -- NOW()';
$c = "SELECT /* NOW() isn't used */ `CURRENT_DATE` FROM t # NOW()";
PHP
check 'SQL comments and identifiers in PHP neither hide nor raise clock findings' 1 '1 error(s)' "$dir"

dir=$(new_repo php-sql-escaped-newlines)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$a = $db->fetchAll("SELECT a -- note\n FROM t WHERE d = NOW()");
$b = $db->fetchAll('SELECT a -- note\n FROM t WHERE d = NOW()');
PHP
check 'an escaped newline ends a SQL comment only in a double-quoted PHP string' 1 '1 error(s)' "$dir"

dir=$(new_repo ordinary-identifiers)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$created = localtime(time(), true);
$deleted = self::CURRENT_TIME_LIMIT;
$updatedAt = $row->getLocalTime();
$defaultFormat = Formats::CURRENT_DATE_FORMAT;
$ready = $isSet or $current_date;
self::setCurrentTime($time);
$view->set('current_time', time());
$db->where('current_date', 1);
PHP
check 'ordinary PHP identifiers are not SQL clock findings' 0 '0 error(s)' "$dir"

dir=$(new_repo declaration-and-clock)
cat > "$dir/src/Source.php" <<'PHP'
<?php
const NOW_SQL = 'SELECT NOW()';
function nowish() { return $db->fetchOne('SELECT NOW()'); }
PHP
check 'clocks on declaration lines are still reported' 1 '2 error(s)' "$dir"

dir=$(new_repo date-alias)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Date as SiteDate;

SiteDate::factory('today');
PHP
check 'Date aliases are reviewed' 0 '1 warning(s)' "$dir"

dir=$(new_repo schema-defaults)
echo "<?php \$ddl = \"TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP\";" > "$dir/src/Source.php"
check 'schema clock defaults are reported for review' 1 '1 error(s)' "$dir"

dir=$(new_repo schema-defaults-sql)
cat > "$dir/src/schema.sql" <<'SQL'
CREATE TABLE events (
  created_at timestamp default current_timestamp,
  updated_at timestamp default now() on update current_timestamp
);
SQL
check 'lowercase SQL schema clock defaults are reported for review' 1 'database server-clock' "$dir"

dir=$(new_repo non-utf8)
# shellcheck disable=SC2016 # the $ is literal PHP fixture source.
printf '<?php\n\$invalid = "\351";\n\$query = "NOW()";\n' > "$dir/src/Source.php"
check 'non-UTF-8 source is still scanned' 1 'database server-clock' "$dir"

cat > "$database_dir/src/Source.php" <<'PHP'
<?php
Date::now();
$clock->now();
$current_date = $value;
$row = ['current_date' => $value, 'current_timestamp' => $value];
public function now() {}
const CURRENT_DATE = 1;
public function localTime() {}
private function sysdate($value) {}
PHP
echo '-- NOW() is only a SQL comment;' >> "$database_dir/src/query.sql"
echo 'SELECT CURRENT_TIMESTAMP; -- timezone-safety-ignore' >> "$database_dir/src/query.sql"
output=$(bash "$SCRIPT" "$database_dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && [ "$(grep -c 'database server-clock' <<< "$output")" -eq 3 ]; then
  echo 'ok - SQL line comments are ignored'
else
  failures=$((failures + 1))
  echo "FAIL - SQL line comments are ignored (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo unrelated-deletion)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$unused = 1;
$old = 'NOW()';
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i '/unused/d' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm remove-unrelated-line
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF '0 error(s), 0 warning(s)' <<< "$output"; then
  echo 'ok - unrelated deletion does not make an old finding new'
else
  failures=$((failures + 1))
  echo "FAIL - unrelated deletion does not make an old finding new (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo import-only-change)
cat > "$dir/src/Source.php" <<'PHP'
<?php
namespace Piwik\Plugins\Example;

use Vendor\Period\Factory;

Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i 's/use Vendor\\Period\\Factory;/use Piwik\\Period\\Factory;/' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm switch-import
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'Timezone finding on a changed production line' <<< "$output"; then
  echo 'ok - changing only the import makes the call a new finding'
else
  failures=$((failures + 1))
  echo "FAIL - changing only the import makes the call a new finding (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo import-reorder-keeps-suppression)
cat > "$dir/src/Source.php" <<'PHP'
<?php
namespace Piwik\Plugins\Example;

use Piwik\Period\Factory;
use Piwik\Date;

// timezone-safety-ignore
Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i -e '4{h;d}' -e '5G' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm reorder-imports
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF 'Findings on changed production lines: 0 error(s)' <<< "$output"; then
  echo 'ok - reordering imports keeps an existing suppression'
else
  failures=$((failures + 1))
  echo "FAIL - reordering imports keeps an existing suppression (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo comment-shape-in-string)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;
Factory::makePeriodFromQueryParams('', 'day', $date); $label = "); // timezone-safety-ignore";
PHP
check 'a suppression marker shaped like a comment inside a string is not a suppression' 1 '1 error(s)' "$dir"

dir=$(new_repo imports-in-strings-and-comments)
cat > "$dir/src/Source.php" <<'PHP'
<?php
namespace Vendor\Reports;

$template = <<<EOT
use Piwik\Period\Factory;
EOT;
// use Piwik\Date;
$note = 'use Piwik\Period\Range;';
Factory::makePeriodFromQueryParams('', 'day', $date);
Date::today();
$range = new Range('day', 'last7');
PHP
check 'use statements in heredocs, comments and strings are not imports' 0 '0 error(s), 0 warning(s)' "$dir"

dir=$(new_repo mixed-case-methods)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Date;
use Piwik\Period\Factory;

Factory::MakePeriodFromQueryParams('', 'day', $date);
Date::Today();
Date::FACTORY('yesterday');
PHP
check 'method names match case-insensitively, as PHP calls them' 1 '1 error(s), 2 warning(s)' "$dir"

dir=$(new_repo interpolated-quotes)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Date;

$label = "{$labels["Date::today()"]} and ${names["Date::yesterday()"]}";
$sql = "SELECT {$columns["day"]} FROM log_visit WHERE day = CURRENT_DATE";
PHP
check 'quotes inside a string interpolation do not end the string' 1 '1 error(s), 0 warning(s)' "$dir"

dir=$(new_repo clock-names-outside-sql)
cat > "$dir/src/Source.php" <<'PHP'
<?php
define('CURRENT_DATE', 1);
$map['CURRENT_TIMESTAMP'] = 1;
$message = 'Retry now()';
$sql = 'SELECT NOW()';
$expression = 'NOW()';
PHP
check 'clock names outside SQL are not findings, uppercase clock calls are' 1 '2 error(s)' "$dir"

for edited in Factory Common; do
  dir=$(new_repo "multiline-import-change-$edited")
  cat > "$dir/src/Source.php" <<'PHP'
<?php
namespace Piwik\Plugins\Example;

use Piwik\{
    Common,
    FACTORY_ENTRY,
};

Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
  if [ "$edited" = Factory ]; then
    sed -i 's/FACTORY_ENTRY/Plugins\\Example\\Factory/' "$dir/src/Source.php"
  else
    sed -i 's/FACTORY_ENTRY/Period\\Factory/' "$dir/src/Source.php"
  fi
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name 'Timezone test'
  git -C "$dir" add .
  git -C "$dir" commit -qm initial
  if [ "$edited" = Factory ]; then
    sed -i 's/Plugins\\Example\\Factory/Period\\Factory/' "$dir/src/Source.php"
    expected_exit=1
  else
    sed -i 's/^    Common,$/    Common as MatomoCommon,/' "$dir/src/Source.php"
    expected_exit=0
  fi
  git -C "$dir" add .
  git -C "$dir" commit -qm "edit-$edited"
  output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
  actual=$?
  tests=$((tests + 1))
  if [ "$actual" -eq "$expected_exit" ]; then
    echo "ok - editing the $edited line of a multi-line grouped import is attributed to its own entry"
  else
    failures=$((failures + 1))
    echo "FAIL - editing the $edited line of a multi-line grouped import is attributed to its own entry (exit $actual)"
    print_indented "$output"
  fi
done

dir=$(new_repo two-findings-one-line)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Date;
use Piwik\Period\Factory;

$today = Date::today(); $period = Factory::build('day', 'today');
PHP
check 'different findings on one line are each reported' 0 '2 warning(s)' "$dir"

dir=$(new_repo ignore-inside-multiline-call)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

Factory::makePeriodFromQueryParams(
    '', // timezone-safety-ignore
    'day',
    $date
);
PHP
check 'a suppression on any line of a multi-line call applies to it' 0 '0 error(s)' "$dir"

commit_all() {
  git -C "$1" init -q
  git -C "$1" config user.email test@example.invalid
  git -C "$1" config user.name 'Timezone test'
  git -C "$1" add .
  git -C "$1" commit -qm "${2:-initial}"
}

check_against_base() {
  local description="$1" expected_exit="$2" base_ref="$3" dir="$4" output actual
  output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref "$base_ref" "$dir" 2>&1)
  actual=$?
  tests=$((tests + 1))
  if [ "$actual" -eq "$expected_exit" ]; then
    echo "ok - $description"
  else
    failures=$((failures + 1))
    echo "FAIL - $description (exit $actual, expected $expected_exit)"
    print_indented "$output"
  fi
}

dir=$(new_repo sql-context-change)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$query = 'label, '
    . 'current_date';
PHP
commit_all "$dir"
sed -i "s/'label, '/'SELECT label, '/" "$dir/src/Source.php"
commit_all "$dir" edit
check_against_base 'adding SQL to one literal of an expression makes its clock a changed finding' 1 HEAD~1 "$dir"

dir=$(new_repo deleted-import)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Vendor\Period;

Period\Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
commit_all "$dir"
sed -i '/^use Vendor/d' "$dir/src/Source.php"
commit_all "$dir" edit
check_against_base 'deleting an import that made a call name another class is a change to that call' 1 HEAD~1 "$dir"

dir=$(new_repo reordered-imports)
cat > "$dir/src/Source.php" <<'PHP'
<?php
namespace Piwik\Plugins\Example;

use Piwik\Period\Factory;
use Piwik\Common;

Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
commit_all "$dir"
sed -i -e 's/^use Piwik\\Period\\Factory;$/use Piwik\\Common;/' -e '5s/.*/use Piwik\\Period\\Factory;/' "$dir/src/Source.php"
commit_all "$dir" edit
check_against_base 'reordering imports leaves an old finding unchanged' 0 HEAD~1 "$dir"

dir=$(new_repo same-line-different-ends)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

Factory::build('day', 'today'); Factory::build('day',
    'today');
PHP
commit_all "$dir"
sed -i "5s/'today'/'yesterday'/" "$dir/src/Source.php"
commit_all "$dir" edit
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
tests=$((tests + 1))
if grep -qF 'Timezone finding on a changed production line' <<< "$output" && grep -qF '2 warning(s)' <<< "$output"; then
  echo 'ok - a same-message call starting on the line of another is reported separately'
else
  failures=$((failures + 1))
  echo 'FAIL - a same-message call starting on the line of another is reported separately'
  print_indented "$output"
fi

dir=$(new_repo suppressed-then-reimported)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Vendor\Period;

Period\Factory::makePeriodFromQueryParams('', 'day', $date); // timezone-safety-ignore
PHP
commit_all "$dir"
sed -i '/^use Vendor/d' "$dir/src/Source.php"
commit_all "$dir" edit
check_against_base 'an old marker does not cover a call an import edit made name another class' 1 HEAD~1 "$dir"

dir=$(new_repo suppressed-then-sql)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$query = 'label, '
    . 'current_date'; // timezone-safety-ignore
PHP
commit_all "$dir"
sed -i "s/'label, '/'SELECT label, '/" "$dir/src/Source.php"
commit_all "$dir" edit
check_against_base 'an old marker does not cover a clock that an SQL edit elsewhere made SQL' 1 HEAD~1 "$dir"

dir=$(new_repo uncommitted-edit)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

$period = Factory::makePeriodFromQueryParams(siteTimezone(), 'day', $date);
PHP
commit_all "$dir"
sed -i "s/siteTimezone()/''/" "$dir/src/Source.php"
check_against_base 'an uncommitted edit is compared with the base revision' 1 HEAD "$dir"

dir=$(new_repo untracked-file)
commit_all "$dir"
cat > "$dir/src/New.php" <<'PHP'
<?php
use Piwik\Period\Factory;

$period = Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
check_against_base 'an untracked source file is all changed lines' 1 HEAD "$dir"

dir=$(new_repo advisory-with-base)
commit_all "$dir"
cat > "$dir/src/New.php" <<'PHP'
<?php
$today = $db->fetchOne('SELECT NOW()');
PHP
output=$(bash "$SCRIPT" --advisory --base-ref HEAD "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF '::notice file=src/New.php,line=2::Timezone finding on a changed production line' <<< "$output" \
  && grep -qF 'Findings on changed production lines: 1 error(s)' <<< "$output"; then
  echo 'ok - an advisory scan with a base still marks findings on changed lines'
else
  failures=$((failures + 1))
  echo "FAIL - an advisory scan with a base still marks findings on changed lines (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo backtick-string)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$output = `echo new \Piwik\Period\Range('today', 'yesterday')`;
PHP
check 'a call written inside a backtick string is not scanned' 0 '0 warning(s)' "$dir"

dir=$(new_repo ignore-around-multiline-sql)
cat > "$dir/src/Source.php" <<'PHP'
<?php
// timezone-safety-ignore
$heredoc = <<<SQL
SELECT idvisit
FROM log_visit WHERE ts < NOW()
SQL;
$string = "SELECT idvisit
    FROM log_visit WHERE ts < NOW()"; // timezone-safety-ignore
PHP
check 'a suppression before or after a multi-line SQL string covers a clock inside it' 0 '0 error(s)' "$dir"

dir=$(new_repo changed-clock-in-suppressed-heredoc)
cat > "$dir/src/Source.php" <<'PHP'
<?php
// timezone-safety-ignore
$heredoc = <<<SQL
SELECT idvisit
FROM log_visit WHERE ts < ?
SQL;
PHP
commit_all "$dir"
sed -i 's/ts < ?/ts < NOW()/' "$dir/src/Source.php"
commit_all "$dir" edit
check_against_base 'an old suppression before a heredoc does not cover a clock newly added inside it' 1 HEAD~1 "$dir"

dir=$(new_repo explicit-empty-timezone)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\{Factory, Range};

Factory::build($period, $date, null);
new Range('range', $date, '');
Factory::build($period, $date,);
Date::factory('today', null);
Date::factory('today', '');
PHP
check 'empty, null, and trailing timezone arguments are reviewed' 0 '5 warning(s)' "$dir"

dir=$(new_repo unrelated-range)
cat > "$dir/src/Source.php" <<'PHP'
<?php
class Range {}
new Range('range', $date, $timezone);
PHP
check 'unrelated Range classes are not treated as period ranges' 0 '0 warning(s)' "$dir"

dir=$(new_repo no-suite)
echo "Date::factory('yesterday');" > "$dir/src/Source.php"
check 'static check works without a suite' 0 'no timezone-specific suite' "$dir"

dir=$(new_repo suite-does-not-suppress)
echo "Date::factory('now');" > "$dir/src/Source.php"
mkdir -p "$dir/tests/Integration"
echo "class TimezoneTest {}" > "$dir/tests/Integration/TimezoneTest.php"
check 'a suite is reported but does not suppress findings' 0 'Timezone coverage files:' "$dir"

dir=$(new_repo yaml-tz-workflow)
mkdir -p "$dir/.github/workflows"
printf '%s\n' 'jobs:' '  test:' '    env:' '      TZ: Pacific/Auckland' > "$dir/.github/workflows/tests.yml"
check 'a workflow setting TZ in YAML counts as timezone coverage' 0 '.github/workflows/tests.yml' "$dir"

dir=$(new_repo warning)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

Factory::build($period, $date);
Period\Factory::build($period, $date); // this comment mentions NOW()
PHP
check 'period construction without timezone is advisory by default' 0 '2 warning(s)' "$dir"
output=$(bash "$SCRIPT" --fail-on-warnings "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF '2 warning(s)' <<< "$output"; then
  echo 'ok - unsafe period warnings can be made strict'
else
  failures=$((failures + 1))
  echo "FAIL - unsafe period warnings can be made strict (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo warning-ignore)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

// timezone-safety-ignore
Date::factory('today');
Factory::build($period, $date), // timezone-safety-ignore
Period\Factory::makePeriodFromQueryParams('', 'day', \$date); # timezone-safety-ignore
PHP
check 'intentional findings can be suppressed locally' 0 '0 error(s), 0 warning(s)' "$dir"

dir=$(new_repo inline-ignore-shapes)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

Factory::build( // timezone-safety-ignore
    $period,
    $date
);
PHP
check 'inline suppression works on multiline call openers' 0 '0 warning(s)' "$dir"

dir=$(new_repo trailing-ignore)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$intentional = "NOW()"; // timezone-safety-ignore
$newFinding = "NOW()";
PHP
check 'trailing suppression markers do not silence the next line' 1 '1 error(s)' "$dir"

dir=$(new_repo suppression-insertion)
cat > "$dir/src/Source.php" <<'PHP'
<?php
// timezone-safety-ignore
$oldFinding = "NOW()";
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
# shellcheck disable=SC2016 # the $ is literal PHP fixture source.
sed -i '/\$oldFinding/i\$newFinding = "NOW()";' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm insertion
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'Timezone errors on changed production lines' <<< "$output"; then
  echo 'ok - inserting below an old suppression cannot hide new findings'
else
  failures=$((failures + 1))
  echo "FAIL - inserting below an old suppression cannot hide new findings (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo multiline-suppression)
cat > "$dir/src/Source.php" <<'PHP'
<?php
Period\Factory::build( // timezone-safety-ignore
    $period,
    $date
);
PHP
check 'same-line multiline suppression works before a change' 0 '0 warning(s)' "$dir"
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i "/\$date/a\\    ''," "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm add-unsafe-timezone
output=$(bash "$SCRIPT" --fail-on-warnings --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'Strict timezone warning mode found 1 warning(s)' <<< "$output"; then
  echo 'ok - an unchanged same-line suppression cannot hide a changed multiline finding'
else
  failures=$((failures + 1))
  echo "FAIL - an unchanged same-line suppression cannot hide a changed multiline finding (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo parser-contexts)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

$html = <<<HTML
Don't scan this text: Date::factory('today');
HTML;
#[Attribute('Date::factory(\'today\')')]
Date::factory('today');
Factory::build(<<<SQL
Don't scan this text either.
SQL, $date);
Date::factory('yesterday');
$fragment = <<<SQL
This closes before a concatenation.
SQL . $suffix;
Date::factory('today');
?>
<p>Date::factory('today');</p>
<?php
Date::factory('yesterday');
PHP
check 'heredocs, attributes, and inline HTML do not hide PHP findings' 0 '5 warning(s)' "$dir"

dir=$(new_repo leading-html)
cat > "$dir/src/Template.php" <<'PHP'
Don't parse this HTML as PHP: https://example.test/path//segment
<?php
$query = 'SELECT NOW()';
PHP
check 'leading inline HTML does not confuse database-clock scanning' 1 'database server-clock' "$dir"

dir=$(new_repo unclosed-heredoc)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$fragment = <<<SQL
The closing label is missing.
Date::factory('today');
PHP
check 'unclosed heredocs fail the scan closed' 2 'parser failed' "$dir"

dir=$(new_repo deletion-only)
cat > "$dir/src/Source.php" <<'PHP'
<?php
// timezone-safety-ignore
Period\Factory::makePeriodFromQueryParams('', 'day', $date);
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i '/timezone-safety-ignore/d' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm remove-suppression
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'Timezone errors on changed production lines' <<< "$output"; then
  echo 'ok - deletion-only changes cannot hide new findings'
else
  failures=$((failures + 1))
  echo "FAIL - deletion-only changes cannot hide new findings (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo delete-suppressed-finding)
cat > "$dir/src/Source.php" <<'PHP'
<?php
// timezone-safety-ignore
$first = "NOW()";
$second = "CURDATE()";
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i '/timezone-safety-ignore/d; /first/d' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm delete-suppressed-finding
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF 'Findings on changed production lines: 0 error(s), 0 warning(s)' <<< "$output"; then
  echo 'ok - deleting a suppression and its finding does not change the next finding'
else
  failures=$((failures + 1))
  echo "FAIL - deleting a suppression and its finding does not change the next finding (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo delete-only-before-finding)
cat > "$dir/src/Source.php" <<'PHP'
<?php
// timezone-safety-ignore
$first = "NOW()";
$second = "CURDATE()";
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i '/first/d' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm delete-only-before-finding
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF 'Findings on changed production lines: 0 error(s)' <<< "$output" \
  && grep -qF '1 error(s)' <<< "$output"; then
  echo 'ok - deleting a suppressed finding does not suppress the next finding'
else
  failures=$((failures + 1))
  echo "FAIL - deleting a suppressed finding does not suppress the next finding (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo replacement-with-suppression)
echo '<?php' > "$dir/src/Source.php"
# shellcheck disable=SC2016 # the $ is literal PHP fixture source.
echo '$query = "SELECT 1";' >> "$dir/src/Source.php"
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
cat > "$dir/src/Source.php" <<'PHP'
<?php
// timezone-safety-ignore
$query = "SELECT NOW()";
PHP
git -C "$dir" add .
git -C "$dir" commit -qm replace-with-suppression
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF '0 error(s), 0 warning(s)' <<< "$output"; then
  echo 'ok - a suppression added in a replacement hunk covers its new finding'
else
  failures=$((failures + 1))
  echo "FAIL - a suppression added in a replacement hunk covers its new finding (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo edited-suppression)
cat > "$dir/src/Source.php" <<'PHP'
<?php
// timezone-safety-ignore
$query = "NOW()";
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i 's/timezone-safety-ignore/timezone-safety-ignore: legacy query/' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm edit-suppression
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF '0 error(s), 0 warning(s)' <<< "$output"; then
  echo 'ok - editing a suppression above an unchanged finding remains allowed'
else
  failures=$((failures + 1))
  echo "FAIL - editing a suppression above an unchanged finding remains allowed (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo multiline-unrelated-deletion)
cat > "$dir/src/Source.php" <<'PHP'
<?php
$unused = 1;
Period\Factory::makePeriodFromQueryParams(
    '',
    'day',
    $date
);
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i '/unused/d' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm remove-unrelated-line
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF 'Findings on changed production lines: 0 error(s), 0 warning(s)' <<< "$output"; then
  echo 'ok - unrelated deletion before a multiline finding stays pre-existing'
else
  failures=$((failures + 1))
  echo "FAIL - unrelated deletion before a multiline finding stays pre-existing (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo multiline-deletion-inside)
cat > "$dir/src/Source.php" <<'PHP'
<?php
Period\Factory::makePeriodFromQueryParams(
    '',
    'day',
    $date,
    $extra
);
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i '/extra/d' "$dir/src/Source.php"
git -C "$dir" add .
git -C "$dir" commit -qm remove-inside-finding
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'Timezone errors on changed production lines: 1' <<< "$output"; then
  echo 'ok - deletion inside a multiline finding is treated as changed'
else
  failures=$((failures + 1))
  echo "FAIL - deletion inside a multiline finding is treated as changed (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo excluded)
mkdir -p "$dir/vendor" "$dir/tests"
echo "Date::factory('today');" > "$dir/vendor/Dependency.php"
echo "Date::factory('today');" > "$dir/tests/Fixture.php"
check 'vendor and tests are excluded from production findings' 0 '0 error(s)' "$dir"

dir=$(new_repo changed)
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
echo "Date::factory('today');" > "$dir/src/Source.php"
git -C "$dir" add src/Source.php
git -C "$dir" commit -qm unsafe
output=$(bash "$SCRIPT" --fail-on-warnings "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'relative date' <<< "$output"; then
  echo 'ok - full scan finds the changed issue'
else
  failures=$((failures + 1))
  echo "FAIL - full scan finds the changed issue (exit $actual)"
  print_indented "$output"
fi
output=$(bash "$SCRIPT" --fail-on-warnings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'relative date' <<< "$output" && grep -qF 'Findings on changed production lines: 0 error(s), 1 warning(s)' <<< "$output"; then
  echo 'ok - base-ref scan finds the changed issue and reports the changed line'
else
  failures=$((failures + 1))
  echo "FAIL - base-ref scan finds the changed issue and reports the changed line (exit $actual)"
  print_indented "$output"
fi
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF 'Findings on changed production lines: 0 error(s), 1 warning(s)' <<< "$output"; then
  echo 'ok - new warnings remain advisory'
else
  failures=$((failures + 1))
  echo "FAIL - new warnings remain advisory (exit $actual)"
  print_indented "$output"
fi
output=$(bash "$SCRIPT" --fail-on-new-findings --fail-on-warnings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ]; then
  echo 'ok - new warnings can be made strict explicitly'
else
  failures=$((failures + 1))
  echo "FAIL - new warnings can be made strict explicitly (exit $actual)"
  print_indented "$output"
fi

echo "Period\\Factory::makePeriodFromQueryParams('', 'day', \$date);" > "$dir/src/Source.php"
git -C "$dir" add src/Source.php
git -C "$dir" commit -qm unsafe-error
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 1 ] && grep -qF 'Timezone errors on changed production lines' <<< "$output"; then
  echo 'ok - new errors remain blocking'
else
  failures=$((failures + 1))
  echo "FAIL - new errors remain blocking (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo existing)
echo "Date::factory('today');" > "$dir/src/Source.php"
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
echo "// unrelated change" >> "$dir/src/Source.php"
git -C "$dir" add src/Source.php
git -C "$dir" commit -qm unrelated
output=$(bash "$SCRIPT" --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] \
  && grep -qF '1 warning(s)' <<< "$output" \
  && grep -qF 'Findings on changed production lines: 0 error(s), 0 warning(s)' <<< "$output"; then
  echo 'ok - base-ref scan still surfaces pre-existing findings'
else
  failures=$((failures + 1))
  echo "FAIL - base-ref scan still surfaces pre-existing findings (exit $actual)"
  print_indented "$output"
fi
output=$(bash "$SCRIPT" --fail-on-new-findings --fail-on-warnings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ]; then
  echo 'ok - strict new-warning mode ignores pre-existing warnings'
else
  failures=$((failures + 1))
  echo "FAIL - strict new-warning mode ignores pre-existing warnings (exit $actual)"
  print_indented "$output"
fi
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF '1 warning(s)' <<< "$output"; then
  echo 'ok - pre-existing findings are advisory in new-findings mode'
else
  failures=$((failures + 1))
  echo "FAIL - pre-existing findings are advisory in new-findings mode (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo existing-error)
echo "Period\\Factory::makePeriodFromQueryParams('', 'day', \$date);" > "$dir/src/Source.php"
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
echo '// unrelated change' >> "$dir/src/Source.php"
git -C "$dir" add src/Source.php
git -C "$dir" commit -qm unrelated
output=$(bash "$SCRIPT" --fail-on-new-findings --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF 'empty timezone' <<< "$output"; then
  echo 'ok - pre-existing errors are advisory in new-findings mode'
else
  failures=$((failures + 1))
  echo "FAIL - pre-existing errors are advisory in new-findings mode (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo tests-only)
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
mkdir -p "$dir/tests/Integration"
echo 'class TimezoneTest {}' > "$dir/tests/Integration/TimezoneTest.php"
git -C "$dir" add tests/Integration/TimezoneTest.php
git -C "$dir" commit -qm tests
output=$(bash "$SCRIPT" --base-ref HEAD~1 "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF 'No changed PHP or SQL source files were selected' <<< "$output"; then
  echo 'ok - a test-only change does not fail for lack of production files'
else
  failures=$((failures + 1))
  echo "FAIL - a test-only change does not fail for lack of production files (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo multiline)
cat > "$dir/src/Source.php" <<'PHP'
<?php
use Piwik\Period\Factory;

Factory::build(
    $period,
    $date,
    $timezone
);
PHP
git -C "$dir" init -q
git -C "$dir" config user.email test@example.invalid
git -C "$dir" config user.name 'Timezone test'
git -C "$dir" add .
git -C "$dir" commit -qm initial
sed -i "s/\$timezone/''/" "$dir/src/Source.php"
git -C "$dir" add src/Source.php
git -C "$dir" commit -qm unsafe
output=$(bash "$SCRIPT" --base-ref HEAD~1 --fail-on-new-findings "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF 'Findings on changed production lines: 0 error(s), 1 warning(s)' <<< "$output"; then
  echo 'ok - multiline findings are identified when a changed argument is unsafe'
else
  failures=$((failures + 1))
  echo "FAIL - multiline findings are identified when a changed argument is unsafe (exit $actual)"
  print_indented "$output"
fi

dir="$WORK/no-source"
mkdir -p "$dir/tests"
check 'repositories without production source fail closed' 2 'No PHP or SQL source files were scanned' "$dir"

dir=$(new_repo parser-failure)
fake_python="$WORK/fake-python"
mkdir -p "$fake_python"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$fake_python/python3"
chmod +x "$fake_python/python3"
output=$(PATH="$fake_python:$PATH" bash "$SCRIPT" "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 2 ] && grep -qF 'Source scanning failed for 1 source file(s)' <<< "$output"; then
  echo 'ok - parser failures fail closed'
else
  failures=$((failures + 1))
  echo "FAIL - parser failures fail closed (exit $actual)"
  print_indented "$output"
fi

dir=$(new_repo advisory)
echo "Period\\Factory::makePeriodFromQueryParams('', 'day', \$date);" > "$dir/src/Source.php"
output=$(bash "$SCRIPT" --advisory "$dir" 2>&1)
actual=$?
tests=$((tests + 1))
if [ "$actual" -eq 0 ] && grep -qF '::notice' <<< "$output" && ! grep -qF '::error' <<< "$output"; then
  echo 'ok - advisory scans use non-error annotations'
else
  failures=$((failures + 1))
  echo "FAIL - advisory scans use non-error annotations (exit $actual)"
  print_indented "$output"
fi

echo "$tests test(s), $failures failure(s)"
[ "$failures" -eq 0 ]
