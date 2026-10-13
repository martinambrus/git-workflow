# shellcheck shell=bash
# Shared helpers for the lab scripts. Source this; do not execute.
LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OPS=$LAB_ROOT/ops
STATE=$OPS/.state
SECRETS=$STATE/secrets.env
MANIFEST=$LAB_ROOT/lab.manifest

# Throwaway credentials: this lab is local-only, nothing here is secret.
GITEA=http://localhost:3000        # host -> gitea without needing /etc/hosts
PACKETON=http://localhost
GITEA_HOST=gitea.test
ADMIN=admin;  ADMIN_PW=admin12345
BOT=bot;      BOT_PW=bot12345
DEV=dev;      DEV_PW=dev12345
MODULE_ORG=activit                 # shared modules (plan: "activit" organization)
SITE_ORG=sites                     # Drupal projects

mkdir -p "$STATE"; touch "$SECRETS"
dc()  { docker compose --project-directory "$OPS" -f "$OPS/docker-compose.yml" "$@"; }
say() { printf '== %s\n' "$*"; }
setval() { grep -v "^$1=" "$SECRETS" > "$SECRETS.tmp" || true; echo "$1=$2" >> "$SECRETS.tmp"; mv "$SECRETS.tmp" "$SECRETS"; }
load_secrets() { set -a; . "$SECRETS"; set +a; }

# api METHOD PATH [json]   -> Gitea API as admin
api() { local m=$1 p=$2; shift 2
  curl -sS -X "$m" -u "$ADMIN:$ADMIN_PW" -H 'Content-Type: application/json' "$GITEA/api/v1$p" ${1:+-d "$1"}; }
http_code() { local m=$1 p=$2; curl -s -o /dev/null -w '%{http_code}' -X "$m" -u "$ADMIN:$ADMIN_PW" "$GITEA/api/v1$p"; }

wait_for_stack() {
  until curl -fsS "$GITEA/api/v1/version" >/dev/null 2>&1; do sleep 2; done
  until curl -fsS -o /dev/null "$PACKETON/login" 2>&1; do sleep 2; done
}
hosts_ok() { getent hosts "$GITEA_HOST" >/dev/null && getent hosts packeton.test >/dev/null; }

repo_exists() { [ "$(http_code GET "/repos/$1/$2")" = 200 ]; }

# ensure_repo ORG NAME [SOURCE_URL]  -> creates an empty repo, or imports SOURCE_URL (history + tags)
ensure_repo() { local org=$1 name=$2 src=${3:-}
  repo_exists "$org" "$name" && return 0
  if [ -n "$src" ]; then
    echo "   importing $org/$name from $src"
    api POST /repos/migrate "$(jq -n --arg a "$src" --arg o "$org" --arg n "$name" \
      '{clone_addr:$a,repo_owner:$o,repo_name:$n,service:"git",private:true,mirror:false}')" | jq -r '.full_name // .message' | sed 's/^/   /'
  else
    echo "   creating $org/$name"
    api POST "/orgs/$org/repos" "$(jq -n --arg n "$name" '{name:$n,private:true,default_branch:"main"}')" | jq -r '.full_name // .message' | sed 's/^/   /'
  fi
}

# Only main devs may create release tags (plan 2.1: protected tags v*)
ensure_tag_protection() { local org=$1 name=$2
  api GET "/repos/$org/$name/tag_protections" | jq -e '.[]|select(.name_pattern=="v*")' >/dev/null 2>&1 ||
    api POST "/repos/$org/$name/tag_protections" "{\"name_pattern\":\"v*\",\"whitelist_usernames\":[\"$ADMIN\"]}" >/dev/null
}

# Per-repository hook -> Packeton (an org-wide hook does not work with Gitea 28 + Packeton, see README)
ensure_pkg_hook() { local name=$1; load_secrets
  local url="http://packeton.test/api/update-package?username=admin&apiToken=$PACKETON_TOKEN&composer_package_name=$MODULE_ORG/$name"
  api GET "/repos/$MODULE_ORG/$name/hooks" | jq -e --arg u "$url" '.[]|select(.config.url==$u)' >/dev/null 2>&1 && return 0
  api POST "/repos/$MODULE_ORG/$name/hooks" "$(jq -n --arg u "$url" \
    '{type:"gitea",active:true,events:["push","create","delete"],config:{url:$u,content_type:"json"}}')" >/dev/null
}

# register_package NAME -> adds the module repo to Packeton once it has a composer.json on main (plan 4.3)
register_package() { local name=$1; load_secrets
  # a freshly seeded repo may not serve its files for a moment (see wait_for_branch)
  local i; for i in 1 2 3 4 5; do [ "$(http_code GET "/repos/$MODULE_ORG/$name/raw/composer.json?ref=main")" = 200 ] && break; [ "$(http_code GET "/repos/$MODULE_ORG/$name/branches/main")" = 200 ] && break; sleep 1; done
  [ "$(http_code GET "/repos/$MODULE_ORG/$name/raw/composer.json?ref=main")" = 200 ] || { echo "   $name: no composer.json on main yet, not registering"; return 0; }
  local have; have=$(curl -s -o /dev/null -w '%{http_code}' "$PACKETON/api/packages/$MODULE_ORG/$name?username=admin&apiToken=$PACKETON_TOKEN")
  [ "$have" = 200 ] && return 0
  curl -sS -X POST "$PACKETON/api/create-package?username=admin&apiToken=$PACKETON_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"repository\":\"http://$GITEA_HOST:3000/$MODULE_ORG/$name.git\",\"repoType\":\"vcs\"}" | jq -r '"   registered in Packeton: \(.name // .message)"'
}

