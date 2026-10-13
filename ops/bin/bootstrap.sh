#!/bin/bash
# Idempotent: start the stack and configure Gitea (users, orgs, team, bot token, org secrets),
# Packeton (read access to Gitea) and the Actions runner. Safe to re-run.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$OPS"

say "starting gitea + packeton"
dc up -d gitea packeton
wait_for_stack

gitea_cli() { dc exec -T -u git gitea gitea "$@" 2>&1 | grep -v Deprecation || true; }

say "gitea users"
mkuser() { gitea_cli admin user create ${3:+--admin} --username "$1" --password "$2" --email "$1@example.test" --must-change-password=false | grep -E 'created|exist' || true; }
mkuser "$ADMIN" "$ADMIN_PW" admin
mkuser "$BOT" "$BOT_PW"
mkuser "$DEV" "$DEV_PW"

say "organizations $MODULE_ORG + $SITE_ORG, team devs (bot, dev: write)"
for org in "$MODULE_ORG" "$SITE_ORG"; do
  api POST /orgs "{\"username\":\"$org\",\"visibility\":\"private\"}" >/dev/null
  team=$(api GET "/orgs/$org/teams/search?q=devs" | jq -r '.data[0].id // empty')
  if [ -z "$team" ]; then
    team=$(api POST "/orgs/$org/teams" '{"name":"devs","includes_all_repositories":true,"can_create_org_repo":false,"permission":"write","units_map":{"repo.code":"write","repo.issues":"write","repo.pulls":"write","repo.actions":"write","repo.releases":"read","repo.packages":"read"}}' | jq -r .id)
  fi
  for u in "$BOT" "$DEV"; do api PUT "/teams/$team/members/$u" >/dev/null; done
done

say "access tokens"
mktoken() { # user password name-prefix scopes-json
  curl -sS -X POST -u "$1:$2" -H 'Content-Type: application/json' "$GITEA/api/v1/users/$1/tokens" \
    -d "{\"name\":\"$3-$(date +%s)\",\"scopes\":$4}" | jq -r .sha1; }
grep -q '^BOT_TOKEN=' "$SECRETS" || setval BOT_TOKEN "$(mktoken "$BOT" "$BOT_PW" bot '["write:repository","write:issue","write:organization","read:user"]')"
grep -q '^DEV_TOKEN=' "$SECRETS" || setval DEV_TOKEN "$(mktoken "$DEV" "$DEV_PW" dev '["write:repository","write:issue","read:user"]')"
PTOKEN=$(dc exec -T packeton app packagist:user:manager admin --show-token 2>/dev/null | grep -oE '[A-Za-z0-9]{20}' | tail -1)
[ -n "$PTOKEN" ] || { echo "could not read packeton token" >&2; exit 1; }
setval PACKETON_TOKEN "$PTOKEN"
load_secrets

say "packeton -> gitea read credentials (stand-in for the read-only credential of plan 2.2)"
dc exec -T packeton sh -c 'mkdir -p /data/composer && cat > /data/composer/auth.json' <<JSON
{ "http-basic": {
  "gitea.test:3000": { "username": "bot", "password": "$BOT_TOKEN" },
  "gitea.test":      { "username": "bot", "password": "$BOT_TOKEN" } } }
JSON
dc exec -T packeton sh -c 'cat > /data/composer/config.json && chown -R www-data:www-data /data/composer' <<JSON
{ "config": { "secure-http": false } }
JSON

say "organization secrets BOT_TOKEN, PACKETON_TOKEN"
for org in "$MODULE_ORG" "$SITE_ORG"; do
  api PUT "/orgs/$org/actions/secrets/BOT_TOKEN" "{\"data\":\"$BOT_TOKEN\"}" >/dev/null
  api PUT "/orgs/$org/actions/secrets/PACKETON_TOKEN" "{\"data\":\"$PTOKEN\"}" >/dev/null
done

say "runner image + runner"
docker image inspect activit-runner:local >/dev/null 2>&1 || dc --profile build build runner-image
grep -q '^RUNNER_TOKEN=' .env 2>/dev/null || echo "RUNNER_TOKEN=$(gitea_cli actions generate-runner-token | tail -1)" >> .env
dc up -d runner
