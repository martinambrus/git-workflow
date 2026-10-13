#!/bin/bash
# End-to-end test of the whole workflow, with assertions. Re-runnable: every run uses a unique branch and the next
# free patch version of ait_banners.
#
#   ./lab e2e            full flow (scaffolds the projects first if they do not exist)
#   ./lab e2e --quick    skip the smoke test and the external-customer test
#
# What it proves: sites render -> in-place edit in shop-a -> Upstream MR in the module repo -> module Checks -> merge
# -> tag as main dev -> Release job -> update PRs in both projects (by bot) -> project Checks -> merge -> both
# projects locked to the new version and carrying the edit -> database rebuilt from committed config.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
QUICK=0; [ "${1:-}" = --quick ] && QUICK=1

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

# --------------------------------------------------------------------------------------------------------------------
step "0. prerequisites"
for t in docker git curl jq ddev; do command -v $t >/dev/null && ok "$t found" || die "$t is required"; done
hosts_ok && ok "gitea.test / packeton.test resolve" || die "run ./lab hosts first"
curl -fsS "$GITEA/api/v1/version" >/dev/null 2>&1 && ok "Gitea is up" || die "stack is not running: ./lab up"
load_secrets
[ -n "${PACKETON_TOKEN:-}" ] && ok "lab secrets present" || die "no secrets: run ./lab up"

step "1a. module registered in Packeton"
"$LAB_ROOT/ops/bin/sync.sh" >/dev/null 2>&1          # idempotent: heals anything ./lab up missed
pk_versions() { curl -s -u "admin:$PACKETON_TOKEN" "$PACKETON/p2/$MODULE_ORG/ait_banners.json" | jq -r '[.packages["'$MODULE_ORG'/ait_banners"][]?.version]|join(" ")'; }
wait_for 180 "ait_banners indexed in Packeton" bash -c "[ -n \"\$(curl -s -u admin:$PACKETON_TOKEN $PACKETON/p2/$MODULE_ORG/ait_banners.json | jq -r '.packages[\"$MODULE_ORG/ait_banners\"][0].version // empty')\" ]" \
  && ok "activit/ait_banners is in Packeton: $(pk_versions)" || die "activit/ait_banners is not in Packeton (registration or indexing failed)"

step "1. projects exist (scaffold if missing)"
for p in shop-a shop-b; do
  dir=$LAB_ROOT/projects/$p
  if [ ! -d "$dir/.git" ]; then "$LAB_ROOT/ops/bin/sync.sh" "$p" >/dev/null 2>&1; fi
  if [ ! -f "$dir/composer.json" ]; then
    case $p in shop-a) args=("Acme Corp" "Proudly supporting Shop A");; *) args=("Globex Ltd" "Proudly supporting Shop B");; esac
    echo "   scaffolding $p (a few minutes)..."
    if "$LAB_ROOT/ops/bin/new-drupal-project.sh" "$p" "${args[@]}" '^1.0' >"$STATE/scaffold-$p.log" 2>&1; then ok "$p scaffolded"
    else bad "$p scaffold failed (see ops/.state/scaffold-$p.log)"; tail -15 "$STATE/scaffold-$p.log"; summary; exit 1; fi
  else ok "$p already scaffolded"; fi
done
"$LAB_ROOT/ops/bin/sync.sh" >/dev/null 2>&1   # topics, protection, hooks: idempotent
for p in shop-a shop-b; do (cd "$LAB_ROOT/projects/$p" && ddev start >/dev/null 2>&1 && ddev_composer_auth "$PWD"); done

