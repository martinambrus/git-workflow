#!/bin/bash
# Update PRs job (plan 9): for every project with the repository topic activit-project that uses <package>, run
# `composer update <package>` on a branch update/<module>-<version>, commit everything (vendor/ included) and open a
# pull request. A human still reviews steps 9.3 / 9.4. Projects whose constraint does not allow the new version
# (frozen, or another major) are skipped silently.
#
# usage: update-prs.sh <org/module> <tag>
# Env: GITEA_URL BOT_TOKEN PACKETON_TOKEN   [PACKETON_URL=http://packeton.test] [TOPIC=activit-project]
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"
package=${1:?org/module}; tag=${2:?tag}
: "${PACKETON_TOKEN:?PACKETON_TOKEN not set}"
PACKETON_URL=${PACKETON_URL:-http://packeton.test}
TOPIC=${TOPIC:-activit-project}
module=${package##*/}; ver=$(release_version "$tag"); branch="update/${module}-${ver}"
phost=$(echo "$PACKETON_URL" | sed -E 's#^https?://([^/:]+).*#\1#')

# Composer: Packeton credentials, a private cache (never trust a stale one) and no 401 fallback (finding 8).
export COMPOSER_AUTH="{\"http-basic\":{\"${phost}\":{\"username\":\"admin\",\"password\":\"${PACKETON_TOKEN}\"}}}"
export COMPOSER_CACHE_DIR; COMPOSER_CACHE_DIR=$(mktemp -d)
export COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1

mapfile -t repos < <(api GET "/repos/search?topic=true&q=${TOPIC}&limit=100" | jq -r '.data[].full_name')
log "projects with topic '$TOPIC': ${#repos[@]}"
rc=0
for repo in "${repos[@]}"; do
  echo "::group::$repo"
  work=$(mktemp -d)
  git clone -q --depth 1 "${GITEA_URL}/${repo}.git" "$work/p" || { warn "cannot clone $repo"; rc=1; echo "::endgroup::"; continue; }
  cd "$work/p"
  if ! jq -e --arg p "$package" '.require[$p] // empty' composer.json >/dev/null 2>&1; then
    log "$repo does not require $package: skipping"; echo "::endgroup::"; continue
  fi
  before=$(jq -r --arg p "$package" '.packages[]|select(.name==$p)|.version' composer.lock | head -1)
  if [ "$(release_version "$before")" = "$ver" ]; then log "$repo is already on $ver"; echo "::endgroup::"; continue; fi

  if api GET "/repos/${repo}/pulls?state=open&limit=50" | jq -e --arg h "$branch" '.[]|select(.head.ref==$h)' >/dev/null; then
    log "$repo already has an open pull request from $branch"; echo "::endgroup::"; continue
  fi
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    log "$repo already has branch $branch (closed/merged earlier?): skipping"; echo "::endgroup::"; continue
  fi

  log "$repo: $package $before -> composer update"
  out=$(composer update "$package" --no-interaction --no-progress --no-scripts 2>&1) || { echo "$out" | tail -15; warn "composer update failed in $repo"; rc=1; echo "::endgroup::"; continue; }
  if grep -qE "could not be fully loaded|required authentication" <<<"$out"; then
    echo "$out" | grep -E "could not be fully loaded|authentication" | head -3
    warn "Packeton answered with an authentication error in $repo: refusing to trust the result"; rc=1; echo "::endgroup::"; continue
  fi
  after=$(jq -r --arg p "$package" '.packages[]|select(.name==$p)|.version' composer.lock | head -1)
  if [ "$(release_version "$after")" != "$ver" ]; then
    log "$repo stays on $after (its constraint '$(jq -r --arg p "$package" '.require[$p]' composer.json)' does not allow $ver): no pull request"
    echo "::endgroup::"; continue
  fi

  path=$(install_path "$package")
  stat=$(git diff --stat HEAD -- "$path" | tail -20 || true)
  git switch -q -c "$branch"
  git add -A
  bot_git commit -q -m "Update ${package} to ${ver}" -m "composer update ${package}: ${before} -> ${after}"
  git push -q origin "$branch"

  body=$(cat <<BODY
Release \`${tag}\` of \`${package}\` is available (was \`${before}\`).

Opened by the Release job. Nothing has been tested yet; please work through plan section 9:

- [ ] **9.3 Read the diff.** In the project that developed the change the module folder should hardly change; in any
  other project the diff *is* the release. If it removes something of yours, it was never sent upstream: stop.
- [ ] **9.4 Test and deploy.** \`drush updb -y\`, \`drush cim -y\`, \`drush cr\` on staging, then merge and deploy.

Changes in \`${path}\`:

\`\`\`
${stat:-no changes in the module folder}
\`\`\`

Rollback: \`git revert\` the update commit (code and \`composer.lock\` go back together).
BODY
)
  pr=$(api POST "/repos/${repo}/pulls" "$(jq -n --arg t "Update ${package} to ${ver}" --arg b "$body" --arg h "$branch" '{title:$t,body:$b,head:$h,base:"main"}')" | jq -r .number)
  log "opened ${repo}#${pr}: ${GITEA_URL}/${repo}/pulls/${pr}"
  echo "::endgroup::"
done
exit $rc
