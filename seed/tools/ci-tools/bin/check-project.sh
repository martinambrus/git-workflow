#!/bin/bash
# Checks job for project repositories (plan section 12, checks 1-4).
#   1. no gitlinks (mode 160000) and no nested .git folders
#   2. no symlinks that point outside the project
#   3. no dev- or pre-release versions of activit/* in composer.lock (feature branches: warning)
#   4. drift: reinstall the Composer-managed folders from composer.lock in a clean checkout, with dev dependencies,
#      and compare. Warning on plain branch pushes for our own modules (unreleased in-place work, sent upstream by the
#      Upstream job); failure for third-party code, and failure for everything on pull requests into main and on main.
#
# Env: GITEA_URL BOT_TOKEN PACKETON_TOKEN REPOSITORY EVENT (push|pull_request) BRANCH (head branch) BASE_REF (PR target)
#      [PACKETON_USER=admin] the Packeton user that owns PACKETON_TOKEN (each project has its own user, plan 10)
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$here/lib/common.sh"
: "${REPOSITORY:?}" "${BRANCH:?}" "${PACKETON_TOKEN:?}"
EVENT=${EVENT:-push}; BASE_REF=${BASE_REF:-}
PACKETON_URL=${PACKETON_URL:-http://packeton.test}
PACKETON_USER=${PACKETON_USER:-admin}
phost=$(echo "$PACKETON_URL" | sed -E 's#^https?://([^/:]+).*#\1#')

# strict = what would land on main: PRs targeting main, and main itself
strict=0
{ [ "$EVENT" = pull_request ] && [ "$BASE_REF" = main ]; } && strict=1
{ [ "$EVENT" = push ] && [ "$BRANCH" = main ]; } && strict=1
log "checking $REPOSITORY branch=$BRANCH event=$EVENT base=${BASE_REF:--} strict=$strict"

fails=0; warns=0
fail() { printf '[ci-tools] FAIL: %s\n' "$*" >&2; fails=$((fails+1)); }
soft() { if [ $strict = 1 ]; then fail "$*"; else printf '[ci-tools] WARN: %s\n' "$*"; warns=$((warns+1)); fi; }

work=$(mktemp -d)
git clone -q --depth 1 --branch "$BRANCH" "${GITEA_URL}/${REPOSITORY}.git" "$work/p" || die "cannot clone $REPOSITORY@$BRANCH"
cd "$work/p"; proj=$PWD

# --- 1. gitlinks, nested .git ---------------------------------------------------------------------------------------
echo "::group::1 gitlinks and nested .git"
gl=$(git ls-files -s | awk '$1==160000{print $4}')
[ -z "$gl" ] || fail "gitlinks (submodule-style entries): $(echo $gl)"
ng=$(find . -mindepth 2 -name .git -not -path './.git/*' | head -20)
[ -z "$ng" ] || fail "nested .git found: $(echo $ng)"
[ -z "$gl$ng" ] && log "ok"
echo "::endgroup::"

# --- 2. symlinks leaving the project --------------------------------------------------------------------------------
echo "::group::2 symlinks"
bad=0
while IFS= read -r l; do
  t=$(readlink -f "$l" 2>/dev/null || true)
  case "$t" in "$proj"/*|"$proj") ;; *) fail "symlink points outside the project: $l -> $(readlink "$l")"; bad=1;; esac
done < <(find . -type l -not -path './.git/*')
[ $bad = 0 ] && log "ok"
echo "::endgroup::"

# --- 3. dev- / pre-release versions of our modules in the lock ---------------------------------------------------------
echo "::group::3 lock versions"
if [ -f composer.lock ]; then
  badv=$(jq -r '.packages[]|select(.name|startswith("activit/"))|select(.version|test("^dev-|-dev$|-(alpha|beta|rc|RC|patch)"))|"\(.name) \(.version)"' composer.lock)
  [ -z "$badv" ] && log "ok" || soft "dev or pre-release version of our modules in composer.lock: $(echo $badv)"
fi
echo "::endgroup::"

# --- 4. drift -------------------------------------------------------------------------------------------------------
echo "::group::4 drift (reinstall from composer.lock)"
if [ -f composer.lock ] && [ -f vendor/composer/installed.json ]; then
  export COMPOSER_AUTH="{\"http-basic\":{\"${phost}\":{\"username\":\"${PACKETON_USER}\",\"password\":\"${PACKETON_TOKEN}\"}}}"
  export COMPOSER_CACHE_DIR; COMPOSER_CACHE_DIR=$(mktemp -d)
  export COMPOSER_NO_INTERACTION=1

  # normalise the only legitimately volatile bit: the root package's own version/reference (= current commit)
  normalise() { perl -0pe "s/('pretty_version' => )'[^']*'(,\s*'version' => )'[^']*'(,\s*'reference' => )(?:null|'[^']*')(,\s*'type' => 'project',\s*'install_path' => __DIR__ \. '\/\.\.\/\.\.\/')/\$1'ROOT'\$2'ROOT'\$3'ROOT'\$4/g"; }

  # folders managed by Composer: every installed package path, plus vendor/ itself
  mapfile -t paths < <(jq -r '.packages[]|.["install-path"]' vendor/composer/installed.json | while read -r r; do realpath -m --relative-to="$proj" "vendor/composer/$r"; done | grep -v '^\.\./' | sort -u)
  own=$(jq -r '.packages[]|select(.name|startswith("activit/"))|.["install-path"]' vendor/composer/installed.json | while read -r r; do realpath -m --relative-to="$proj" "vendor/composer/$r"; done)
  for p in "${paths[@]}"; do [ "$p" = . ] || rm -rf "./$p"; done
  rm -rf ./vendor

  out=$(composer install --no-interaction --no-progress 2>&1); rc=$?
  if [ $rc -ne 0 ]; then echo "$out" | tail -15; fail "composer install from composer.lock failed"; fi
  grep -qE "could not be fully loaded|required authentication" <<<"$out" && fail "Packeton authentication problem during composer install"
  grep -q "lock file is not up to date" <<<"$out" && fail "composer.lock is not up to date with composer.json"

  # What is NOT comparable byte for byte (found in the pilot, see README finding 12): files Composer generates
  # (autoloader suffix, include_paths ordering, hashes). They are verified indirectly below instead.
  generated='^vendor/(autoload[^/]*\.php|composer/[^/]+|drupal/DrupalInstalled\.php)$'
  changed=$(git status --porcelain --untracked-files=all | sed -E 's/^.. //' | grep -Ev "$generated" || true)
  # pure line-ending differences of shipped text files are not drift either
  keep=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if git ls-files --error-unmatch -- "$c" >/dev/null 2>&1 && git diff --ignore-cr-at-eol --quiet -- "$c"; then continue; fi
    keep="$keep$c"$'\n'
  done <<<"$changed"
  changed=${keep%$'\n'}

  if [ -z "$changed" ]; then log "ok: a clean reinstall reproduces every package file"
  else
    n_own=0; n_other=0; other_list=""; own_list=""
    while IFS= read -r c; do
      isown=0; for o in $own; do case "$c" in "$o"/*|"$o") isown=1;; esac; done
      if [ $isown = 1 ]; then n_own=$((n_own+1)); own_list="$own_list $c"; else n_other=$((n_other+1)); other_list="$other_list $c"; fi
    done <<<"$changed"
    [ $n_own -gt 0 ]   && soft "drift in our own modules ($n_own files, unreleased in-place work?):$(echo "$own_list" | tr ' ' '\n' | head -8 | sed 's/^/ /')"
    [ $n_own -gt 0 ] && [ $strict = 1 ] && log "This is expected for an in-place module change: do not merge. The Upstream job sent it to the module repository (see its comment on the pull request); once it is released, the Release job adds the release to this pull request and the check passes."
    [ $n_other -gt 0 ] && fail "drift in third-party/vendor code ($n_other files):$(echo "$other_list" | tr ' ' '\n' | head -8 | sed 's/^/ /')"
  fi

  # The committed vendor/composer/installed.json must agree with composer.lock (same packages, versions, references).
  want=$(jq -S '[(.packages + .["packages-dev"])[] | {name, version, ref: .dist.reference}] | sort_by(.name)' composer.lock)
  have=$(git show HEAD:vendor/composer/installed.json 2>/dev/null | jq -S '[.packages[] | {name, version, ref: .dist.reference}] | sort_by(.name)')
  if [ "$want" = "$have" ]; then log "ok: committed vendor/composer/installed.json matches composer.lock"
  else
    fail "committed vendor/composer/installed.json does not match composer.lock (run composer install and commit)"
    diff <(echo "$want") <(echo "$have") | head -10 | sed 's/^/    /'
  fi
elif [ -f composer.lock ]; then
  # without the committed vendor/ the drift check cannot run: say so, and fail where it matters (strict)
  soft "composer.lock is committed but vendor/composer/installed.json is not: drift cannot be compared (commit vendor/)"
else
  log "no composer.lock/vendor: nothing to compare"
fi
echo "::endgroup::"

# --- 5. every locked activit/* version is visible to this project's own Packeton user ------------------------------
# A frozen project (version limit or update-expiration date in Packeton) cannot list newer versions, but the lock's
# dist URL still downloads them, so a pull request that moves the lock would pass the other checks. Fail it here.
echo "::group::5 Packeton visibility (${PACKETON_USER})"
if [ -f composer.lock ]; then
  nv=0
  while IFS=$'\t' read -r name ver; do
    seen=$(curl -fsS -u "${PACKETON_USER}:${PACKETON_TOKEN}" "${PACKETON_URL}/p2/${name}.json" 2>/dev/null \
      | jq -r --arg n "$name" '.packages[$n][]?.version' | grep -cxF "$ver")
    [ "${seen:-0}" -gt 0 ] || { soft "$name $ver is locked but not listed for Packeton user ${PACKETON_USER} (frozen or outside its version limit)"; nv=1; }
  done < <(jq -r '.packages[]|select(.name|startswith("activit/"))|select(.version|test("^dev-|-dev$")|not)|"\(.name)\t\(.version)"' composer.lock)
  [ $nv = 0 ] && log "ok"
fi
echo "::endgroup::"

echo
if [ $fails -gt 0 ]; then log "RESULT: $fails check(s) failed, $warns warning(s)"; exit 1; fi
log "RESULT: passed${warns:+ with $warns warning(s)}"
