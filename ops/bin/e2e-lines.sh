#!/bin/bash
# Release-line scenarios (plan sections 9, 10, 11), isolated from shop-a / shop-b: a uniquely named base module, a
# separate shared extension package that requires it, and four disposable minimal Composer projects.
#
#   ./lab e2e lines          run only this
#   E2E_KEEP=1 ./lab e2e lines   keep the created repos for inspection
#
# Proves, with a real 2.0.0, a real 1.x branch and real external-customer grants:
#  - a 2.0.0 release opens NO update PR in projects on ^1.0 (nor in opted-out or pinned ones)
#  - an extension package that requires ^1.0 blocks the base module's major upgrade until it supports 2.x
#  - a project on 1.x edits in place -> the Upstream MR targets the 1.x branch (not main) -> a 1.x patch release
#    reaches only the projects that opted in and are on 1.x
#  - an expired-support client (no topic) and an exactly pinned client get nothing
#  - an external customer limited to <2.0 whose updates expired is frozen on what was released before the date
set -uo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/e2e-lib.sh"
load_secrets

ts=$(date +%s)
BASE="ait_l$ts"; EXT="ait_l${ts}_ext"
PBASE="$MODULE_ORG/$BASE"; PEXT="$MODULE_ORG/$EXT"
P_OLD="l$ts-old"; P_EXP="l$ts-exp"; P_NEW="l$ts-new"; P_PIN="l$ts-pin"
WORK=$(mktemp -d)
export COMPOSER_AUTH="{\"http-basic\":{\"packeton.test\":{\"username\":\"admin\",\"password\":\"$PACKETON_TOKEN\"}}}"

admin_url() { echo "http://$ADMIN:$ADMIN_PW@$GITEA_HOST:3000/$1.git"; }
dev_url()   { echo "http://$DEV:$DEV_PW@$GITEA_HOST:3000/$1.git"; }

composer_in() { # dir composer-args...  (runner image, lab network, Packeton auth, private cache)
  local d=$1; shift
  docker run --rm --network wf-net --user "$(id -u):$(id -g)" -e HOME=/tmp -e COMPOSER_HOME=/tmp/ch -e COMPOSER_CACHE_DIR=/tmp/cc \
    -e COMPOSER_NO_INTERACTION=1 -e COMPOSER_AUTH -v "$d:/w" -w /w activit-runner:local composer "$@"; }

pk_versions_of() { curl -s -u "admin:$PACKETON_TOKEN" "$PACKETON/p2/$1.json" | jq -r --arg p "$1" '[.packages[$p][]?.version]|join(" ")'; }
pk_has() { [[ " $(pk_versions_of "$1") " == *" $2 "* ]]; }
lock_version() { # repo package -> version in composer.lock on main (retries: a fresh repo may serve files late)
  local i out v
  for i in $(seq 1 20); do
    out=$(api GET "/repos/$1/raw/composer.lock?ref=main" 2>&1)
    v=$(jq -r --arg p "$2" '.packages[]?|select(.name==$p)|.version' <<<"$out" 2>/dev/null)
    [ -n "$v" ] && { echo "$v"; return; }
    sleep 3
  done
  echo "   lock_version($1): no version after retries; last response: $(echo "$out" | head -c 160)" >&2; }
pr_exists() { api GET "/repos/$1/pulls?state=all&limit=50" | jq -e --arg h "$2" '.[]|select(.head.ref==$h)' >/dev/null; }
tag_sha() { git ls-remote "$(admin_url "$1")" "refs/tags/$2^{}" 2>/dev/null | cut -f1; }
release_result() { # repo tag -> conclusion of the Release run for that tag's commit, or "timeout"
  local sha n=0 c; sha=$(tag_sha "$1" "$2")
  while [ $n -lt 150 ]; do
    c=$(api GET "/repos/$1/actions/runs?limit=50" 2>/dev/null | jq -r --arg s "$sha" \
        '([.workflow_runs[]|select(.head_sha==$s)|select(.path|test("release"))][0]) as $r | if $r and $r.status=="completed" then $r.conclusion else empty end')
    [ -n "$c" ] && { echo "$c"; return; }; n=$((n+1)); sleep 5; done; echo timeout; }

find_pr() { # repo head-prefix base -> number of the newest open PR with that head prefix into that base
  api GET "/repos/$1/pulls?state=open&limit=50" | jq -r --arg p "$2" --arg b "$3" \
    '[.[]|select(.head.ref|startswith($p))|select(.base.ref==$b)]|sort_by(.number)|last|.number // empty'; }
wait_pr() { local n=0 r; while [ "$n" -lt "$4" ]; do r=$(find_pr "$1" "$2" "$3"); [ -n "$r" ] && { echo "$r"; return 0; }; n=$((n+5)); sleep 5; done; return 1; }
find_issue() { # repo title-fragment -> number of an open issue
  api GET "/repos/$1/issues?state=open&type=issues&limit=50" | jq -r --arg t "$2" '[.[]|select(.title|contains($t))]|first|.number // empty'; }
direct_push_rejected() { # repo branch -> success when a direct push by a DEVELOPER (not a main dev) is refused
  local d; d=$(mktemp -d -p "$WORK")
  git clone -q --depth 1 --branch "$2" "$(dev_url "$1")" "$d/c" 2>/dev/null || return 1
  ( cd "$d/c" && git config user.name x && git config user.email x@x.test && echo "# direct" >> DIRECT.md \
      && git add -A && git commit -qm direct && ! git push -q origin "$2" ) >/dev/null 2>&1; }
