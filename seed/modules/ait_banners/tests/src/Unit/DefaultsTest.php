<?php

declare(strict_types=1);

namespace Drupal\Tests\ait_banners\Unit;

use Drupal\ait_banners\Plugin\Block\SponsorshipBannerBlock;
use Drupal\Tests\UnitTestCase;

/**
 * Checks the banner block defaults.
 *
 * @group ait_banners
 */
class DefaultsTest extends UnitTestCase {

  /**
   * The block has a sponsor and URL out of the box.
   */
  public function testDefaults(): void {
    $block = new SponsorshipBannerBlock([], 'ait_banners_sponsorship', ['provider' => 'ait_banners']);
    $defaults = $block->defaultConfiguration();
    $this->assertNotEmpty($defaults['sponsor']);
    $this->assertNotEmpty($defaults['url']);
  }

}
