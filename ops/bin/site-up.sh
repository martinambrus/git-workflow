#!/bin/bash
# Start a project's DDEV site and, if it has no database yet (fresh clone), install it from the committed
# config/sync (module enabled, block placed): the database itself is never committed.
#   usage: site-up.sh <project>|all
set -euo pipefail
. "$(dirname "$0")/lib.sh"
targets=${1:?project name or 'all'}
[ "$targets" = all ] && targets=$(cd "$LAB_ROOT/projects" && ls -d */ | tr -d /)
for name in $targets; do
  dir=$LAB_ROOT/projects/$name
  [ -f "$dir/composer.json" ] || { echo "$name: not scaffolded yet (ops/bin/new-drupal-project.sh)" >&2; continue; }
  say "$name"
  ( cd "$dir"
    ddev start >/dev/null
    if ddev drush status --field=bootstrap 2>/dev/null | grep -q Successful; then
      echo "   database present, nothing to install"
    else
      ddev drush si --existing-config -y --account-name=admin --account-pass=admin >/dev/null
      echo "   installed from config/sync"
    fi
    echo "   $(ddev describe -j | jq -r .raw.httpsurl)  (admin/admin)" )
done
