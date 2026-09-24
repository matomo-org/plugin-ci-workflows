<?php

/**
 * Matomo - free/libre analytics platform
 *
 * @link    https://matomo.org
 * @license http://www.gnu.org/licenses/gpl-3.0.html GPL v3 or later
 *
 * GENERATED FILE - do not commit this to the plugin repository.
 * It is written into the runner's Matomo checkout by matomo-org/plugin-ci-workflows.
 * To change it, edit scripts/php/templates/GeneratedAssetCompilationTest.php.tpl in that repository.
 */

namespace Piwik\Plugins\{{PLUGIN_NAME}}\{{TEST_ROOT}}\Integration;

use Piwik\AssetManager;
use Piwik\Plugin\Manager;
use Piwik\Tests\Framework\TestCase\IntegrationTestCase;
use Piwik\Theme;

/**
 * Compiles the merged stylesheet with the plugin loaded, so that a plugin using a core Less
 * mixin or variable that does not exist in the Matomo version under test fails here rather
 * than fatally on every page of an install running that version.
 *
 * @group Plugins
 */
class GeneratedAssetCompilationTest extends IntegrationTestCase
{
    private const PLUGIN_NAME = '{{PLUGIN_NAME}}';

    public function testStylesheetsCompileAgainstTheMatomoVersionUnderTest()
    {
        // the test framework decides which plugin to load from this class' namespace, so a
        // wrongly generated namespace would leave the plugin out and make the merge below pass
        // no matter what the plugin ships
        self::assertTrue(
            Manager::getInstance()->isPluginLoaded(self::PLUGIN_NAME),
            self::PLUGIN_NAME . ' is not loaded, so this check would not cover the plugin.'
        );

        $assetManager = AssetManager::getInstance();

        // a theme's own stylesheet is only merged while that theme is the enabled one
        $plugin = Manager::getInstance()->getLoadedPlugin(self::PLUGIN_NAME);
        if ($plugin->isTheme()) {
            $assetManager->setTheme(new Theme($plugin));
        }

        $assetManager->removeMergedAssets();

        self::assertNotEmpty($assetManager->getMergedStylesheet()->getContent());
    }
}
