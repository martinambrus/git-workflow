#!/bin/bash
# Housekeeping: delete branches without an open PR (merged update/*, up/* bot branches, ...) in every project and
# module repo, then make Packeton forget the matching dev- versions (it never drops vanished branches by itself,
# only `packagist:update <pkg> --delete-before` does; see README finding 13).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
for repo in $(api GET "/orgs/$SITE_ORG/repos?limit=100" | jq -r '.[].full_name') $(api GET "/orgs/$MODULE_ORG/repos?limit=100" | jq -r '.[].full_name'); do
  open=$(api GET "/repos/$repo/pulls?state=open&limit=100" | jq -r '[.[].head.ref]|join(" ")')
  def=$(api GET "/repos/$repo" | jq -r .default_branch)
  for b in $(api GET "/repos/$repo/branches?limit=100" | jq -r --arg d "$def" '.[].name|select(.!=$d)'); do
    case " $open " in *" $b "*) echo "keep    $repo:$b (open PR)";; *)
      api DELETE "/repos/$repo/branches/$(printf '%s' "$b" | jq -sRr @uri)" >/dev/null; echo "deleted $repo:$b";; esac
  done
done
load_secrets
for pkg in $(api GET "/orgs/$MODULE_ORG/repos?limit=100" | jq -r '.[].name'); do
  # only packages that are registered in Packeton (ci-tools is not a Composer package)
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$PACKETON/api/packages/$MODULE_ORG/$pkg?username=admin&apiToken=$PACKETON_TOKEN")" = 200 ] || continue
  dc exec -T -u www-data packeton app packagist:update "$MODULE_ORG/$pkg" --delete-before >/dev/null 2>&1 && echo "packeton: re-crawled $MODULE_ORG/$pkg (dev- versions of deleted branches disappear within seconds)" || true
done
