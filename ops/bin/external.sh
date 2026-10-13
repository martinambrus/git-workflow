#!/bin/bash
# "External customer" side of plan section 10 / 2.2: Packeton behind a TLS proxy on a separate network that cannot
# reach Gitea (or Packeton directly), plus a Unipo-like test customer with a limited grant.
#   external.sh up     certificate (mkcert), hosts entry, proxy container
#   external.sh test   create customer 'unipo' (grant <1.1) if missing and install from the customer network
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cmd=${1:-up}
CERTS=$STATE/ext-certs
PA="username=admin&apiToken="

up() {
  command -v mkcert >/dev/null || { echo "mkcert is required (DDEV installs it: ddev --version; mkcert -install)" >&2; exit 1; }
  mkdir -p "$CERTS"
  [ -f "$CERTS/cert.pem" ] || mkcert -cert-file "$CERTS/cert.pem" -key-file "$CERTS/key.pem" packeton-ext.test >/dev/null 2>&1
  cp "$(mkcert -CAROOT)/rootCA.pem" "$CERTS/rootCA.pem"
  getent hosts packeton-ext.test >/dev/null || { echo "127.0.0.1 packeton-ext.test" | sudo tee -a /etc/hosts >/dev/null; }
  dc --profile external up -d ext-proxy
  echo "https://packeton-ext.test  (customer-facing; internal Gitea hostname is scrubbed from the metadata)"
}

ensure_customer() { load_secrets
  # always (re)apply the intended state, so the test cannot run against leftovers of manual experiments
  local A="username=admin&apiToken=$PACKETON_TOKEN" gid uid
  local grant='{"name":"unipo","aclPermissions":[{"name":"activit/ait_banners","version":"<1.1"}]}'
  gid=$(curl -fsS "$PACKETON/api/groups?$A" | jq -r '.[]|select(.name=="unipo").id')
  if [ -z "$gid" ]; then gid=$(curl -fsS -X POST "$PACKETON/api/groups?$A" -H 'Content-Type: application/json' -d "$grant" | jq -r .id)
  else curl -fsS -X PUT "$PACKETON/api/group/$gid?$A" -H 'Content-Type: application/json' -d "$grant" >/dev/null; fi
  uid=$(curl -fsS "$PACKETON/api/users?$A" | jq -r '.[]|select(.username=="unipo").id')
  if [ -z "$uid" ]; then
    curl -fsS -X POST "$PACKETON/api/users?$A" -H 'Content-Type: application/json' \
      -d "{\"username\":\"unipo\",\"email\":\"dev@unipo.example\",\"plainPassword\":{\"first\":\"unipo-pass-123\",\"second\":\"unipo-pass-123\"},\"enabled\":true,\"groups\":[$gid]}" >/dev/null
  else
    curl -fsS -X PUT "$PACKETON/api/user/$uid?$A" -H 'Content-Type: application/json' \
      -d "{\"username\":\"unipo\",\"email\":\"dev@unipo.example\",\"expiredUpdatesAt\":null,\"groups\":[$gid]}" >/dev/null
  fi
  dc exec -T packeton app packagist:user:manager unipo --show-token 2>/dev/null | grep -oE '[A-Za-z0-9]{20}' | tail -1
}

test_customer() {
  local tok; tok=$(ensure_customer)
  echo "customer grant: activit/ait_banners <1.1 (set in Packeton group 'unipo')"
  docker run --rm --network wf-ext -e UT="$tok" -v "$CERTS/rootCA.pem:/ca.pem:ro" activit-runner:local bash -c '
    export SSL_CERT_FILE=/ca.pem
    printf "gitea (internal)      : %s\n" "$(curl -s -m 3 -o /dev/null -w %{http_code} http://gitea.test:3000/ || true)"
    printf "packeton (internal)   : %s\n" "$(curl -s -m 3 -o /dev/null -w %{http_code} http://packeton.test/login || true)"
    printf "packeton-ext (https)  : %s\n" "$(curl -s -m 3 -o /dev/null -w %{http_code} https://packeton-ext.test/login)"
    mkdir /tmp/c && cd /tmp/c && echo "{\"replace\":{\"drupal/core\":\"11.4.9\"}}" > composer.json
    composer config repositories.activit composer https://packeton-ext.test >/dev/null
    composer config http-basic.packeton-ext.test unipo "$UT" >/dev/null
    composer config preferred-install.\* dist >/dev/null
    composer require "activit/ait_banners:^1.0" --no-interaction 2>&1 | grep -E "Installing activit|rror"
    echo "--- asking for ^1.1 must fail:"
    composer require "activit/ait_banners:^1.1" --no-interaction 2>&1 | grep -E "does not match the constraint" | sed "s/^ *//"'
}

case $cmd in up) up ;; test) test_customer ;; *) echo "usage: $0 up|test" >&2; exit 1 ;; esac
