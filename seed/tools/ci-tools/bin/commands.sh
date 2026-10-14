#!/bin/bash
# Commands in pull requests (workflow commands.yml, event issue_comment). In a project pull request the main devs drive
# the in-place module flow from the developer's pull request instead of switching repositories; in a module
# repository they merge and release forward-port pull requests (/merge, /release vX.Y.Z).
#   /merge <org>/<module>#<n>          merge the module merge request the Upstream job opened for THIS pull request
#   /release <org>/<module> v<x.y.z>   tag that version on the module's release line; the Release job then adds the
#                                      release to this pull request
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
case $line in /merge|/merge\ *|/release\ *) ;; *) log "not a command: nothing to do"; exit 0 ;; esac
read -r cmd arg1 arg2 _ <<<"$line"
log "$user: $cmd ${arg1:-} ${arg2:-}"

reply() { api POST "/repos/${REPOSITORY}/issues/${PR}/comments" "$(jq -n --arg b "$1" '{body:$b}')" >/dev/null || true; log "replied: ${1%%$'\n'*}"; }
pr=$(api GET "/repos/${REPOSITORY}/pulls/${PR}") || { log "#${PR} is not a pull request: ignored"; exit 0; }
head_ref=$(jq -r .head.ref <<<"$pr")

# ---- in a module repository: forward-port pull requests (fwd/<from>/<sha>-to-<to>) -------------------------------
#   /merge          merge it (Checks green)
#   /release vX.Y.Z merge it (if still open) and tag the merge commit, or tag the line's head if it was merged already
if [ "${REPOSITORY%%/*}" = "$MODULE_ORG" ]; then
  usage() { reply "@${user}: \`${line}\` was not understood. On a forward-port pull request use \`/merge\` or \`/release v<x.y.z>\`."; exit 0; }
  # a forward-port PR carries <!-- forward-port:<from>:<sha> --> (its head branch is gone once it is merged)
  [[ $(jq -r '.body // ""' <<<"$pr") =~ \<\!--\ forward-port:([^:]+):[0-9a-f]{40}\ --\> ]] \
    || { reply "@${user}: commands work here only on forward-port pull requests (and in project pull requests for module changes): nothing done."; exit 0; }
  from=${BASH_REMATCH[1]}
  is_main_dev "$user" "$MODULE_ORG" || { reply "@${user}: only main devs (members of the \`${MODULE_ORG}\` Owners team) can run \`${cmd}\`: nothing done."; exit 0; }
  base=$(jq -r .base.ref <<<"$pr")
  state=$(jq -r .state <<<"$pr"); merged=$(jq -r .merged <<<"$pr")
  case $cmd in
    /merge)   [ -z "${arg1:-}" ] || usage ;;
    /release) [[ ${arg1:-} =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]] && [ -z "${arg2:-}" ] || usage; version=$arg1; major=${BASH_REMATCH[1]} ;;
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
    [ "$st" = success ] || { reply "@${user}: the Checks of this pull request are \`${st}\`, not green yet: try again when they pass."; exit 0; }
    api POST "/repos/${REPOSITORY}/pulls/${PR}/merge" '{"Do":"merge","delete_branch_after_merge":true}' >/dev/null \
      || { reply "@${user}: Gitea refused the merge (conflict, or a branch rule): nothing done."; exit 0; }
    sha=""; for _ in 1 2 3 4 5; do sha=$(api GET "/repos/${REPOSITORY}/pulls/${PR}" | jq -r '.merge_commit_sha // empty'); [ -n "$sha" ] && break; sleep 2; done
    [ "$cmd" = /merge ] && { reply "Merged into \`${base}\` (requested by @${user}). Nothing is released yet: reply \`/release v<x.y.z>\` here when it should be."; exit 0; }
  else
    sha=$(git -C "$work/m" rev-parse "origin/${base}")   # merged earlier: release the line as it is now
  fi

  git -C "$work/m" fetch -q origin
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
usage() { reply "@${user}: \`${line}\` was not understood. Use \`/merge ${MODULE_ORG}/<module>#<number>\` or \`/release ${MODULE_ORG}/<module> v<x.y.z>\`."; exit 0; }
[ "$(jq -r .state <<<"$pr")" = open ] || { reply "@${user}: this pull request is not open: nothing done."; exit 0; }

case $cmd in
  /merge)   [[ ${arg1:-} =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]] || usage
            org=${BASH_REMATCH[1]}; mrepo=${BASH_REMATCH[2]}; mr=${BASH_REMATCH[3]} ;;
  /release) [[ ${arg1:-} =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] || usage
            org=${BASH_REMATCH[1]}; mrepo=${BASH_REMATCH[2]}
            [[ ${arg2:-} =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]] || usage; version=$arg2; major=${BASH_REMATCH[1]} ;;
esac
module="${org}/${mrepo}"
[ "$org" = "$MODULE_ORG" ] || { reply "@${user}: only \`${MODULE_ORG}/*\` modules can be handled here: nothing done."; exit 0; }
is_main_dev "$user" "$org" || { reply "@${user}: only main devs (members of the \`${org}\` Owners team) can run \`${cmd}\`: nothing done."; exit 0; }

if [ "$cmd" = /merge ]; then
  m=$(api GET "/repos/${module}/pulls/${mr}") || { reply "@${user}: ${module}#${mr} does not exist: nothing done."; exit 0; }
  want="up/${project}/${head_ref//\//-}"
  [ "$(jq -r .head.ref <<<"$m")" = "$want" ] || { reply "@${user}: ${module}#${mr} was not opened for this pull request (expected branch \`${want}\`): nothing done."; exit 0; }
  [ "$(jq -r .merged <<<"$m")" = false ] || { reply "@${user}: ${module}#${mr} is already merged."; exit 0; }
  [ "$(jq -r .state <<<"$m")" = open ] || { reply "@${user}: ${module}#${mr} is closed: nothing done."; exit 0; }
  st=$(api GET "/repos/${module}/commits/$(jq -r .head.sha <<<"$m")/status" | jq -r '.state // "pending"')
  [ "$st" = success ] || { reply "@${user}: the Checks of ${module}#${mr} are \`${st}\`, not green yet: try again when they pass."; exit 0; }
  if api POST "/repos/${module}/pulls/${mr}/merge" '{"Do":"merge","delete_branch_after_merge":true}' >/dev/null; then
    reply "Merged ${GITEA_URL}/${module}/pulls/${mr} into \`$(jq -r .base.ref <<<"$m")\` (requested by @${user}). The release question follows in a moment."
  else
    reply "@${user}: Gitea refused to merge ${module}#${mr} (conflict, or a branch rule): open it and merge it there."
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
fi
if api POST "/repos/${module}/tags" "$(jq -n --arg t "$version" --arg l "$line" --arg m "${version#v} (released from ${REPOSITORY}#${PR} by ${user})" '{tag_name:$t,target:$l,message:$m}')" >/dev/null; then
  reply "Tagged \`${version}\` on \`${line}\` of ${module} (requested by @${user}). The Release job publishes it and adds it to this pull request; that takes a minute or two."
else
  reply "@${user}: Gitea refused the tag (the bot may not be on the protected-tag list of ${module}). Tag it yourself: \`git fetch origin && git switch ${line} && git pull && git tag -a ${version} -m \"${version#v}\" && git push origin ${version}\`"
fi
