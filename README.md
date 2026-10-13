# Git workflow lab

A local, rebuildable Gitea + Packeton + Actions runner to test
[`shared-drupal-modules-workflow.md`](shared-drupal-modules-workflow.md) end to end on one machine.

## Quick start

Needs Docker with Compose, `git`, `curl`, `jq`. PHP/Composer are **not** needed on the host.
For the Drupal sites also install [DDEV](https://ddev.com) and run once:
`ddev config global --router-http-port=8080 --router-https-port=8443` (Packeton owns port 80) and `mkcert -install`.

```bash
git clone https://github.com/martinambrus/git-workflow.git && cd git-workflow
./lab hosts      # once: adds "127.0.0.1 gitea.test packeton.test" to /etc/hosts (sudo)
./lab up         # builds the runner image, starts everything, creates and clones the repos
./lab e2e        # scaffolds both Drupal sites if missing, then runs the WHOLE workflow with assertions
```

`./lab e2e` is the proof that everything works on your machine (measured here after `./lab up`: about 4.5 minutes with
warm Docker/Composer caches; expect longer on a cold machine, mostly Composer and the CI reinstalls). It prints PASS/FAIL per step and exits non-zero on any failure. It is re-runnable on a
used lab: each run releases the next patch version. `./lab e2e --quick` skips the smoke, customer and release-line tests; `./lab e2e lines` runs only the release-line
scenarios (about 3 minutes on a warm lab).
`./lab destroy -y` wipes everything (including DDEV sites and local clones) for a from-scratch run.

| What | URL | Login |
| --- | --- | --- |
| Gitea | http://gitea.test:3000 | `admin`/`admin12345` (main dev), `dev`/`dev12345`, `bot`/`bot12345` |
| Packeton | http://packeton.test | `admin`/`admin12345` |

The same URLs work on the host and inside containers/jobs, which is why the hosts entry is needed.
Everything is throwaway: the credentials are fixed, public and local-only.

## The scenario this lab runs

Two Drupal 11 sites share one module, `activit/ait_banners` (a sponsorship banner block). They are scaffolded
identically by `ops/bin/new-drupal-project.sh`; the differences come from what happens next:

| | shop-a | shop-b |
| --- | --- | --- |
| Shared module | `^1.0`, follows releases (update PRs) | `^1.0` too; can be pinned to an exact version to freeze it |
| Promo badge (module 1.1+) | not configured | "-20% this week" (set by the scaffold) |
| Client-only behaviour | none | `shop_b_banner_tiers`: a sponsor-tier label, an **extension module inside the project** (plan rule 8) |

Developers edit the shared module in place inside a project and push; the Upstream job turns that into a merge request
in the module repo; the main dev merges and tags; the Release job waits for Packeton and opens update PRs in every
opted-in project; the Checks job gates `main`. Everything from section 14.4 of the plan except real internet exposure
has been exercised (see the findings below). The numbered findings tell the story of the pilot run (releases 1.0.1 to
1.1.2, `shop-b` frozen at 1.1.1); a fresh lab starts from the **latest** module code tagged `v1.0.0`, so versions in
the findings differ from what you see on a replay.

## Release lines and client variants (verified by `./lab e2e lines`)

Run on disposable, uniquely named modules and minimal Composer projects (not shop-a/shop-b), so the version-line
logic is isolated and the scenario is re-runnable; everything goes through the real pipeline (Upstream, Release,
Update PRs, Checks, protected branches, Packeton grants). 68 assertions:

| Variant | Expected and verified |
| --- | --- |
| `2.0.0` (breaking) released on `main`, `1.x` cut from the last 1.x tag | the Release job succeeds and opens **no** update PR in any project on `^1.0`, nor in an opted-out or pinned one |
| Shared **extension package** (own repo, own Packeton package) requiring the base `^1.0` | `composer require base:^2.0` is refused because of the extension; the extension's own `2.0.0` needs base `^2.0`; the client then moves both together in one PR |
| Client deliberately moves to 2.x | by `composer require ^2.0` through a PR; stays on 1.0.1 until then |
| In-place fix by a client locked to 1.x | the Upstream MR targets the **`1.x`** branch (not `main`), module Checks run on that PR, tag `v1.0.2` is placed on `1.x`, update PRs reach only 1.x clients that opted in |
| Client whose support expired (no `activit-project` topic) / client pinned to exactly `1.0.1` | no update PRs for 1.x or 2.x releases |
| External customer, grant `<2.0`, `expiredUpdatesAt` in the past | sees exactly the releases from before the date; no 1.0.2, no 2.0.0; `composer` resolves the newest allowed; cannot resolve `^2.0`; anonymous: 401 |
| Same customer **re-subscribes** (grant widened, expiry cleared) | now sees 1.0.2 and 2.0.0; `composer update` stays on 1.x because the constraint is still `^1.0`; moves to 2.0 only by a deliberate `require ^2.0` |
| Internal client re-subscribes (topic added back) | receives the next 1.x patch release, then migrates to 2.0; its next in-place edit targets the **`2.x`** branch; a `2.0.1` tagged on `2.x` reaches every opted-in 2.x client |

29. **Real bug in the Upstream job since `v1.0.0`, found by this scenario:** the bot branch was cut from the module
    repository's *current default branch* instead of the locked tag (the script said "cut from the tag"). It only
    worked while `main` still equalled the tag; once `main` moved to 2.0.0 a project on 1.x could not send a fix
    (`patch does not apply`). Fixed in `ci-tools` **v1.3.1**; bump `upstream.yml` in existing projects.
30. The plan's rule "1.x if that branch exists, otherwise main" generalises to **`<locked major>.x` if it exists**;
    verified for both `1.x` and `2.x`.
31. **Maintenance branches are not protected automatically**: `./lab sync` protects `main` only. A real release line
    needs the same rule (PR only, Checks required) on `1.x`/`2.x`; the scenario creates it explicitly. Plan section 11
    should say so. The module `checks.yml` already triggers on PRs into `*.x`.
32. **Re-subscription is two separate decisions**: widening the grant (Packeton) lets the client *see* 2.x, but
    nothing moves until the project's constraint changes; and a client on 1.x keeps receiving 1.x fixes only. That is
    the behaviour the plan wants, but it means "re-subscribing" needs an explicit migration PR on the client side.
33. A `2.x` fix developed in a client lands on the `2.x` branch only; **forward-porting to `main` is not automated**
    (the plan mentions it as a manual follow-up).

34. **One unexplained intermittent failure.** Of the full from-scratch runs with these scenarios, one (the 2nd) failed
    in the release-line part: the `new` client's migration PR to 2.0 failed immediately (instant failure, not a
    Checks timeout) and the lock read for that repo came back empty. The identical commit then passed in 6 further runs
    (4 on a live lab, 2 from scratch). The likely class is Gitea's asynchronous handling of a repository that was
    created and pushed seconds earlier (as findings 25 and 27), but this was not proven. The harness now retries lock
    reads, states *why* a project change failed, and leaves the disposable repos in place on failure so the next
    occurrence can be diagnosed. If you hit it, re-run `./lab e2e lines` and open an issue with the printed reason.

