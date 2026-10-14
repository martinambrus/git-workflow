#!/bin/bash
# Release reminder, runs in a module repository when a pull request is closed. For a MERGED merge request from the
# Upstream job (branch up/<project>/<branch>): the change is on the release line but not released, and a project is
# waiting for it. Comment on the merge request with the next version and how to tag it, and tell the project's pull
# request that its change was merged and waits for that release. For a merged forward-port (fwd/...): update the
# overview in the project pull request the change came from, and ask for /release if the merge was not tagged.
# Idempotent (a marker in each comment).
#
# Env: GITEA_URL BOT_TOKEN REPOSITORY (org/module) PR (number) MERGED (true|false) HEAD_REF BASE_REF
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"
: "${REPOSITORY:?}" "${PR:?}" "${HEAD_REF:?}" "${BASE_REF:?}"
[ "${MERGED:-false}" = true ] || { log "#$PR was closed without merging: nothing to do"; exit 0; }
case $HEAD_REF in
  up/*)  ;;
  fwd/*) # a merged forward-port: released already (/release tags the merge commit) or not; tell the origin PR
         work=$(mktemp -d)
         git clone -q --branch "$BASE_REF" "${GITEA_URL}/${REPOSITORY}.git" "$work/m" || die "cannot clone ${REPOSITORY}@${BASE_REF}"
         sha=$(api GET "/repos/${REPOSITORY}/pulls/${PR}" | jq -r '.merge_commit_sha // empty')
         [ -n "$sha" ] || die "#$PR has no merge commit"
         from=$(sed -E 's#^fwd/([^/]+)/.*#\1#' <<<"$HEAD_REF")
         origin=$(origin_of "$REPOSITORY" "$sha")
         tag=""; for _ in 1 2 3 4 5 6; do           # /release tags right after its merge: give it a moment
           git -C "$work/m" fetch -q --tags origin
           tag=$(git -C "$work/m" tag --points-at "$sha" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
           [ -n "$tag" ] && break; sleep 5; done
         if [ -n "$tag" ]; then
           overview "$origin" "${REPOSITORY}#${PR}" "$(fwd_line "$REPOSITORY" "$PR" "$from" "$BASE_REF" "merged, **released as \`${tag}\`**")"
           log "#$PR: merged and released as $tag"
         else
           nv=$(next_version "$work/m" "origin/${BASE_REF}")
           marker="<!-- release-reminder -->"
           if ! api GET "/repos/${REPOSITORY}/issues/${PR}/comments?limit=100" | jq -e --arg m "$marker" '.[]|select(.body|contains($m))' >/dev/null; then
             msg="${marker}
Merged into \`${BASE_REF}\`, **not released yet**. **Main devs:** reply here with
\`/release ${nv}\`
to tag \`${BASE_REF}\` and release it (projects on this line then get their update pull requests)."
             api POST "/repos/${REPOSITORY}/issues/${PR}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null || true
           fi
           overview "$origin" "${REPOSITORY}#${PR}" "$(fwd_line "$REPOSITORY" "$PR" "$from" "$BASE_REF" "merged, not released yet; main devs reply \`/release ${nv}\` there")"
           log "#$PR: merged, not released (asked for $nv)"
         fi
         exit 0 ;;
  *)     log "#$PR is not from the Upstream or Forward-port job ($HEAD_REF): nothing to do"; exit 0 ;;
esac

marker="<!-- release-reminder -->"
if api GET "/repos/${REPOSITORY}/issues/${PR}/comments?limit=100" | jq -e --arg m "$marker" '.[]|select(.body|contains($m))' >/dev/null; then
  log "#$PR already has the reminder"; exit 0; fi

work=$(mktemp -d)
git clone -q --branch "$BASE_REF" "${GITEA_URL}/${REPOSITORY}.git" "$work/m" || die "cannot clone ${REPOSITORY}@${BASE_REF}"
latest=$(latest_tag "$work/m" "origin/${BASE_REF}")
if [[ $latest =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  next="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
  since="latest release on this line: \`${latest}\`"
else
  next="v1.0.0"; since="no release on this line yet"
fi

# the project that sent it: marker in the merge request body (ci-tools >= v1.5.0), else the readable first line
body=$(api GET "/repos/${REPOSITORY}/pulls/${PR}" | jq -r '.body // ""')
read -r src_repo src_branch < <(sed -nE 's/.*<!-- upstream-source: ([^ ]+) ([^ ]+) -->.*/\1 \2/p' <<<"$body" | head -1) || true
if [ -z "${src_repo:-}" ]; then
  read -r src_repo src_branch < <(sed -nE 's/.*Sent by the Upstream job from `([^`]+)` branch `([^`]+)`.*/\1 \2/p' <<<"$body" | head -1) || true
fi
src_pr=""
if [ -n "${src_repo:-}" ]; then
  src_pr=$(api GET "/repos/${src_repo}/pulls?state=open&limit=50" | jq -r --arg h "$src_branch" '.[]|select(.head.ref==$h)|.number' | head -1 || true)
fi
waiting="A project is waiting for it."
[ -n "${src_repo:-}" ] && waiting="\`${src_repo}\` is waiting for it${src_pr:+ (${GITEA_URL}/${src_repo}/pulls/${src_pr})}."

msg=$(cat <<MSG
${marker}
Merged into \`${BASE_REF}\`, **not released yet** (${since}). ${waiting}

To ship it, a main dev tags **\`${next}\`** on \`${BASE_REF}\` (a minor version instead if the change adds a feature):
- command line: \`git fetch origin && git switch ${BASE_REF} && git pull && git tag -a ${next} -m "${next#v}" && git push origin ${next}\`
- web UI: *Code* → branch dropdown → **\`${BASE_REF}\`** → open it again → *Tags* → type \`${next}\` → *Create tag ${next}* (check the branch first: the tag is cut from the branch you are on)

Or reply \`/release ${REPOSITORY} ${next}\` in the project's pull request and the bot tags it. The Release job then adds the release to that pull request (one bot commit), which can then be merged; other projects get update pull requests.
MSG
)
api POST "/repos/${REPOSITORY}/issues/${PR}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null
log "#$PR: reminder posted (next ${next} on ${BASE_REF})"

if [ -n "$src_pr" ]; then
  pmarker="<!-- upstream-merged:${REPOSITORY}#${PR} -->"
  if ! api GET "/repos/${src_repo}/issues/${src_pr}/comments?limit=100" | jq -e --arg m "$pmarker" '.[]|select(.body|contains($m))' >/dev/null; then
    pmsg="${pmarker}
Module change merged: ${GITEA_URL}/${REPOSITORY}/pulls/${PR} (into \`${BASE_REF}\`), not released yet.

**Main devs:** reply here with
\`/release ${REPOSITORY} ${next}\`
(or tag \`${next}\` on \`${BASE_REF}\` yourself: see ${GITEA_URL}/${REPOSITORY}/pulls/${PR})"
    api POST "/repos/${src_repo}/issues/${src_pr}/comments" "$(jq -n --arg b "$pmsg" '{body:$b}')" >/dev/null \
      && log "${src_repo}#${src_pr}: told the project pull request" || warn "could not comment on ${src_repo}#${src_pr}"
  fi
fi
