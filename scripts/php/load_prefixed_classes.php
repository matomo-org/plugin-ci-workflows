<?php
// Loads every class, interface, trait and enum a vendor/prefixed tree declares, through the tree's own
// autoloader, and prints "<class>\tok\t" or "<class>\tfail\t<message>" for each, after a line of the
// same form for the autoloader itself, named (vendor/autoload.php). When the autoloader fails, that
// line is all it prints.
//
// A class that lints can still fail to load: Rector can drop a return type from a method whose
// interface keeps it, which only fails when PHP links the class. That is a fatal error, so the classes
// are loaded in a child process, and when it dies the parent records the class it was loading and
// starts a new child at the next one.
//
// Usage: php load_prefixed_classes.php <vendor-prefixed-dir>
// Run it on the PHP the tree has to work on. It is written for PHP 7.2, so that it runs on any floor.
// Exits 0 whether or not a class failed, 1 when the tree has no autoloader, 2 on a usage error.

require_once __DIR__ . '/prefixed_declarations.php';

if ($argc === 5 && $argv[1] === '--child') {
    childMain($argv[2], $argv[3], (int) $argv[4]);
    exit(0);
}
if ($argc !== 2) {
    fwrite(STDERR, "Usage: php load_prefixed_classes.php <vendor-prefixed-dir>\n");
    exit(2);
}
$root = rtrim($argv[1], '/');
if (!is_file($root . '/vendor/autoload.php')) {
    fwrite(STDERR, "$root/vendor/autoload.php does not exist.\n");
    exit(1);
}
$classes = declaredClasses($root);
$list = tempnam(sys_get_temp_dir(), 'classes');
file_put_contents($list, implode("\n", $classes));
$failures = [];
$autoloaded = true;
$start = 0;
while (true) {
    $command = escapeshellarg(PHP_BINARY) . ' -d memory_limit=1G -d display_errors=0 -d log_errors=0 '
        . escapeshellarg(__FILE__) . ' --child ' . escapeshellarg($root) . ' ' . escapeshellarg($list) . ' ' . $start;
    $output = [];
    exec($command . ' 2>/dev/null', $output);
    $loading = null;
    $finished = false;
    $fatal = null;
    foreach ($output as $line) {
        $fields = explode("\t", $line, 3);
        if ($fields[0] === 'L') {
            $loading = (int) $fields[1];
        } elseif ($fields[0] === 'E') {
            $failures[$fields[1]] = $fields[2];
        } elseif ($fields[0] === 'F') {
            $fatal = $fields[2];
        } elseif ($fields[0] === 'D') {
            $finished = true;
        }
    }
    if ($finished) {
        break;
    }
    if ($loading === null) {
        $autoloaded = false;
        report('(vendor/autoload.php)', 'fail', $fatal !== null ? $fatal : 'The autoloader ended the process.', $root);
        break;
    }
    $failures[$classes[$loading]] = $fatal !== null ? $fatal : 'The process ended while loading it.';
    $start = $loading + 1;
}
unlink($list);
if ($autoloaded) {
    report('(vendor/autoload.php)', 'ok', '', $root);
    foreach ($classes as $class) {
        report($class, isset($failures[$class]) ? 'fail' : 'ok', isset($failures[$class]) ? $failures[$class] : '', $root);
    }
}
exit(0);

function report($class, $status, $message, $root)
{
    // The tree's location differs between the trees a caller compares.
    echo $class, "\t", $status, "\t", str_replace($root . '/', '', preg_replace('/\s+/', ' ', $message)), "\n";
}

function childMain($root, $list, $start)
{
    $GLOBALS['loading'] = '(vendor/autoload.php)';
    register_shutdown_function(function () {
        $error = error_get_last();
        if ($GLOBALS['loading'] !== null && $error !== null
            && in_array($error['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR], true)) {
            echo "\nF\t", $GLOBALS['loading'], "\t", preg_replace('/\s+/', ' ', $error['message']), "\n";
        }
    });
    require $root . '/vendor/autoload.php';
    $classes = explode("\n", file_get_contents($list));
    for ($i = $start; $i < count($classes); $i++) {
        $GLOBALS['loading'] = $classes[$i];
        // Each marker starts a line of its own, whatever a loaded file printed without a newline.
        echo "\nL\t", $i, "\n";
        try {
            // An enum is a class to class_exists(), and enum_exists() only exists from PHP 8.1.
            if (!class_exists($classes[$i]) && !interface_exists($classes[$i]) && !trait_exists($classes[$i])) {
                echo "\nE\t", $classes[$i], "\tThe autoloader did not find it.\n";
            }
        } catch (Throwable $error) {
            echo "\nE\t", $classes[$i], "\t", get_class($error), ': ', preg_replace('/\s+/', ' ', $error->getMessage()), "\n";
        }
    }
    $GLOBALS['loading'] = null;
    echo "\nD\n";
}
