<?php

/**
 * Matomo - free/libre analytics platform
 *
 * @link    https://matomo.org
 * @license http://www.gnu.org/licenses/gpl-3.0.html GPL v3 or later
 *
 * GENERATED FILE - do not commit this to the plugin repository.
 * It is written into the runner's Matomo checkout by matomo-org/plugin-ci-workflows.
 * To change it, edit scripts/php/templates/GeneratedTwigCompilationTest.php.tpl in that repository.
 */

namespace Piwik\Plugins\{{PLUGIN_NAME}}\{{TEST_ROOT}}\Integration;

use Piwik\Plugin\Manager;
use Piwik\Tests\Framework\TestCase\IntegrationTestCase;

/**
 * Compiles every template the plugin ships, so that one using a core template function, filter
 * or tag that does not exist in the Matomo version under test fails here rather than when a
 * user opens the page on an install running that version.
 *
 * Only compilation is covered. Undefined variables, and an extends, include, embed or import of a
 * core template or macro that was renamed or removed, resolve at render time and are not reported.
 *
 * @group Plugins
 */
class GeneratedTwigCompilationTest extends IntegrationTestCase
{
    private const PLUGIN_NAME = '{{PLUGIN_NAME}}';

    public function testTemplatesCompileAgainstTheMatomoVersionUnderTest()
    {
        $templateDir = PIWIK_DOCUMENT_ROOT . '/plugins/' . self::PLUGIN_NAME . '/templates';
        $templates   = is_dir($templateDir) ? $this->getTemplateNames($templateDir) : [];

        if (empty($templates)) {
            self::markTestSkipped(self::PLUGIN_NAME . ' ships no templates.');
        }

        // the plugin's own template extensions are only registered while it is loaded, and the
        // test framework decides what to load from this class' namespace
        self::assertTrue(
            Manager::getInstance()->isPluginLoaded(self::PLUGIN_NAME),
            self::PLUGIN_NAME . ' is not loaded, so this check would not cover the plugin.'
        );

        $environment = (new \Piwik\Twig())->getTwigEnvironment();

        foreach ($templates as $template) {
            $environment->load('@' . self::PLUGIN_NAME . '/' . $template);
        }
    }

    /**
     * @return string[] template names relative to the plugin's templates directory
     */
    private function getTemplateNames(string $templateDir): array
    {
        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($templateDir, \FilesystemIterator::SKIP_DOTS)
        );

        $names = [];

        foreach ($iterator as $file) {
            if ($file->getExtension() !== 'twig') {
                continue;
            }

            // theme overrides under templates/plugins/<Other>/ are included: the plugin's own
            // namespace is rooted at templates/, so this reaches the override file itself. Their
            // registered namespace is only added for the theme that is currently enabled, which
            // the plugin under test is not, so addressing them that way would compile the
            // overridden plugin's copy instead of the file shipped here.
            $names[] = str_replace('\\', '/', substr($file->getPathname(), strlen($templateDir) + 1));
        }

        sort($names);

        return $names;
    }
}
