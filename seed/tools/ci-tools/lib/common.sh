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