create_line_rejected() { # repo new-branch -> success when a DEVELOPER cannot create a release line
  local d; d=$(mktemp -d -p "$WORK")
  git clone -q --depth 1 "$(dev_url "$1")" "$d/c" 2>/dev/null || return 1
  ! ( cd "$d/c" && git push -q origin "HEAD:refs/heads/$2" ) >/dev/null 2>&1; }
merge_forward_pr() { # repo number -> wait for Checks on its head, then merge
  local h; h=$(api GET "/repos/$1/pulls/$2" | jq -r .head.ref)
  wait_for 600 "Checks on $1#$2" is_success "$1" "$h" && merge_pr "$1" "$2"; }

seed_module_repo() { # name srcdir
  ensure_repo "$MODULE_ORG" "$1" >/dev/null
  ensure_tag_protection "$MODULE_ORG" "$1"
  seed_repo "$MODULE_ORG" "$1" "$2" "$LAB_ROOT/seed/module-template" >/dev/null
  ensure_pkg_hook "$1"
  register_package "$1" >/dev/null
  ensure_main_protection "$MODULE_ORG" "$1" >/dev/null
  ensure_release_line_protection "$MODULE_ORG" "$1" >/dev/null
  api PATCH "/repos/$MODULE_ORG/$1" '{"default_delete_branch_after_merge":true}' >/dev/null
}

module_change() { # repo base-branch new-branch message editor-function  -> PR, wait for Checks, merge
  local repo=$1 base=$2 br=$3 msg=$4 editor=$5 d n
  d=$(mktemp -d -p "$WORK")
  git clone -q --depth 1 --branch "$base" "$(dev_url "$repo")" "$d/c" 2>/dev/null || return 1
  ( cd "$d/c" && git config user.name "Dev One" && git config user.email dev@example.test \
      && git switch -q -c "$br" && "$editor" && git add -A && git commit -qm "$msg" && git push -q origin "$br" ) >/dev/null 2>&1 || return 1
  n=$(api POST "/repos/$repo/pulls" "$(jq -n --arg h "$br" --arg b "$base" --arg t "$msg" '{title:$t,head:$h,base:$b}')" | jq -r .number)
  [ -n "$n" ] && [ "$n" != null ] || return 1
  wait_for 600 "Checks on $repo#$n" is_success "$repo" "$br" || return 1
  merge_pr "$repo" "$n"
}

tag_release() { # repo ref tag  (as the main dev)
  local d; d=$(mktemp -d -p "$WORK")
  git clone -q --depth 1 --branch "$2" "$(admin_url "$1")" "$d/c" 2>/dev/null \
    && git -C "$d/c" -c user.name="Main Dev" -c user.email=admin@example.test tag -a "$3" -m "e2e $3" \
    && git -C "$d/c" push -q origin "$3" 2>/dev/null; }

