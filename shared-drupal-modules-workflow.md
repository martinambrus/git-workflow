# Shared Drupal modules: developer workflow

*Draft for the Elmont call | 8 October 2026, revised 13 October 2026 with the decisions in section 14, revised 14 October 2026 after the pilot lab, and 19 October 2026 (per-project Packeton users, the Packeton visibility check, forward-ports merged only): everything below ran against Gitea 28.1, Packeton, a Gitea Actions runner, Composer and two Drupal 11 projects, unless section 14 lists it as open. The evidence (findings 1 to 47) is in the lab's `README.md`; `manual/TASKLIST.md` is the step-by-step setup guide for Ops.*

## 1. The rules in one minute

1. Every shared module is its own Git repository in Gitea. The repository root is the module folder.
2. A version is a Git tag (`v1.4.0`), created only by a main dev, or by the bot on a main dev's `/release` reply (protected tags). Tags are never moved or re-used: a fix is a new version.
3. Packeton (self-hosted, open source) is the only Composer registry, for our own projects and for external customers. A webhook on each module repository tells Packeton about every new tag or branch, and Packeton reads the module repositories directly. Nothing is uploaded by hand.
4. Projects install shared modules with Composer from Packeton, as archives. Nobody runs `git clone` into a project, so there is never a nested `.git` folder.
5. Projects commit everything, including `vendor/` with dev dependencies and the module code, and are deployed from Git. A plain `git clone` of a project is all a developer needs for the code.
6. Developers edit shared module code in place, inside the project, where they can run and debug it, then commit and push as usual. A Gitea Actions job sends the difference to the module repository as a merge request. The main dev reviews it and merges and releases it **from the developer's pull request** with two replies (`/merge`, `/release`); the release then lands in that same pull request, which the developer merges.
7. A project moves to a new module version only through an explicit, reviewed change: the developer's own pull request (above), an update pull request (opened automatically for opted-in projects) or `composer update activit/<module>` by hand. Nothing updates by itself.
8. Module branches are release lines only: `main` for the newest major, `<N>.x` for each older major still supported. A fix merged into an old line is forward-ported to the newer lines automatically; releasing it there is one reply.
9. Client-only behaviour lives in an extension module in the client's project, or in a patch file. There are no per-client branches in module repositories.
10. Everything runs inside our own infrastructure: Gitea, its runners and Packeton. Workflows use no actions from github.com.

Releases flow one way: module repository, tag, Packeton, Composer, project, Git deploy. Fixes flow back the other way: project, push, merge request in the module repository. Gitea Actions does the moving in both directions (section 12); people edit, review and decide, mostly by replying in the pull request they are already looking at.

**Which module version does a project use?** Not a branch. Each project's own `composer.json` (the allowed range) and `composer.lock` (the exact version) decide:

| Project | `composer.json` | `composer.lock` pins | Effect |
| --- | --- | --- | --- |
| Client 1 | `"activit/ait_demo": "^1.4"` | 1.4.2 | moves only when someone updates it, and only within 1.x |
| Client 2 | `"^2.0"` | 2.1.0 | on the 2.x line |
| Frozen | `"1.4.2"` | 1.4.2 | never moves, not even with `composer update` |
| Unipo (external) | `"^1.4"` | up to what their Packeton grant allows | Packeton limits what they see |

Moving a project to a new major version is one deliberate `composer require activit/ait_demo:^2.0`. Developers work on branches of the project, as they do today. The Upstream job creates the module-side branch itself and picks its target from the locked version: 1.4.2 goes to `1.x` if that branch exists, otherwise to `main`.

Roles used below: **Dev A** and **Dev B** (any developers), the **Main dev** (owns releases: reviews module merge requests, merges and releases them, manages Packeton customers; in Gitea a member of the module organization's **Owners** team), **Ops** (runs Gitea, the runners and Packeton), **Management** (sets support and grant dates per client and contract) and **Unipo**, the example of an external customer who only ever talks to Packeton, never to Git or Gitea.

Names in the examples: module `activit/ait_demo`, projects `shop-a` (on 1.x) and `shop-b` (on 2.x), branch `feature/promo-banner`. Replace `<module-repo>`, `<project-repo>`, `<gitea-host>`, `<packeton-host>` and `<org>` with your own.

## 2. One-time setup

**2.1 Gitea and runners (Ops).**

- Gitea Actions is on by default in Gitea 28; register at least one runner (`act_runner`) whose labels point at our own image (`ubuntu-latest:docker://<image>`, `activit-runner:docker://<image>`), so nothing is pulled from Docker Hub at job time. Size it for the Checks: each run reinstalls Drupal core from `composer.lock` (about a minute), and a pull request branch fires both a push and a pull request run.
- The runner image: `git`, `curl`, `jq`, `openssh-client`, `patch`, `perl`, PHP (the version your projects use, with the extensions Composer needs and `yaml`) and Composer. Push it to Gitea's container registry (`<gitea-host>/<org>/runner:<tag>`; *the registry itself is still open, section 14*).
- Runners have outbound internet access for Composer (packagist.org and packages.drupal.org for third-party packages). They do not use github.com actions (2.4).
- Gitea 28 refuses webhooks to private addresses. Allow Packeton's address in `app.ini`: `[security] EGRESS_MODE = lax` and `[webhook] ALLOWED_HOST_LIST = private,loopback` (or Packeton's host only). Disable self-registration and set the default branch to `main`.
- Create the organizations `activit` (modules, `ci-tools`) and `sites` (projects), and a team `devs` with general **Write** on all repositories in both. Add the developers and the bot account to it. The main devs are the members of `activit`'s **Owners** team: the bot checks that team before it acts on a `/merge` or `/release` reply.
- The bot is an ordinary user (type *Individual*). Its token has `write:repository`, `write:issue`, `write:organization`, `read:user`; store it as the organization secret `BOT_TOKEN` in both organizations, together with the bot's Packeton token as `PACKETON_TOKEN` (2.2).
- Create the shared `ci-tools` repository (the scripts every workflow calls, tagged; 2.4). The workflow stubs for modules and projects live in the template material (`seed/module-template`, `seed/project-template` in the lab).
- Protection, the same in every module repository: tag pattern `v*` may be created by the main devs and the bot only; branch rule `main` and branch rule `[0-9]*.x` (one glob rule covers `1.x`, `2.x`, `1.2.x` but not `feat.x`): pull requests only, **Enable Status Check** with the context `checks / checks (pull_request)`, and **Administrators must follow branch protection rules**, so nobody, not even an admin, can force-merge a red pull request. On `[0-9]*.x` the main devs and the bot are on the push allowlist, because creating a release line is a push (the bot creates one with `/release_major`, 8.3). Project repositories get the `main` rule only. In every repository tick **Delete pull request branch after merge by default**.
- There is no organization webhook: Gitea's payload cannot be matched to a package by Packeton, so each module repository gets its own webhook when it is created (4.3).

