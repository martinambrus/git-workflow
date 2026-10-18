#!/bin/bash
# Release job (plan 8.3 / 12), runs in a module repository when a tag v* is pushed:
#   1. check the tag and composer.json (check 5)
#   2. wait until Packeton lists the version
#   3. run Update PRs for projects that opted in (repository topic activit-project)
#
# Env: GITEA_URL BOT_TOKEN PACKETON_TOKEN REPOSITORY (org/module) TAG   [PACKETON_URL=http://packeton.test]
#      (update-prs.sh also gets RELEASE_TREE: the release checkout)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"
: "${REPOSITORY:?REPOSITORY not set}" "${TAG:?TAG not set}" "${PACKETON_TOKEN:?PACKETON_TOKEN not set}"
PACKETON_URL=${PACKETON_URL:-http://packeton.test}
module=${REPOSITORY##*/}; package="${REPOSITORY%%/*}/${module}"

# --- 1. checks ---------------------------------------------------------------------------------------------------
log "release check for $package $TAG"
if [[ ! $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
  die "tag '$TAG' does not look like vX.Y.Z (or vX.Y.Z-rc.N)"
fi
work=$(mktemp -d)
git clone -q --branch "$TAG" --depth 1 "${GITEA_URL}/${REPOSITORY}.git" "$work/mod"
cj="$work/mod/composer.json"
[ -f "$cj" ] || die "no composer.json at $TAG"
jq -e . "$cj" >/dev/null || die "composer.json is not valid JSON"
jq -e 'has("version")|not' "$cj" >/dev/null || die "composer.json has a 'version' key: the tag is the version (plan 4.2)"
[ "$(jq -r .name "$cj")" = "$package" ] || die "composer.json name '$(jq -r .name "$cj")' != '$package'"
( cd "$work/mod" && composer validate --no-check-publish --no-check-lock --quiet ) || die "composer validate failed"
log "tag and composer.json OK"

# Pre-releases are for testing in one project (plan 11): never start update PRs for them.
if [[ $TAG == *-* ]]; then log "pre-release: skipping update pull requests"; exit 0; fi

# --- 2. wait for Packeton ----------------------------------------------------------------------------------------
want=$(release_version "$TAG")
log "waiting for Packeton ($PACKETON_URL) to list $package $want"
for i in $(seq 1 60); do
  if curl -fsS -u "admin:${PACKETON_TOKEN}" "${PACKETON_URL}/p2/${package}.json" 2>/dev/null \
     | jq -e --arg p "$package" --arg v "$want" '.packages[$p][]|select((.version|ltrimstr("v"))==$v)' >/dev/null 2>&1; then
    log "Packeton lists $want"; found=1; break
  fi
  sleep 5
done
[ "${found:-0}" = 1 ] || die "Packeton did not list $want within 5 minutes (webhook? try the update button on the package page)"

# --- 3. update pull requests ---------------------------------------------------------------------------------------
RELEASE_TREE="$work/mod" exec "$here/bin/update-prs.sh" "$package" "$TAG"