## Fresh-machine replay (verified)

Done from a plain `git clone` of this repository on a machine that had been wiped of every lab container, volume,
network and image: `./lab up`, then `ops/bin/new-drupal-project.sh` for both projects, then a complete release cycle
with only the repo's own scripts: edit in place in `shop-a` -> Upstream MR -> module Checks green -> merge -> tag
`v1.0.1` -> Release job -> update PRs in **both** projects (by `bot`) -> project Checks green -> merged -> both sites on
`v1.0.1`. Also green on the replay: `./lab smoke`, `./lab external test`, and `./lab site` rebuilding a dropped database
from committed config.

The replay found three bugs that the incremental build had hidden (all fixed):

24. `./lab sync` protected `main` on empty repos, so a new project's first push was rejected. Protection is now applied
    once `main` exists.
25. Right after the first push Gitea's branch API does not list `main` yet (async), so protection was skipped silently.
    The scaffold now waits for the branch.
26. `./lab destroy` left the external proxy and its network behind (it only knew the `build` profile).

Re-testing with `./lab e2e` from a wiped machine (destroy, fresh clone, the three README commands) found two more
problems, both fixed; after that **two consecutive from-scratch runs passed 44/44** and a re-run on a used lab
passed 39/39 (it releases the next patch version):

27. After seeding the module, Gitea did not serve `main` for a moment, so `activit/ait_banners` was **never
    registered in Packeton** and the scaffold failed with "could not be found in any version". Same async-branch race
    as finding 25. Fixed in `seed_repo`/`register_package`; `./lab e2e` now heals with a `sync` and asserts the
    registration before doing anything else.
