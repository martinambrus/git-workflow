# Shared Drupal modules: developer workflow

*Draft for the Elmont call | 8 October 2026, revised 13 October 2026 with the decisions in section 14 | Git steps and the upstream step were tested in a sandbox; Gitea, Packeton, Composer and runner steps still need confirming in the pilot (section 14).*

## 1. The rules in one minute

1. Every shared module is its own Git repository in Gitea. The repository root is the module folder.
2. A version is a Git tag (`v1.4.0`), created only by a main dev (protected tags). Tags are never moved or re-used: a fix is a new version.
3. Packeton (self-hosted, open source) is the only Composer registry, for our own projects and for external customers. A Gitea webhook tells Packeton about every new tag or branch, and Packeton reads the module repositories directly. Nothing is uploaded by hand.
4. Projects install shared modules with Composer from Packeton, as archives. Nobody runs `git clone` into a project, so there is never a nested `.git` folder.
5. Projects commit everything, including `vendor/` with dev dependencies and the module code, and are deployed from Git. A plain `git clone` of a project is all a developer needs.
6. Developers edit shared module code in place, inside the project, where they can run and debug it, then commit and push as usual. A Gitea Actions job sends the difference to the module repository as a merge request.
7. A project moves to a new module version only through an explicit, reviewed change: an update pull request (opened automatically for opted-in projects) or `composer update activit/<module>` by hand. Nothing updates by itself.
8. Client-only behaviour lives in an extension module in the client's project, or in a patch file. There are no per-client branches in module repositories.
9. Everything runs inside our own infrastructure: Gitea, its runners and Packeton. Workflows use no actions from github.com.

Releases flow one way: module repository, tag, Packeton, Composer, project, Git deploy. Fixes flow back the other way: project, push, merge request in the module repository. Gitea Actions does the moving in both directions (section 12); people edit, review, merge and tag.

**Which module version does a project use?** Not a branch. Each project's own `composer.json` (the allowed range) and `composer.lock` (the exact version) decide:

| Project | `composer.json` | `composer.lock` pins | Effect |
| --- | --- | --- | --- |
| Client 1 | `"activit/ait_demo": "^1.4"` | 1.4.2 | moves only when someone updates it, and only within 1.x |
| Client 2 | `"^2.0"` | 2.1.0 | on the 2.x line |
| Frozen or out of support | `"1.4.2"` | 1.4.2 | never moves |
| Unipo (external) | `"^1.4"` | up to what their Packeton grant allows | Packeton limits what they see |

Moving a project to a new major version is one deliberate `composer require activit/ait_demo:^2.0`. Developers work on branches of the project, as they do today. Module branches are only long-lived release lines (`main`, plus `1.x` if 1.x is still maintained after 2.0) and short-lived testing branches. The Upstream job creates the module-side branch itself and picks its target from the locked version: 1.4.2 goes to `1.x` if that branch exists, otherwise to `main`.

Roles used below: **Dev A** and **Dev B** (any developers), the **Main dev** (owns releases: merges module merge requests, tags versions, manages Packeton customers), **Ops** (runs Gitea, the runners and Packeton), **Management** (sets support and grant dates per client and contract) and **Unipo**, the example of an external customer who only ever talks to Packeton, never to Git or Gitea.

Names in the examples: module `activit/ait_demo`, projects `shop-a` and `shop-b`, branch `feature/promo-banner`. Replace `<module-repo>`, `<project-repo>`, `<gitea-host>`, `<packeton-host>` and `<org>` with your own.

## 2. One-time setup

**2.1 Gitea and runners (Ops).**