step "2. the sites render, projects are set up as designed"
html=$(site_html shop-a); grep -q 'data-ait-banner="sponsorship"' <<<"$html" && ok "shop-a shows the sponsorship banner" || bad "shop-a: no banner"
html=$(site_html shop-b); grep -q 'data-ait-banner="sponsorship"' <<<"$html" && ok "shop-b shows the sponsorship banner" || bad "shop-b: no banner"
grep -q 'shop-b-tier--gold' <<<"$html" && ok "shop-b has the extension module's Gold tier" || bad "shop-b: tier label missing"
grep -q 'ait-banner__promo' <<<"$html" && ok "shop-b shows the promo badge (module 1.1+ feature)" || bad "shop-b: promo badge missing"
for r in sites/shop-a sites/shop-b activit/ait_banners; do
  [ "$(api GET "/repos/$r/branch_protections/main" | jq -r '.rule_name // empty')" = main ] && ok "main protected: $r" || bad "main NOT protected: $r"
done
for r in sites/shop-a sites/shop-b; do
  api GET "/repos/$r" | jq -e '.topics|index("activit-project")' >/dev/null && ok "opted in to update PRs: $r" || bad "topic activit-project missing: $r"
done

# --------------------------------------------------------------------------------------------------------------------
step "3. release cycle"
cur=$(git ls-remote --tags "http://$ADMIN:$ADMIN_PW@$GITEA_HOST:3000/$MODULE_ORG/ait_banners.git" 2>/dev/null \
      | grep -E 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's#.*refs/tags/v##' | sort -V | tail -1)
[ -n "$cur" ] || die "ait_banners has no release tag"
next="${cur%.*}.$(( ${cur##*.} + 1 ))"
ts=$(date +%s); branch="e2e/tweak-$ts"; bot_branch="up/shop-a/e2e-tweak-$ts"; marker="e2e-$ts"
echo "   latest release v$cur, will release v$next"

A=$LAB_ROOT/projects/shop-a; B=$LAB_ROOT/projects/shop-b
for d in "$A" "$B"; do
  git -C "$d" fetch -q origin && git -C "$d" switch -q main && git -C "$d" pull -q --ff-only origin main || die "cannot update $d"
  [ -z "$(git -C "$d" status --porcelain)" ] || die "$d has local changes: commit or stash them first"
done

echo "/* $marker: edited in place in shop-a */" >> "$A/web/modules/custom/ait_banners/css/banner.css"
git -C "$A" switch -q -c "$branch" && git -C "$A" commit -qam "Banner css: e2e marker $marker" && git -C "$A" push -q -u origin "$branch" 2>/dev/null \
  && ok "in-place edit pushed to shop-a ($branch)" || die "could not push the edit"
git -C "$A" switch -q main