# wait_for_branch ORG NAME BRANCH [SECONDS] -> Gitea records a pushed branch asynchronously: the API (and with it
# protection, raw file reads, registration) only sees it a moment later. Seen on fresh labs, so wait explicitly.
wait_for_branch() { local org=$1 name=$2 br=$3 t=${4:-60} i
  for i in $(seq 1 "$t"); do [ "$(http_code GET "/repos/$org/$name/branches/$br")" = 200 ] && return 0; sleep 1; done
  echo "   warning: $org/$name:$br not visible via the API after ${t}s" >&2; return 1; }

# seed_repo ORG NAME SEED_DIR [TEMPLATE_DIR] -> if the repo is still empty and SEED_DIR exists, push TEMPLATE_DIR +
# SEED_DIR as the first commit and tag it (as admin: only main devs may tag). Tags come from SEED_DIR.tags
# (space separated, default v1.0.0). Lets a fresh lab start from known code.
seed_repo() { local org=$1 name=$2 seed=$3 template=${4:-}
  [ -d "$seed" ] || return 0
  [ "$(api GET "/repos/$org/$name/branches" | jq 'length')" = 0 ] || return 0
  local tags=v1.0.0; [ -f "$seed.tags" ] && tags=$(cat "$seed.tags")
  local tmp; tmp=$(mktemp -d)
  [ -n "$template" ] && [ -d "$template" ] && cp -a "$template/." "$tmp/"
  cp -a "$seed/." "$tmp/"
  ( cd "$tmp" && git init -q -b main && git config user.name "Main Dev" && git config user.email "admin@example.test" \
    && git add -A && git commit -qm "Initial commit (seeded by ./lab sync)" \
    && for t in $tags; do git tag -a "$t" -m "Release $t"; done \
    && git push -q "http://$ADMIN:$ADMIN_PW@$GITEA_HOST:3000/$org/$name.git" main $tags ) \
    && echo "   seeded $org/$name from ${seed#$LAB_ROOT/}, tagged $tags"
  rm -rf "$tmp"
  wait_for_branch "$org" "$name" main
}

# ddev_composer_auth -> (re)write Packeton credentials into DDEV's global Composer config. Needed after every lab
# rebuild: the Packeton API token changes, and Composer then silently falls back to its stale cache (exit code 0!)
ddev_composer_auth() { load_secrets
  ddev composer config --global http-basic.packeton.test admin "$PACKETON_TOKEN" >/dev/null 2>&1 \
    || ( cd "$1" && ddev composer config --global http-basic.packeton.test admin "$PACKETON_TOKEN" >/dev/null )
}

# ensure_main_protection ORG NAME -> plan 2.1: main takes merge requests only, and the Checks job must pass.
# Applies to admins too (otherwise the main dev could push straight to main).
ensure_main_protection() { local org=$1 name=$2
  # An empty repo has no main yet and its first commit must be pushable: protect once main exists
  # (new-drupal-project.sh calls this after the initial push; ./lab sync re-applies it).
  [ "$(http_code GET "/repos/$org/$name/branches/main")" = 200 ] || { echo "   (no main branch yet: protection applied after the first push)"; return 0; }
  local body='{"rule_name":"main","enable_push":false,"enable_status_check":true,"status_check_contexts":["checks / checks (pull_request)"],"required_approvals":0,"apply_to_admins":true}'
  if [ "$(http_code GET "/repos/$org/$name/branch_protections/main")" = 200 ]; then
    api PATCH "/repos/$org/$name/branch_protections/main" "$body" >/dev/null
  else
    api POST "/repos/$org/$name/branch_protections" "$body" | jq -r '.rule_name // .message' | sed 's/^/   protected: /'
  fi
}

# ensure_release_line_protection ORG NAME -> every maintenance branch (1.x, 2.x, 10.x, 1.2.x ...) gets the same rule as
# main (PR only, Checks required, admins included) as soon as it exists, via one glob rule. Gitea matches the glob
# against the branch name; `feat.x` is not matched, `9.x` is.
ensure_release_line_protection() { local org=$1 name=$2 rule='[0-9]*.x'
  local body='{"rule_name":"[0-9]*.x","enable_push":false,"enable_status_check":true,"status_check_contexts":["checks / checks (pull_request)"],"required_approvals":0}'
  local enc; enc=$(printf '%s' "$rule" | jq -sRr @uri)
  if [ "$(http_code GET "/repos/$org/$name/branch_protections/$enc")" = 200 ]; then
    api PATCH "/repos/$org/$name/branch_protections/$enc" "$body" >/dev/null
  else
    api POST "/repos/$org/$name/branch_protections" "$body" | jq -r '.rule_name // .message' | sed 's/^/   protected release lines: /'
  fi
}