- Enable Gitea Actions on the instance and in each repository, and register at least one runner (`act_runner`).
- Build one runner image with `git`, `curl`, `jq`, `openssh-client`, PHP (the version your projects use, with the extensions Composer needs) and Composer. Push it to Gitea's container registry (`<gitea-host>/<org>/runner:<tag>`) and point the runner labels at it, so every job uses the same image and nothing is pulled from Docker Hub at job time.
- Runners have outbound internet access for Composer (packagist.org and packages.drupal.org for third-party packages). They do not use github.com actions (2.4).
- Create the organization that owns the module repositories (`activit`), and a bot account. Give the bot a token with write access to repositories and issues (pull requests), and store it as an organization secret (`BOT_TOKEN`). Store the bot's Packeton token as `PACKETON_TOKEN` (2.2).
- Create the shared `ci-tools` repository (the scripts every workflow calls). The template repositories `module-template` and `project-template` are built during implementation, from the first pilot module and the first Elmont project (section 12).
- Protect `main` in every module and project repository (merge requests only, checks required), and protect the tag pattern `v*` so that only main devs can create release tags.
- Add an organization webhook on `activit` that sends push events (tags and branches) to Packeton (2.2), so every module repository is covered without per-repository setup.

**2.2 Packeton (Ops).**

- Run Packeton from its Docker image (`packeton/packeton`) with a persistent volume for `/data`, behind HTTPS at `<packeton-host>`. Create the admin user with `bin/console packagist:user:manager <name> --password=<password> --admin`.
- Keep anonymous access off (`PUBLIC_ACCESS=false`, the default).
- Give Packeton read-only access to the module repositories: a read-only deploy key or a read-only Gitea token for the `activit` organization, entered under Packeton's credentials.
- Add each module repository as a package (its Gitea clone URL). Packeton then indexes every tag as a version and every branch as a `dev-<branch>` version.
- Packeton is the only part that must be reachable from outside, for external customers (section 10). Gitea stays internal.
- Accounts: one internal group with access to all `activit/*` packages, for developers, the bot and CI; one customer user or group per external customer with that customer's limits (section 10).

**2.3 Every developer machine.** Git with SSH access to the project and module repositories, PHP, Composer and your usual local site setup. For Composer, create a Packeton token and add it with `composer config --global http-basic.<packeton-host> <username> <token>`. This token is only needed for `composer require` and `composer update`, never for cloning or running a project, and once update pull requests exist most developers will rarely run Composer at all.

**2.4 Workflows without github.com.** Gitea resolves an unqualified `uses: actions/checkout@v4` against github.com by default, so our workflows contain no `uses:` steps at all. Every step is a `run:` step in our runner image. A workflow fetches `ci-tools` at a fixed tag with the bot token and runs a script from it:

```yaml
- name: Upstream
  run: |
    git clone -q --depth 1 --branch v1.0.0 \
      "https://bot:${{ secrets.BOT_TOKEN }}@<gitea-host>/activit/ci-tools.git" /tmp/ci-tools
    /tmp/ci-tools/bin/upstream.sh
```

Checking out the repository the workflow runs in is also a plain `git clone` or `git fetch` with the bot token, done by a `ci-tools` script.

**2.5 Project template.** Add Packeton to the existing `repositories` array and force archive installs. `preferred-install` is committed with the project, so it applies to everyone without any per-machine setup. The project-template repository also carries the workflow stubs from section 12.

```json
{
  "repositories": [
    { "type": "composer", "url": "https://<packeton-host>" }
  ],
  "config": {
    "preferred-install": { "*": "dist" }
  }
}
```

Three checks on the template: `extra.installer-paths` should map the package type `drupal-custom-module` to `web/modules/custom/{$name}` (`drupal/recommended-project` normally does); `.gitignore` must not hide `vendor/`, `web/core` or the module folders; and installs are done without `--no-dev`, because dev dependencies are committed and deployed (14.1, decision 6).

## 3. Create a project (once per site)

Start from the `project-template` repository once it exists: it carries the Composer settings, the `.gitignore` rules and the workflow stubs. Until then:

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

Dev-only modules (for example `devel`) are committed and deployed like everything else, but stay disabled on production until someone needs them for debugging. Keep them out of the configuration that is imported on production, for example with `config_exclude_modules` in `settings.php` or a config split.

New projects from the start of the Elmont project get the repository topic `activit-project` (section 9). Existing projects get it only when they are refactored or migrated to this workflow.

## 4. Create a new shared module (once per module)

**4.1 Create the repository.** In Gitea create `ait_demo` in the `activit` organization from the `module-template` template repository (New repository, Template) once it exists, or as an empty repository until then, and clone it into a scratch folder, not inside a project:

```bash
git clone <module-repo> /tmp/ait_demo && cd /tmp/ait_demo
```

