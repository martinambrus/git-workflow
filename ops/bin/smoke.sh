#!/bin/bash
# End-to-end self-test of the stack, run from inside the docker network (no /etc/hosts needed).
# Creates activit/smoke_module, tags it, checks Packeton picks it up via the org webhook, runs an Actions
# job, installs the package with Composer and checks protected tags. Re-runnable; remove with: bin/smoke.sh clean
set -uo pipefail
. "$(dirname "$0")/lib.sh"
load_secrets
export BOT_TOKEN PACKETON_TOKEN DEV_TOKEN
G=$GITEA/api/v1
P=$PACKETON
adm() { curl -sS -u admin:admin12345 -H 'Content-Type: application/json' "$@"; }
pk() { curl -sS "$@"; }
FAILED=0
ok()  { echo "  OK    $*"; }
bad() { echo "  FAIL  $*"; FAILED=1; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { [[ $1 == *$2* ]]; }   # has "<haystack>" "<needle>"
RUN() { docker run --rm --network wf-net -e BOT_TOKEN -e PACKETON_TOKEN -e DEV_TOKEN activit-runner:local bash -c "$1"; }
versions() { pk "$P/packages/activit/smoke_module.json?username=admin&apiToken=$PACKETON_TOKEN" 2>/dev/null | jq -r '.package.versions // {} | keys[]' 2>/dev/null | sort | tr '\n' ' '; }

if [ "${1:-}" = clean ]; then
  adm -X DELETE "$G/repos/activit/smoke_module" -o /dev/null
  adm -X DELETE "$P/api/packages/activit/smoke_module?username=admin&apiToken=$PACKETON_TOKEN" -o /dev/null || true
  dc exec -T packeton app dbal:run-sql "delete from package where name='activit/smoke_module'" >/dev/null 2>&1 || true
  echo cleaned; exit 0
fi

echo "== 1. repo + protected tags + per-repo hook to Packeton"
ensure_repo "$MODULE_ORG" smoke_module
ensure_tag_protection "$MODULE_ORG" smoke_module
ensure_pkg_hook smoke_module
check "hook exists" bash -c "curl -s -u admin:admin12345 $G/repos/activit/smoke_module/hooks | jq -e 'length>0' >/dev/null"

echo "== 2. push module, tag v1.0.0 (admin); tag as dev must be refused"
out=$(RUN '
set -e
rm -rf /tmp/m && mkdir /tmp/m && cd /tmp/m && git init -q -b main && git config user.email a@a.test && git config user.name admin
echo "{\"name\":\"activit/smoke_module\",\"type\":\"drupal-custom-module\",\"license\":\"GPL-2.0-or-later\"}" > composer.json
mkdir -p .gitea/workflows
cat > .gitea/workflows/ci.yml <<Y
name: ci
on: [push]
jobs:
  smoke:
    runs-on: activit-runner
    steps:
      - name: Plain run step (no uses:), secrets, tooling, reach Gitea and Packeton
        run: |
          php -v | head -1
          composer --version
          test -n "\${{ secrets.BOT_TOKEN }}" && echo "bot secret present"
          git ls-remote "http://bot:\${{ secrets.BOT_TOKEN }}@gitea.test:3000/activit/smoke_module.git" | head -1
          curl -fsS -o /dev/null http://packeton.test/login && echo "packeton reachable from job"
Y
git add -A && git commit -qm "Initial module" && git tag -a v1.0.0 -m first
git push -q "http://admin:admin12345@gitea.test:3000/activit/smoke_module.git" main v1.0.0
echo y > y.md && git add y.md && git commit -qm y && git tag -a v9.9.9 -m nope
set +e
git push "http://dev:$DEV_TOKEN@gitea.test:3000/activit/smoke_module.git" v9.9.9 >/tmp/devpush.log 2>&1
[ $? -ne 0 ] && echo DEV_TAG_REFUSED || echo DEV_TAG_ALLOWED
' 2>&1)
check "admin pushed main + v1.0.0" bash -c "! grep -q 'fatal\|error:' <<<'$out' || grep -q DEV_TAG <<<'$out'"
check "dev cannot create v* tag (protected tags)" grep -q DEV_TAG_REFUSED <<<"$out"

echo "== 3. register package in Packeton, then watch for the version"
register_package smoke_module
for i in $(seq 1 30); do v=$(versions); has "$v" 1.0.0 && break; sleep 2; done
check "Packeton lists 1.0.0 (versions: $v)" has "$v" 1.0.0

echo "== 4. new tag v1.0.1 reaches Packeton via the repo webhook (no manual update)"
RUN '
set -e
git clone -q "http://admin:admin12345@gitea.test:3000/activit/smoke_module.git" /tmp/c && cd /tmp/c
git config user.email a@a.test; git config user.name admin
echo "# fix" >> README.md && git add -A && git commit -qm "Fix" && git push -q origin main
git tag -a v1.0.1 -m fix && git push -q origin v1.0.1
' >/dev/null 2>&1
for i in $(seq 1 30); do v=$(versions); has "$v" "1.0.1 " && break; sleep 2; done
check "Packeton lists 1.0.1 and dev-main (versions: $v)" has "$v" "1.0.1 "

echo "== 5. Actions job ran on the runner with run-only steps"
for i in $(seq 1 40); do
  st=$(adm "$G/repos/activit/smoke_module/actions/runs" | jq -r '.workflow_runs[0].status // "none"'); [ "$st" = completed ] && break; sleep 3
done
concl=$(adm "$G/repos/activit/smoke_module/actions/runs" | jq -r '.workflow_runs[0].conclusion // "none"')
check "workflow run concluded: $concl" test "$concl" = success

echo "== 6. composer require from Packeton as a project would"
res=$(RUN '
set -e
mkdir /tmp/p && cd /tmp/p && echo "{}" > composer.json
composer config secure-http false
composer config repositories.activit composer http://packeton.test
composer config http-basic.packeton.test admin "$PACKETON_TOKEN"
composer config preferred-install.* dist
composer require activit/smoke_module:^1.0 --no-interaction 2>&1 | tail -6
jq -r ".packages[]|\"LOCKED \(.name) \(.version) \(.dist.type) \(.dist.url)\"" composer.lock
' 2>&1)
echo "$res" | sed 's/^/    /'
check "composer installed activit/smoke_module 1.0.1 (v1.0.1) as a dist archive" grep -qE 'LOCKED activit/smoke_module v?1\.0\.1 zip' <<<"$res"

echo
[ $FAILED -eq 0 ] && echo "SMOKE TEST PASSED" || echo "SMOKE TEST HAD FAILURES"
exit $FAILED