**2.2 Packeton (Ops).**

- Run Packeton from its Docker image (`packeton/packeton`) with a persistent volume for `/data`, behind HTTPS at `<packeton-host>`. Create the admin user with `bin/console packagist:user:manager <name> --password=<password> --admin`.
- Keep anonymous access off (`PUBLIC_ACCESS=false`, the default): anonymous requests get 401.
- Give Packeton read access to the module repositories: a Composer `auth.json` in Packeton's Composer home (`/data/composer`) with the bot token as HTTP basic credentials for the Gitea host, **including the port** if it has one (`<gitea-host>:3000`), and `config.json` with `secure-http: false` for a plain-HTTP internal Gitea. An SSH deploy key is the alternative (not tried).
- Each module repository is registered once as a package (4.3). Packeton indexes every tag as a version and every branch as a `dev-<branch>` version (`1.x-dev` for a release line).
- Packeton is the only part reachable from outside, for external customers (section 10). Gitea stays internal. Packeton's metadata shows the internal Gitea clone URL as `source.url`; rewrite it in the TLS proxy or use an internal-only hostname.
- Accounts: the admin's API token for the modules, the bot and CI (the organization secret `PACKETON_TOKEN`); each project has its own Packeton user and token (plan 10, 2.3), so Packeton limits what each project gets; and one customer user or group per external customer with that customer's limits (section 10).

**2.3 Every developer machine.** Git with access to the project and module repositories, PHP, Composer and your usual local site setup. For Composer, create a Packeton token and add it with `composer config --global http-basic.<packeton-host> <username> <token>`. With DDEV, put it in `~/.ddev/homeadditions/.composer/auth.json` instead: DDEV copies it into every project's container on each start, while `ddev composer config --global` is lost on `ddev poweroff`. The token is only needed for `composer require` and `composer update`, never for cloning or running a project. A project has its own Packeton user and token (plan 10), kept in an `auth.json` in the project folder that is never committed; the shared token is the fallback for projects without one.

- When Packeton answers 401 (a rotated or missing token), Composer prints one warning, uses its stale cache and **exits 0**: `composer update` then says "Nothing to modify" and a new release is never seen. If a release does not arrive, check the credentials first. CI jobs use a private cache and fail on that warning.
- Scripts and CI that drive `ddev` must close stdin (`</dev/null`): `ddev composer ...` started with an open, silent stdin hangs without printing anything.
- A fresh clone has the code but no database: `drush si --existing-config` rebuilds the site from the committed `config/sync` (content is not preserved), or use the team's dump process.

**2.4 Workflows without github.com.** Gitea resolves an unqualified `uses: actions/checkout@v4` against github.com by default, so our workflows contain no `uses:` steps at all. Every step is a `run:` step in our runner image. A workflow fetches `ci-tools` at a fixed tag with the bot token and runs a script from it:

```yaml
- name: Upstream
  env:
    BOT_TOKEN: ${{ secrets.BOT_TOKEN }}
  run: |
    git clone -q --depth 1 --branch v1.9.11 \
      "http://bot:${BOT_TOKEN}@<gitea-host>/activit/ci-tools.git" /tmp/ci-tools
    export GITEA_URL="${{ github.server_url }}" REPOSITORY="${{ github.repository }}" \
           BRANCH="${{ github.head_ref || github.ref_name }}"
    /tmp/ci-tools/bin/upstream.sh
```

Checking out the repository the workflow runs in is also a plain `git clone` with the bot token, done by the `ci-tools` script; the token goes in through `GIT_CONFIG_*` environment variables, never into URLs or logs. `ci-tools` tags are never moved: change a script, tag a new version, bump the tag in the stubs, and copy the new stubs into existing repositories through a pull request. Comment replies (`/merge`, `/release`) run the `commands.yml` of the repository's **default branch**: until it is there, replies do nothing at all.

**2.5 Project template.** Add Packeton to the `repositories` array and force archive installs. `preferred-install` is committed with the project, so it applies to everyone without any per-machine setup. The project template also carries the workflow stubs `checks.yml`, `upstream.yml` and `commands.yml` (section 12).

