#!/bin/bash
# Scaffold a Drupal 11 DDEV project in projects/<name> (plan section 3 + 5):
# Packeton repository + dist installs, committed vendor/ and web/, shared module installed and a banner placed.
#   usage: new-drupal-project.sh <name> <sponsor> <tagline> [module-constraint]
#   e.g.:  new-drupal-project.sh shop-a "Acme Corp" "Proudly supporting Shop A" '^1.0'
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_secrets

name=${1:?project name}; sponsor=${2:?sponsor}; tagline=${3:?tagline}; constraint=${4:-^1.0}
dir=$LAB_ROOT/projects/$name
[ -d "$dir/.git" ] || { echo "no clone at $dir: add '$name' to lab.manifest and run ./lab sync" >&2; exit 1; }
[ -e "$dir/composer.json" ] && { echo "$name is already scaffolded" >&2; exit 1; }
cd "$dir"

say "ddev project ($name, Drupal 11, PHP 8.3)"
ddev config --project-type=drupal11 --docroot=web --php-version=8.3 --project-name="$name" --auto >/dev/null
cat > .ddev/docker-compose.wfnet.yaml <<'YAML'
# Join the git-workflow lab network so Composer in the web container can reach packeton.test / gitea.test
services:
  web:
    networks: [default, wf-net]
networks:
  wf-net:
    external: true
YAML
rm -rf web                      # stub created by 'ddev config'; create-project needs a clean docroot
ddev composer config --global http-basic.packeton.test admin "$PACKETON_TOKEN" >/dev/null 2>&1 || true
ddev restart >/dev/null 2>&1 || ddev start >/dev/null
ddev composer config --global http-basic.packeton.test admin "$PACKETON_TOKEN" >/dev/null

say "drupal/recommended-project:^11"
# A stuck `ddev` client was seen once on a fresh lab (blocked on the Docker socket, nothing running in the container):
# never wait for ever, and retry from a clean directory (keep .git and .ddev, remove what a failed attempt left).
create_project() { local try
  for try in 1 2 3; do
    timeout 900 ddev composer create-project drupal/recommended-project:^11 . --no-interaction && return 0
    echo "create-project attempt $try failed or timed out; cleaning up and retrying" >&2
    find . -mindepth 1 -maxdepth 1 ! -name .git ! -name .ddev -exec rm -rf {} + 
    ddev restart >/dev/null 2>&1 || true
  done
  return 1
}
create_project
ddev composer config repositories.packeton '{"type":"composer","url":"http://packeton.test"}'
ddev composer config secure-http false        # lab only: Packeton is plain HTTP here
ddev composer config preferred-install.'*' dist   # plan 2.5: archives, never clones

say "drush + activit/ait_banners:$constraint"
timeout 900 ddev composer require drush/drush --no-interaction
timeout 900 ddev composer require "activit/ait_banners:$constraint" --no-interaction
find web/modules/custom -name .git | grep . && { echo "nested .git found" >&2; exit 1; } || true

say "site install, block, config export"
mkdir -p config/sync
ddev drush si standard -y --site-name="$name" --account-name=admin --account-pass=admin
python3 -I - <<'PY'
p='web/sites/default/settings.php'
s=open(p).read()
m="include __DIR__ . '/settings.ddev.php';"
i=s.rfind('\n', 0, s.rfind('if (', 0, s.index(m)))
add="\n// Committed config sync directory\n$settings['config_sync_directory'] = '../config/sync';\n"
if "'../config/sync'" not in s: open(p,'w').write(s[:i]+add+s[i:])
PY
ddev drush en ait_banners -y
ddev drush php:eval "\$b=\Drupal\block\Entity\Block::create(['id'=>'olivero_sponsorship_banner','theme'=>'olivero','region'=>'content_above','plugin'=>'ait_banners_sponsorship','weight'=>-10,'status'=>TRUE,'settings'=>['id'=>'ait_banners_sponsorship','label'=>'Sponsorship banner','label_display'=>'0','provider'=>'ait_banners','sponsor'=>'$sponsor','tagline'=>'$tagline','url'=>'https://example.com','image_url'=>''],'visibility'=>[]]);\$b->save();"

# project-only extension modules and setup (plan rule 8: client-only behaviour lives in the project)
extras="$LAB_ROOT/seed/project-extras/$name"
if [ -d "$extras" ]; then
  say "project extras: extension modules"
  rsync -a --exclude post-install.sh "$extras/" ./
  for m in $(cd "$extras/web/modules/custom" 2>/dev/null && ls -d */ | tr -d /); do ddev drush en "$m" -y; done
  [ -x "$extras/post-install.sh" ] && "$extras/post-install.sh"
fi
ddev drush cex -y

say "commit (vendor/ and web/ included) + push"
git check-ignore -v vendor web/core web/modules/contrib web/modules/custom && { echo "important paths are ignored" >&2; exit 1; } || true
# workflow stubs from the project template (plan 2.5 / section 12)
cp -a "$LAB_ROOT/seed/project-template/." .
# runtime files only: everything else (vendor/, web/core, modules) is committed on purpose
# (config/sync/.htaccess is written by Drupal lazily, after our commit, and would leave the tree dirty)
printf '%s\n' "web/sites/default/files/" "config/sync/.htaccess" > .gitignore
git add -A
git commit -qm "Initial project: Drupal 11, Packeton repository, activit/ait_banners, vendor and web committed"
git push -u origin main 2>&1 | grep -v '^remote:' | tail -2
# only now: the first push had to be possible. Gitea records the new branch asynchronously, so wait for it.
for _ in $(seq 1 30); do [ "$(http_code GET "/repos/$SITE_ORG/$name/branches/main")" = 200 ] && break; sleep 1; done
ensure_main_protection "$SITE_ORG" "$name"
echo "$name ready: $(ddev describe -j | jq -r .raw.httpsurl)"
