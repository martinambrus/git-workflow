#!/bin/bash
# Make Gitea + Packeton + the local folders match lab.manifest. Idempotent; run it as often as you like.
#   module  <name> [<source-git-url>]  -> activit/<name>, cloned to modules/<name>
#   project <name> [<source-git-url>]  -> sites/<name>,   cloned to projects/<name>
#   tool    <name> [<source-git-url>]  -> activit/<name>, cloned to tools/<name> (e.g. ci-tools: not a Composer package)
# With a source URL the repo is imported (history + tags) the first time; without one it is created empty.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
load_secrets
only=${1:-}

can_clone=1
hosts_ok || { can_clone=0; echo "!! $GITEA_HOST / packeton.test do not resolve on this machine: repos are created in Gitea but not cloned."
              echo "!! run: ./lab hosts   (adds '127.0.0.1 gitea.test packeton.test' to /etc/hosts), then ./lab sync"; }

grep -vE '^\s*(#|$)' "$MANIFEST" | while read -r kind name src _; do
  [ -z "$only" ] || [ "$only" = "$name" ] || continue
  case $kind in
    module)  org=$MODULE_ORG; dir=$LAB_ROOT/modules/$name ;;
    project) org=$SITE_ORG;   dir=$LAB_ROOT/projects/$name ;;
    tool)    org=$MODULE_ORG; dir=$LAB_ROOT/tools/$name ;;
    *) echo "manifest: unknown kind '$kind'" >&2; continue ;;
  esac
  say "$kind $org/$name"
  ensure_repo "$org" "$name" "$src"
  if [ "$kind" = tool ]; then
    ensure_tag_protection "$org" "$name"
    seed_repo "$org" "$name" "$LAB_ROOT/seed/tools/$name"
  fi
  if [ "$kind" = project ]; then
    # opt in to update pull requests (plan 9): every lab project carries the topic
    api PUT "/repos/$org/$name/topics/activit-project" >/dev/null
    api PATCH "/repos/$org/$name" '{"default_delete_branch_after_merge":true}' >/dev/null
  fi
  if [ "$kind" = module ]; then
    ensure_tag_protection "$org" "$name"
    # merged bot branches (up/...) are removed; Packeton keeps their dev- versions until a --delete-before update
    api PATCH "/repos/$org/$name" '{"default_delete_branch_after_merge":true}' >/dev/null
    seed_repo "$org" "$name" "$LAB_ROOT/seed/modules/$name" "$LAB_ROOT/seed/module-template"
    ensure_pkg_hook "$name"
    register_package "$name"
  fi
  case $kind in module|project) ensure_main_protection "$org" "$name" ;; esac
  [ "$kind" = module ] && ensure_release_line_protection "$org" "$name"
  [ $can_clone = 1 ] || continue
  url="http://$DEV:$DEV_PW@$GITEA_HOST:3000/$org/$name.git"
  if [ -d "$dir/.git" ]; then
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then echo "   $dir has local changes, not pulling"
    else git -C "$dir" pull --ff-only -q 2>&1 | sed 's/^/   /' || true; echo "   up to date: $dir"; fi
  else
    mkdir -p "$(dirname "$dir")"
    git clone -q "$url" "$dir" 2>&1 | grep -v 'empty repository' | sed 's/^/   /' || true
    git -C "$dir" config user.name "Dev One"; git -C "$dir" config user.email "dev@example.test"
    git -C "$dir" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    echo "   cloned to $dir"
  fi
done