```json
{
  "repositories": [
    { "type": "composer", "url": "https://<packeton-host>" }
  ],
  "config": {
    "preferred-install": { "*": "dist" },
    "allow-plugins": { "cweagans/composer-patches": true }
  }
}
```

Checks on the template: `extra.installer-paths` maps the package type `drupal-custom-module` to `web/modules/custom/{$name}` (`drupal/recommended-project` does); `drupal/recommended-project` ships **no** `.gitignore`, so add one that ignores `web/sites/default/files/` and `config/sync/.htaccess` (Drupal writes the latter after the first commit) but never `vendor/`, `web/core` or the module folders; commit `settings.php` with `$settings['config_sync_directory'] = '../config/sync'` placed **before** DDEV's include; and install without `--no-dev`, because dev dependencies are committed and deployed (14.1, decision 6).

## 3. Create a project (once per site)

Start from the project template: it carries the Composer settings, the `.gitignore` rules and the workflow stubs.

```bash
composer create-project drupal/recommended-project shop-a   # or your agency template
cd shop-a
# apply 2.5, then check that nothing important is ignored (this must print nothing):
git init
git check-ignore -v vendor web/core web/modules/contrib web/modules/custom
git add -A && git commit -m "Initial project, vendor and web committed"
git remote add origin <project-repo> && git push -u origin main
```

If scaffold files are still ignored, look at the `gitignore` option of `drupal/core-composer-scaffold`.

**After the first push** (Gitea cannot protect an empty repository, and its topic field only appears once there is code): protect `main` (2.1), tick "delete branch after merge" and add the repository topic `activit-project` if the project should receive update pull requests (section 9). New projects from the start of the Elmont project get the topic; existing projects only once they are refactored or migrated to this workflow. Gitea lists a just-pushed repository's branch with a delay of a few seconds; scripts that protect or read a repository right after its first push must wait until `main` exists and the repository no longer reports `"empty": true`.

Dev-only modules (for example `devel`) are committed and deployed like everything else, but stay disabled on production until someone needs them for debugging. Keep them out of the configuration that is imported on production, for example with `config_exclude_modules` in `settings.php` or a config split.

## 4. Create a new shared module (once per module)

**4.1 Create the repository.** In Gitea create `ait_demo` in the `activit` organization, private and empty, and clone it into a scratch folder, not inside a project:

```bash
git clone <module-repo> /tmp/ait_demo && cd /tmp/ait_demo
```

Then apply 2.1's protection to it: tag pattern `v*`, branch rules `main` and `[0-9]*.x`, delete branch after merge.

**4.2 Add the skeleton.** Copy the module template (its `.gitea/workflows/`: `checks.yml`, `release.yml`, `release-reminder.yml`, `forward-port.yml`, `commands.yml`) and the two files below; change the names. Do not put a `version` key in `composer.json`; the tag is the version. Keep a `.gitattributes` that marks `/tests`, `/.gitea` and `/.gitattributes` as `export-ignore`: Packeton's archives honour it exactly like `git archive`, so tests and CI files never reach a project, and changes to them never need a release.

`composer.json`:

```json
{
  "name": "activit/ait_demo",
  "description": "Short description.",
  "type": "drupal-custom-module",
  "license": "GPL-2.0-or-later",
  "require": { "drupal/core": "^10.3 || ^11" }
}
```

`ait_demo.info.yml`:

```yaml
name: AIT Demo
type: module
description: Short description.
package: Activit
core_version_requirement: ^10.3 || ^11
```

Push `main` without a tag yet.

**4.3 Register it in Packeton and add its webhook.** Register first, then tag: the webhook only reaches registered packages.

- Packeton: **Submit** the repository's clone URL (repository type VCS). Packeton lists `dev-main` within seconds.
- Gitea, in the module repository: *Settings → Webhooks → Add webhook → Gitea*, target `https://<packeton-host>/api/update-package?username=<user>&apiToken=<token>&composer_package_name=activit/ait_demo`, content type JSON, events *push*, *branch or tag creation*, *branch or tag deletion*. The `composer_package_name` parameter is what lets Packeton find the package; a webhook without it, and an organization webhook, answer `406 Missing or invalid payload`. The test delivery answers 202.

**4.4 Release 1.0.0.**

```bash
git tag -a v1.0.0 -m "First release" && git push origin v1.0.0
```

Packeton lists 1.0.0 within seconds, and the Release job (section 12) goes green. If the version does not appear, check the webhook's recent deliveries in Gitea, then use the update button on the package page.

**If the module started as a prototype inside a project**, move it out together with its history:

```bash
git subtree split --prefix=web/modules/custom/proto -b extract-proto
git push <module-repo> extract-proto:main
```

In the new repository add `composer.json` (see 4.2), push it, register it in Packeton and tag `v1.0.0`. Then in the project delete the folder, run `composer require activit/proto:^1.0` and commit.

## 5. Put the module into the project

```bash
cd shop-a && git switch -c add-ait-demo
composer require activit/ait_demo:^1.0
find web/modules/custom/ait_demo -name .git     # must print nothing
drush en ait_demo -y && drush cex -y            # enable and export config, as your project does
git add -A && git commit -m "Add activit/ait_demo 1.0.0"
```

Merge through the usual project merge request. While a module is on 0.x, `^0.1` accepts only 0.1.x, so release 1.0.0 before the first production use. After a module update that changes rendering, the site may need `drush cr`.

## 6. Work on the module (Dev A)

