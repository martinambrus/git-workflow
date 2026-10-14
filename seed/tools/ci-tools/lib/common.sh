# shellcheck shell=bash
# Shared helpers for ci-tools scripts. Source this; do not execute.
# Required env: GITEA_URL (e.g. http://gitea.test:3000), BOT_TOKEN.

log()  { printf '[ci-tools] %s\n' "$*"; }
warn() { printf '[ci-tools] WARNING: %s\n' "$*" >&2; }
die()  { printf '[ci-tools] ERROR: %s\n' "$*" >&2; exit 1; }

: "${GITEA_URL:?GITEA_URL not set}" "${BOT_TOKEN:?BOT_TOKEN not set}"
GITEA_URL=${GITEA_URL%/}
MODULE_ORG=${MODULE_ORG:-activit}

# Authenticate every git command to this Gitea with the bot token, without putting it in URLs or logs.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.${GITEA_URL}/.extraheader"
export GIT_CONFIG_VALUE_0="Authorization: token ${BOT_TOKEN}"
export GIT_TERMINAL_PROMPT=0

# api METHOD PATH [json-body]  -> prints the response body, dies on HTTP >= 400
api() {
  local method=$1 path=$2 body=${3:-} out code
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" \
        -H "Authorization: token ${BOT_TOKEN}" -H 'Content-Type: application/json' \
        "${GITEA_URL}/api/v1${path}" ${body:+-d "$body"}) || { rm -f "$out"; die "curl failed: $method $path"; }
  if [ "$code" -ge 400 ]; then
    warn "API $method $path -> HTTP $code: $(head -c 300 "$out")"; rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

# Fixed bot identity for commits we create.
bot_git() { git -c user.name="Upstream Bot" -c user.email="bot@example.test" "$@"; }

# install_path PACKAGE  -> module folder relative to the project root (run inside a project checkout)
install_path() {
  local proj rel
  proj=$(git rev-parse --show-toplevel)
  rel=$(jq -r --arg n "$1" '.packages[]|select(.name==$n)|.["install-path"] // empty' vendor/composer/installed.json 2>/dev/null || true)
  if [ -n "$rel" ]; then realpath -m --relative-to="$proj" "vendor/composer/$rel"; else echo "web/modules/custom/${1##*/}"; fi
}

# release_version TAG -> 1.1.0 (strips the leading v)
release_version() { echo "${1#v}"; }

# latest_tag GIT_DIR REF -> the latest stable release tag reachable from REF; on a line <N>.x only vN.* tags count
latest_tag() {
  local line=${2#origin/} pat='v[0-9]*'
  [[ $line =~ ^([0-9]+)(\.[0-9]+)*\.x$ ]] && pat="v${BASH_REMATCH[1]}.*"
  git -C "$1" describe --tags --abbrev=0 --match "$pat" --exclude '*-*' "$2" 2>/dev/null || true
}

# released_in GIT_DIR SHA LINE -> the first stable release on LINE (vN.* for <N>.x, any on main) that contains SHA
released_in() {
  local pat='v*'
  [[ $3 =~ ^([0-9]+)(\.[0-9]+)*\.x$ ]] && pat="v${BASH_REMATCH[1]}.*"
  git -C "$1" tag --contains "$2" --list "$pat" 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | head -1 || true
}

# next_version GIT_DIR REF -> the next patch version after latest_tag (v1.0.0 if none)
next_version() {
  local latest; latest=$(latest_tag "$1" "$2")
  if [[ $latest =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
  else echo v1.0.0; fi
}

# is_main_dev USER ORG -> true when USER is in ORG's Owners team (the main devs: they review module changes and tag)
is_main_dev() {
  local tid; tid=$(api GET "/orgs/$2/teams?limit=50" | jq -r '.[]|select(.name=="Owners")|.id' | head -1) || return 1
  [ -n "$tid" ] || return 1
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token ${BOT_TOKEN}" "${GITEA_URL}/api/v1/teams/${tid}/members/$1")" = 200 ]
}

# origin_of REPO SHA -> "org/project#N": the project pull request a module commit came from. Follows the pull request
# that merged SHA: an Upstream merge request names its project branch (upstream-source marker, or its first line);
# a forward-port pull request names its source commit (forward-port marker), which is followed again (next hop).
# A merged pull request whose branch was deleted reports head.ref refs/pull/<n>/head; head.label keeps the branch.
# Prints nothing when the commit has no such origin (an ordinary module change).
origin_of() {
  local repo=$1 sha=$2 pr body head src_repo src_branch n i
  for i in 1 2 3 4 5 6; do
    pr=$(api GET "/repos/$repo/commits/$sha/pull" 2>/dev/null) || return 0
    body=$(jq -r '.body // ""' <<<"$pr")
    if [[ $body =~ \<\!--\ upstream-source:\ ([^ ]+)\ ([^ ]+)\ --\> ]] \
       || [[ $body =~ Sent\ by\ the\ Upstream\ job\ from\ \`([^\`]+)\`\ branch\ \`([^\`]+)\` ]]; then
      src_repo=${BASH_REMATCH[1]}; src_branch=${BASH_REMATCH[2]}
      n=$(api GET "/repos/$src_repo/pulls?state=all&limit=50" 2>/dev/null \
          | jq -r --arg h "$src_branch" '[.[]|select(.head.ref==$h or .head.label==$h)]|sort_by(.number)|last|.number // empty')
      [ -n "$n" ] && echo "$src_repo#$n"
      return 0
    elif [[ $body =~ \<\!--\ forward-port:[^:]+:([0-9a-f]{40})\ --\> ]]; then
      sha=${BASH_REMATCH[1]}
    else
      return 0
    fi
  done
}

# overview ORIGIN KEY TEXT -> one bot comment in the origin project pull request ("org/project#N") lists where its
# change went (forward-ports, conflicts, releases); the line for KEY is replaced, or added. On every update the comment
# is posted anew at the end of the conversation and the old one is deleted, so the latest state is always the last
# comment.
overview() {
  local origin=$1 key=$2 text=$3 repo n c id body line mark="<!-- fp:$2 -->"
  [ -n "$origin" ] || return 0
  repo=${origin%#*}; n=${origin##*#}
  line="- ${text} ${mark}"
  c=$(api GET "/repos/$repo/issues/$n/comments?limit=100") || return 0
  id=$(jq -r '[.[]|select(.body|contains("<!-- forward-ports -->"))][0].id // empty' <<<"$c")
  if [ -z "$id" ]; then
    body="<!-- forward-ports -->
**Where this change went** (forward-ports to newer module lines; the bot keeps this list up to date)
${line}"
    api POST "/repos/$repo/issues/$n/comments" "$(jq -n --arg b "$body" '{body:$b}')" >/dev/null || return 0
  else
    body=$(jq -r --argjson id "$id" '.[]|select(.id==$id)|.body' <<<"$c")
    if grep -qF -- "$mark" <<<"$body"; then
      body=$(MARK="$mark" LINE="$line" awk 'index($0, ENVIRON["MARK"]) { print ENVIRON["LINE"]; next } { print }' <<<"$body")
    else
      body="${body}"$'\n'"${line}"
    fi
    api POST "/repos/$repo/issues/$n/comments" "$(jq -n --arg b "$body" '{body:$b}')" >/dev/null || return 0
    api DELETE "/repos/$repo/issues/comments/$id" >/dev/null || warn "$origin: old overview comment $id not deleted"
  fi
  log "overview in $origin: $text"
}

# fwd_line REPO NUMBER FROM TO STATE -> the overview text for a forward-port pull request
fwd_line() { echo "[$1#$2](${GITEA_URL}/$1/pulls/$2) \`$3\` → \`$4\`: $5"; }
