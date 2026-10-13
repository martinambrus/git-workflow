#!/bin/bash
# Run on the host from the project directory by ops/bin/new-drupal-project.sh, after the extension modules were copied.
# Shop B only: promo badge (shared module, 1.1+) and the sponsor tier (shop_b_banner_tiers extension).
set -euo pipefail
ddev drush php:eval '
$b = \Drupal\block\Entity\Block::load("olivero_sponsorship_banner");
$settings = $b->get("settings");
$settings["promo"] = "-20% this week";
$b->set("settings", $settings);
$b->setThirdPartySetting("shop_b_banner_tiers", "tier", "gold");
$b->save();'