**4.2 Adjust the skeleton.** The template holds the two files below; change the names. Do not put a `version` key in `composer.json`; the tag is the version. Keep a `.gitattributes` that marks tests and CI files `export-ignore`: the package archive must leave them out (to confirm for Packeton, section 14).

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

**4.3 Register it in Packeton.** Add the repository URL as a package in Packeton (Ops or Main dev, once per module). The organization webhook (2.1) keeps it up to date from then on.

**4.4 Release 1.0.0.**

```bash
git add -A && git commit -m "Initial module"
git push origin main
git tag -a v1.0.0 -m "First release" && git push origin v1.0.0
```

The tag push reaches Packeton through the webhook. Check that version 1.0.0 appears on the package's page in Packeton. If it does not, use the update button on the package page and check the webhook's delivery log in Gitea (Appendix B).

**If the module started as a prototype inside a project**, move it out together with its history (tested):

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

Merge through the usual project merge request. While a module is on 0.x, `^0.1` accepts only 0.1.x, so release 1.0.0 before the first production use.

## 6. Work on the module (Dev A)

**6.1 Branch.** In the project: `git switch -c feature/promo-banner`.

**6.2 Edit in place.** Change files in `web/modules/custom/ait_demo/` and run and debug on the real site. The module folder has no `.git` of its own, so Git commands run there act on the project repository.

**6.3 Commit.** Commit as usual. Module and project changes may share a commit: only the difference in the module folder is sent upstream. Write messages that make sense on their own, because the module merge request lists them.

**6.4 Push the project branch** so that Dev B can pick it up: `git push -u origin feature/promo-banner`.

**6.5 The Upstream job sends the module changes.** Every push to a project branch runs it (section 12). It compares each of our module folders with the release the project is locked to. If a folder differs, the job pushes the difference to a bot branch in the module repository (`up/shop-a/feature-promo-banner`), opens or updates a merge request there and comments its link on the project's pull request, with what happens next: the project pull request is not merged yet (its Checks fail on purpose, see 6.6, and the protection rule blocks merging it, for admins too); once the change is released, the Release job adds the release to that pull request, which then passes and is merged (section 9). If the change is already merged into the module but not released, no second merge request is opened. The job also runs when the project pull request is opened. The merge request targets `1.x` or `main`, chosen from the locked version, holds one cumulative commit and lists the project commits and their authors in its description. If nothing differs, the job does nothing.

- Re-running is safe: the job rebuilds the bot branch from scratch every time, so there is nothing to keep track of, and a second developer's push simply updates the same merge request.
- Answer review comments by changing the project and pushing again. Never commit to a bot branch (`up/...`) by hand: the next push rebuilds it.
- Until the job exists, or when it fails or Actions is down, run the same script by hand (Appendix A).

**6.6 Keep working.** The project branch runs on the in-place code. CI shows a drift warning on feature branches until the release exists, and the branch cannot merge into `main` before that.

## 7. Another developer continues (Dev B)

**7.1 Clone.** `git clone <project-repo>`. Everything is there: vendor, the module code and Dev A's commits. No Composer and no Packeton token are needed; set up the database and files as usual.

**7.2 Switch.** `git switch feature/promo-banner`.

**7.3 Work.** Edit, test, commit and `git push`.

**7.4 Nothing more to do.** The push runs the Upstream job again, and the same module merge request is updated with Dev B's changes. Dev A and Dev B do not need to agree on who sent which commit: the job rebuilds the merge request from the project's current state each time.

## 8. Review and release (Main dev)