**6.1 Branch.** In the project: `git switch -c feature/promo-banner`.

**6.2 Edit in place.** Change files in `web/modules/custom/ait_demo/` and run and debug on the real site. The module folder has no `.git` of its own, so Git commands run there act on the project repository.

**6.3 Commit.** Commit as usual. Module and project changes may share a commit: only the difference in the module folder is sent upstream. Write messages that make sense on their own, because the module merge request lists them.

**6.4 Push the project branch and open the pull request** into `main`: `git push -u origin feature/promo-banner`.

**6.5 The Upstream job sends the module changes.** It runs when a project pull request is opened or gets new commits (section 12). A plain branch push does not open a merge request, so a branch in progress reaches the module repository only once its pull request exists. It compares each of our module folders with the release the project is locked to, after reversing the client patches the project declares for that module (11). If a folder differs, the job:

- cuts a bot branch in the module repository (`up/shop-a/feature-promo-banner`) **from the locked tag**, never from a moving `main` or `1.x`, applies the difference as one cumulative commit listing the project commits and their authors, checks that the branch reproduces the project folder exactly, and pushes it (not again when an identical branch is already there, so its Checks do not restart);
- opens or updates a merge request into `<locked major>.x` if that branch exists, else `main`;
- comments once on the developer's pull request: "**This pull request changes the shared module `activit/ait_demo`** … it becomes mergeable when that change is released … **Main devs:** review the change in …, then reply here with `/merge activit/ait_demo#N`".

If the change is already merged into the module but not released (for example the pull request was opened after the merge), the job opens no second merge request; its comment asks for `/release` instead. If nothing differs, the job does nothing.

- Re-running is safe: the job rebuilds the bot branch from scratch every time, so a second developer's push simply updates the same merge request.
- Answer review comments by changing the project and pushing again. Never commit to a bot branch (`up/...`) by hand, and ignore Gitea's "This branch is out-of-date with the base branch" there: the branch is cut from the locked release on purpose, and a commit added by *Update branch by merge* would be thrown away by the next push.
- If another in-place change to the same lines was merged into the line since that release, the merge request conflicts; the main dev resolves it, or releases the earlier change first so that the project updates and sends again.

**6.6 Keep working.** The project branch runs on the in-place code. Its Checks report drift in our own module: a warning on branch pushes, a failure on the pull request into `main`, so the pull request stays red and cannot be merged (not even by an admin, 2.1) until the release lands in it (9).

## 7. Another developer continues (Dev B)

**7.1 Clone.** `git clone <project-repo>`. Everything is there: vendor, the module code and Dev A's commits. No Composer and no Packeton token are needed; set up the database and files as usual (2.3).

**7.2 Switch.** `git switch feature/promo-banner`.

**7.3 Work.** Edit, test, commit and `git push`.

**7.4 Nothing more to do.** The push runs the Upstream job again, and the same module merge request is updated with Dev B's changes. Dev A and Dev B do not need to agree on who sent which commit: the job rebuilds the merge request from the project's current state each time.

## 8. Review and release (Main dev)

Everything here can be done **from the developer's pull request in the project**; the bot's comments there always end with the reply to give. Only main devs (the `activit` Owners team) can use the replies; anybody else gets "only main devs … can run". The comment is read by its id through the API, never pasted into a shell.

**8.1 Review and merge.** Review the module merge request the bot opened (the link is in its comment). Requests for changes go back to the developer, who changes the project and pushes again. Then reply in the developer's pull request:

```
/merge activit/ait_demo#N
```

The bot merges the merge request (only the one opened for this pull request, only with green Checks; while they still run, Gitea merges it as soon as they pass). A reminder follows, in the merge request and in the developer's pull request: "merged, not released yet … reply `/release activit/ait_demo v1.4.3`", with the next patch version of that line. Merging in the module repository works too; the reminder appears all the same.

**8.2 Pick the version.** Patch (`1.0.1`) for bug fixes, minor (`1.1.0`) for backwards-compatible features, major (`2.0.0`) for breaking changes or for dropping a Drupal core version, which also starts a new release line (section 11). The reminder suggests the next patch; use a minor if the change adds a feature.

**8.3 Release.** Reply in the developer's pull request:

```
/release activit/ait_demo v1.4.3
```

The bot tags the version on the project's line (`<major>.x` if it exists, else `main`). It refuses a version that exists or is not newer than the line's latest, one from another major line than the project's, a module this pull request does not change, and a release that would contain no change to the package (only `export-ignore` files changed). A new major is released with `/release_major` in the project's pull request, not with `/release`: `/release_major activit/ait_demo 2.0.0`. The release reminder names it. It is refused unless the project is locked to 1.x, the module has no `2.x` line and no `v2.*` tag, and main's last 1.x release is the newest thing on main. The bot then creates the `1.x` line at that release, merges the module merge request into `main`, tags `v2.0.0` on the merge commit and raises the pull request's constraint to `^2.0` (ci-tools v1.9.1, v1.9.5). Other projects do not move to 2.0; their own update pull requests and constraints decide.

By hand it is the same:

```bash
git switch 1.x && git pull
git tag -a v1.4.3 -m "Promo banner block" && git push origin v1.4.3
```

or in Gitea's web interface (*Code* → branch dropdown → select the **release line** → *Tags* → *Create tag*; the Tags page has no create button, and a tag is cut from the branch selected, which defaults to `main`). The tag push does two things: the webhook makes Packeton index the version, and the Release job checks the tag and then delivers it (section 9). Never move or re-use a tag; a mistake is fixed by the next patch version.