28. Drupal writes `config/sync/.htaccess` lazily, after the scaffold's commit, so a freshly scaffolded project had a
    dirty working tree and the release cycle (rightly) refused to start. It is now in the project's `.gitignore`.

Prerequisites on a new machine (the lab does not install them): Docker + Compose, `git`, `curl`, `jq`, `python3`,
DDEV with `ddev config global --router-http-port=8080 --router-https-port=8443`, `mkcert -install`, and (optional)
Google Chrome at `/opt/google/chrome/chrome` for the browser MCP.

## What `./lab up` creates

- **Gitea** (pinned image) with Actions on; orgs `activit` (modules) and `sites` (projects); team `devs`
  (users `dev` and `bot`, write access); org secrets `BOT_TOKEN` and `PACKETON_TOKEN`.
- **Packeton** (pinned image), admin user, read access to Gitea.
- **Runner** (`act_runner`) with labels `ubuntu-latest` and `activit-runner`, both running our own image
  `activit-runner:local` (PHP 8.3, Composer, git, curl, jq, openssh). Workflows must use `run:` steps only.
- Repos from [`lab.manifest`](lab.manifest): created in Gitea (or imported from a source URL, with history and
  tags) and cloned to `modules/<name>` and `projects/<name>`. Re-run `./lab sync` after editing the manifest;
  it clones missing repos and fast-forward pulls existing clean ones.
- For every module: protected tag pattern `v*` (only `admin` may tag), a push hook to Packeton, and
  registration in Packeton as soon as `main` has a `composer.json`.

## Day to day

```bash
./lab status | logs [svc] | down | destroy | reset
./lab composer require activit/ait_demo:^1.0     # Composer on the lab network, Packeton auth preloaded
```

Projects need `"secure-http": false` in `config` (Packeton is plain HTTP here), plus the repository entry:
`{ "type": "composer", "url": "http://packeton.test" }`.

## Where this lab differs from the plan (found while building it)

1. **No organization-wide webhook to Packeton.** With Gitea 28.1 the `gitea` webhook payload carries
   `repository.url` (the API URL), so Packeton's `/api/update-package` cannot match it to a package
   (`406 Missing or invalid payload`); Gitea's `packagist` hook type is hard-wired to packagist.org and cannot be
   created through the API. The lab creates a **per-repository** hook with `composer_package_name`, which works.
   Plan section 2.1/Appendix B should say so, or use Packeton's Gitea OAuth integration (not tried).
2. **Gitea 28 egress policy** blocks webhooks to private IPs by default: set `[security] EGRESS_MODE=lax` and
   `ALLOWED_HOST_LIST=private,loopback` (done in `docker-compose.yml`). Ops will hit this on any internal setup.
3. **Packeton reads private repos** through Composer's `auth.json` in `/data/composer` (HTTP basic with the bot
   token, key must include the port: `gitea.test:3000`). The plan's "read-only deploy key" was not used here.
4. Packeton exposes versions as `v1.0.1` (tag name kept); dist URLs are Packeton-built zipballs.

Verified by `./lab smoke`: protected tags refuse the bot, tag push reaches Packeton within seconds, an Actions job
with only `run:` steps runs in our image and can clone with `BOT_TOKEN`, `composer require` installs a dist archive.

Verified with the real Drupal projects (plan 14.4): `drupal-custom-module` lands in `web/modules/custom/<name>`
with the stock `drupal/recommended-project` installer paths; Packeton's archive honours `export-ignore` (no
`tests/`, no `.gitattributes` in the install); no nested `.git`; `composer update activit/ait_banners` moves a
project from `v1.0.0` to `v1.0.1`; DDEV web containers reach Packeton once joined to the `wf-net` network.
Verified through a full release cycle: MR merged, tag `v1.1.0`, Packeton indexed it in seconds; on the project that
developed the change (`shop-a`) `composer update` moved only `composer.lock` and Composer's vendor metadata, the module
folder stayed identical (plan 9.3) and the Upstream job then reported no drift; on `shop-b` the diff was exactly the
release (5 module files), `drush updb`/`cr` were clean, and the new "Promo badge" field appeared in the admin form.
Everything in plan 14.4 has now been exercised except real internet exposure (see "External customers" below).

5. **`drupal/recommended-project` ships no `.gitignore`**, so Drupal's runtime `web/sites/default/files/` would be
   committed (twig cache, `.htaccess` files). The projects add `web/sites/default/files/` and nothing else
   (plan section 3 should say so). `settings.php` is committed too, as plan rule 5 implies.
