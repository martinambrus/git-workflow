<?php

declare(strict_types=1);

namespace Drupal\ait_banners\Plugin\Block;

use Drupal\Core\Block\Attribute\Block;
use Drupal\Core\Block\BlockBase;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\StringTranslation\TranslatableMarkup;

/**
 * Provides a sponsorship banner block.
 */
#[Block(
  id: 'ait_banners_sponsorship',
  admin_label: new TranslatableMarkup('Sponsorship banner'),
  category: new TranslatableMarkup('AIT'),
)]
class SponsorshipBannerBlock extends BlockBase {

  /**
   * {@inheritdoc}
   */
  public function defaultConfiguration(): array {
    return [
      'sponsor' => 'Our sponsor',
      'tagline' => '',
      'url' => 'https://example.com',
      'image_url' => '',
      'promo' => '',
    ];
  }

  /**
   * {@inheritdoc}
   */
  public function blockForm($form, FormStateInterface $form_state): array {
    $form['sponsor'] = [
      '#type' => 'textfield',
      '#title' => $this->t('Sponsor name'),
      '#default_value' => $this->configuration['sponsor'],
      '#required' => TRUE,
    ];
    $form['tagline'] = [
      '#type' => 'textfield',
      '#title' => $this->t('Tagline'),
      '#default_value' => $this->configuration['tagline'],
    ];
    $form['url'] = [
      '#type' => 'url',
      '#title' => $this->t('Link URL'),
      '#default_value' => $this->configuration['url'],
      '#required' => TRUE,
    ];
    $form['image_url'] = [
      '#type' => 'url',
      '#title' => $this->t('Logo URL'),
      '#default_value' => $this->configuration['image_url'],
    ];
    $form['promo'] = [
      '#type' => 'textfield',
      '#title' => $this->t('Promo badge'),
      '#description' => $this->t('Short promotional text shown as a badge, e.g. "-20% this week". Leave empty for none.'),
      '#default_value' => $this->configuration['promo'],
      '#maxlength' => 40,
    ];
    return $form;
  }

  /**
   * {@inheritdoc}
   */
  public function blockSubmit($form, FormStateInterface $form_state): void {
    foreach (['sponsor', 'tagline', 'url', 'image_url', 'promo'] as $key) {
      $this->configuration[$key] = $form_state->getValue($key);
    }
  }

  /**
   * {@inheritdoc}
   */
  public function build(): array {
    return [
      '#theme' => 'ait_banners_banner',
      '#sponsor' => $this->configuration['sponsor'],
      '#tagline' => $this->configuration['tagline'],
      '#url' => $this->configuration['url'],
      '#image_url' => $this->configuration['image_url'],
      '#promo' => $this->configuration['promo'],
      '#attached' => ['library' => ['ait_banners/banner']],
    ];
  }

}
