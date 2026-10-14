#!/bin/bash
# Release reminder, runs in a module repository when a pull request is closed. For a MERGED merge request from the
# Upstream job (branch up/<project>/<branch>): the change is on the release line but not released, and a project is
# waiting for it. Comment on the merge request with the next version and how to tag it, and tell the project's pull
# request that its change was merged and waits for that release. Idempotent (a marker in each comment).
#
# Env: GITEA_URL BOT_TOKEN REPOSITORY (org/module) PR (number) MERGED (true|false) HEAD_REF BASE_REF
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"
: "${REPOSITORY:?}" "${PR:?}" "${HEAD_REF:?}" "${BASE_REF:?}"
[ "${MERGED:-false}" = true ] || { log "#$PR was closed without merging: nothing to do"; exit 0; }
case $HEAD_REF in up/*) ;; *) log "#$PR is not from the Upstream job ($HEAD_REF): nothing to do"; exit 0 ;; esac

marker="<!-- release-reminder -->"
if api GET "/repos/${REPOSITORY}/issues/${PR}/comments?limit=100" | jq -e --arg m "$marker" '.[]|select(.body|contains($m))' >/dev/null; then
  log "#$PR already has the reminder"; exit 0; fi

work=$(mktemp -d)
git clone -q --branch "$BASE_REF" "${GITEA_URL}/${REPOSITORY}.git" "$work/m" || die "cannot clone ${REPOSITORY}@${BASE_REF}"
latest=$(git -C "$work/m" describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' HEAD 2>/dev/null || true)
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

The Release job then opens the update pull requests and closes the project's pull request.
MSG
)
api POST "/repos/${REPOSITORY}/issues/${PR}/comments" "$(jq -n --arg b "$msg" '{body:$b}')" >/dev/null
log "#$PR: reminder posted (next ${next} on ${BASE_REF})"

if [ -n "$src_pr" ]; then
  pmarker="<!-- upstream-merged:${REPOSITORY}#${PR} -->"
  if ! api GET "/repos/${src_repo}/issues/${src_pr}/comments?limit=100" | jq -e --arg m "$pmarker" '.[]|select(.body|contains($m))' >/dev/null; then
    pmsg="${pmarker}
Your module change was merged: ${GITEA_URL}/${REPOSITORY}/pulls/${PR} (into \`${BASE_REF}\`). It now waits for a main dev to tag the release (\`${next}\` suggested); the Release job then opens the update pull request here and closes this one."
    api POST "/repos/${src_repo}/issues/${src_pr}/comments" "$(jq -n --arg b "$pmsg" '{body:$b}')" >/dev/null \
      && log "${src_repo}#${src_pr}: told the project pull request" || warn "could not comment on ${src_repo}#${src_pr}"
  fi
fi