mk_project() { # name require-json topic(yes|no)  -> minimal Composer project with committed vendor/, workflows, protection
  local name=$1 req=$2 topic=$3 d; d=$(mktemp -d -p "$WORK")/p; mkdir -p "$d"
  jq -n --arg n "lab/$name" --argjson r "$req" '{name:$n,type:"project",repositories:[{type:"composer",url:"http://packeton.test"}],
      replace:{"drupal/core":"11.4.9"},require:$r,config:{"secure-http":false,"preferred-install":{"*":"dist"}},"minimum-stability":"stable"}' > "$d/composer.json"
  composer_in "$d" update --no-progress >/dev/null 2>&1 || { echo "   composer update failed for $name"; return 1; }
  mkdir -p "$d/.gitea/workflows" && cp "$LAB_ROOT"/seed/project-template/.gitea/workflows/*.yml "$d/.gitea/workflows/"
  ensure_repo "$SITE_ORG" "$name" >/dev/null
  ( cd "$d" && git init -q -b main && git config user.name "Dev One" && git config user.email dev@example.test \
      && git add -A && git commit -qm "Initial project" && git push -q "$(admin_url "$SITE_ORG/$name")" main ) >/dev/null 2>&1 || return 1
  [ "$topic" = yes ] && api PUT "/repos/$SITE_ORG/$name/topics/activit-project" >/dev/null
  api PATCH "/repos/$SITE_ORG/$name" '{"default_delete_branch_after_merge":true}' >/dev/null
  wait_for_branch "$SITE_ORG" "$name" main 180 >/dev/null 2>&1
  ensure_main_protection "$SITE_ORG" "$name" >/dev/null
}

project_change() { # project branch message  cmd...   -> clone, run cmd in the clone (composer via composer_in), PR, Checks, merge
  local name=$1 br=$2 msg=$3 d n log; shift 3
  d=$(mktemp -d -p "$WORK"); log=$d/steps.log
  git clone -q "$(dev_url "$SITE_ORG/$name")" "$d/c" 2>>"$log" || { echo "   [$name] clone failed: $(tail -2 "$log")"; return 1; }
  ( cd "$d/c" && git config user.name "Dev One" && git config user.email dev@example.test && git switch -q -c "$br" \
      && "$@" "$d/c" && git add -A && git commit -qm "$msg" && git push -q origin "$br" ) >>"$log" 2>&1 \
    || { echo "   [$name] change/commit/push failed: $(tail -4 "$log" | tr '\n' ' ')"; return 1; }
  n=$(api POST "/repos/$SITE_ORG/$name/pulls" "$(jq -n --arg h "$br" --arg t "$msg" '{title:$t,head:$h,base:"main"}')" 2>>"$log" | jq -r .number)
  [ -n "$n" ] && [ "$n" != null ] || { echo "   [$name] PR creation failed: $(tail -3 "$log" | tr '\n' ' ')"; return 1; }
  wait_for 1200 "Checks on $name#$n" is_success "$SITE_ORG/$name" "$br" || { echo "   [$name#$n] Checks state: $(pr_status "$SITE_ORG/$name" "$br")"; return 1; }
  merge_pr "$SITE_ORG/$name" "$n" || { echo "   [$name#$n] merge refused: $(api GET "/repos/$SITE_ORG/$name/pulls/$n" | jq -c '{mergeable,state,merged}')"; return 1; }
}

# --------------------------------------------------------------------------------------------------------------------
step "L0. clean up leftovers of earlier runs"
for r in $(api GET "/orgs/$SITE_ORG/repos?limit=200" | jq -r '.[].name|select(test("^l[0-9]+-(old|exp|new|pin)$"))'); do
  api DELETE "/repos/$SITE_ORG/$r" >/dev/null; done
for r in $(api GET "/orgs/$MODULE_ORG/repos?limit=200" | jq -r '.[].name|select(test("^ait_l[0-9]+(_ext)?$"))'); do
  api DELETE "/repos/$MODULE_ORG/$r" >/dev/null
  dc exec -T packeton app dbal:run-sql "delete from package where name='$MODULE_ORG/$r'" >/dev/null 2>&1; done
ok "stale line-scenario repos removed"

step "L1. base module $PBASE with releases 1.0.0 and 1.0.1"
src=$WORK/base-src; mkdir -p "$src"; cp -a "$LAB_ROOT/seed/modules/ait_banners/." "$src/"
jq --arg n "$PBASE" '.name=$n' "$src/composer.json" > "$src/c.json" && mv "$src/c.json" "$src/composer.json"
seed_module_repo "$BASE" "$src"
wait_for 180 "Packeton lists $PBASE v1.0.0" pk_has "$PBASE" v1.0.0 && ok "$PBASE v1.0.0 seeded, registered and indexed" || die "base module not in Packeton"
edit_release_101() { echo "/* $ts: 1.0.1 */" >> css/banner.css; }
module_change "$PBASE" main "rel/1.0.1" "Release 1.0.1 prep" edit_release_101 && tag_release "$PBASE" main v1.0.1 \
  && wait_for 180 "v1.0.1 indexed" pk_has "$PBASE" v1.0.1 && ok "v1.0.1 released through PR, Checks, merge, tag" || die "cannot release v1.0.1"

step "L1b. shared extension package $PEXT (requires $PBASE ^1.0)"
esrc=$WORK/ext-src; mkdir -p "$esrc"
jq -n --arg n "$PEXT" --arg b "$PBASE" '{name:$n,description:"Extends the banner block through hooks (separate shared package)",type:"drupal-custom-module",license:"GPL-2.0-or-later",require:{($b):"^1.0","drupal/core":"^10.3 || ^11"}}' > "$esrc/composer.json"
printf 'name: "AIT line ext"\ntype: module\ndescription: "Extension of the banner module"\npackage: Activit\ncore_version_requirement: ^10.3 || ^11\ndependencies:\n  - %s:%s\n' "$BASE" "$BASE" > "$esrc/$EXT.info.yml"
printf '<?php\n\n/**\n * @file\n * Extension module (hooks only).\n */\n' > "$esrc/$EXT.module"
printf '/tests export-ignore\n/.gitea export-ignore\n/.gitattributes export-ignore\n' > "$esrc/.gitattributes"
seed_module_repo "$EXT" "$esrc"
wait_for 180 "Packeton lists $PEXT v1.0.0" pk_has "$PEXT" v1.0.0 && ok "$PEXT registered and indexed" || die "extension package not in Packeton"

step "L2. four clients: old (opted in, base+ext), exp (support expired: no topic), new (opted in), pin (opted in, exact 1.0.1)"
mk_project "$P_OLD" "$(jq -n --arg b "$PBASE" --arg e "$PEXT" '{($b):"^1.0",($e):"^1.0"}')" yes && ok "$P_OLD created" || die "$P_OLD"
mk_project "$P_EXP" "$(jq -n --arg b "$PBASE" '{($b):"^1.0"}')" no  && ok "$P_EXP created (no activit-project topic)" || die "$P_EXP"
mk_project "$P_NEW" "$(jq -n --arg b "$PBASE" '{($b):"^1.0"}')" yes && ok "$P_NEW created" || die "$P_NEW"
mk_project "$P_PIN" "$(jq -n --arg b "$PBASE" '{($b):"1.0.1"}')" yes && ok "$P_PIN created (pinned to exactly 1.0.1)" || die "$P_PIN"
for p in "$P_OLD" "$P_EXP" "$P_NEW" "$P_PIN"; do
  [ "$(lock_version "$SITE_ORG/$p" "$PBASE")" = v1.0.1 ] && ok "$p locked to v1.0.1" || bad "$p lock: $(lock_version "$SITE_ORG/$p" "$PBASE")"
done

