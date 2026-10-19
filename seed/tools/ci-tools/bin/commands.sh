#!/bin/bash
# Commands in pull requests (workflow commands.yml, event issue_comment). In a project pull request the main devs drive
# the in-place module flow from the developer's pull request instead of switching repositories; in a module
# repository they merge and release forward-port pull requests (/merge, /release vX.Y.Z).
#   /merge <org>/<module>#<n>          merge the module merge request the Upstream job opened for THIS pull request
#   /release <org>/<module> v<x.y.z>   tag that version on the module's release line; the Release job then adds the
#                                      release to this pull request
#   /release_major <org>/<module> vN.0.0  a new major from this pull request's change: creates the old line <N-1>.x
#                                      from its last release, merges the module merge request into main (or uses it, if
#                                      merged already) and tags vN.0.0 there. A `Module-Major: N` trailer is optional;
#                                      if a commit names a major, it must be N
# Only main devs (members of the module org's Owners team) may run them. Every command gets an answer.
# The comment is read through the API by its id: its text never becomes part of a shell command.
#
# Env: GITEA_URL BOT_TOKEN REPOSITORY (org/project) PR (number) COMMENT_ID
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"
: "${REPOSITORY:?}" "${PR:?}" "${COMMENT_ID:?}"
project=${REPOSITORY##*/}

c=$(api GET "/repos/${REPOSITORY}/issues/comments/${COMMENT_ID}") || die "cannot read comment ${COMMENT_ID}"
user=$(jq -r '.user.login' <<<"$c")
line=$(jq -r '.body' <<<"$c" | head -1 | tr -d '\r')
case $line in /merge|/merge\ *|/release\ *|/release_major\ *) ;; *) log "not a command: nothing to do"; exit 0 ;; esac
read -r cmd arg1 arg2 _ <<<"$line"
log "$user: $cmd ${arg1:-} ${arg2:-}"

reply() { api POST "/repos/${REPOSITORY}/issues/${PR}/comments" "$(jq -n --arg b "$1" '{body:$b}')" >/dev/null || true; log "replied: ${1%%$'\n'*}"; }
pr=$(api GET "/repos/${REPOSITORY}/pulls/${PR}") || { log "#${PR} is not a pull request: ignored"; exit 0; }
head_ref=$(jq -r .head.ref <<<"$pr")

