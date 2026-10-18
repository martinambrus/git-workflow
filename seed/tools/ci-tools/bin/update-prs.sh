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

# The module's .gitea/ folder is CI, excluded from the package archive (export-ignore): a pull request's changes there
# never reverse-apply to the release, so they are left out of the "contained" check.
without_gitea() { awk '/^diff --git /{skip = ($0 ~ /\/\.gitea\//)} !skip' "$1"; }

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
    if ! without_gitea "$pdiff" | git apply -R --check --include="${path}/*" - 2>/dev/null; then
      msg="${seen}
Release \`${tag}\` of \`${package}\` is out (update pull request #${upd}), but it does not contain all of this pull request's changes in \`${path}\` (pushed after the module merge request was merged, or not merged yet). This pull request stays open; the Upstream job keeps the module merge request up to date."
      api POST "/repos/${repo}/issues/${n}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null || warn "$repo#$n: comment failed"
      log "$repo#$n: its module change is not (fully) in ${tag}: left open, commented"
    elif [ "$n" = "$INPLACE_SKIP" ]; then
      msg="${seen}
Release \`${tag}\` of \`${package}\` contains this pull request's module change, but the Release job could not add it to this branch (the branch moved meanwhile, or the update failed there; see the Release run), so it opened the update pull request #${upd}. Merge #${upd} first, then merge \`main\` into this branch: what remains is your work beyond the release. If nothing remains, close this pull request."
      api POST "/repos/${repo}/issues/${n}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null || warn "$repo#$n: comment failed"
      log "$repo#$n: release not added to its branch: left open, commented"
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

# major_of VERSION -> the major number of a version (v2.0.0 -> 2)
major_of() { local v=${1#v}; echo "${v%%.*}"; }

# inplace REPO MODULE_PATH -> the project pull request this release came from gets the release itself: when exactly one
# open pull request carries the Upstream job's marker for this package and its own module diff is contained in the
# release (working tree = the release, see supersede), run `composer update <package>` on THAT branch and push one
# commit (never forced). Its Checks then pass and the developer merges their own pull request. Returns 1 to fall back
# to a separate update pull request; INPLACE_SKIP then names a pull request that must not be closed.
INPLACE_SKIP=""
inplace() { local repo=$1 path=$2 n head comments pdiff b out a sha i m cands=() contained=()
  local marker="<!-- upstream:${package} -->" done_marker="<!-- updated-in-place:${package}:${ver} -->"
  INPLACE_SKIP=""
  while read -r n head; do
    [ -n "$n" ] || continue
    comments=$(api GET "/repos/${repo}/issues/${n}/comments?limit=100") || continue
    jq -e --arg m "$marker" '.[]|select(.body|contains($m))' <<<"$comments" >/dev/null || continue
    cands+=("$n $head")
    pdiff=$(mktemp)
    if api GET "/repos/${repo}/pulls/${n}.diff" > "$pdiff" && without_gitea "$pdiff" | git apply -R --check --include="${path}/*" - 2>/dev/null; then
      contained+=("$n $head"); fi
    rm -f "$pdiff"
  done < <(api GET "/repos/${repo}/pulls?state=open&limit=50" | jq -r --arg b "$branch" '.[]|select(.head.ref!=$b)|"\(.number) \(.head.ref)"')
  [ ${#cands[@]} -gt 0 ] || return 1
  if [ ${#cands[@]} -gt 1 ]; then log "$repo: ${#cands[@]} open pull requests change $package in place: separate update pull request"; return 1; fi
  if [ ${#contained[@]} -ne 1 ]; then log "$repo#${cands[0]%% *}: its module change is not (fully) in ${tag}: separate update pull request"; return 1; fi
  n=${contained[0]%% *}; head=${contained[0]#* }

  b=$(mktemp -d)
  git clone -q --depth 1 --branch "$head" "${GITEA_URL}/${repo}.git" "$b/p" || { warn "$repo: cannot clone $head"; INPLACE_SKIP=$n; return 1; }
  # a new major raises the project's constraint to ^N.0 (the code of that pull request was written against it);
  # any other release keeps the constraint and updates the lock only
  local how=(update "$package")
  [ "${new_major:-0}" = 1 ] && how=(require "${package}:^$(major_of "$ver").0")
  out=$(cd "$b/p" && composer "${how[@]}" --no-interaction --no-progress --no-scripts 2>&1) \
    || { echo "$out" | tail -10; warn "$repo#$n: composer update failed on $head"; INPLACE_SKIP=$n; return 1; }
  if grep -qE "could not be fully loaded|required authentication" <<<"$out"; then
    warn "$repo#$n: Packeton authentication error on $head: refusing to trust the result"; INPLACE_SKIP=$n; return 1; fi
  a=$(jq -r --arg p "$package" '.packages[]|select(.name==$p)|.version' "$b/p/composer.lock" | head -1)
  if [ "$(release_version "$a")" != "$ver" ]; then
    log "$repo#$n: its branch stays on $a (constraint): separate update pull request"; INPLACE_SKIP=$n; return 1; fi
  ( cd "$b/p" && git add -A && bot_git commit -q -m "Update ${package} to ${ver}" -m "composer update ${package} on the pull request it came from (Release job)" ) \
    || { warn "$repo#$n: nothing to commit on $head"; INPLACE_SKIP=$n; return 1; }
  sha=$(git -C "$b/p" rev-parse HEAD)
  if ! git -C "$b/p" push -q origin "HEAD:refs/heads/${head}" 2>/dev/null; then
    log "$repo#$n: $head moved meanwhile (push rejected, never forced): separate update pull request"; INPLACE_SKIP=$n; return 1; fi
  log "$repo#$n: release ${tag} added to its branch $head (${sha:0:8})"

  m="${done_marker}
<!-- superseded:${package}:${ver} -->
**Release \`${tag}\` of \`${package}\` is now in this pull request.** The Release job ran \`composer update ${package}\` on this branch and pushed one commit (\`${sha:0:8}\`). The module folder now equals the release, so the Checks pass: review and merge this pull request as usual.

- Run \`git pull\` before you push to this branch again (the bot added a commit).
- [ ] **9.3 Read the diff** of the bot's commit: \`composer.lock\`, \`vendor/composer/*\` and anything the release adds to \`${path}\` beyond your own change.
- [ ] **9.4 Test and deploy.** \`drush updb -y\`, \`drush cim -y\`, \`drush cr\` on staging, then merge and deploy."
  api POST "/repos/${repo}/issues/${n}/comments" "$(jq -n --arg b "$m" '{body:$b}')" >/dev/null || warn "$repo#$n: comment failed"

  # Gitea recomputes mergeability after the push: if main moved (typically composer.lock), say how to fix it
  for i in $(seq 1 12); do
    [ "$(api GET "/repos/${repo}/pulls/${n}" | jq -r '.head.sha')" = "$sha" ] && break; sleep 5; done
  sleep 5
  if [ "$(api GET "/repos/${repo}/pulls/${n}" | jq -r '.mergeable')" = false ]; then
    sleep 10
    if [ "$(api GET "/repos/${repo}/pulls/${n}" | jq -r '.mergeable')" = false ]; then
      m="This pull request now conflicts with \`main\`: \`main\` changed \`composer.lock\` or Composer's generated files in \`vendor/\` since this branch was cut. Fix it on your machine (with DDEV: \`ddev composer\`):
\`\`\`
git pull
git merge origin/main
git diff --name-only --diff-filter=U | xargs git checkout --theirs --   # main's version of each conflicted file
composer update ${package}                                              # regenerates composer.lock and vendor/composer
git add -A && git commit --no-edit && git push
\`\`\`
If a conflict is in your own files rather than Composer's, resolve that one by hand instead of taking main's version."
      api POST "/repos/${repo}/issues/${n}/comments" "$(jq -n --arg b "$m" '{body:$b}')" >/dev/null || true
      log "$repo#$n: conflicts with main after the update: told the developer"
    fi
  fi
  return 0
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

  if api GET "/repos/${repo}/pulls?state=open&limit=50" | jq -r '.[].number' | while read -r n; do
       api GET "/repos/${repo}/issues/${n}/comments?limit=100" | jq -e --arg m "<!-- updated-in-place:${package}:${ver} -->" '.[]|select(.body|contains($m))' >/dev/null && echo "$n"; done | grep -q .; then
    log "$repo: ${ver} was already added to the project pull request it came from"; echo "::endgroup::"; continue
  fi
  if api GET "/repos/${repo}/pulls?state=open&limit=50" | jq -e --arg h "$branch" '.[]|select(.head.ref==$h)' >/dev/null; then
    log "$repo already has an open pull request from $branch"; echo "::endgroup::"; continue
  fi
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    log "$repo already has branch $branch (closed/merged earlier?): skipping"; echo "::endgroup::"; continue
  fi

  if [ "$(major_of "$ver")" -gt "$(major_of "${before:-0}")" ]; then
    # a new major moves only the project pull request the change came from; other projects stay on their major
    new_major=1
    if inplace "$repo" "$(install_path "$package")"; then echo "::endgroup::"; continue; fi
    log "$repo stays on $before: a new major moves only the project pull request the change came from"
    echo "::endgroup::"; continue
  fi
  new_major=0
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
  if inplace "$repo" "$path"; then echo "::endgroup::"; continue; fi
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
