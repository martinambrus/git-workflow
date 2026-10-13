# Git workflow lab

A local, rebuildable Gitea + Packeton + Actions runner to test
[`shared-drupal-modules-workflow.md`](shared-drupal-modules-workflow.md) end to end on one machine.

## Quick start

Needs Docker with Compose, `git`, `curl`, `jq`. PHP/Composer are **not** needed on the host.
For the Drupal sites also install [DDEV](https://ddev.com) and run once:
`ddev config global --router-http-port=8080 --router-https-port=8443` (Packeton owns port 80) and `mkcert -install`.

```bash
git clone <this repo> && cd <this repo>
./lab hosts      # once: adds "127.0.0.1 gitea.test packeton.test" to /etc/hosts (sudo)
./lab up         # builds the runner image, starts everything, creates repos, clones them
./lab smoke      # optional: end-to-end self-test of the stack
```

| What | URL | Login |
| --- | --- | --- |
| Gitea | http://gitea.test:3000 | `admin`/`admin12345` (main dev), `dev`/`dev12345`, `bot`/`bot12345` |
| Packeton | http://packeton.test | `admin`/`admin12345` |

The same URLs work on the host and inside containers/jobs, which is why the hosts entry is needed.
Everything is throwaway: the credentials are fixed, public and local-only.

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
Not yet verified: `dev-up/...` branch installs, customer limits, frozen/out-of-range projects in Update PRs.

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
                       site-up                  (pushed to empty repos by ./lab sync)
modules/  projects/    working clones (gitignored; each is a repo in Gitea)
```