**8.1 Review and merge.** Review the module merge request the bot opened, check that module CI is green and merge it into `main` (or into `1.x` if that is its target). Requests for changes go back to the developer, who changes the project and pushes again. The main dev can do both steps from the developer's pull request in the project: the bot's comment there ends with the reply to give, `/merge activit/<module>#<n>` (the bot merges the module merge request once its checks pass) and then `/release activit/<module> v<x.y.z>` (the bot tags it on the right line). Only main devs (the module organization's Owners team) can use these replies. When a merge request from the Upstream job is merged, a reminder comment on it names the next version and how to tag it, and the project's pull request is asked for the `/release` reply.

**8.2 Pick the version.** Patch (`1.0.1`) for bug fixes, minor (`1.1.0`) for backwards-compatible features, major (`2.0.0`) for breaking changes or for dropping a Drupal core version, which also starts a new release line (section 11).

**8.3 Tag.**

```bash
git switch main && git pull
git tag -a v1.1.0 -m "Promo banner block" && git push origin v1.1.0
```

Only main devs can create `v*` tags (protected tags). The tag push does two things: the webhook makes Packeton index 1.1.0, and the Release job checks the tag and then starts the update pull requests (section 12). Never move or re-use a tag; a mistake is fixed by the next patch version.

**8.4 Announce.** Check that 1.1.0 appears in Packeton and that the Release run is green. Update pull requests (section 9) follow for the opted-in projects. Post one line in the team channel: module, version, what changed, which projects should update.

## 9. Apply a release to a project (when the project decides)

**Which projects get update pull requests.** Projects with the repository topic `activit-project`: every new project from the start of the Elmont project, and existing projects once they are refactored or migrated to this workflow. Nothing else is opted in at the start.

**Update pull requests.** After a release, the Update PRs job opens an `update/ait_demo-1.1.0` pull request in every project that carries the topic. It runs `composer update activit/ait_demo`, commits everything including `vendor/` and `composer.lock`, and opens the request; a reviewer then does steps 9.3 and 9.4 below. Frozen or out-of-support projects simply have no such topic. The project where the change was developed gets no separate update pull request: the release is committed to its open pull request (one `composer update` commit on that branch), which then passes its Checks and is merged by the developer. Only when that is not safe (several open pull requests change the module, the branch moved meanwhile, or the change is not fully released) does it get a normal update pull request; module-only pull requests whose change the release contains are then closed with a link to it. Until the job exists, or when you want to update by hand, follow all the steps below, per project, on a clean working tree.

**9.1 Where to start.** In the project where the change was developed, stay on the feature branch. In any other project, start from main:

```bash
git switch main && git pull && git switch -c update/ait_demo-1.1.0
```

**9.2 Update only this package.**

```bash
git status                           # must be clean
composer update activit/ait_demo     # add -w only if Composer asks for dependency updates
git diff --stat
```

Moving to a new major version, or off 0.x, needs a new constraint first: `composer require activit/ait_demo:^2.0`.

**9.3 Read the diff.** In the project that developed the change, the module folder should hardly change, because the release contains what was developed in place; mostly `composer.lock` moves. In any other project the diff is the release. If the diff removes something of yours, it was never sent upstream: stop, check why the Upstream job did not send it (6.5), release, then update.

**9.4 Test and deploy.** Run what the project's deploy needs (for example `drush updb -y`, `drush cim -y` and `drush cr` on staging), then commit `Update activit/ait_demo to 1.1.0`, open the merge request, let CI run, merge into `main` and deploy from Git.

**9.5 Overview and rollback.** `composer outdated "activit/*"` shows what is behind. Projects that are frozen or out of support are simply skipped. To roll back, `git revert` the update commit (code and `composer.lock` go back together) and redeploy; database and configuration changes need their own plan.

## 10. External customers (for example Unipo)

External customers never get Git or Gitea access. They use Composer against Packeton, which is reachable from outside; Gitea stays internal and has no customer organizations or accounts.

**Management** decides, per client and per contract, which packages and versions a customer gets and until when (support and grant dates). These dates are not fixed in this plan.

**Main dev, in Packeton.** Create the customer user (or a group for the customer, if several people need access), grant the packages, set the limits from the contract (a version constraint such as `^1.0`, a release-date limit or an expiry date) and hand over the repository URL and a token. When the expiry date passes, Packeton freezes the customer on what was released before it.

**Customer, in their own project.**

```bash
composer config repositories.activit composer https://<packeton-host>
composer config http-basic.<packeton-host> <customer-user> <customer-token>
composer require activit/ait_demo
composer update activit/ait_demo     # later: only what their grant allows
```

When the grant ends nothing breaks: they stay on the last version they were allowed, and development goes on for everyone else.

## 11. Special cases

**Test unreleased module code in another project.** First choice, a development branch: Packeton serves every branch of a module repository as a `dev-` version, including the bot branches, so `composer require activit/ait_demo:dev-up/shop-a/feature-promo-banner` installs exactly what the Upstream job sent. If that does not work in the pilot, ask the Main dev for a pre-release tag (`v1.1.0-rc.1`) and require it with `composer require activit/ait_demo:^1.1@RC`. Either way `composer.lock` must never keep a pre-release or `dev-` version of our modules on `main`; CI rejects it.

**You need it now, before a tag exists.** Ask the Main dev for a patch release. With Packeton indexing tags automatically it is a tag and a minute; merging a project with unreleased module code is not allowed.

**The change adds a PHP dependency.** Dependencies are read from the module's `composer.json` only when the module is installed. While developing, `composer require` the library in the project as a temporary requirement. After the release run `composer update activit/ait_demo -w`, then `composer remove` the temporary requirement.

**Fix for an old release line.** Keep as few release lines as possible. End-of-support dates are set by management per client and per contract, so a line stays maintained as long as a client's contract needs it. Create the line from its last tag (`git switch -c 1.x v1.4.0 && git push -u origin 1.x`), fix through a merge request into `1.x`, and tag `v1.4.1` on that branch. Projects on that line run `composer update`. The Upstream job targets `1.x` for projects locked to a 1.x version; such a fix may also need merging forward into `main`. The Forward-port job opens that pull request itself; its comment asks the main dev to reply `/release v2.0.x` (merge it and release it on the newer line in one step) or `/merge`, and the project pull request the change came from lists where it went: each forward-port with its state, up to the release that contains it.

**A change only one client needs.** First choice: an extension module in the client's project (hooks, events, service decorators); if the shared module lacks the extension point, add it upstream so everybody gets it. Second choice: a patch file applied by `cweagans/composer-patches` (`extra.patches` plus a file under `patches/`); it is re-applied on every update and fails loudly when it no longer fits. Never leave client-only changes as in-place edits, because the next update would remove them.

**Third-party modules.** `composer require drupal/<name>`, straight from packages.drupal.org; never edit them in place. Changes go in as patches from the issue queue or as a patch file. If a dev-only module has no archive, fork it into the `activit` organization, register the fork in Packeton and treat it like ours.

**Freeze a project.** Pin the exact version in `composer.json` (`1.4.2`) and remove the repository topic `activit-project`, so no update pull requests are opened. Lifting the freeze later is a normal update, with a catch-up diff to review.

## 12. What Gitea automates and enforces

All automation runs as Gitea Actions workflows on our own runners, so nobody has to remember anything. The logic lives in one shared repository (`ci-tools`, versioned by tags); each module or project repository only carries a short stub that clones `ci-tools` at a fixed tag and runs a script (2.4). No workflow uses `uses:` steps or anything from github.com.

| Job (trigger) | What it does | Replaces | Status |
| --- | --- | --- | --- |
| Packeton webhook (organization webhook, push of a tag or branch) | Packeton re-reads the module repository and indexes new versions and `dev-` branches (Appendix B) | manual registry uploads | planned, set up first |
| Checks (project repo, every pull request, required on `main`) | the checks listed below | "remember not to..." | planned, build first |
| Upstream (project repo, push to any branch) | compares each module folder with its locked release, pushes the difference to a bot branch in the module repo, opens or updates the merge request, comments the link (Appendix A) | patch export, temp clone, branch, push | core tested locally |
| Release (module repo, tag `v*`) | checks the tag (check 5), waits until Packeton lists the version, then runs Update PRs | manual announce and update | planned |
| Update PRs (started by Release) | for projects with the repository topic `activit-project`: `composer update <module>`, commit including `vendor/`, open a pull request | `composer update` and diff reading (a human still reviews) | planned, build last |
| Templates (Gitea template repositories) | new modules and projects start with the workflows and Composer settings in place | setup sections 2 to 4 | built during implementation |

The bot account needs write access to the module and project repositories and a Packeton token with read access to all `activit/*` packages. With `main` and the `v*` tags protected it can only create branches (`up/...`, `update/...`), so it cannot release anything. Packeton itself only has read access to the module repositories.

**Checks.** The first four run on project repositories, number 5 on module repositories, and number 6 is an optional nightly report:

1. No gitlinks (submodule-style entries, mode 160000) and no nested `.git` folders. This is the old mimemail and logging alerts problem.
2. No symlinks that point outside the project.
3. No `dev-` or pre-release versions of `activit/*` in `composer.lock` on `main` (feature branches may use them).
4. Drift: reinstall the Composer-managed folders from `composer.lock` in a clean checkout, with dev dependencies (plain `composer install`, no `--no-dev`), and fail if anything differs. On feature branches this is a warning for our own modules (unreleased in-place work, which the Upstream job sends on) and a failure for third-party code. On merge requests into `main` and on `main` itself it is a failure for everything.
5. Module repositories: tags look like `vX.Y.Z`, `composer.json` is valid and has no `version` key.
6. Optional nightly report: `composer outdated "activit/*"` for every project.

## 13. Do and don't

**Do:** edit shared modules in place in the project and push; answer module review comments by changing the project and pushing again; tag only from `main` or a maintenance line; update one module at a time and read the diff.

**Don't:** `git clone` or `--prefer-source` into a project; create client branches in module repositories; put a module branch in `composer.json` (except a short-lived test); commit to a bot branch (`up/...`) by hand; move or re-use a tag; edit third-party modules in place; run `composer update` on a dirty working tree; add `uses:` steps that point at github.com.

## 14. Decisions and what has been verified

**14.1 Decided on 13 October 2026.**

1. **Registry:** Packeton is the only Composer registry, for internal projects and external customers. Gitea's built-in Composer registry is not used, and there is no upload job.
2. **Unreleased code in another project:** `dev-` branches from Packeton; pre-release tags (`@RC`) if branches do not work in the pilot.
3. **Support and grant dates:** set by management per client and per contract; they change over time and are not fixed in this plan.
4. **Update pull requests:** every new project from the start of the Elmont project gets the topic `activit-project`; existing projects only once they are refactored or migrated.
5. **Infrastructure:** everything runs on our own Gitea, runners and Packeton. Workflows use plain shell steps from `ci-tools`, no github.com actions. Runners use our own image from Gitea's container registry and may reach the internet for Composer (packagist.org, packages.drupal.org).
6. **Dev dependencies:** committed and deployed to production with the rest of `vendor/`. Dev-only modules stay disabled on production and are enabled only for debugging, so production never needs Composer installs or clean-up.
7. **Template repositories:** built during implementation, not before.

**14.2 Tested in a sandbox** (Git 2.43, local repositories; Composer, Gitea, Packeton and a runner were not available, so a dist install was simulated by unpacking `git archive` of a tag):

- A fresh clone of a project with committed module code is complete, with no nested `.git`.
- The Upstream step compares a module folder with the archive of its locked tag and applies the difference to a branch cut from that tag. Edits, new files, deletions and a binary change all came through, and files the archive leaves out (a `tests/` folder marked `export-ignore`) were left alone in the module repository.
- Re-running the step from scratch after a second developer's push gave the right result with no bookkeeping: one cumulative commit on the bot branch.
- After a release, a folder replaced by the release archive left `git status` empty when its edit had been sent, and the step reported no drift. When the release also contained someone else's change and the project had its own unsent edit, only the project's own edit was sent.
- A prototype module can be extracted from a project with its history.

**14.3 Read in documentation, not run:**

- Packeton: Composer API v2, Gitea webhooks, customer users and ACL groups limited by package, version and release date, freezing updates after a customer's license expires, credentials for reading repositories, Docker image.
- Gitea Actions: enabled by an admin and per repository, `act_runner`, `.gitea/workflows/`, tag triggers, repository and organization secrets, unqualified `uses:` resolved against github.com by default.
- Gitea protected tags with a pattern such as `v*`, organization webhooks and the container registry.

**14.4 To confirm in the pilot** (needs Gitea with a runner, Packeton and real Composer). Nothing here is confirmed yet:

- Actions is enabled on our instance, and the runner works with our own image from Gitea's container registry.
- The organization webhook reaches Packeton, and a new tag shows up as a version within a minute or two.
- Packeton's archives leave out `export-ignore` files, exactly like `git archive` of the same tag. The Upstream job compares against `git archive`, so any difference would show as false drift.
- `dev-` versions of module branches, including bot branches with slashes (`dev-up/shop-a/feature-promo-banner`), install from Packeton.
- Customer limits behave as documented: version constraint, release date and expiry freeze, tested with a Unipo-like test customer.
- Packeton is reachable from outside with HTTPS, and Gitea stays internal.
- The bot token's scopes are enough to push branches, open pull requests and comment, and the pull request API calls behave as expected.
- Workflows with only `run:` steps can clone `ci-tools` and the repository they run in with the bot token.
- `drupal-custom-module` lands in `web/modules/custom/` with your template's `installer-paths`.
- `composer update` replaces an edited module folder without prompting.
- `composer-patches` works with a committed `vendor/`.
- The CI drift check reproduces the committed `vendor/` with dev dependencies included.
- Speed and ergonomics of all this on your largest project repository.

**14.5 Still to build:** the Packeton webhook setup, the Checks, Release and Update PRs jobs, the workflow around the Upstream script (see the end of Appendix A), the runner image and the template repositories.

## Appendix A. The upstream script (core, tested locally)

This is the core of the Upstream job as it was tested, with plain Git on local repositories. Arguments: the module folder inside the project, the module repository URL, the tag the project is locked to, and the bot branch name. It expects `origin/main` to exist in the project clone.

```bash
#!/bin/bash
set -euo pipefail
path=$1; remote=$2; tag=$3; branch=$4
proj=$(git rev-parse --show-toplevel); work=$(mktemp -d); mod="$work/mod"; base="$work/base"
git clone -q --branch "$tag" "$remote" "$mod" 2>/dev/null
mkdir "$base" && git -C "$mod" archive "$tag" | tar -x -C "$base"     # what the package of the locked tag contains
if diff -rq "$base" "$proj/$path" >/dev/null; then echo "no drift: nothing to send"; exit 0; fi
git -C "$base" init -q && git -C "$base" add -A && git -C "$base" -c user.name=x -c user.email=x@x commit -qm base
find "$base" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
cp -a "$proj/$path/." "$base/" && git -C "$base" add -A
git -C "$base" diff --cached --binary > "$work/changes.patch"     # locked release -> project folder
msg=$(git -C "$proj" log --format='- %s (%an)' origin/main..HEAD -- "$path")
git -C "$mod" switch -q -c "$branch" && git -C "$mod" apply --index "$work/changes.patch"
git -C "$mod" commit -q -m "Changes from project $(basename "$proj")" -m "$msg"
git -C "$mod" push -q --force origin "$branch"
rm -rf "$work/chk" && mkdir "$work/chk" && git -C "$mod" archive HEAD | tar -x -C "$work/chk"
diff -rq "$work/chk" "$proj/$path" >/dev/null && echo "integrity OK: module branch == project folder"
```

What the workflow around it still has to add: find the modules and their locked tags from `composer.lock` and `vendor/composer/installed.json` (both are committed); authenticate with the bot token; create or update the merge request and comment on the project's pull request through the Gitea API; choose `1.x` or `main` as the target from the locked version; and fail the job when the integrity line is missing, ideally by running that check before the push. The bot branch push also reaches Packeton through the webhook, which is what makes the `dev-up/...` install in section 11 possible.

## Appendix B. Packeton indexing (from Packeton's documentation, not yet run)

There is no upload step. Packeton reads the module repositories itself:

1. Each module repository is registered once as a package in Packeton (4.3), with Packeton's read-only credential for Gitea.
2. The `activit` organization webhook in Gitea sends every push (tags and branches) to Packeton's Gitea webhook endpoint, authenticated with a Packeton token. The exact URL and token format come from Packeton's webhook settings page.
3. Packeton re-reads the repository: every `vX.Y.Z` tag becomes version `X.Y.Z`, and every branch becomes a `dev-<branch>` version.
4. If a version is missing, check the webhook's recent deliveries in Gitea, then use the update button on the package page in Packeton.

The Release job (section 12) waits until Packeton lists the new version before it starts the update pull requests, for example by polling the package's metadata with the bot's Packeton token until the version appears or a time limit passes.
