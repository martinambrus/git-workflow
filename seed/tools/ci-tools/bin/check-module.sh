#!/bin/bash
# Checks job for module repositories (plan section 12, check 5 + basic sanity), runs on pull requests, including
# the merge requests the Upstream job opens. Tag format is checked again by the Release job.
# Env: GITEA_URL BOT_TOKEN REPOSITORY BRANCH
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"
: "${REPOSITORY:?}" "${BRANCH:?}"
module=${REPOSITORY##*/}; package="${REPOSITORY%%/*}/${module}"
fails=0
fail() { printf '[ci-tools] FAIL: %s\n' "$*" >&2; fails=$((fails+1)); }
work=$(mktemp -d)
git clone -q --depth 1 --branch "$BRANCH" "${GITEA_URL}/${REPOSITORY}.git" "$work/m" || die "cannot clone $REPOSITORY@$BRANCH"
cd "$work/m"

log "composer.json"
if jq -e . composer.json >/dev/null 2>&1; then
  jq -e 'has("version")|not' composer.json >/dev/null || fail "composer.json has a 'version' key: the tag is the version"
  [ "$(jq -r .name composer.json)" = "$package" ] || fail "composer.json name '$(jq -r .name composer.json)' != '$package'"
  [ "$(jq -r .type composer.json)" = drupal-custom-module ] || fail "composer.json type must be drupal-custom-module"
  composer validate --no-check-publish --no-check-lock --quiet 2>&1 | sed 's/^/    /'
else fail "composer.json missing or not valid JSON"; fi

log "php syntax"
while IFS= read -r f; do php -l "$f" >/dev/null 2>&1 || { fail "PHP syntax error: $f"; php -l "$f" 2>&1 | head -2 | sed 's/^/    /'; }; done \
  < <(find . -path ./.git -prune -o \( -name '*.php' -o -name '*.module' -o -name '*.install' -o -name '*.inc' \) -type f -print)

log "yaml syntax"
while IFS= read -r f; do
  php -r 'set_error_handler(function($n,$s){fwrite(STDERR,$s."\n");exit(1);}); if (yaml_parse_file($argv[1]) === false) exit(1);' "$f" 2>/tmp/yerr \
    || { fail "YAML parse error: $f ($(head -1 /tmp/yerr))"; }
done < <(find . -path ./.git -prune -o -name '*.yml' -type f -print)

log "package archive hygiene"
[ -f .gitattributes ] && grep -q export-ignore .gitattributes || log "  note: no export-ignore rules in .gitattributes (tests would ship in the package)"

[ $fails -eq 0 ] && { log "RESULT: passed"; exit 0; } || { log "RESULT: $fails check(s) failed"; exit 1; }
