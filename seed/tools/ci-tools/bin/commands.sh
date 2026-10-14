#!/bin/bash
# Commands in a project pull request (workflow commands.yml, event issue_comment): the main devs drive the in-place
# module flow from the developer's pull request instead of switching repositories.
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
case $line in /merge\ *|/release\ *) ;; *) log "not a command: nothing to do"; exit 0 ;; esac
read -r cmd arg1 arg2 _ <<<"$line"
log "$user: $cmd ${arg1:-} ${arg2:-}"

reply() { api POST "/repos/${REPOSITORY}/issues/${PR}/comments" "$(jq -n --arg b "$1" '{body:$b}')" >/dev/null || true; log "replied: ${1%%$'\n'*}"; }
usage() { reply "@${user}: \`${line}\` was not understood. Use \`/merge ${MODULE_ORG}/<module>#<number>\` or \`/release ${MODULE_ORG}/<module> v<x.y.z>\`."; exit 0; }

pr=$(api GET "/repos/${REPOSITORY}/pulls/${PR}") || { log "#${PR} is not a pull request: ignored"; exit 0; }
[ "$(jq -r .state <<<"$pr")" = open ] || { reply "@${user}: this pull request is not open: nothing done."; exit 0; }
head_ref=$(jq -r .head.ref <<<"$pr")

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
latest=$(git -C "$work/m" describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' "origin/${line}" 2>/dev/null || true)
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