6. **Tag order:** registering a package in Packeton *after* its first tag was pushed worked (registration indexes
   existing tags), but the webhook only fires for registered packages. Register first, tag second (plan 4.3 order).
7. A quoted-colon bug in the first module release (`description: A: b` in `info.yml`) broke site install; fixed as
   `v1.0.1`, as the plan demands (tags are never moved).

8. **Composer silently falls back to its cache when Packeton returns 401.** It prints a warning, uses stale data and
   exits 0, so `composer update` reports "Nothing to modify" and a new release is never seen. Hit here after a lab
   rebuild regenerated the Packeton token. The lab now rewrites the credential on every `./lab site` and in
   `new-drupal-project.sh`. Worth a CI check for the string "could not be fully loaded" in real deployments.
9. **DDEV's `composer config --global` is per project** (each web container has its own Composer home), so the
   Packeton credential must be set in every project, not once.

## Drupal projects (DDEV)

`projects/shop-a` and `projects/shop-b` are Drupal 11 sites, each committed with `vendor/` and `web/`, each
requiring `activit/ait_banners` from Packeton.

```bash
./lab sync                                   # create + clone the repos
ops/bin/new-drupal-project.sh shop-a "Acme Corp" "Proudly supporting Shop A" '^1.0'
ops/bin/new-drupal-project.sh shop-b "Globex Ltd" "Proudly supporting Shop B" '^1.0'
```

| Site | URL | Login |
| --- | --- | --- |
| shop-a | https://shop-a.ddev.site:8443 | `admin`/`admin` |
| shop-b | https://shop-b.ddev.site:8443 | `admin`/`admin` |

**The database is never committed**: it lives in DDEV's Docker volume. Code and `config/sync/` are committed, and the
config export includes the enabled module and the placed banner block. So after cloning (or `./lab sync`):

```bash
./lab site shop-a        # or: ./lab site   (all projects)
```

starts DDEV and, when there is no database, runs `drush si --existing-config`, which rebuilds the site from the
committed config (verified: database dropped, site rebuilt, banner shows). Content is not preserved, only config.
`new-drupal-project.sh` itself refuses to run on an already scaffolded project.

`seed/modules/ait_banners/` holds the module's source. On a fresh lab `./lab sync` pushes it to the empty
`activit/ait_banners` repository and tags `v1.0.0` (this is the already-fixed code, i.e. what was `v1.0.1` in the
first run). After that, the module lives in Gitea and `modules/ait_banners` is its working clone.

## The Upstream job (ci-tools)

`activit/ci-tools` is a plain repository (kind `tool` in `lab.manifest`, source in `seed/tools/ci-tools`, tagged
`v1.0.0`). Project workflows clone it at a fixed tag and run `bin/upstream.sh`; the stub lives in
`seed/project-template/.gitea/workflows/upstream.yml` and is copied into every project.

What it does on every push to a project branch: reads the locked `activit/*` modules from `composer.lock`, compares
each module folder with `git archive` of its locked tag, and if they differ pushes **one cumulative commit** to
`up/<project>/<branch>` in the module repo, opens or updates the merge request (target `<major>.x` if that branch
exists, else `main`), and comments the link once on the project's pull request. The integrity check (module branch ==
project folder) runs **before** the push. Re-running is safe.

Verified here: `shop-a` branch `feature/promo-banner` (in-place edit of `ait_banners` locked to `v1.0.1`) produced
`activit/ait_banners#1`; re-runs update the same MR; `shop-b` (no drift) sends nothing; the job ran on the runner with
only `run:` steps; the bot token is passed through `GIT_CONFIG_*` env so it never appears in URLs or logs.
Packeton's archive and `git archive` of the tag are identical for this module (no false drift).

## Release and Update PRs jobs

`ci-tools` **v1.1.0** adds `bin/release.sh` and `bin/update-prs.sh`. The stub is
`seed/module-template/.gitea/workflows/release.yml` (module repos, on tag `v*`); projects opt in with the repository
topic `activit-project` (`./lab sync` sets it on every project in the manifest).

