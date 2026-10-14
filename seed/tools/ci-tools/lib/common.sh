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

# next_version GIT_DIR REF -> the next patch version after the latest stable tag reachable from REF (v1.0.0 if none)
next_version() {
  local latest; latest=$(git -C "$1" describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' "$2" 2>/dev/null || true)
  if [[ $latest =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
  else echo v1.0.0; fi
}

# is_main_dev USER ORG -> true when USER is in ORG's Owners team (the main devs: they review module changes and tag)
is_main_dev() {
  local tid; tid=$(api GET "/orgs/$2/teams?limit=50" | jq -r '.[]|select(.name=="Owners")|.id' | head -1) || return 1
  [ -n "$tid" ] || return 1
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token ${BOT_TOKEN}" "${GITEA_URL}/api/v1/teams/${tid}/members/$1")" = 200 ]
}