# --------------------------------------------------------------------------------------------------------------------
step "L3. 2.0.0 (breaking) released on main, 1.x line created from v1.0.1"
api POST "/repos/$PBASE/branches" '{"new_branch_name":"1.x","old_ref_name":"v1.0.1"}' >/dev/null
wait_for_branch "$MODULE_ORG" "$BASE" 1.x 60 >/dev/null 2>&1
[ "$(http_code GET "/repos/$PBASE/branches/1.x")" = 200 ] && ok "maintenance branch 1.x created from v1.0.1" || die "1.x missing"
direct_push_rejected "$PBASE" 1.x && ok "1.x is protected automatically: a developer's direct push is refused (no rule was created for it by hand)" \
  || bad "1.x accepted a developer's direct push: release lines are not protected"
create_line_rejected "$PBASE" "8.x" && ok "a developer cannot create a release line (only the main dev can); the main dev just did" \
  || bad "a developer could create the release line 8.x"
edit_major() { jq '.require["drupal/core"]="^11"' composer.json > c.tmp && mv c.tmp composer.json; echo "// $ts: 2.0.0" >> ait_banners.module; }
module_change "$PBASE" main "rel/2.0.0" "Breaking: require Drupal 11" edit_major && tag_release "$PBASE" main v2.0.0 \
  && wait_for 180 "v2.0.0 indexed" pk_has "$PBASE" v2.0.0 && ok "v2.0.0 released on main" || die "cannot release v2.0.0"
c=$(release_result "$PBASE" v2.0.0); [ "$c" = success ] && ok "Release job for v2.0.0 finished: $c" || bad "Release job for v2.0.0: $c"
for p in "$P_OLD" "$P_EXP" "$P_NEW" "$P_PIN"; do
  pr_exists "$SITE_ORG/$p" "update/$BASE-2.0.0" && bad "$p got an update PR for 2.0.0 although it is on ^1.0" || ok "$p: no update PR for 2.0.0"
done
# the 2.x line, so that the forward-port chain 1.x -> 2.x -> main exists
api POST "/repos/$PBASE/branches" '{"new_branch_name":"2.x","old_ref_name":"v2.0.0"}' >/dev/null
wait_for_branch "$MODULE_ORG" "$BASE" 2.x 60 >/dev/null 2>&1
direct_push_rejected "$PBASE" 2.x && ok "2.x is protected automatically as well" || bad "2.x accepted a developer's direct push"