Verified with a real patch release (`v1.1.1`, an `aria-label` fix developed in place in `shop-a`): push -> Upstream MR
-> merge -> tag as `admin` -> Release job checked the tag, waited for Packeton, and opened `update/ait_banners-1.1.1`
PRs in **both** projects (authored by `bot`, body with the module diff stat and the 9.3/9.4 checklist) with no manual
step. Merging them worked, `shop-a`'s own fix branch stayed mergeable (identical content), and `shop-b` then served
the new markup. Re-running does nothing ("already on 1.1.1"); a malformed tag fails the job; an `-rc.1` tag stops after
the checks and opens no PRs.

10. In the project that developed the change the update PR only shows the release in the module folder **if the fix
    is not on `main` yet**; here `shop-a#2` showed the one-line template change because the fix was still on its
    feature branch. Both merge cleanly because the content is identical.
11. The Release job needs `composer` in the runner image (it validates `composer.json` and runs `composer update`
    for every project), and the bot needs write access to the project repos (team `devs` in org `sites`).

## Checks job and `main` protection (ci-tools v1.2.0)

`bin/check-project.sh` (projects, on PRs into `main` and on every push) implements plan checks 1-4; `bin/check-module.sh`
(module repos, on PRs, including the Upstream MRs) checks `composer.json`, PHP and YAML syntax (the `yaml` PHP
extension was added to the runner image; it would have caught the `v1.0.0` `info.yml` bug). `./lab sync` protects `main`
in every module and project: merge by PR only, status `checks / checks (pull_request)` required, **also for admins**.

Verified on the real runner and Gitea: direct pushes to `main` are rejected for `dev` and `admin`; a harmless PR passes
and merges; a PR with an unreleased in-place edit of the shared module gets `failure` and the merge is refused
(`405 Not all required status checks successful`) while the same branch's *push* check is only a warning; symlink
outside the project, gitlink and `dev-main` of our module in the lock all fail the PR check (negative tests on a
local bare repo); the bot's own update PR passes the gate; a project pinned to `1.1.1` is skipped by Update PRs
("its constraint '1.1.1' does not allow 1.1.2") while the other project gets its PR; `dev-up/<project>/<branch>`
installs from Packeton into a real project (`composer require activit/ait_banners:dev-up/...@dev`).

12. **Plan check 4 needs refining: `vendor/` is not byte-reproducible.** After a clean `composer install` from the lock,
    real package code was identical, but Composer's *generated* files differed: the autoloader suffix
    (`ComposerAutoloaderInit<hash>`), the order of `include_paths.php`, `DrupalInstalled::VERSIONS_HASH`, and the root
    package's own `reference`; one shipped file differed only by CRLF vs LF. A naive "reinstall and diff everything"
    fails on every project. The check compares package files, ignores Composer-generated metadata and CR-at-EOL, and
    instead verifies that the committed `vendor/composer/installed.json` matches `composer.lock`.
13. **Packeton keeps versions of deleted branches** (`dev-up/shop-b/test-inplace-drift` was still listed after the
    branch was deleted in Gitea). Harmless, but `dev-up/...` versions pile up; plan section 11 should mention cleanup.
14. **Checks are heavy**: each run reinstalls Drupal core (about a minute locally). The runner has `capacity: 2` and
    queued runs wait; push and PR events both fire for a PR branch. Fine for a pilot, size the runners accordingly.
15. Branch protection status contexts are named `<workflow> / <job> (<event>)`, here `checks / checks (pull_request)`;
    they only exist after the first run, so the stub must be on `main` before the rule can be meaningfully required.

## External customers (plan section 10) and Packeton housekeeping

`./lab external up` starts `ext-proxy` (nginx, TLS from mkcert) on a **separate Docker network `wf-ext`**; the proxy is
the only thing on that network that reaches Packeton. `./lab external test` creates a Unipo-like customer (group
`unipo`, grant `activit/ait_banners` `<1.1`) and installs from a container that can reach nothing but
`https://packeton-ext.test`.

Verified: from the customer network Gitea and Packeton's internal address are unreachable (`000`) while the proxy
answers `200`; anonymous requests get `401`; the customer installs `v1.0.1` as a dist zip over HTTPS with only the
mkcert CA trusted and **cannot** resolve `^1.1` ("found [v1.0.0, v1.0.1] but it does not match the constraint");
dist URLs carry the external scheme and host (`https://packeton-ext.test/zipball/...`, Packeton honours the
`X-Forwarded-*` headers); lifting the version limit shows all releases; a group/user `expiredUpdatesAt` of
2026-10-10 with 1.0.x back-dated before it and 1.1+ after it left the customer on exactly `v1.0.0 v1.0.1`, and
moving the date forward restored everything (the freeze of plan section 10).