**8.4 Announce.** Check that the version appears in Packeton and that the Release run is green. Post one line in the team channel: module, version, what changed, which projects should update.

## 9. Apply a release to a project (when the project decides)

**Which projects receive releases automatically.** Projects with the repository topic `activit-project`: every new project from the start of the Elmont project, and existing projects once they are refactored or migrated to this workflow. A project whose constraint does not allow the version (another major, an exact pin) is skipped, topic or not.

**The project where the change was developed** gets the release **in the developer's own pull request**: the Release job runs `composer update activit/ait_demo` on that branch and pushes one commit ("Update activit/ait_demo to 1.4.3", never forced), with a comment carrying steps 9.3 and 9.4. The Checks turn green and the developer merges the pull request as usual; run `git pull` before pushing to that branch again. If `main` changed `composer.lock` meanwhile, the pull request conflicts, and the bot's comment gives the fix: merge `main`, take main's version of the conflicted Composer files (`git diff --name-only --diff-filter=U | xargs git checkout --theirs --`), `composer update activit/ait_demo`, commit, push.

Any other open project pull request that carries the change and whose own constraint allows the release gets it the same way, even when the project's default branch does not (ci-tools v1.9.10: a pull request that pinned the project back to an older line). When that is not safe, the project gets a normal update pull request instead (below), and the developer's pull request a comment saying what to do: several open pull requests change the module (each one whose change is in the release and that changes nothing else is closed as superseded, its branch deleted, *Restore branch* undoes it), the branch moved meanwhile (the bot never force-pushes), or its module change is not fully released yet (it stays open).

**Every other project** gets an update pull request `update/ait_demo-1.4.3`: the Update PRs step runs `composer update activit/ait_demo`, commits everything including `vendor/` and `composer.lock`, and opens the request; a reviewer then does 9.3 and 9.4. It is never merged automatically: for that project the release is new code from elsewhere. Until the job runs, or when you want to update by hand, follow all the steps below, per project, on a clean working tree.

**9.1 Where to start.** Start from main:

```bash
git switch main && git pull && git switch -c update/ait_demo-1.4.3
```

**9.2 Update only this package.**

```bash
git status                           # must be clean
composer update activit/ait_demo     # add -w only if Composer asks for dependency updates
git diff --stat
```

Moving to a new major version, or off 0.x, needs a new constraint first: `composer require activit/ait_demo:^2.0`.

**9.3 Read the diff.** In any other project the diff is the release: everything since the version it had, not only the change that triggered the release. If the diff removes something of yours, it was never sent upstream: stop, check why the Upstream job did not send it (6.5), release, then update.

**9.4 Test and deploy.** Run what the project's deploy needs (for example `drush updb -y`, `drush cim -y` and `drush cr` on staging), then merge into `main` and deploy from Git.

**9.5 Overview and rollback.** `composer outdated --minor-only "activit/*"` shows the newer versions within the project's constraint (without `--minor-only` Composer shows the newest version of any major). To roll back, `git revert` the update commit (code and `composer.lock` go back together) and redeploy; database and configuration changes need their own plan.

## 10. External customers (for example Unipo)

External customers never get Git or Gitea access. They use Composer against Packeton, which is reachable from outside; Gitea stays internal and has no customer organizations or accounts.

**Management** decides, per client and per contract, which packages and versions a customer gets and until when (support and grant dates). These dates are not fixed in this plan.

**Main dev, in Packeton** (*Settings → My groups / My users*).

- A group per customer (*Create group*): name, and per granted package a **Version** constraint from the contract (`<2.0` for the 1.x line, `*` for everything).
- A user per customer (*Create user*): enabled, **no password** (API access only), *Full read access* and *Maintainer* not ticked, the customer's group under *ACL Groups*. Hand over the repository URL and the user's API token (`packagist:user:manager <user> --show-token`).
- **Support ends:** set the user's **Update expiration date**. The customer then sees only the versions released before that day and stays on them; their installs keep working. Do **not** use the *Access expiration date* for this: it locks the customer out completely.
- **Renewal, for example with 2.x:** clear the date and widen the group's version. The customer now *sees* 2.x, but their project stays on 1.x with `composer update` until they deliberately run `composer require activit/ait_demo:^2.0`.

Verified as the customer: anonymous 401; a package outside the grant 404; only the granted versions visible, no `dev-` versions; `composer require` takes the newest allowed version and a constraint outside the grant fails.

**Customer, in their own project.**

```bash
composer config repositories.activit composer https://<packeton-host>
composer config http-basic.<packeton-host> <customer-user> <customer-token>
composer require activit/ait_demo
composer update activit/ait_demo     # later: only what their grant allows
```

When the grant ends nothing breaks: they stay on the last version they were allowed, and development goes on for everyone else.

## 11. Special cases

**Test unreleased module code in another project.** Packeton serves every branch of a module repository as a `dev-` version, including the bot branches, so `composer require activit/ait_demo:dev-up/shop-a/feature-promo-banner@dev` installs exactly what the Upstream job sent. A pre-release tag (`v1.1.0-rc.1`, required with `^1.1@RC`) is the alternative; the Release job opens no update pull requests for it. Either way `composer.lock` must never keep a pre-release or `dev-` version of our modules on `main`; the Checks reject it. Packeton keeps the `dev-` version of a deleted branch until the package is re-read with `packagist:update <pkg> --delete-before`; do that from time to time.

