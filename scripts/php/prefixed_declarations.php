<?php
// The classes, interfaces, traits and enums a vendor/prefixed tree declares, for load_prefixed_classes.php
// and list_prefixed_enums.php. Written for PHP 7.2, like the loader.

/** @return string[] */
function declaredClasses($root)
{
    return array_values(array_unique(array_column(declarations($root), 0)));
}

/** @return string[] */
function declaredEnums($root)
{
    return array_values(array_unique(array_column(array_filter(declarations($root), function ($declaration) {
        return $declaration[1];
    }), 0)));
}

/** @return array{string, bool}[] each declaration's name, and whether it is an enum */
function declarations($root)
{
    $files = [];
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));
    foreach ($iterator as $file) {
        $path = $file->getPathname();
        // Composer's own loader, which the autoloader has already loaded.
        if ($file->getExtension() === 'php' && strpos($path, $root . '/vendor/') !== 0) {
            $files[] = $path;
        }
    }
    sort($files);
    $declarations = [];
    foreach ($files as $path) {
        foreach (declaredIn(file_get_contents($path)) as $declaration) {
            $declarations[] = $declaration;
        }
    }
    return $declarations;
}

/** @return array{string, bool}[] */
function declaredIn($source)
{
    // Lexing, not parsing, so a file this PHP cannot parse still names its classes. Before PHP 8.1
    // "enum" is an ordinary name, and before PHP 8.0 a namespace is lexed in parts.
    $tokens = array_values(array_filter(token_get_all($source), function ($token) {
        return !is_array($token) || !in_array($token[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true);
    }));
    $declaring = [T_CLASS, T_INTERFACE, T_TRAIT];
    if (defined('T_ENUM')) {
        $declaring[] = T_ENUM;
    }
    $namespace = '';
    $classes = [];
    for ($i = 0; $i < count($tokens); $i++) {
        $token = $tokens[$i];
        if (!is_array($token)) {
            continue;
        }
        if ($token[0] === T_NAMESPACE) {
            $name = '';
            for ($j = $i + 1; $j < count($tokens) && is_array($tokens[$j]); $j++) {
                $name .= $tokens[$j][1];
            }
            // Before PHP 8.0 a relative name, namespace\Foo, starts with this token too.
            if (strpos($name, '\\') !== 0) {
                $namespace = $name;
            }
            continue;
        }
        $isEnum = (defined('T_ENUM') && $token[0] === T_ENUM) || ($token[0] === T_STRING && strtolower($token[1]) === 'enum'
            && isset($tokens[$i + 1]) && is_array($tokens[$i + 1]) && $tokens[$i + 1][0] === T_STRING);
        if (!$isEnum && !in_array($token[0], $declaring, true)) {
            continue;
        }
        // Foo::class and new class are not declarations.
        $previous = $i > 0 ? $tokens[$i - 1] : null;
        if (is_array($previous) && in_array($previous[0], [T_DOUBLE_COLON, T_NEW], true)) {
            continue;
        }
        if (isset($tokens[$i + 1]) && is_array($tokens[$i + 1]) && $tokens[$i + 1][0] === T_STRING) {
            $classes[] = [($namespace === '' ? '' : $namespace . '\\') . $tokens[$i + 1][1], $isEnum];
        }
    }
    return $classes;
}
