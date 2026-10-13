# shellcheck shell=bash
# Shared helpers for the e2e scripts (assertion counters, waiting, PR helpers). Source after lib.sh.
PASS=0; FAIL=0; START=$(date +%s)
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
need() { if "$@"; then return 0; else return 1; fi; }
die()  { bad "$*"; summary; exit 1; }
summary() {
  printf '\n%s\n' "------------------------------------------------------------"
  printf 'E2E: %d passed, %d failed, %ds\n' "$PASS" "$FAIL" "$(( $(date +%s) - START ))"
  [ "$FAIL" -eq 0 ] && echo "RESULT: PASSED" || echo "RESULT: FAILED"
}

# wait_for SECONDS DESCRIPTION cmd...   (cmd succeeds => done)
wait_for() { local t=$1 d=$2 n=0; shift 2
  until "$@" >/dev/null 2>&1; do n=$((n+5)); [ $n -ge "$t" ] && { echo "   timed out after ${t}s waiting for: $d"; return 1; }; sleep 5; done; }
pr_status() { # repo branch -> success|failure|pending|none  (the pull_request Checks context)
  api GET "/repos/$1/commits/$(printf '%s' "$2" | jq -sRr @uri)/statuses" 2>/dev/null \
    | jq -r '[.[]|select(.context|test("pull_request"))|.status]|first // "none"'; }
is_success() { [ "$(pr_status "$1" "$2")" = success ]; }
site_html() { curl -sk --max-time 20 "https://$1.ddev.site:8443/"; }
open_pr_number() { # repo head-branch
  api GET "/repos/$1/pulls?state=open&limit=50" | jq -r --arg h "$2" '.[]|select(.head.ref==$h)|.number' | head -1; }
merge_pr() { # repo number
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -u "$ADMIN:$ADMIN_PW" -H 'Content-Type: application/json' \
    "$GITEA/api/v1/repos/$1/pulls/$2/merge" -d '{"Do":"merge","delete_branch_after_merge":true}'); [ "$code" = 200 ]; }