**You need it now, before a tag exists.** Ask the Main dev for a patch release: it is two replies and a minute; merging a project with unreleased module code is not possible.

**The change adds a PHP dependency.** Dependencies are read from the module's `composer.json` only when the module is installed. While developing, `composer require` the library in the project as a temporary requirement. After the release run `composer update activit/ait_demo -w`, then `composer remove` the temporary requirement.

**Release lines and fixes for an old line.** Keep as few release lines as possible: `main` carries the newest major, and `<N>.x` exists for each older major that is still supported. End-of-support dates are set by management per client and per contract. When a new major starts, the main dev creates the old line from its last tag (`git switch -c 1.x v1.4.0 && git push -u origin 1.x`; only main devs and the bot can push it (`/release_major` creates it from the last tag), and the `[0-9]*.x` rule protects it from then on). Fixes for the old line arrive as merge requests into `1.x`, from the Upstream job for projects locked to 1.x, or written directly; they are tagged `v1.4.1` on that branch, and only projects on that line receive them.

A change merged into an old line is carried forward automatically. The Forward-port job cherry-picks each merged change onto the next newer line (`2.x` if it exists, else `main`) as a pull request, and every merge there triggers the next hop (1.x → 2.x → main). On each forward-port pull request the bot asks for `/merge` only. A forward-port is never released by itself: its change already shipped on the older line, so a release from its pull request would only repeat it. `/release` on a forward-port pull request is refused (ci-tools v1.9.11). When the newer line needs a release, a main dev tags it there (8.3), and the merged forward-port's line in the origin's overview says so. Forward-porting moves code; only a release on the newer line delivers it to the projects there, which then get normal update pull requests. A change that does not apply cleanly opens an issue naming the conflicting files and the exact commands to port it by hand, and no pull request. A change that only touches `export-ignore` files (CI workflows, tests) gets "nothing to release, merge it" instead of a release prompt.

The developer's pull request the change came from keeps one bot comment, **"Where this change went"**, listing every hop with its state: open, merged, released as `vX`, already there, or does not apply cleanly (with the issue). It moves to the end of the conversation whenever it changes.

**A change only one client needs.** First choice: an extension module in the client's project (hooks, events, service decorators). It is invisible to the Upstream job and the drift check; one Drupal detail: core's block `#pre_render` removes `#block`, so read what you need in `hook_block_view_*_alter` and carry it on the build array. If the shared module lacks the extension point, add it upstream so everybody gets it. Second choice: a patch file applied by `cweagans/composer-patches` (`extra.patches` plus a file under `patches/`); the Upstream job reverses declared patches before comparing, so a client patch is never proposed to the shared module, and a patch that cannot be reversed fails the job loudly. After editing `extra.patches` run `composer update --lock`. Never leave client-only changes as in-place edits, because the next update would remove them.

**Shared extension packages.** A separate shared package that requires the base module (`"activit/ait_demo": "^1.0"`) blocks the base's major upgrade in every project that has it, until the extension releases a version requiring the new major. Release the base first, then the extension (its 2.0 cannot be installed before the base's 2.0 exists); update pull requests do not move the extension to its new major; a project migrates both with one `composer require activit/ait_demo:^2.0 activit/ait_demo_ext:^2.0` pull request.

**Third-party modules.** `composer require drupal/<name>`, straight from packages.drupal.org; never edit them in place (the drift check fails on it). Changes go in as patches from the issue queue or as a patch file. If a dev-only module has no archive, fork it into the `activit` organization, register the fork in Packeton and treat it like ours.

**Support expired, or frozen.** Remove the repository topic `activit-project`: the project receives no more releases automatically, but can still update by hand (`composer outdated --minor-only` shows what it misses). To freeze it completely, pin the exact version (`composer require activit/ait_demo:1.4.2`): nothing moves it, not even `composer update`, and update pull requests skip it even with the topic. Lifting the freeze is `composer require activit/ait_demo:^1.4` in a pull request, which catches up to the newest allowed version in one diff; add the topic back for future releases. A project pull request whose lock names a version the project's own Packeton user cannot list fails the Packeton visibility check, and is closed with a comment when that is its only failure (12).

## 12. What Gitea automates and enforces

All automation runs as Gitea Actions workflows on our own runners, so nobody has to remember anything. The logic lives in one shared repository (`ci-tools`, versioned by tags); each module or project repository only carries short stubs that clone `ci-tools` at a fixed tag and run a script (2.4). No workflow uses `uses:` steps or anything from github.com.

