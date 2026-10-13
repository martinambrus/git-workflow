# Git workflow lab

A local, rebuildable Gitea + Packeton + Actions runner to test
[`shared-drupal-modules-workflow.md`](shared-drupal-modules-workflow.md) end to end on one machine.

## Quick start

Needs Docker with Compose, `git`, `curl`, `jq`. PHP/Composer are **not** needed on the host.

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
Not yet verified: export-ignore in Packeton archives, `dev-up/...` branch installs, customer limits (plan 14.4).

## Layout

```
lab                    CLI entry point          lab.manifest   repos to create/clone
ops/docker-compose.yml stack (pinned images)    ops/runner/    runner image + act_runner config
ops/bin/               bootstrap, sync, smoke   ops/.state/    generated tokens (gitignored)
modules/  projects/    working clones (gitignored; each is a repo in Gitea)
```
