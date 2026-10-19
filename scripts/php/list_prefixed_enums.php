<?php
// Prints each enum a vendor/prefixed tree declares, one per line. Rector turns an enum into a class of
// constants, so once the tree is transpiled nothing in it says which classes were enums: run this first.
//
// Usage: php list_prefixed_enums.php <vendor-prefixed-dir>
// Exits 0, or 2 on a usage error.

require_once __DIR__ . '/prefixed_declarations.php';

if ($argc !== 2 || !is_dir($argv[1])) {
    fwrite(STDERR, "Usage: php list_prefixed_enums.php <vendor-prefixed-dir>\n");
    exit(2);
}
foreach (declaredEnums(rtrim($argv[1], '/')) as $enum) {
    echo $enum, "\n";
}
