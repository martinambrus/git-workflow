#!/bin/bash
# Forward-port job (plan section 11, "fix for an old release line"): after a change lands on a maintenance branch
# (<N>.x), carry it to the NEXT HIGHER line (<M>.x with M > N) or, if there is none, to the default branch, as a pull
# request. Each merge into the target triggers the job again, so a fix flows 1.x -> 2.x -> main without anyone
# remembering. A conflict is never guessed at: the job opens an issue naming the files and fails loudly.
#
# Env: GITEA_URL BOT_TOKEN REPOSITORY (org/module) BRANCH (the maintenance branch) BEFORE AFTER (push range)
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"
: "${REPOSITORY:?REPOSITORY not set}" "${BRANCH:?BRANCH not set}" "${AFTER:?AFTER not set}"
BEFORE=${BEFORE:-}

[[ $BRANCH =~ ^[0-9]+(\.[0-9]+)*\.x$ ]] || { log "$BRANCH is not a release line: nothing to do"; exit 0; }
if [ -z "$BEFORE" ] || [[ $BEFORE =~ ^0+$ ]]; then log "$BRANCH was just created: nothing to port"; exit 0; fi

default=$(api GET "/repos/$REPOSITORY" | jq -r .default_branch) || die "cannot read repository"
src_major=${BRANCH%%.*}
target=$default
while read -r b; do
  [ -n "$b" ] || continue
  if [ "${b%%.*}" -gt "$src_major" ]; then target=$b; break; fi
done < <(api GET "/repos/$REPOSITORY/branches?limit=100" | jq -r '.[].name' | grep -E '^[0-9]+(\.[0-9]+)*\.x$' | sort -V)
log "forward-porting $BRANCH ($BEFORE..$AFTER) to $target"

work=$(mktemp -d)
git clone -q "${GITEA_URL}/${REPOSITORY}.git" "$work/r" || die "cannot clone $REPOSITORY"
cd "$work/r"
git rev-parse -q --verify "${BEFORE}^{commit}" >/dev/null || die "$BEFORE is not reachable (force push?): port by hand"
mapfile -t commits < <(git rev-list --first-parent --reverse "$BEFORE..$AFTER")
[ "${#commits[@]}" -gt 0 ] || { log "no commits in the range"; exit 0; }

rc=0
for c in "${commits[@]}"; do
  short=${c:0:8}
  subject=$(git log -1 --format=%s "$c")
  marker="<!-- forward-port:${BRANCH}:${c} -->"
  fb="fwd/${BRANCH}/${short}-to-${target}"

  if api GET "/repos/$REPOSITORY/pulls?state=all&limit=100" | jq -e --arg m "$marker" '.[]|select((.body // "")|contains($m))' >/dev/null; then
    log "$short: already forward-ported"; continue; fi
  if api GET "/repos/$REPOSITORY/issues?state=all&type=issues&limit=100" | jq -e --arg m "$marker" '.[]|select((.body // "")|contains($m))' >/dev/null; then
    log "$short: an issue for it exists already"; continue; fi

  git switch -q -C "$fb" "origin/$target"
  nparents=$(git rev-list --parents -n1 "$c" | wc -w)          # 1 + number of parents
  flags=(); [ "$nparents" -gt 2 ] && flags=(-m 1)               # a merged MR: take its net change
  if out=$(bot_git cherry-pick -x "${flags[@]}" "$c" 2>&1); then
    :
  else
    files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    if [ -z "$files" ]; then                                    # nothing unmerged: the change is already on the target
      git cherry-pick --abort >/dev/null 2>&1 || true
      log "$short: already present on $target (empty cherry-pick)"; continue
    fi
    git cherry-pick --abort >/dev/null 2>&1 || true
    body=$(printf '%s\n\nThe change `%s` ("%s") was merged into `%s` but does not apply cleanly to `%s`.\n\nConflicting files: %s\n\nPort it by hand: `git switch -c %s origin/%s && git cherry-pick -x %s%s` and open a pull request into `%s`.\n' \
           "$marker" "$short" "$subject" "$BRANCH" "$target" "$files" "$fb" "$target" "$([ ${#flags[@]} -gt 0 ] && echo '-m 1 ')" "$c" "$target")
    num=$(api POST "/repos/$REPOSITORY/issues" "$(jq -n --arg t "Forward-port needed ($BRANCH -> $target): $subject" --arg b "$body" '{title:$t,body:$b}')" | jq -r .number)
    warn "$short does not apply to $target ($files): opened issue #$num"
    rc=1; continue
  fi

  git push -q origin "$fb" || { warn "cannot push $fb"; rc=1; continue; }
  body=$(printf '%s\n\nForward-port of `%s` ("%s") from `%s` to `%s`, opened by the Forward-port job.\n\nThe change is a cherry-pick (`-x` records the source commit). Review it like any other change; merging it into a release line triggers the next hop towards `%s`.\n' \
         "$marker" "$short" "$subject" "$BRANCH" "$target" "$default")
  num=$(api POST "/repos/$REPOSITORY/pulls" "$(jq -n --arg t "Forward-port ($BRANCH -> $target): $subject" --arg b "$body" --arg h "$fb" --arg base "$target" '{title:$t,body:$b,head:$h,base:$base}')" | jq -r .number)
  log "$short: opened ${REPOSITORY}#${num} into $target: ${GITEA_URL}/${REPOSITORY}/pulls/${num}"
done
exit $rc
