<?php

use Rector\Config\RectorConfig;

return static function (RectorConfig $rectorConfig): void {
    $targetPhpVersion = getenv('RECTOR_DOWNGRADE_PHP_VERSION') ?: '7.3';

    $supportedTargets = [
        '7.3' => \Rector\Set\ValueObject\DowngradeLevelSetList::DOWN_TO_PHP_73,
        '8.1' => \Rector\Set\ValueObject\DowngradeLevelSetList::DOWN_TO_PHP_81,
    ];

    if (!isset($supportedTargets[$targetPhpVersion])) {
        throw new \InvalidArgumentException(sprintf(
            'Unsupported Rector downgrade PHP version "%s". Supported values: %s',
            $targetPhpVersion,
            implode(', ', array_keys($supportedTargets))
        ));
    }

    $rectorConfig->sets([
        $supportedTargets[$targetPhpVersion],
    ]);

    // Both exceptions below are PHP 8.0 downgrade rules, which are only registered when the target is
    // below 8.0. Listing them for a higher target makes Rector warn that they are never registered.
    if (version_compare($targetPhpVersion, '8.0', '<')) {
        $rectorConfig->skip([
            // Attributes are kept rather than downgraded: PHP 7 treats `#[` as a comment, so they are inert there while
            // still applying on PHP 8. That only holds while each attribute sits on its own line, which the plugins that
            // support PHP 7 arrange via a patcher in their scoper.inc.php.
            \Rector\DowngradePhp80\Rector\Class_\DowngradeAttributeToAnnotationRector::class,
            // Skip downgrading Token for php-parser since it already provides a polyfill
            \Rector\DowngradePhp80\Rector\StaticCall\DowngradePhpTokenRector::class => [
                '*/vendor/prefixed/nikic/php-parser/*',
            ],
        ]);
    }
};
