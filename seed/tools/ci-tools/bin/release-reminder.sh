#!/bin/bash
# Release reminder, runs in a module repository when a pull request is closed. For a MERGED merge request from the
# Upstream job (branch up/<project>/<branch>): the change is on the release line but not released, and a project is
# waiting for it. Comment on the merge request with the next minor and the next major (the main devs choose) and how
# to tag, and tell the project's pull
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
           tag=$(released_in "$work/m" "$sha" "$BASE_REF")    # any release on the line that contains the merge
           [ -n "$tag" ] && break; sleep 5; done
         git -C "$work/m" fetch -q origin
         if [ -z "$tag" ] && ! package_changed "$work/m" "${sha}^1" "$sha"; then
           overview "$origin" "${REPOSITORY}#${PR}" "$(fwd_line "$REPOSITORY" "$PR" "$from" "$BASE_REF" "merged (CI-only, nothing to release)")"
           log "#$PR: merged; it changes nothing in the package: no release needed"
           exit 0
         fi
         if [ -n "$tag" ]; then
           overview "$origin" "${REPOSITORY}#${PR}" "$(fwd_line "$REPOSITORY" "$PR" "$from" "$BASE_REF" "merged, **released as \`${tag}\`**")"
           log "#$PR: merged and released as $tag"
         else
           # a forward-port is not released by itself (its change already shipped on the older line): no release prompt
           overview "$origin" "${REPOSITORY}#${PR}" "$(fwd_line "$REPOSITORY" "$PR" "$from" "$BASE_REF" "merged; not released by this pull request (tag \`${BASE_REF}\` when it needs a release)")"
           log "#$PR: merged, not released by the forward-port (no release prompt)"
         fi
         exit 0 ;;
  *)     log "#$PR is not from the Upstream or Forward-port job ($HEAD_REF): nothing to do"; exit 0 ;;
esac

marker="<!-- release-reminder -->"
if api GET "/repos/${REPOSITORY}/issues/${PR}/comments?limit=100" | jq -e --arg m "$marker" '.[]|select(.body|contains($m))' >/dev/null; then
  log "#$PR already has the reminder"; exit 0; fi

work=$(mktemp -d)
git clone -q --branch "$BASE_REF" "${GITEA_URL}/${REPOSITORY}.git" "$work/m" || die "cannot clone ${REPOSITORY}@${BASE_REF}"
msha=$(api GET "/repos/${REPOSITORY}/pulls/${PR}" | jq -r '.merge_commit_sha // empty')
if [ -n "$msha" ] && ! package_changed "$work/m" "${msha}^1" "$msha"; then
  log "#$PR changes nothing in the package (CI-only): no release reminder"; exit 0; fi
latest=$(latest_tag "$work/m" "origin/${BASE_REF}")
read -r minor major < <(release_versions "$work/m" "origin/${BASE_REF}")
lmajor=""
if [[ $latest =~ ^v([0-9]+)\. ]]; then lmajor=${BASH_REMATCH[1]}; fi
if [ -n "$latest" ]; then since="latest release on this line: \`${latest}\`"; else since="no release on this line yet"; fi

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
major_where="the project's pull request"
[ -n "${src_pr:-}" ] && major_where="${GITEA_URL}/${src_repo}/pulls/${src_pr}"
waiting="A project is waiting for it."
[ -n "${src_repo:-}" ] && waiting="\`${src_repo}\` is waiting for it${src_pr:+ (${GITEA_URL}/${src_repo}/pulls/${src_pr})}."

msg=$(cat <<MSG
${marker}
Merged into \`${BASE_REF}\`, **not released yet** (${since}). ${waiting}

**Main devs:** choose the release and reply with one of:
- a minor release on \`${BASE_REF}\`: reply here with \`/release ${minor}\`
- a new major: reply in ${major_where} with \`/release_major ${REPOSITORY} ${major}\` (the \`${lmajor:-?}.x\` line starts at \`${latest:-none}\`, and the change is merged into \`${BASE_REF}\` and tagged \`${major}\`)

Or tag one of them yourself on \`${BASE_REF}\` (check the branch first: the tag is cut from the branch you are on): \`git fetch origin && git switch ${BASE_REF} && git pull && git tag -a ${minor} -m "${minor#v}" && git push origin ${minor}\`.

The Release job then adds the release to the project's pull request (one bot commit), which can then be merged; other projects get update pull requests.
MSG
)
api POST "/repos/${REPOSITORY}/issues/${PR}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null
log "#$PR: reminder posted (minor ${minor}, major ${major} on ${BASE_REF})"

if [ -n "$src_pr" ]; then
  pmarker="<!-- upstream-merged:${REPOSITORY}#${PR} -->"
  if ! api GET "/repos/${src_repo}/issues/${src_pr}/comments?limit=100" | jq -e --arg m "$pmarker" '.[]|select(.body|contains($m))' >/dev/null; then
    pmsg="${pmarker}
Module change merged: ${GITEA_URL}/${REPOSITORY}/pulls/${PR} (into \`${BASE_REF}\`), not released yet.

**Main devs:** choose the release and reply here with one of:
- a minor release: \`/release ${REPOSITORY} ${minor}\`
- a new major: \`/release_major ${REPOSITORY} ${major}\`
(or tag one of them yourself: see ${GITEA_URL}/${REPOSITORY}/pulls/${PR})"
    api POST "/repos/${src_repo}/issues/${src_pr}/comments" "$(jq -n --arg b "$pmsg" '{body:$b}')" >/dev/null \
      && log "${src_repo}#${src_pr}: told the project pull request" || warn "could not comment on ${src_repo}#${src_pr}"
  fi
fi