wait_for 300 "Upstream MR" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; [ -n \"\$(api GET '/repos/$MODULE_ORG/ait_banners/pulls?state=open&limit=50' | jq -r '.[]|select(.head.ref==\"$bot_branch\")|.number')\" ]" \
  && ok "Upstream job opened a merge request in activit/ait_banners" || die "no Upstream MR"
mr=$(open_pr_number "$MODULE_ORG/ait_banners" "$bot_branch")
files=$(api GET "/repos/$MODULE_ORG/ait_banners/pulls/$mr/files" | jq -r '[.[].filename]|join(",")')
[ "$files" = "css/banner.css" ] && ok "MR #$mr contains exactly the edit (css/banner.css)" || bad "MR #$mr files: $files"
wait_for 900 "module Checks" is_success "$MODULE_ORG/ait_banners" "$bot_branch" && ok "module Checks green on MR #$mr" || bad "module Checks not green ($(pr_status "$MODULE_ORG/ait_banners" "$bot_branch"))"
merge_pr "$MODULE_ORG/ait_banners" "$mr" && ok "MR #$mr merged by the main dev" || die "merge refused"

tmp=$(mktemp -d)
git clone -q --depth 1 "http://$ADMIN:$ADMIN_PW@$GITEA_HOST:3000/$MODULE_ORG/ait_banners.git" "$tmp/m" \
  && git -C "$tmp/m" -c user.name="Main Dev" -c user.email=admin@example.test tag -a "v$next" -m "e2e release $next" \
  && git -C "$tmp/m" push -q origin "v$next" 2>/dev/null && ok "tagged v$next as the main dev" || die "could not tag"
rm -rf "$tmp"
git -C "$A" push -q origin --delete "$branch" 2>/dev/null; git -C "$A" branch -D "$branch" >/dev/null 2>&1

upd="update/ait_banners-$next"
for r in sites/shop-a sites/shop-b; do
  wait_for 600 "update PR in $r" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; [ -n \"\$(api GET '/repos/$r/pulls?state=open&limit=50' | jq -r '.[]|select(.head.ref==\"$upd\")|.number')\" ]" \
    && ok "Release job opened $upd in $r" || bad "no update PR in $r"
done
for r in sites/shop-a sites/shop-b; do
  n=$(open_pr_number "$r" "$upd"); [ -n "$n" ] || continue
  author=$(api GET "/repos/$r/pulls/$n" | jq -r .user.login)
  [ "$author" = bot ] && ok "$r#$n was authored by bot" || bad "$r#$n author is '$author'"
  wait_for 1200 "Checks on $r#$n" is_success "$r" "$upd" && ok "$r#$n: project Checks green" || bad "$r#$n: Checks not green ($(pr_status "$r" "$upd"))"
  merge_pr "$r" "$n" && ok "$r#$n merged" || bad "$r#$n merge refused"
done

step "4. result: both projects on v$next with the edit"
for p in shop-a shop-b; do
  d=$LAB_ROOT/projects/$p
  git -C "$d" fetch -q --prune origin && git -C "$d" switch -q main && git -C "$d" pull -q --ff-only origin main
  lock=$(jq -r '.packages[]|select(.name=="activit/ait_banners")|.version' "$d/composer.lock")
  [ "$lock" = "v$next" ] && ok "$p locked to v$next" || bad "$p locked to $lock"
  grep -q "$marker" "$d/web/modules/custom/ait_banners/css/banner.css" && ok "$p carries the edit" || bad "$p is missing the edit"
  (cd "$d" && ddev drush cr >/dev/null 2>&1)
done

step "5. database rebuilt from committed config"
(cd "$B" && ddev drush sql:drop -y >/dev/null 2>&1)
"$LAB_ROOT/ops/bin/site-up.sh" shop-b >/dev/null 2>&1
html=$(site_html shop-b)
grep -q 'shop-b-tier--gold' <<<"$html" && grep -q 'ait-banner__promo' <<<"$html" \
  && ok "shop-b rebuilt from config/sync: banner, promo badge and tier are back" || bad "shop-b rebuild lost configuration"

if [ $QUICK = 0 ]; then
  step "6. smoke test"
  if "$LAB_ROOT/ops/bin/smoke.sh" >"$STATE/e2e-smoke.log" 2>&1; then ok "./lab smoke passed"; else bad "./lab smoke failed (ops/.state/e2e-smoke.log)"; fi
  "$LAB_ROOT/ops/bin/smoke.sh" clean >/dev/null 2>&1
  step "7. external customer"
  "$LAB_ROOT/ops/bin/external.sh" up >/dev/null 2>&1
  out=$("$LAB_ROOT/ops/bin/external.sh" test 2>&1)
  grep -q "packeton-ext (https)  : 200" <<<"$out" && ok "customer reaches Packeton over HTTPS" || bad "customer cannot reach the proxy"
  grep -q "gitea (internal)      : 000" <<<"$out" && ok "Gitea is unreachable from the customer network" || bad "Gitea reachable from outside!"
  grep -q "Installing activit/ait_banners" <<<"$out" && ok "customer installs within their grant" || bad "customer install failed"
  grep -q "does not match the constraint" <<<"$out" && ok "customer cannot get versions beyond the grant" || bad "grant not enforced"
fi

summary
[ "$FAIL" -eq 0 ]