| Job (where, trigger) | What it does |
| --- | --- |
| Packeton webhook (each module repo: push, create, delete) | Packeton re-reads the repository and indexes new versions and `dev-` branches (Appendix B) |
| Checks (project repo: every push and every pull request into `main`; required) | the project checks 1 to 4 below, and the Packeton visibility check after them |
| Checks (module repo: pull requests into `main` and `<N>.x`; required) | item 5 of the list above |
| Upstream (project repo: pull request opened or updated) | 6.5: compares each module folder with its locked release (client patches reversed), rebuilds the bot branch from the locked tag, opens or updates the merge request, comments in the developer's pull request |
| Commands (project and module repos: new comment `/merge …` or `/release …`) | 8.1, 8.3, 11: main devs only; merges a module merge request or a forward-port (`/merge`), tags a release (`/release`, `/release_major`; never a forward-port) |
| Release reminder (module repo: pull request closed) | after a merged Upstream merge request: names the next version and asks for `/release`, unless it changes nothing in the package or is already released (a merged forward-port gets no release prompt: it is not released by itself, only its origin's overview is updated); updates "Where this change went" |
| Release (module repo: tag `v*`) | checks the tag and `composer.json`, waits until Packeton lists the version, then delivers it (section 9): into the developer's pull request where it came from, update pull requests in the other opted-in projects; pre-releases stop after the checks |
| Forward-port (module repo: push to `<N>.x`) | 11: cherry-picks merged changes onto the next newer line as pull requests with a `/merge` prompt (never released by themselves), or opens an issue on a conflict |

The bot account has write access to the module and project repositories (team `devs`) and a Packeton token with read access to all `activit/*` packages. It may create `v*` tags, which it does only on a main dev's `/release` or `/release_major` reply; the trade-off is that any workflow with `BOT_TOKEN` could create a release tag (leave the bot off the tag list to keep tagging manual; `/release` then answers with the command to run). With `main` and the release lines protected for everybody, it can only merge pull requests whose Checks are green. Packeton itself only has read access to the module repositories.

**Checks.** Checks 1 to 4 run on project repositories, number 5 on module repositories, and number 6 is an optional nightly report. The Packeton visibility check of project repositories (called check 5 in ci-tools) follows the list:

1. No gitlinks (submodule-style entries, mode 160000) and no nested `.git` folders. This is the old mimemail and logging alerts problem.
2. No symlinks that point outside the project.
3. No `dev-` or pre-release versions of `activit/*` in `composer.lock` on `main` (feature branches may use them).
4. Drift: reinstall the Composer-managed folders from `composer.lock` in a clean checkout, with dev dependencies (plain `composer install`, no `--no-dev`), and compare the package files. Composer's *generated* files differ on every install (autoloader suffix, `include_paths.php` order, `DrupalInstalled::VERSIONS_HASH`, the root package's reference) and some shipped files only by CR-at-EOL, so those are not compared byte for byte; instead the committed `vendor/composer/installed.json` must match `composer.lock`. Drift in our own modules is a warning on branch pushes (unreleased in-place work, which the Upstream job sends on) and a failure on pull requests into `main` and on `main`, pointing to the Upstream comment; drift in third-party code always fails.
5. Module repositories: tags look like `vX.Y.Z`, `composer.json` is valid, has no `version` key and the right name; PHP and YAML syntax.
6. Optional nightly report: `composer outdated --minor-only "activit/*"` for every project.

**Packeton visibility (project repositories, ci-tools v1.9.8).** Every locked `activit/*` version must be listed for the project's own Packeton user (`PACKETON_USER`, 2.3). A frozen project cannot list newer versions, but the dist URL in the lock still downloads them, so without this check an update pull request that moved the lock would pass every other check. The check looks three times, 20 seconds apart, in case the release is not indexed yet. It fails on pull requests into `main` and on `main`, and warns on feature branches. When it is the only failure of a pull request into `main`, the bot comments with the reason and closes the pull request, keeping its branch so it can be reopened once the project has access (v1.9.9).

## 13. Do and don't

**Do:** edit shared modules in place in the project and push; open the pull request and follow the bot's comment; answer module review comments by changing the project and pushing again; as main dev, review the module merge request, then reply `/merge …` and `/release …` where the bot asks; tag only on `main` or a release line; read the diff of an update pull request before merging it.

**Don't:** `git clone` or `--prefer-source` into a project; create client branches in module repositories; put a module branch in `composer.json` (except a short-lived test); commit to a bot branch (`up/...`, `update/...`, `fwd/...`) by hand or press *Update branch by merge* on it; move or re-use a tag; tag a 1.x patch from `main` (check the branch in the tag dialog); edit third-party modules in place; run `composer update` on a dirty working tree; add `uses:` steps that point at github.com.

## 14. Decisions and what has been verified

**14.1 Decided on 13 October 2026.**

1. **Registry:** Packeton is the only Composer registry, for internal projects and external customers. Gitea's built-in Composer registry is not used, and there is no upload job.
2. **Unreleased code in another project:** `dev-` branches from Packeton (verified, with `@dev`); pre-release tags (`@RC`) as the alternative.
3. **Support and grant dates:** set by management per client and per contract; they change over time and are not fixed in this plan.
4. **Update pull requests:** every new project from the start of the Elmont project gets the topic `activit-project`; existing projects only once they are refactored or migrated.
5. **Infrastructure:** everything runs on our own Gitea, runners and Packeton. Workflows use plain shell steps from `ci-tools`, no github.com actions. Runners use our own image and may reach the internet for Composer (packagist.org, packages.drupal.org).
6. **Dev dependencies:** committed and deployed to production with the rest of `vendor/`. Dev-only modules stay disabled on production and are enabled only for debugging, so production never needs Composer installs or clean-up.
7. **Template repositories:** built during implementation; the pilot's template material is in the lab (`seed/`).

**14.2 Added by the pilot (to confirm on the Elmont call).**