16. **Packeton leaks the internal Gitea clone URL to customers** as `source.url` in every package's metadata, and has
    no setting to hide it. Harmless for dist installs, but it discloses the internal hostname. The lab's proxy rewrites
    it (`sub_filter` to `git.internal.invalid`); in production either do the same or use an internal-only hostname.
17. **Expiry has two meanings**: `expiredUpdatesAt` freezes the customer on what was released before the date (the
    plan's behaviour); a user's `expireAt` is an account expiry that locks them out entirely. Pick deliberately.
18. **Packeton never drops vanished branches**: after a branch is deleted its `dev-...` version stays until
    `packagist:update <pkg> --delete-before`. `./lab prune` deletes branches without an open PR in all repos and runs
    that update for registered packages (the effect shows after a few seconds). Repos are also set to "delete branch
    after merge" by default, but merges through the API must pass `delete_branch_after_merge`.
19. Packeton lists pre-release tags (`v1.2.0-rc.1`) in its stable metadata; customers only get them when their
    `minimum-stability` allows it. The Release job opens no update PRs for them.
20. Not verified (cannot be locally): real internet exposure, a publicly trusted certificate, rate limits.

## Client-only behaviour: extension module and patches (plan rule 8, section 11)

**Extension module (first choice).** `projects/shop-b/web/modules/custom/shop_b_banner_tiers` adds a "Sponsor tier"
select to the shared block's configuration form and wraps the rendered banner in a tier label. It uses only core hooks
(`hook_form_block_form_alter`, `hook_block_view_BASE_alter`) and never touches `activit/ait_banners`. Verified: it is
invisible to the Upstream job (no MR, no bot branch), the Checks gate passes (its folder is not Composer-managed, so a
clean reinstall leaves it alone), `shop-a` is unaffected, and it is rebuilt on a fresh lab from
`seed/project-extras/shop-b/` by `new-drupal-project.sh`.

21. **Drupal gotcha found while writing it:** core's own block `#pre_render` does `unset($build['#block'])`, so a
    `#pre_render` appended in `hook_block_view_*_alter` cannot read the block entity. Read what you need in the alter
    hook and carry it on the build array (`#shop_b_tier`).

**Patch file (second choice).** Tested with `cweagans/composer-patches` v2 on a throwaway branch of `shop-a`:

22. **A patched shared module looks like an in-place edit to the Upstream job.** The Checks gate passes (a clean
    reinstall re-applies the patch from `patches.lock.json`, so the patched folder *is* reproducible), but Upstream
    compared the folder with the raw archive of the tag and opened a green merge request proposing the Shop A-only
    patch to the shared module, where a reviewer could merge it for everybody. Fixed in `ci-tools` **v1.3.0**:
    Upstream reverses the module's `extra.patches` before comparing, so only real edits travel upstream (verified: a
    patched module alone sends nothing; patch + a real edit sends only the edit). A patch that cannot be reversed
    fails the job loudly.
23. Smaller facts from the same test: `allow-plugins.cweagans/composer-patches` must be enabled per project (put it
    in the project template); editing `extra.patches` changes the lock's content hash, so `composer update --lock`
    is required (the Checks job caught my forgetting it: "composer.lock is not up to date with composer.json");
    `composer reinstall`/`update` replaces an edited module folder without prompting (dist install).

## Browser checks (optional)

`.claude/mcp_settings.json` configures the Chrome DevTools MCP server (`npx chrome-devtools-mcp`) so Claude Code can
open the DDEV sites, click through the Drupal admin and take screenshots. Needs Node.js and **Google Chrome stable
installed at `/opt/google/chrome/chrome`** (the `.deb` from google.com/chrome; Chromium or Firefox will not do).
Gitea shows private repos as 404 until you log in, so sign in as `admin` first.

## Layout

```
lab                    CLI entry point          lab.manifest   repos to create/clone
ops/docker-compose.yml stack (pinned images)    ops/runner/    runner image + act_runner config
ops/bin/               bootstrap, sync, smoke,  ops/.state/    generated tokens (gitignored)
                       new-drupal-project,      seed/            module, ci-tools and project-template sources
                       site-up, external, prune (pushed to empty repos by ./lab sync;
                                                 module-template: module workflow stubs;
                                                 project-extras: per-project extension modules)
modules/  projects/    working clones (gitignored; each is a repo in Gitea)
```
