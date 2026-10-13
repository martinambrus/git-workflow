#!/bin/bash
# Upstream job (plan 6.5 / Appendix A): for every shared module installed in this project, compare the module
# folder with the release the project is locked to and, if it differs, push the difference to a bot branch in the
# module repository and open or update a merge request there. Re-running is safe: the branch is rebuilt from scratch.
#
# Env:  GITEA_URL BOT_TOKEN REPOSITORY (org/project) BRANCH SHA   [MODULE_ORG=activit]
# Runs in a plain checkout of the project (cloned here when not already inside one).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"

: "${REPOSITORY:?REPOSITORY not set (org/project)}" "${BRANCH:?BRANCH not set}"
project=${REPOSITORY##*/}
branch_slug=${BRANCH//\//-}
bot_branch="up/${project}/${branch_slug}"

# --- checkout (plain git, no actions) -------------------------------------------------------------------------
if ! git rev-parse --show-toplevel >/dev/null 2>&1 || [ "$(basename "$(git rev-parse --show-toplevel)")" = ci-tools ]; then
  work=$(mktemp -d)
  log "cloning $REPOSITORY"
  git clone -q "${GITEA_URL}/${REPOSITORY}.git" "$work/project"
  cd "$work/project"
  git checkout -q "${SHA:-origin/$BRANCH}"
fi
proj=$(git rev-parse --show-toplevel); cd "$proj"
git fetch -q origin main 2>/dev/null || true
base_ref=origin/main; git rev-parse -q --verify "$base_ref" >/dev/null || base_ref=HEAD~1

[ -f composer.lock ] || { log "no composer.lock: nothing to do"; exit 0; }

# --- modules: ours (activit/*), of the module type, with an installed path --------------------------------------
mapfile -t mods < <(jq -r --arg org "$MODULE_ORG/" '.packages[]
    | select(.name | startswith($org)) | select(.type == "drupal-custom-module")
    | "\(.name) \(.version)"' composer.lock)
[ "${#mods[@]}" -gt 0 ] || { log "no $MODULE_ORG/* modules in composer.lock: nothing to do"; exit 0; }

install_path() { # name -> path relative to project root
  local rel
  rel=$(jq -r --arg n "$1" '.packages[]|select(.name==$n)|.["install-path"] // empty' vendor/composer/installed.json 2>/dev/null || true)
  if [ -n "$rel" ]; then realpath -m --relative-to="$proj" "vendor/composer/$rel"; else echo "web/modules/custom/${1##*/}"; fi
}

rc=0
for entry in "${mods[@]}"; do
  name=${entry% *}; version=${entry#* }; short=${name##*/}
  path=$(install_path "$name")
  echo "::group::$name $version ($path)"
  if [[ $version == dev-* ]] || [[ $version == *-dev ]]; then
    warn "$name is locked to '$version', not a release: cannot compare, skipping"; echo "::endgroup::"; continue
  fi
  [ -d "$path" ] || { warn "$path does not exist, skipping"; echo "::endgroup::"; continue; }

  work=$(mktemp -d); mod="$work/mod"; base="$work/base"
  remote="${GITEA_URL}/${MODULE_ORG}/${short}.git"

  # Client-only patches (cweagans/composer-patches, plan section 11) must never travel upstream: compare the
  # project folder with those patches reversed. Patches are re-applied by Composer on every install anyway.
  cand="$path"
  mapfile -t patch_files < <(jq -r --arg n "$name" '
      (.extra.patches[$n] // empty)
      | (if type == "object" then to_entries | map(.value) else . end)
      | .[] | (if type == "object" then .url else . end)' composer.json 2>/dev/null)
  if [ "${#patch_files[@]}" -gt 0 ]; then
    cand="$work/unpatched"; cp -a "$path" "$cand"
    for (( i=${#patch_files[@]}-1; i>=0; i-- )); do   # reverse order
      pf=${patch_files[$i]}
      [[ $pf == http* ]] && { warn "$name: remote patch '$pf' cannot be reversed here, skipping module"; rc=1; continue 2; }
      [ -f "$pf" ] || { warn "$name: patch file '$pf' not found, skipping module"; rc=1; continue 2; }
      if ! patch -R -p1 -s --no-backup-if-mismatch -d "$cand" < "$proj/$pf" >/dev/null; then
        warn "$name: patch '$pf' could not be reversed (edited on top of it?), skipping module"; rc=1; echo "::endgroup::"; continue 2
      fi
    done
    log "$name: ${#patch_files[@]} client patch(es) reversed before comparing"
  fi
  git clone -q "$remote" "$mod" || die "cannot clone $remote"
  git -C "$mod" rev-parse -q --verify "refs/tags/$version" >/dev/null || die "tag $version not found in $remote"
  mkdir "$base" && git -C "$mod" archive "$version" | tar -x -C "$base"     # what the package of the locked tag contains

  if diff -rq "$base" "$cand" >/dev/null; then
    log "no drift in $path against $version: nothing to send"; echo "::endgroup::"; continue
  fi
  log "drift in $path against $version:"; diff -rq "$base" "$cand" | sed 's/^/    /' || true

  # patch: locked release -> project folder (binary-safe)
  git -C "$base" init -q && git -C "$base" add -A && bot_git -C "$base" commit -qm base
  find "$base" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
  cp -a "$cand/." "$base/" && git -C "$base" add -A
  git -C "$base" diff --cached --binary > "$work/changes.patch"

  # target line: <major>.x if that branch exists, else main
  major=${version#v}; major=${major%%.*}
  if git -C "$mod" ls-remote --exit-code --heads origin "${major}.x" >/dev/null 2>&1; then target="${major}.x"; else target=main; fi

  # one cumulative commit on a branch cut from the locked tag
  msg=$(git log --format='- %s (%an)' "$base_ref"..HEAD -- "$path" || true)
  git -C "$mod" switch -q -c "$bot_branch" "refs/tags/$version"   # cut from the LOCKED release, never from a moved main/1.x
  git -C "$mod" apply --index "$work/changes.patch"
  bot_git -C "$mod" commit -q -m "Changes from project ${project} (${BRANCH})" -m "$msg"

  # integrity: the module branch must reproduce the project folder exactly (checked BEFORE pushing)
  chk="$work/chk"; mkdir "$chk"; git -C "$mod" archive HEAD | tar -x -C "$chk"
  if ! diff -rq "$chk" "$cand" >/dev/null; then
    warn "integrity check failed for $name: module branch differs from project folder"; diff -rq "$chk" "$cand" | sed 's/^/    /' || true
    rc=1; echo "::endgroup::"; continue
  fi
  log "integrity OK: module branch == project folder (client patches reversed)"

  git -C "$mod" push -q --force origin "$bot_branch"
  log "pushed ${MODULE_ORG}/${short}:${bot_branch} (cut from $version, target $target)"

  # --- merge request in the module repo ---------------------------------------------------------------------
  title="Changes from ${project}: ${BRANCH}"
  body=$(printf 'Sent by the Upstream job from `%s` branch `%s` (locked to `%s`).\n\nProject commits touching `%s`:\n\n%s\n\nThe branch is rebuilt on every push of the project branch. Do not commit to it by hand.\n' \
         "$REPOSITORY" "$BRANCH" "$version" "$path" "$msg")
  existing=$(api GET "/repos/${MODULE_ORG}/${short}/pulls?state=open&limit=50" | jq -r --arg h "$bot_branch" '.[]|select(.head.ref==$h)|.number' | head -1)
  if [ -n "$existing" ]; then
    api PATCH "/repos/${MODULE_ORG}/${short}/pulls/${existing}" "$(jq -n --arg t "$title" --arg b "$body" '{title:$t,body:$b}')" >/dev/null
    mr=$existing; log "updated merge request ${MODULE_ORG}/${short}#${mr}"
  else
    mr=$(api POST "/repos/${MODULE_ORG}/${short}/pulls" "$(jq -n --arg t "$title" --arg b "$body" --arg h "$bot_branch" --arg base "$target" \
         '{title:$t,body:$b,head:$h,base:$base}')" | jq -r .number)
    log "opened merge request ${MODULE_ORG}/${short}#${mr}"
  fi
  mr_url="${GITEA_URL}/${MODULE_ORG}/${short}/pulls/${mr}"

  # --- comment on the project's own pull request (once per module) --------------------------------------------
  pr=$(api GET "/repos/${REPOSITORY}/pulls?state=open&limit=50" | jq -r --arg h "$BRANCH" '.[]|select(.head.ref==$h)|.number' | head -1 || true)
  if [ -n "${pr:-}" ]; then
    marker="<!-- upstream:${name} -->"
    if api GET "/repos/${REPOSITORY}/issues/${pr}/comments" | jq -e --arg m "$marker" '.[]|select(.body|contains($m))' >/dev/null; then
      log "project pull request #${pr} already links the merge request"
    else
      api POST "/repos/${REPOSITORY}/issues/${pr}/comments" "$(jq -n --arg b "${marker}"$'\n'"Module changes to \`${name}\` were sent upstream: ${mr_url}" '{body:$b}')" >/dev/null
      log "commented on project pull request #${pr}"
    fi
  fi
  echo "::endgroup::"
done
exit $rc
