<?php

declare(strict_types=1);

namespace Drupal\shop_b_banner_tiers;

use Drupal\Core\Security\TrustedCallbackInterface;

/**
 * Wraps the shared banner in a tier label (Shop B only).
 */
final class BannerTier implements TrustedCallbackInterface {

  /**
   * Tier machine name => label.
   */
  public static function options(): array {
    return [
      'silver' => t('Silver sponsor'),
      'gold' => t('Gold sponsor'),
      'platinum' => t('Platinum sponsor'),
    ];
  }

  /**
   * #pre_render callback of the block: runs after the shared block built it.
   */
  public static function preRender(array $build): array {
    $tier = (string) ($build['#shop_b_tier'] ?? '');
    $options = self::options();
    if ($tier === '' || !isset($options[$tier]) || empty($build['content'])) {
      return $build;
    }
    $build['content']['#prefix'] = '<div class="shop-b-tier shop-b-tier--' . $tier . '"><span class="shop-b-tier__label">' . $options[$tier] . '</span>';
    $build['content']['#suffix'] = '</div>';
    $build['content']['#attached']['library'][] = 'shop_b_banner_tiers/tier';
    return $build;
  }

  /**
   * {@inheritdoc}
   */
  public static function trustedCallbacks(): array {
    return ['preRender'];
  }

}