step "L4. the extension (requires base ^1.0) blocks the major upgrade"
d=$WORK/blk; git clone -q "$(dev_url "$SITE_ORG/$P_OLD")" "$d" 2>/dev/null
out=$(composer_in "$d" require "$PBASE:^2.0" --no-progress --dry-run 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "$EXT" <<<"$out" && ok "composer refuses $PBASE ^2.0 in $P_OLD because $PEXT requires ^1.0" \
  || bad "upgrade was not blocked as expected (rc=$rc): $(echo "$out" | tail -4 | tr '\n' ' ')"

step "L5. $P_NEW migrates to 2.0 deliberately (composer require ^2.0 through a PR)"
migrate_new() { composer_in "$1" require "$PBASE:^2.0" --no-progress >/dev/null 2>&1; }
project_change "$P_NEW" "migrate/2.0" "Move to $BASE 2.0" migrate_new && ok "$P_NEW: migration PR passed Checks and merged" || bad "$P_NEW migration failed"
[ "$(lock_version "$SITE_ORG/$P_NEW" "$PBASE")" = v2.0.0 ] && ok "$P_NEW is on v2.0.0" || bad "$P_NEW lock: $(lock_version "$SITE_ORG/$P_NEW" "$PBASE")"
[ "$(lock_version "$SITE_ORG/$P_OLD" "$PBASE")" = v1.0.1 ] && ok "$P_OLD is still on v1.0.1 (old line)" || bad "$P_OLD moved unexpectedly"

step "L6. 1.x line: in-place fix in $P_OLD goes to the 1.x branch and ships as 1.0.2 to 1.x clients only"
d=$WORK/fix; git clone -q "$(dev_url "$SITE_ORG/$P_OLD")" "$d" 2>/dev/null
( cd "$d" && git config user.name "Dev One" && git config user.email dev@example.test && git switch -q -c "fix/1x-$ts" \
  && echo "/* $ts: 1.x fix */" >> "vendor/$PBASE/css/banner.css" && git commit -qam "Fix on the 1.x line" && git push -q origin "fix/1x-$ts" ) >/dev/null 2>&1
bot_branch="up/$P_OLD/fix-1x-$ts"
ppr=$(api POST "/repos/$SITE_ORG/$P_OLD/pulls" "$(jq -n --arg h "fix/1x-$ts" '{title:"Fix on the 1.x line",head:$h,base:"main"}')" | jq -r .number)
[ -n "$ppr" ] && [ "$ppr" != null ] && ok "project PR $P_OLD#$ppr opened (the developer's view)" || bad "could not open the project PR"
wait_for 600 "Upstream MR" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; [ -n \"\$(api GET '/repos/$PBASE/pulls?state=open&limit=50' | jq -r '.[]|select(.head.ref==\"$bot_branch\")|.number')\" ]" \
  && ok "Upstream opened a merge request in $PBASE" || die "no Upstream MR from the 1.x project"
mr=$(open_pr_number "$PBASE" "$bot_branch")
[ "$(api GET "/repos/$PBASE/pulls/$mr" | jq -r .base.ref)" = 1.x ] && ok "MR #$mr targets the 1.x branch (project is locked to a 1.x release)" \
  || bad "MR #$mr targets $(api GET "/repos/$PBASE/pulls/$mr" | jq -r .base.ref), expected 1.x"
wait_for 600 "module Checks on the MR" is_success "$PBASE" "$bot_branch" && ok "module Checks ran and passed on a PR into 1.x" || bad "Checks on the 1.x MR: $(pr_status "$PBASE" "$bot_branch")"
merge_pr "$PBASE" "$mr" && ok "MR merged into 1.x" || die "cannot merge the 1.x MR"
comments_of() { api GET "/repos/$1/issues/$2/comments?limit=100" | jq -r '[.[].body]|join("\n")'; }
wait_for 300 "release reminder on MR #$mr" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; api GET '/repos/$PBASE/issues/$mr/comments' | grep -q 'release-reminder'" \
  && comments_of "$PBASE" "$mr" | grep -q 'tags \*\*`v1.0.2`\*\* on `1.x`' && ok "release reminder on MR #$mr suggests v1.0.2 on 1.x" \
  || bad "no (correct) release reminder on MR #$mr: $(comments_of "$PBASE" "$mr" | head -3 | tr '\n' ' ')"
[ -n "$ppr" ] && { comments_of "$SITE_ORG/$P_OLD" "$ppr" | grep -q "upstream-merged:$PBASE#$mr" && ok "project PR #$ppr was told its change is merged and waits for the release" || bad "project PR #$ppr got no 'merged' notice"; }
fp=$(wait_pr "$PBASE" "fwd/1.x/" 2.x 300) && ok "Forward-port job opened PR #$fp: 1.x -> 2.x (the next higher line, not main)" || { bad "no forward-port PR from 1.x"; fp=; }
if [ -n "$fp" ] && [ -n "$ppr" ]; then
  comments_of "$PBASE" "$fp" | grep -q "fwd-prompt" && ok "forward-port PR #$fp asks the main devs for /release or /merge" || bad "no /release prompt on forward-port PR #$fp"
  wait_for 120 "overview in $P_OLD#$ppr" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; api GET '/repos/$SITE_ORG/$P_OLD/issues/$ppr/comments?limit=100' | grep -q 'fp:$PBASE#$fp'" \
    && ok "the project PR $P_OLD#$ppr lists forward-port #$fp in its overview" || bad "no overview line for #$fp in $P_OLD#$ppr"
fi
if [ -n "$fp" ]; then
  merge_forward_pr "$PBASE" "$fp" && ok "forward-port PR #$fp passed Checks and merged into 2.x" || bad "forward-port PR #$fp not merged"
  fp2=$(wait_pr "$PBASE" "fwd/2.x/" main 300) && ok "merging into 2.x triggered the next hop: PR #$fp2 2.x -> main" || { bad "no second hop 2.x -> main"; fp2=; }
  [ -n "$fp2" ] && { merge_forward_pr "$PBASE" "$fp2" && ok "second hop merged: the fix is on 1.x, 2.x and main" || bad "second hop PR #$fp2 not merged"; }
  [ -n "$fp2" ] && [ -n "$ppr" ] && { wait_for 120 "overview line for #$fp2" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; api GET '/repos/$SITE_ORG/$P_OLD/issues/$ppr/comments?limit=100' | grep -q 'fp:$PBASE#$fp2'" \
    && ok "the overview follows the second hop too (#$fp2, traced back through #$fp)" || bad "no overview line for the second hop #$fp2"; }
fi
tag_release "$PBASE" 1.x v1.0.2 && wait_for 180 "v1.0.2 indexed" pk_has "$PBASE" v1.0.2 && ok "v1.0.2 tagged on the 1.x branch and indexed" || die "cannot release v1.0.2"
c=$(release_result "$PBASE" v1.0.2); [ "$c" = success ] && ok "Release job for v1.0.2 finished: $c" || bad "Release job for v1.0.2: $c"
wait_for 300 "1.0.2 added to $P_OLD#$ppr" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; api GET '/repos/$SITE_ORG/$P_OLD/issues/$ppr/comments' | grep -q 'updated-in-place:$PBASE:1.0.2'" \
  && ok "$P_OLD: v1.0.2 was added to the developer's PR #$ppr (in place)" || bad "v1.0.2 was not added to $P_OLD#$ppr"
pr_exists "$SITE_ORG/$P_OLD" "update/$BASE-1.0.2" && bad "$P_OLD got a separate update PR as well" || ok "$P_OLD: no separate update PR"
for p in "$P_EXP" "$P_NEW" "$P_PIN"; do
  pr_exists "$SITE_ORG/$p" "update/$BASE-1.0.2" && bad "$p got an update PR for 1.0.2" || ok "$p: no update PR for 1.0.2 ($(case $p in *exp) echo support expired;; *new) echo on 2.0;; *pin) echo pinned;; esac))"
done
n=$ppr
if [ -n "$n" ]; then
  wait_for 1200 "Checks on $P_OLD#$n" is_success "$SITE_ORG/$P_OLD" "fix/1x-$ts" && ok "$P_OLD#$n: Checks green after the update" || bad "$P_OLD#$n: Checks not green"
  merge_pr "$SITE_ORG/$P_OLD" "$n" && ok "$P_OLD#$n merged" || bad "$P_OLD#$n merge refused"
  [ "$(lock_version "$SITE_ORG/$P_OLD" "$PBASE")" = v1.0.2 ] && ok "$P_OLD is on v1.0.2" || bad "$P_OLD lock: $(lock_version "$SITE_ORG/$P_OLD" "$PBASE")"
fi

step "L7. extension 2.0: released only after base 2.0 exists; then the client moves both packages together"
edit_ext2() { jq --arg b "$PBASE" '.require[$b]="^2.0"' composer.json > c.tmp && mv c.tmp composer.json; echo "/* $ts: ext 2.0 */" >> "$EXT.module"; }
module_change "$PEXT" main "rel/2.0.0" "Support $BASE 2.x" edit_ext2 && tag_release "$PEXT" main v2.0.0 \
  && wait_for 180 "ext v2.0.0 indexed" pk_has "$PEXT" v2.0.0 && ok "$PEXT v2.0.0 released (requires $PBASE ^2.0)" || die "cannot release ext 2.0.0"
c=$(release_result "$PEXT" v2.0.0); [ "$c" = success ] && ok "Release job for ext v2.0.0 finished: $c" || bad "Release job for ext v2.0.0: $c"
pr_exists "$SITE_ORG/$P_OLD" "update/$EXT-2.0.0" && bad "$P_OLD got an automatic update PR for ext 2.0.0 (it must wait for the base upgrade)" \
  || ok "$P_OLD: no automatic PR for ext 2.0.0 (its constraint is ^1.0)"
migrate_both() { composer_in "$1" require "$PBASE:^2.0" "$PEXT:^2.0" --no-progress >/dev/null 2>&1; }
project_change "$P_OLD" "migrate/2.0" "Move base and extension to 2.0" migrate_both && ok "$P_OLD: joint migration PR passed Checks and merged" || bad "$P_OLD joint migration failed"
b=$(lock_version "$SITE_ORG/$P_OLD" "$PBASE"); e=$(lock_version "$SITE_ORG/$P_OLD" "$PEXT")
[ "$b" = v2.0.0 ] && [ "$e" = v2.0.0 ] && ok "$P_OLD is on base $b and extension $e" || bad "$P_OLD: base=$b ext=$e"

step "L8. external customers (Packeton grants): support for the 1.x line expired, and a current customer"
dayold=$(date -u -d '60 days ago' '+%Y-%m-%d 09:00:00'); expiry=$(date -u -d '30 days ago' '+%Y-%m-%d')
A="username=admin&apiToken=$PACKETON_TOKEN"
mkcust() { # name version-constraint-or-null expiredUpdatesAt-or-empty -> prints token
  local name=$1 ver=$2 exp=$3 gid uid
  gid=$(curl -fsS -X POST "$PACKETON/api/groups?$A" -H 'Content-Type: application/json' \
        -d "$(jq -n --arg n "g-$name" --arg p "$PBASE" --argjson v "$ver" '{name:$n,aclPermissions:[{name:$p,version:$v}]}')" | jq -r .id)
  uid=$(curl -fsS -X POST "$PACKETON/api/users?$A" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$name\",\"email\":\"$name@lines.example\",\"plainPassword\":{\"first\":\"pw-$ts-aaa\",\"second\":\"pw-$ts-aaa\"},\"enabled\":true,\"groups\":[$gid]}" | jq -r .id)
  [ -z "$exp" ] || curl -fsS -X PUT "$PACKETON/api/user/$uid?$A" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$name\",\"email\":\"$name@lines.example\",\"expiredUpdatesAt\":\"$exp\",\"groups\":[$gid]}" >/dev/null
  dc exec -T packeton app packagist:user:manager "$name" --show-token 2>/dev/null | grep -oE '[A-Za-z0-9]{20}' | tail -1
}
# simulate time passing: 1.0.0 and 1.0.1 were released 60 days ago, the support grant ended 30 days ago
dc exec -T packeton app dbal:run-sql "update package_version set releasedat='$dayold' where version in ('v1.0.0','v1.0.1') and package_id=(select id from package where name='$PBASE')" >/dev/null 2>&1
t_legacy=$(mkcust "legacy$ts" '"<2.0"' "$expiry"); t_current=$(mkcust "current$ts" null "")
seen() { curl -s -u "$1:$2" "$PACKETON/p2/$PBASE.json" | jq -r --arg p "$PBASE" '[.packages[$p][]?.version]|sort|join(" ")'; }
got=$(seen "legacy$ts" "$t_legacy")
[ "$got" = "v1.0.0 v1.0.1" ] && ok "legacy customer (grant <2.0, updates expired): sees exactly '$got' (no 1.0.2, no 2.0.0)" || bad "legacy customer sees '$got'"
got=$(seen "current$ts" "$t_current")
[ "$got" = "v1.0.0 v1.0.1 v1.0.2 v2.0.0" ] && ok "current customer (no limits): sees '$got'" || bad "current customer sees '$got'"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$PACKETON/p2/$PBASE.json")" = 401 ] && ok "anonymous request: 401" || bad "anonymous access not refused"
cdir=$WORK/cust1; mkdir -p "$cdir"; echo '{"replace":{"drupal/core":"11.4.9"},"repositories":[{"type":"composer","url":"http://packeton.test"}],"config":{"secure-http":false}}' > "$cdir/composer.json"
COMPOSER_AUTH="{\"http-basic\":{\"packeton.test\":{\"username\":\"legacy$ts\",\"password\":\"$t_legacy\"}}}" composer_in "$cdir" require "$PBASE:^1.0" --no-progress >/dev/null 2>&1
v=$(jq -r --arg p "$PBASE" '.packages[]?|select(.name==$p)|.version' "$cdir/composer.lock" 2>/dev/null)
[ "$v" = v1.0.1 ] && ok "legacy customer's composer install resolves v1.0.1 (the newest they are allowed)" || bad "legacy customer installed '$v'"
out=$(COMPOSER_AUTH="{\"http-basic\":{\"packeton.test\":{\"username\":\"legacy$ts\",\"password\":\"$t_legacy\"}}}" composer_in "$cdir" require "$PBASE:^2.0" --no-progress 2>&1)
grep -q "does not match the constraint\|could not be found" <<<"$out" && ok "legacy customer cannot get 2.0" || bad "legacy customer could resolve 2.0"

step "L9. re-subscription: the expired 1.x client comes back and moves to the 2.x line"
# 9a. external customer: grant widened to everything, expiry cleared -> sees 1.0.2 and 2.0.0 now
gid=$(curl -s "$PACKETON/api/groups?$A" | jq -r --arg g "g-legacy$ts" '.[]|select(.name==$g).id')
uid=$(curl -s "$PACKETON/api/users?$A" | jq -r --arg u "legacy$ts" '.[]|select(.username==$u).id')
curl -fsS -o /dev/null -X PUT "$PACKETON/api/group/$gid?$A" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg n "g-legacy$ts" --arg p "$PBASE" '{name:$n,aclPermissions:[{name:$p,version:null}]}')"
curl -fsS -o /dev/null -X PUT "$PACKETON/api/user/$uid?$A" -H 'Content-Type: application/json' \
  -d "{\"username\":\"legacy$ts\",\"email\":\"legacy$ts@lines.example\",\"expiredUpdatesAt\":null,\"groups\":[$gid]}"
got=$(seen "legacy$ts" "$t_legacy")
[ "$got" = "v1.0.0 v1.0.1 v1.0.2 v2.0.0" ] && ok "re-subscribed customer now sees '$got'" || bad "re-subscribed customer sees '$got'"
LEG="{\"http-basic\":{\"packeton.test\":{\"username\":\"legacy$ts\",\"password\":\"$t_legacy\"}}}"
COMPOSER_AUTH="$LEG" composer_in "$cdir" update "$PBASE" --no-progress >/dev/null 2>&1
v=$(jq -r --arg p "$PBASE" '.packages[]?|select(.name==$p)|.version' "$cdir/composer.lock")
[ "$v" = v1.0.2 ] && ok "composer update stays on the 1.x line: v1.0.2 (the constraint is still ^1.0)" || bad "customer update went to '$v'"
COMPOSER_AUTH="$LEG" composer_in "$cdir" require "$PBASE:^2.0" --no-progress >/dev/null 2>&1
v=$(jq -r --arg p "$PBASE" '.packages[]?|select(.name==$p)|.version' "$cdir/composer.lock")
[ "$v" = v2.0.0 ] && ok "the customer moves to 2.0 only by a deliberate composer require ^2.0: v2.0.0" || bad "customer is on '$v' after require ^2.0"

# 9b. internal client: support renewed (opts in again), a 1.x patch release reaches it
api PUT "/repos/$SITE_ORG/$P_EXP/topics/activit-project" >/dev/null
edit_103() { echo "// $ts: 1.0.3" >> ait_banners.module; }   # same file/EOF as 2.0.0 prep: must conflict on the way to 2.x
module_change "$PBASE" 1.x "rel/1.0.3" "Release 1.0.3 prep (1.x line)" edit_103 && tag_release "$PBASE" 1.x v1.0.3 \
  && wait_for 180 "v1.0.3 indexed" pk_has "$PBASE" v1.0.3 && ok "v1.0.3 released on the 1.x branch" || die "cannot release v1.0.3"
c=$(release_result "$PBASE" v1.0.3); [ "$c" = success ] && ok "Release job for v1.0.3 finished: $c" || bad "Release job for v1.0.3: $c"
wait_for 300 "conflict issue" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; [ -n \"\$(api GET '/repos/$PBASE/issues?state=open&type=issues&limit=50' | jq -r '.[]|select(.title|contains(\"Forward-port needed (1.x -> 2.x)\"))|.number')\" ]" \
  && ok "a conflicting forward-port opened an issue instead of guessing (1.x -> 2.x)" || bad "no conflict issue for the 1.0.3 prep"
[ -z "$(find_pr "$PBASE" "fwd/1.x/" 2.x)" ] && ok "and no pull request was opened for the conflicting change" || bad "a forward-port PR exists for a conflicting change"
wait_for 300 "update PR in $P_EXP" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; [ -n \"\$(api GET '/repos/$SITE_ORG/$P_EXP/pulls?state=open&limit=50' | jq -r '.[]|select(.head.ref==\"update/$BASE-1.0.3\")|.number')\" ]" \
  && ok "$P_EXP (re-subscribed, still on 1.x) received update/$BASE-1.0.3" || bad "no 1.0.3 update PR in $P_EXP"
for p in "$P_OLD" "$P_NEW" "$P_PIN"; do
  pr_exists "$SITE_ORG/$p" "update/$BASE-1.0.3" && bad "$p got an update PR for 1.0.3" || ok "$p: no update PR for 1.0.3 (not on the 1.x line / pinned)"
done
n=$(open_pr_number "$SITE_ORG/$P_EXP" "update/$BASE-1.0.3")
if [ -n "$n" ]; then
  wait_for 1200 "Checks" is_success "$SITE_ORG/$P_EXP" "update/$BASE-1.0.3" && merge_pr "$SITE_ORG/$P_EXP" "$n" \
    && ok "$P_EXP#$n merged: now on $(lock_version "$SITE_ORG/$P_EXP" "$PBASE")" || bad "$P_EXP#$n did not pass or merge"
fi

# 9c. the client moves to 2.x deliberately; from then on its edits must go to the 2.x branch
migrate_exp() { composer_in "$1" require "$PBASE:^2.0" --no-progress >/dev/null 2>&1; }
project_change "$P_EXP" "migrate/2.0" "Move to $BASE 2.0 (renewed support)" migrate_exp && ok "$P_EXP: migration to 2.0 merged" || bad "$P_EXP migration failed"
[ "$(lock_version "$SITE_ORG/$P_EXP" "$PBASE")" = v2.0.0 ] && ok "$P_EXP is on v2.0.0" || bad "$P_EXP lock: $(lock_version "$SITE_ORG/$P_EXP" "$PBASE")"
[ "$(http_code GET "/repos/$PBASE/branches/2.x")" = 200 ] || die "2.x branch missing"
d=$WORK/fix2; git clone -q "$(dev_url "$SITE_ORG/$P_EXP")" "$d" 2>/dev/null
( cd "$d" && git config user.name "Dev One" && git config user.email dev@example.test && git switch -q -c "fix/2x-$ts" \
  && echo "# $ts: 2.x fix" >> "vendor/$PBASE/ait_banners.info.yml" && git commit -qam "Fix on the 2.x line" && git push -q origin "fix/2x-$ts" ) >/dev/null 2>&1
bot2="up/$P_EXP/fix-2x-$ts"
wait_for 600 "Upstream MR" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; [ -n \"\$(api GET '/repos/$PBASE/pulls?state=open&limit=50' | jq -r '.[]|select(.head.ref==\"$bot2\")|.number')\" ]" \
  && ok "Upstream opened a merge request from $P_EXP" || die "no Upstream MR from the 2.x client"
mr=$(open_pr_number "$PBASE" "$bot2")
[ "$(api GET "/repos/$PBASE/pulls/$mr" | jq -r .base.ref)" = 2.x ] && ok "MR #$mr targets the 2.x branch (client locked to 2.0.0), not 1.x and not main" \
  || bad "MR #$mr targets $(api GET "/repos/$PBASE/pulls/$mr" | jq -r .base.ref), expected 2.x"
wait_for 600 "module Checks" is_success "$PBASE" "$bot2" && merge_pr "$PBASE" "$mr" && ok "2.x MR passed Checks and merged" || die "2.x MR did not pass/merge"
fp3=$(wait_pr "$PBASE" "fwd/2.x/" main 300) && ok "the 2.x fix was forward-ported to main automatically (PR #$fp3)" || bad "no forward-port PR 2.x -> main for the client's fix"
tag_release "$PBASE" 2.x v2.0.1 && wait_for 180 "v2.0.1 indexed" pk_has "$PBASE" v2.0.1 && ok "v2.0.1 tagged on the 2.x branch" || die "cannot release v2.0.1"
c=$(release_result "$PBASE" v2.0.1); [ "$c" = success ] && ok "Release job for v2.0.1 finished: $c" || bad "Release job for v2.0.1: $c"
for p in "$P_OLD" "$P_NEW" "$P_EXP"; do
  wait_for 300 "update PR in $p" bash -c ". '$LAB_ROOT/ops/bin/lib.sh'; [ -n \"\$(api GET '/repos/$SITE_ORG/$p/pulls?state=open&limit=50' | jq -r '.[]|select(.head.ref==\"update/$BASE-2.0.1\")|.number')\" ]" \
    && ok "$p (on 2.x, opted in) received update/$BASE-2.0.1" || bad "no 2.0.1 update PR in $p"
done
pr_exists "$SITE_ORG/$P_PIN" "update/$BASE-2.0.1" && bad "$P_PIN (pinned) got a 2.0.1 PR" || ok "$P_PIN: still pinned, no update PR"

step "L10. cleanup"
if [ "${E2E_KEEP:-0}" = 1 ] || [ "$FAIL" -gt 0 ]; then echo "   leaving $BASE, $EXT, l$ts-* and the Packeton customers in place for inspection (E2E_KEEP=1 or failures; the next run removes them)"
else
  for p in "$P_OLD" "$P_EXP" "$P_NEW" "$P_PIN"; do api DELETE "/repos/$SITE_ORG/$p" >/dev/null; done
  for m in "$BASE" "$EXT"; do api DELETE "/repos/$MODULE_ORG/$m" >/dev/null
    dc exec -T packeton app dbal:run-sql "delete from package where name='$MODULE_ORG/$m'" >/dev/null 2>&1; done
  for u in "legacy$ts" "current$ts"; do
    uid=$(curl -s "$PACKETON/api/users?$A" | jq -r --arg u "$u" '.[]|select(.username==$u).id'); [ -n "$uid" ] && curl -s -o /dev/null -X DELETE "$PACKETON/api/user/$uid?$A"; done
  for g in "g-legacy$ts" "g-current$ts"; do
    gid=$(curl -s "$PACKETON/api/groups?$A" | jq -r --arg g "$g" '.[]|select(.name==$g).id'); [ -n "$gid" ] && curl -s -o /dev/null -X DELETE "$PACKETON/api/group/$gid?$A"; done
  ok "disposable repos, packages and customers removed"
fi
rm -rf "$WORK"

summary
[ "$FAIL" -eq 0 ]