# ---- forward-port pull requests in a module repository (fwd/<from>/<sha>-to-<to>) -----------------------------------
#   /merge          merge it (Checks green)
#   /release vX.Y.Z merge it (if still open) and tag the merge commit, or tag the line's head if it was merged already
# Routed by the pull request itself, not by the repository's org: project repositories live in the same org as the
# modules (activit/drupal-b next to activit/weather), so the org cannot tell them apart. A forward-port PR carries
# <!-- forward-port:<from>:<sha> --> in its body; every other pull request is a project pull request (below).
if [[ $(jq -r '.body // ""' <<<"$pr") =~ \<\!--\ forward-port:([^:]+):[0-9a-f]{40}\ --\> ]]; then
  usage() { reply "@${user}: \`${line}\` was not understood. On a forward-port pull request use \`/merge\` or \`/release v<x.y.z>\`."; exit 0; }
  from=${BASH_REMATCH[1]}
  is_main_dev "$user" "$MODULE_ORG" || { reply "@${user}: only main devs (members of the \`${MODULE_ORG}\` Owners team) can run \`${cmd}\`: nothing done."; exit 0; }
  base=$(jq -r .base.ref <<<"$pr")
  state=$(jq -r .state <<<"$pr"); merged=$(jq -r .merged <<<"$pr")
  case $cmd in
    /merge)   [ -z "${arg1:-}" ] || usage ;;
    /release) reply "@${user}: a forward-port is not released by itself: its change already shipped on the older line. Merge it with \`/merge\`, and tag \`${base}\` yourself when that line needs a release (the Release job runs on the tag): nothing done."; exit 0 ;;
    *) usage ;;
  esac
  [ "$merged" = true ] || [ "$state" = open ] || { reply "@${user}: this pull request was closed without merging: nothing done."; exit 0; }
  [ "$cmd" = /merge ] && [ "$merged" = true ] && { reply "@${user}: already merged."; exit 0; }

  work=$(mktemp -d)
  git clone -q "${GITEA_URL}/${REPOSITORY}.git" "$work/m" || { reply "@${user}: cannot read ${REPOSITORY}: nothing done."; exit 0; }
  if [ "$cmd" = /release ]; then             # check the version BEFORE merging anything
    git -C "$work/m" rev-parse -q --verify "refs/tags/${version}" >/dev/null && { reply "@${user}: \`${version}\` already exists: nothing done."; exit 0; }
    latest=$(latest_tag "$work/m" "origin/${base}")
    if [ -n "$latest" ]; then
      [ "${latest#v${major}.}" != "$latest" ] || { reply "@${user}: \`${base}\` carries \`${latest}\`, so \`${version}\` is on the wrong line: nothing done."; exit 0; }
      [ "$(printf '%s\n%s\n' "${latest#v}" "${version#v}" | sort -V | tail -1)" = "${version#v}" ] && [ "${latest#v}" != "${version#v}" ] \
        || { reply "@${user}: \`${version}\` is not newer than \`${latest}\`, the latest release on \`${base}\`: nothing done."; exit 0; }
    fi
  fi

  if [ "$cmd" = /release ] && [ "$merged" = true ]; then   # releasing a merged PR: is there anything to release?
    msha=$(jq -r '.merge_commit_sha // empty' <<<"$pr")
    rel=$([ -n "$msha" ] && released_in "$work/m" "$msha" "$base")
    [ -z "$rel" ] || { reply "@${user}: this change is already released in \`${rel}\`: nothing done."; exit 0; }
    [ -z "${latest:-}" ] || [ "$(git -C "$work/m" rev-list -n1 "$latest")" != "$(git -C "$work/m" rev-parse "origin/${base}")" ] \
      || { reply "@${user}: \`${base}\` has nothing new since \`${latest}\`: nothing done."; exit 0; }
  fi
  if [ "$merged" != true ]; then
    st=$(api GET "/repos/${REPOSITORY}/commits/$(jq -r .head.sha <<<"$pr")/status" | jq -r '.state // "pending"')
    if [ "$st" = pending ] && [ "$cmd" = /merge ]; then   # /merge only: Gitea merges it once the Checks pass
      api POST "/repos/${REPOSITORY}/pulls/${PR}/merge" '{"Do":"merge","delete_branch_after_merge":true,"merge_when_checks_succeed":true}' >/dev/null \
        && reply "The Checks are still running: Gitea merges this into \`${base}\` as soon as they pass (requested by @${user})." \
        || reply "@${user}: the Checks are still running and Gitea refused to schedule the merge: try again when they pass."
      exit 0
    fi
    [ "$st" = success ] || { reply "@${user}: the Checks of this pull request are \`${st}\`, not green yet: $([ "$st" = pending ] && echo "reply \`/release\` again when they pass" || echo "fix them first"); nothing done."; exit 0; }
    api POST "/repos/${REPOSITORY}/pulls/${PR}/merge" '{"Do":"merge","delete_branch_after_merge":true}' >/dev/null \
      || { reply "@${user}: Gitea refused the merge (conflict, or a branch rule): nothing done."; exit 0; }
    sha=""; for _ in 1 2 3 4 5; do sha=$(api GET "/repos/${REPOSITORY}/pulls/${PR}" | jq -r '.merge_commit_sha // empty'); [ -n "$sha" ] && break; sleep 2; done
    [ "$cmd" = /merge ] && { reply "Merged into \`${base}\` (requested by @${user}). Nothing is released yet: reply \`/release v<x.y.z>\` here when it should be."; exit 0; }
  else
    sha=$(git -C "$work/m" rev-parse "origin/${base}")   # merged earlier: release the line as it is now
  fi

  git -C "$work/m" fetch -q origin
  if [ -n "${latest:-}" ] && ! package_changed "$work/m" "$latest" "$sha"; then
    reply "@${user}: $([ "$merged" != true ] && echo "merged into \`${base}\`, but ")nothing to release: since \`${latest}\` only files outside the package changed (CI workflows, tests)."
    exit 0
  fi
  if [ -n "${latest:-}" ]; then list=$(git -C "$work/m" log --first-parent --format='- %s (%h)' "${latest}..${sha}" | head -30)
  else list=$(git -C "$work/m" log --first-parent --format='- %s (%h)' -n 15 "$sha"); fi
  list=$(sed -E "s/^- Merge pull request '(.*)' \(#([0-9]+)\) from .* into [^ ]+ \(([0-9a-f]+)\)$/- \1 (#\2, \3)/" <<<"$list")
  if api POST "/repos/${REPOSITORY}/tags" "$(jq -n --arg t "$version" --arg c "$sha" --arg m "${version#v} (released from ${REPOSITORY}#${PR} by ${user})" '{tag_name:$t,target:$c,message:$m}')" >/dev/null; then
    reply "$([ "$merged" != true ] && echo "Merged into \`${base}\` and tagged" || echo "Tagged") \`${version}\` at \`${sha:0:8}\` (requested by @${user}). The Release job publishes it; projects on this line get update pull requests. It contains, since \`${latest:-the start}\`:
${list}"
    overview "$(origin_of "$REPOSITORY" "$sha")" "${REPOSITORY}#${PR}" "$(fwd_line "$REPOSITORY" "$PR" "$from" "$base" "merged, **released as \`${version}\`**")"
  else
    reply "@${user}: Gitea refused the tag (the bot may not be on the protected-tag list). Tag it yourself: \`git fetch origin && git tag -a ${version} -m \"${version#v}\" ${sha:0:12} && git push origin ${version}\`"
  fi
  exit 0
fi

# ---- in a project repository: the developer's pull request ---------------------------------------------------------
usage() { reply "@${user}: \`${line}\` was not understood. Use \`/merge ${MODULE_ORG}/<module>#<number>\`, \`/release ${MODULE_ORG}/<module> v<x.y.z>\` or \`/release_major ${MODULE_ORG}/<module> v<N>.0.0\`."; exit 0; }
[ "$(jq -r .state <<<"$pr")" = open ] || { reply "@${user}: this pull request is not open: nothing done."; exit 0; }

case $cmd in
  /merge)   [[ ${arg1:-} =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]] || usage
            org=${BASH_REMATCH[1]}; mrepo=${BASH_REMATCH[2]}; mr=${BASH_REMATCH[3]} ;;
  /release) [[ ${arg1:-} =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] || usage
            org=${BASH_REMATCH[1]}; mrepo=${BASH_REMATCH[2]}
            [[ ${arg2:-} =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]] || usage; version=$arg2; major=${BASH_REMATCH[1]} ;;
  /release_major) [[ ${arg1:-} =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] || usage
            org=${BASH_REMATCH[1]}; mrepo=${BASH_REMATCH[2]}
            [[ ${arg2:-} =~ ^v([0-9]+)\.0\.0$ ]] || usage; version=$arg2; major=${BASH_REMATCH[1]} ;;
esac
module="${org}/${mrepo}"
[ "$org" = "$MODULE_ORG" ] || { reply "@${user}: only \`${MODULE_ORG}/*\` modules can be handled here: nothing done."; exit 0; }
is_main_dev "$user" "$org" || { reply "@${user}: only main devs (members of the \`${org}\` Owners team) can run \`${cmd}\`: nothing done."; exit 0; }

if [ "$cmd" = /merge ]; then
  m=$(api GET "/repos/${module}/pulls/${mr}") || { reply "@${user}: ${module}#${mr} does not exist: nothing done."; exit 0; }
  # the merge request names its project branch in its body (the head branch is deleted after a merge)
  marker="<!-- upstream-source: ${REPOSITORY} ${head_ref} -->"
  jq -e --arg m "$marker" '.body|contains($m)' <<<"$m" >/dev/null || { reply "@${user}: ${module}#${mr} was not opened for this pull request: nothing done."; exit 0; }
  [ "$(jq -r .merged <<<"$m")" = false ] || { reply "@${user}: ${module}#${mr} is already merged."; exit 0; }
  [ "$(jq -r .state <<<"$m")" = open ] || { reply "@${user}: ${module}#${mr} is closed: nothing done."; exit 0; }
  st=$(api GET "/repos/${module}/commits/$(jq -r .head.sha <<<"$m")/status" | jq -r '.state // "pending"')
  case $st in
    success) ;;
    pending) # Checks still running: let Gitea merge it the moment they pass
      if api POST "/repos/${module}/pulls/${mr}/merge" '{"Do":"merge","delete_branch_after_merge":true,"merge_when_checks_succeed":true}' >/dev/null; then
        reply "The Checks of ${GITEA_URL}/${module}/pulls/${mr} are still running: Gitea merges it into \`$(jq -r .base.ref <<<"$m")\` as soon as they pass (requested by @${user}). The release question follows then."
      else reply "@${user}: the Checks of ${module}#${mr} are still running and Gitea refused to schedule the merge: try again when they pass."; fi
      exit 0 ;;
    *) reply "@${user}: the Checks of ${module}#${mr} are \`${st}\`: fix them first (push to this branch again), nothing done."; exit 0 ;;
  esac
  if api POST "/repos/${module}/pulls/${mr}/merge" '{"Do":"merge","delete_branch_after_merge":true}' >/dev/null; then
    reply "Merged ${GITEA_URL}/${module}/pulls/${mr} into \`$(jq -r .base.ref <<<"$m")\` (requested by @${user}). The release question follows in a moment."
  else
    reply "@${user}: Gitea refused to merge ${module}#${mr} (conflict, or a branch rule): open it and merge it there."
  fi
  exit 0
fi

# /release_major: the first release of a new major. Refused when the new major already has a line or a tag, when the
# project is not locked to the major before it, when a commit names another major (the Module-Major trailer is optional),
# or when main has unreleased changes (the old line would miss them). The merge request may be open (it is merged here)
# or merged already (after /merge). Order: the old line <N-1>.x first (a failure after that leaves nothing behind that
# matters), then the merge request into main, then vN.0.0 on the merge commit.
if [ "$cmd" = /release_major ]; then
  api GET "/repos/${REPOSITORY}/issues/${PR}/comments?limit=100" | jq -e --arg m "<!-- upstream:${module} -->" '.[]|select(.body|contains($m))' >/dev/null \
    || { reply "@${user}: this pull request has no change to \`${module}\` (no Upstream comment): nothing done."; exit 0; }
  locked=$(api GET "/repos/${REPOSITORY}/raw/composer.lock?ref=$(printf '%s' "$head_ref" | jq -sRr @uri)" | jq -r --arg p "$module" '.packages[]|select(.name==$p)|.version' | head -1)
  lmajor=${locked#v}; lmajor=${lmajor%%.*}
  [[ $lmajor =~ ^[0-9]+$ ]] && [ "$major" -eq $((lmajor + 1)) ] \
    || { reply "@${user}: this project is locked to \`${module}\` \`${locked:-?}\`; \`/release_major\` starts the next major after it, so use \`/release_major ${module} v$((lmajor + 1)).0.0\`: nothing done."; exit 0; }

  work=$(mktemp -d)
  git clone -q "${GITEA_URL}/${REPOSITORY}.git" "$work/p" || { reply "@${user}: cannot read ${REPOSITORY}: nothing done."; exit 0; }
  git -C "$work/p" log --format=%B "origin/main..origin/${head_ref}" > "$work/messages"
  # the Module-Major trailer is optional: the version decides. A commit that names another major is refused
  if grep -q '^Module-Major: ' "$work/messages" && ! grep -qx "Module-Major: ${major}" "$work/messages"; then
    reply "@${user}: a commit of this pull request says another \`Module-Major\`: nothing done."; exit 0
  fi

  git clone -q "${GITEA_URL}/${module}.git" "$work/m" || { reply "@${user}: cannot read ${module}: nothing done."; exit 0; }
  git -C "$work/m" rev-parse -q --verify "refs/tags/${version}" >/dev/null && { reply "@${user}: \`${version}\` already exists in ${module}: nothing done."; exit 0; }
  [ -z "$(git -C "$work/m" tag -l "v${major}.*")" ] || { reply "@${user}: ${module} already has a \`v${major}.*\` release, so the ${major}.x line exists: use \`/release\`: nothing done."; exit 0; }
  git -C "$work/m" rev-parse -q --verify "refs/remotes/origin/${major}.x" >/dev/null && { reply "@${user}: \`${major}.x\` already exists in ${module}: nothing done."; exit 0; }

  # the old line starts at main's last release of the locked major, and main may hold nothing unreleased on top of it
  latest=$(latest_tag "$work/m" "origin/main")
  [ -n "$latest" ] && [ "${latest#v${lmajor}.}" != "$latest" ] \
    || { reply "@${user}: main of ${module} has no \`v${lmajor}.*\` release to start the \`${lmajor}.x\` line from: nothing done."; exit 0; }
  # the newest merge request from this project branch: found by its body, since a merged one has lost its head branch
  mr=$(api GET "/repos/${module}/pulls?state=all&limit=50" | jq -r --arg m "<!-- upstream-source: ${REPOSITORY} ${head_ref} -->" '[.[]|select(.body|contains($m))]|sort_by(.number)|last|.number // empty')
  [ -n "$mr" ] || { reply "@${user}: no merge request from the Upstream job exists for this pull request: nothing done."; exit 0; }
  m=$(api GET "/repos/${module}/pulls/${mr}")
  merged=$(jq -r .merged <<<"$m")
  [ "$(jq -r .state <<<"$m")" = open ] || [ "$merged" = true ] || { reply "@${user}: ${module}#${mr} is closed: nothing done."; exit 0; }
  [ "$(jq -r .base.ref <<<"$m")" = main ] || { reply "@${user}: ${module}#${mr} targets \`$(jq -r .base.ref <<<"$m")\`, not \`main\`: nothing done."; exit 0; }
  if [ "$merged" = true ]; then
    # merged already (after /merge): its merge commit is the new major, so nothing unreleased may sit on either side of it
    mrsha=$(jq -r .merge_commit_sha <<<"$m")
    package_changed "$work/m" "$latest" "${mrsha}^1" \
      && { reply "@${user}: main of ${module} has unreleased changes before ${module}#${mr}: release them (\`/release v${lmajor}.<next>\`) first, nothing done."; exit 0; }
    package_changed "$work/m" "$mrsha" "origin/main" \
      && { reply "@${user}: main of ${module} has changes after ${module}#${mr}: release the new major by hand from \`${mrsha:0:8}\`, nothing done."; exit 0; }
  else
    package_changed "$work/m" "$latest" "origin/main" \
      && { reply "@${user}: main of ${module} has unreleased changes since \`${latest}\`: release them (\`/release v${lmajor}.<next>\`) first, nothing done."; exit 0; }
    st=$(api GET "/repos/${module}/commits/$(jq -r .head.sha <<<"$m")/status" | jq -r '.state // "pending"')
    [ "$st" = success ] || { reply "@${user}: the Checks of ${module}#${mr} are \`${st}\`, not green: $([ "$st" = pending ] && echo "reply \`/release_major\` again when they pass" || echo "fix them first"); nothing done."; exit 0; }
  fi

  # 1. the old line, from the commit of main's last release of the locked major (an existing line at that commit is fine)
  lsha=$(git -C "$work/m" rev-list -n1 "$latest")
  if oldsha=$(git -C "$work/m" ls-remote origin "refs/heads/${lmajor}.x" | cut -f1) && [ -n "$oldsha" ]; then
    [ "$oldsha" = "$lsha" ] || { reply "@${user}: \`${lmajor}.x\` of ${module} exists at another commit: nothing done."; exit 0; }
  else
    api POST "/repos/${module}/branches" "$(jq -n --arg n "${lmajor}.x" --arg o "$lsha" '{new_branch_name:$n,old_ref_name:$o}')" >/dev/null \
      || { reply "@${user}: Gitea refused to create \`${lmajor}.x\` in ${module}: nothing done."; exit 0; }
  fi
  # 2. the merge request into main (skipped when it is merged already)
  if [ "$merged" = true ]; then sha=$mrsha
  else
    api POST "/repos/${module}/pulls/${mr}/merge" '{"Do":"merge","delete_branch_after_merge":true}' >/dev/null \
      || { reply "@${user}: \`${lmajor}.x\` is created at \`${latest}\`, but Gitea refused to merge ${module}#${mr} (conflict, or a branch rule): merge it there, then reply \`/release_major\` again."; exit 0; }
    sha=""; for _ in 1 2 3 4 5; do sha=$(api GET "/repos/${module}/pulls/${mr}" | jq -r '.merge_commit_sha // empty'); [ -n "$sha" ] && break; sleep 2; done
  fi
  # 3. the new major on main
  if api POST "/repos/${module}/tags" "$(jq -n --arg t "$version" --arg c "$sha" --arg m "${version#v} (new major, released from ${REPOSITORY}#${PR} by ${user})" '{tag_name:$t,target:$c,message:$m}')" >/dev/null; then
    reply "New major \`${version}\` released from main of ${module} (requested by @${user}). The \`${lmajor}.x\` line starts at \`${latest}\`, where ${lmajor}.x fixes go; main carries \`${version}\`. The Release job publishes it. Projects stay on \`${lmajor}.x\` until a project moves to \`^${major}.0\`."
  else
    reply "@${user}: \`${lmajor}.x\` and the merge into main are done, but Gitea refused the tag \`${version}\` (the bot may not be on the protected-tag list of ${module}). Tag it yourself: \`git fetch origin && git tag -a ${version} -m \"${version#v}\" ${sha:0:12} && git push origin ${version}\`"
  fi
  exit 0
fi

# /release: only for a module this pull request changes, and only on the project's own line (its locked major)
api GET "/repos/${REPOSITORY}/issues/${PR}/comments?limit=100" | jq -e --arg m "<!-- upstream:${module} -->" '.[]|select(.body|contains($m))' >/dev/null \
  || { reply "@${user}: this pull request has no change to \`${module}\` (no Upstream comment): nothing done."; exit 0; }
locked=$(api GET "/repos/${REPOSITORY}/raw/composer.lock?ref=$(printf '%s' "$head_ref" | jq -sRr @uri)" | jq -r --arg p "$module" '.packages[]|select(.name==$p)|.version' | head -1)
lmajor=${locked#v}; lmajor=${lmajor%%.*}
[ "$lmajor" = "$major" ] || { reply "@${user}: this project is locked to \`${module}\` \`${locked:-?}\` (the ${lmajor:-?}.x line); \`/release\` here only releases that line: nothing done."; exit 0; }

# tag the version on the module's line for this major (<major>.x if it exists, else main)
work=$(mktemp -d)
git clone -q "${GITEA_URL}/${module}.git" "$work/m" || { reply "@${user}: cannot read ${module}: nothing done."; exit 0; }
if git -C "$work/m" rev-parse -q --verify "refs/remotes/origin/${major}.x" >/dev/null; then line="${major}.x"; else line=main; fi
git -C "$work/m" rev-parse -q --verify "refs/tags/${version}" >/dev/null && { reply "@${user}: \`${version}\` already exists in ${module}: nothing done."; exit 0; }
latest=$(latest_tag "$work/m" "origin/${line}")
if [ -n "$latest" ]; then
  [ "${latest#v}" != "${version#v}" ] && [ "$(printf '%s\n%s\n' "${latest#v}" "${version#v}" | sort -V | tail -1)" = "${version#v}" ] \
    || { reply "@${user}: \`${version}\` is not newer than \`${latest}\`, the latest release on \`${line}\`: nothing done."; exit 0; }
  [ "${latest#v}" != "${latest#v${major}.}" ] || { reply "@${user}: \`${line}\` carries \`${latest}\`, not the ${major}.x line: nothing done."; exit 0; }
  [ "$(git -C "$work/m" rev-list -n1 "$latest")" != "$(git -C "$work/m" rev-parse "origin/${line}")" ] \
    || { reply "@${user}: \`${line}\` has nothing new since \`${latest}\`: nothing done."; exit 0; }
  package_changed "$work/m" "$latest" "origin/${line}" \
    || { reply "@${user}: nothing to release on \`${line}\`: since \`${latest}\` only files outside the package changed (CI workflows, tests)."; exit 0; }
fi
if api POST "/repos/${module}/tags" "$(jq -n --arg t "$version" --arg l "$line" --arg m "${version#v} (released from ${REPOSITORY}#${PR} by ${user})" '{tag_name:$t,target:$l,message:$m}')" >/dev/null; then
  reply "Tagged \`${version}\` on \`${line}\` of ${module} (requested by @${user}). The Release job publishes it and adds it to this pull request; that takes a minute or two."
else
  reply "@${user}: Gitea refused the tag (the bot may not be on the protected-tag list of ${module}). Tag it yourself: \`git fetch origin && git switch ${line} && git pull && git tag -a ${version} -m \"${version#v}\" && git push origin ${version}\`"
fi
