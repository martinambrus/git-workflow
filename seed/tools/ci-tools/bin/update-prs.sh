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

# supersede REPO UPDATE_PR MODULE_PATH -> project pull requests whose in-place module change was sent upstream (the
# Upstream job's marker comment) and is now contained in this release: close them when they change nothing but the
# module folder, otherwise say what to do. "Contained" = the pull request's own diff of the module folder reverse-
# applies cleanly to the release (the release may contain more, e.g. other developers' changes). Runs inside the
# project clone on the update branch (working tree = the release).
supersede() { local repo=$1 upd=$2 path=$3 n head others comments msg pdiff
  local marker="<!-- upstream:${package} -->" seen="<!-- superseded:${package}:${ver} -->"
  while read -r n head; do
    [ -n "$n" ] || continue
    comments=$(api GET "/repos/${repo}/issues/${n}/comments?limit=100") || continue
    jq -e --arg m "$marker" '.[]|select(.body|contains($m))' <<<"$comments" >/dev/null || continue
    jq -e --arg m "$seen" '.[]|select(.body|contains($m))' <<<"$comments" >/dev/null && continue
    pdiff=$(mktemp); api GET "/repos/${repo}/pulls/${n}.diff" > "$pdiff" || { warn "$repo#$n: cannot read its diff"; continue; }
    others=$(api GET "/repos/${repo}/pulls/${n}/files?limit=100" | jq -r --arg p "${path}/" '.[].filename|select(startswith($p)|not)')
    if ! git apply -R --check --include="${path}/*" "$pdiff" 2>/dev/null; then
      msg="${seen}
Release \`${tag}\` of \`${package}\` is out (update pull request #${upd}), but it does not contain all of this pull request's changes in \`${path}\` (pushed after the module merge request was merged, or not merged yet). This pull request stays open; the Upstream job keeps the module merge request up to date."
      api POST "/repos/${repo}/issues/${n}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null || warn "$repo#$n: comment failed"
      log "$repo#$n: its module change is not (fully) in ${tag}: left open, commented"
    elif [ -n "$others" ]; then
      msg="${seen}
Release \`${tag}\` of \`${package}\` contains this pull request's module change: merge the update pull request #${upd} first, then merge \`main\` into this branch. The module part then disappears from this pull request and the rest ($(echo $others | sed 's/ /, /g')) is reviewed and merged as usual."
      api POST "/repos/${repo}/issues/${n}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null || warn "$repo#$n: comment failed"
      log "$repo#$n: module change released, other files changed too: left open, commented"
    else
      msg="${seen}
Superseded by #${upd}: release \`${tag}\` of \`${package}\` contains this change. Merge #${upd} to bring it into \`main\`.

Closed automatically by the Release job, and the branch \`${head}\` was deleted (*Restore branch* on this page brings it back)."
      api POST "/repos/${repo}/issues/${n}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null \
        && api PATCH "/repos/${repo}/pulls/${n}" '{"state":"closed"}' >/dev/null \
        && log "$repo#$n: superseded by #${upd}: closed" || warn "$repo#$n: could not close"
      api DELETE "/repos/${repo}/branches/$(printf '%s' "$head" | jq -sRr @uri)" >/dev/null && log "$repo: deleted branch $head" || true
    fi
    rm -f "$pdiff"
  done < <(api GET "/repos/${repo}/pulls?state=open&limit=50" | jq -r --arg b "$branch" '.[]|select(.head.ref!=$b)|"\(.number) \(.head.ref)"')
}

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
  supersede "$repo" "$pr" "$path"
  echo "::endgroup::"
done
exit $rc