1. **Webhooks:** one per module repository, created with the module (4.3), instead of an organization webhook (does not work with Gitea 28 and Packeton; Packeton's Gitea OAuth integration was not tried).
2. **Release lines and forward-ports:** `main` plus `<N>.x` per supported older major, protected by one glob rule; forward-ports are automatic and merged, never released by themselves: the newer line gets its release as a main dev decision (11). Who reviews forward-port pull requests and handles conflict issues: the main devs.
3. **Releases from the pull request:** main devs merge and release with `/merge` and `/release` replies; the bot may create release tags for that (12). The release lands in the developer's own pull request.
4. **No forced merges:** branch rules bind administrators too (2.1).
5. **Customer expiry model:** the contract maps to Packeton's *Update expiration date* (freeze), never to account expiry.
6. **Packeton's read access to Gitea:** the bot token in Packeton's `auth.json` (2.2); a rotation must update it, because Composer hides the resulting 401 (2.3).
7. **Automatic merges of update pull requests:** none by default; a per-project opt-in for patch releases is possible later.

**14.3 Verified in the pilot lab** (Gitea 28.1, Packeton, `act_runner` 0.6.1 with our image, Composer, DDEV with Drupal 11.4; an automated end-to-end test of 138 assertions (passed on 14 October 2026 from scratch with ci-tools v1.8.6), a manual walkthrough of the whole setup by hand from an empty Gitea, and throwaway instances for every change to `ci-tools`):

- Everything in sections 2 to 13 as written: the protection rules (direct pushes rejected for everybody, red pull requests blocked for admins too), the per-repository webhook (new tags indexed in seconds), the Checks, Upstream (from the locked tag, patches reversed, no duplicate merge requests), the release into the developer's pull request and its fallbacks, update pull requests and their skip rules, `/merge` and `/release` with their refusals, forward-ports over two hops with conflicts as issues, CI-only changes, the overview comment.
- Packeton's archives leave out `export-ignore` files exactly like `git archive` (no false drift); `dev-` versions of bot branches with slashes install; customer limits (version constraint, update expiration, renewal) behave as section 10 says, also behind a TLS proxy in a separate network.
- The bot token's scopes are enough; run-only workflows clone `ci-tools` and their repository; `drupal-custom-module` lands in `web/modules/custom/`; `composer update` replaces an edited module folder without prompting; `composer-patches` works with a committed `vendor/`; the drift check as described in 12 reproduces the committed `vendor/`.

**14.4 Still open.**

- The runner image from Gitea's container registry (the lab builds it locally).
- Packeton on the internet: a publicly trusted certificate, rate limits, the clone-URL rewrite (2.2).
- Speed and ergonomics on the largest real project repository (the lab's projects are small); runner capacity.
- Productionising: the templates as Gitea template repositories, HTTPS in front of Packeton, monitoring of the jobs.

## Appendix A. The upstream script (core)

This is the core of the Upstream job, with plain Git. Arguments: the module folder inside the project, the module repository URL, the tag the project is locked to, and the bot branch name. It expects `origin/main` to exist in the project clone. The full job (`ci-tools/bin/upstream.sh`) adds: finding the modules and their locked tags from `composer.lock` and `vendor/composer/installed.json`; reversing the project's declared patches first; the target line (`<major>.x` or `main`); skipping a change that is already merged into the line, and an identical re-push; the merge request and the comment through the Gitea API with the bot token.

```bash
#!/bin/bash
set -euo pipefail
path=$1; remote=$2; tag=$3; branch=$4
proj=$(git rev-parse --show-toplevel); work=$(mktemp -d); mod="$work/mod"; base="$work/base"
git clone -q "$remote" "$mod"
mkdir "$base" && git -C "$mod" archive "$tag" | tar -x -C "$base"     # what the package of the locked tag contains
if diff -rq "$base" "$proj/$path" >/dev/null; then echo "no drift: nothing to send"; exit 0; fi
git -C "$base" init -q && git -C "$base" add -A && git -C "$base" -c user.name=x -c user.email=x@x commit -qm base
find "$base" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
cp -a "$proj/$path/." "$base/" && git -C "$base" add -A
git -C "$base" diff --cached --binary > "$work/changes.patch"     # locked release -> project folder
msg=$(git -C "$proj" log --format='- %s (%an)' origin/main..HEAD -- "$path")
git -C "$mod" switch -q -c "$branch" "refs/tags/$tag"              # cut from the LOCKED tag, never from main or 1.x
git -C "$mod" apply --index "$work/changes.patch"
git -C "$mod" commit -q -m "Changes from project $(basename "$proj")" -m "$msg"
mkdir "$work/chk" && git -C "$mod" archive HEAD | tar -x -C "$work/chk"
diff -rq "$work/chk" "$proj/$path" >/dev/null || { echo "integrity check failed: not pushed"; exit 1; }   # BEFORE the push
git -C "$mod" push -q --force origin "$branch"
```

The bot branch push also reaches Packeton through the webhook, which is what makes the `dev-up/...` install in section 11 possible.

## Appendix B. Packeton indexing

There is no upload step. Packeton reads the module repositories itself:

1. Each module repository is registered once as a package in Packeton (4.3), with Packeton's read credential for Gitea (2.2).
2. The repository's own webhook sends every push, tag and branch creation and deletion to `https://<packeton-host>/api/update-package?username=<user>&apiToken=<token>&composer_package_name=<org>/<module>` (Gitea webhook type *Gitea*, JSON). The `composer_package_name` parameter is required: Gitea's payload names the repository by its API URL, which Packeton cannot match to a package by itself.
3. Packeton re-reads the repository within seconds: every `vX.Y.Z` tag becomes version `X.Y.Z`, `main` becomes `dev-main`, a release line `1.x` becomes `1.x-dev`, and every other branch a `dev-<branch>` version.
4. If a version is missing, check the webhook's recent deliveries in Gitea (a 202 means Packeton accepted it), then use the update button on the package page in Packeton.

The Release job (section 12) waits until Packeton lists the new version before it delivers it, by polling the package's metadata with the bot's Packeton token until the version appears or a time limit passes.
