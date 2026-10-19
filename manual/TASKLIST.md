# Manual walkthrough: tasklist

You set up everything yourself, in this order, and take the screenshots for the ops team. The stack that is running
for you now is **only** Gitea 28.1 and Packeton (started by `./lab bare up`): no users, no organizations, no
repositories, no tokens, no webhooks, no runner. Every task below says what to do, what you should see, and what to
screenshot. Tick the boxes as you go; **do not skip the "Done when" lines**, later phases depend on them.

Legend: 📸 take a screenshot · ✅ what you should see · ⚠ a trap we hit in the pilot (finding number in
[`README.md`](../README.md)) · 🧪 optional check · `$REPO` = the folder this repository is cloned to.

> Run only **one** stack. The automated lab (`./lab up`, `./lab e2e`) and this bare stack share ports and names. To go
> back to the automated lab: `./lab bare destroy` and then `./lab up`.

## Contents

0. [Before you start](#phase-0--before-you-start)
1. [Gitea: install and base setup](#phase-1--gitea-install-and-base-setup)
2. [Packeton: admin, credentials, secrets](#phase-2--packeton-admin-credentials-secrets)
3. [The runner](#phase-3--the-runner)
4. [`ci-tools`: the scripts every workflow calls](#phase-4--ci-tools-the-scripts-every-workflow-calls)
5. [The module repository, release 1.0.0](#phase-5--the-module-repository-release-100)
6. [Two Drupal 11 projects](#phase-6--two-drupal-11-projects)
7. [Release 1.1.0 with a hook (edit in the module repo, not in a project)](#phase-7--release-110-with-a-hook)
8. [An extension package that uses the hook, added to project 2](#phase-8--an-extension-package-that-uses-the-hook)
9. [2.0.0: a refactor; project 1 stays on v1, project 2 moves (and fails first)](#phase-9--200-a-refactor)
10. [Fix an old version and let it flow forward (and fail on a conflict)](#phase-10--fix-an-old-version-and-let-it-flow-forward)
11. [Lock a client to a line or version, and re-allow upgrades](#phase-11--lock-a-client-and-re-allow-upgrades)
12. [Optional: edit the module in place inside a project](#phase-12--optional-edit-in-place-inside-a-project)
13. [Optional: external customers in Packeton](#phase-13--optional-external-customers-in-packeton)

Appendices: [A names](#appendix-a--names-that-must-match) · [B module repo checklist](#appendix-b--module-repository-checklist) ·
[C project repo checklist](#appendix-c--project-repository-checklist) · [D troubleshooting](#appendix-d--troubleshooting) ·
[E screenshots](#appendix-e--screenshot-list)

## The story we are telling

| Who | What they are | Ends up |
| --- | --- | --- |
| **shop-a** (project 1) | a client that did **not** pay for upgrades | stays on the **1.x** line, gets 1.x fixes only while support is active, then is locked, then re-allowed |
| **shop-b** (project 2) | a client that is up to date | gets 1.1.0, an **extension** package that uses the new hook, then moves to **2.0** |
| `activit/ait_banners` | the shared module | 1.0.0, 1.1.0 (adds a hook), 2.0.0 (renames the hook: a refactor) |
| `activit/ait_banners_ribbon` | an extension package of the module | 1.0.0 uses the 1.1 hook; 2.0.0 uses the 2.0 hook |

---

## Phase 0 — Before you start

- [ ] **0.1 Tools.** `docker`, `git`, `jq`, `curl` installed; DDEV installed with the router moved off port 80:
  ```bash
  ddev config global --router-http-port=8080 --router-https-port=8443
  mkcert -install
  ```
- [ ] **0.2 Names resolve.** `getent hosts gitea.test packeton.test` prints `127.0.0.1` for both. If not: `./lab hosts`.
- [ ] **0.3 The bare stack is running.**
  ```bash
  cd $REPO
  ./lab bare status
  ```
  ✅ `gitea` and `packeton` are `Up`. If you are not sure, `./lab bare up` is safe to repeat.
- [ ] **0.4 A shell alias for the bare stack's Compose** (use it for every `docker compose` command below):
  ```bash
  export REPO=~/git-workflow-test            # adjust if you cloned elsewhere
  alias wfb='docker compose --project-directory $REPO/ops/bare -f $REPO/ops/bare/docker-compose.yml'
  mkdir -p $REPO/workspace                   # your clones go here (git-ignored)
  ```

**Done when:** `curl -s -o /dev/null -w '%{http_code}\n' http://gitea.test:3000/` prints `200` and
`curl -s -o /dev/null -w '%{http_code}\n' http://packeton.test/login` prints `200`.

---

## Phase 1 — Gitea: install and base setup

*Plan 2.1.* 📸 = screenshot for the ops runbook.

- [ ] **1.1 Run the install wizard.** Open <http://gitea.test:3000/>.
  📸 the wizard as it first appears (database SQLite3, URL `http://gitea.test:3000/`, SSH port 2222 are pre-filled
  from the Compose file; the "Environment Configuration" box lists the variables that were applied).
  Tick **"Only administrators can create user accounts"**, open **Administrator Account Settings**, choose a username
  (the guide calls it `admin`; it is the "main dev"), an email and a password. Click **Install Gitea**.
  ✅ You land on the dashboard logged in as `admin`. 📸 the dashboard.
  ⚠ Settings that need a restart or an `app.ini` edit are covered in 1.3.
- [ ] **1.2 Check that Actions are on.** In Gitea 28.1 Actions is **enabled by default** (plan 2.1 says "enable
  Actions": on this version that is only a check). Create nothing yet; you will see the *Actions* tab on the first
  repository (Phase 4). Site Administration → *Actions* → *Runners* exists (empty for now). 📸
- [ ] **1.3 Egress policy** (so webhooks may reach Packeton on the private network). Gitea 28 blocks it by default.
  🧪 *Optional, to screenshot the error first:* do 5.4 (the webhook) before this task and look at **Recent
  Deliveries**: the error is `denied by egress policy ... needs an explicit IP allow entry`. 📸
  Then edit `$REPO/ops/bare/gitea.env` and add:
  ```
  GITEA__security__EGRESS_MODE=lax
  GITEA__security__ALLOWED_HOST_LIST=private,loopback
  GITEA__repository__DEFAULT_BRANCH=main
  ```
  and recreate the container (data is kept in the volume):
  ```bash
  wfb up -d gitea
  ```
  ✅ <http://gitea.test:3000/> is back within ~10 s. ⚠ Finding 2. In production use the explicit Packeton host, not
  `private`.
- [ ] **1.4 Two more users.** Site Administration → *User Accounts* → *Create User Account*: `dev` (a normal
  developer) and `bot` (the automation account). Untick "User must change password". Use any passwords you will
  remember. 📸 the user list.
- [ ] **1.5 Two organizations.** *+* → *New Organization*: `activit` (modules and tools) and `sites` (projects),
  visibility **Private**. ⚠ The names matter: the workflow stubs contain `activit/ci-tools` (Appendix A). 📸
- [ ] **1.6 A team per organization.** In each organization → *Teams* → *Create new team*: name `devs`, tick
  **Include all repositories**, permission **Write**, then *Add team member*: `dev` and `bot`. 📸
  ✅ `bot` can push branches and open pull requests, but cannot create release tags (that comes from protected tags
  in Phase 5).
- [ ] **1.7 A token for the bot.** Log in as `bot` (private window) → *Settings → Applications → Generate New
  Token*, name `ci`, permissions: **repository: Read and Write**, **issue: Read and Write**,
  **organization: Read and Write**, **user: Read**. Copy it now (shown once). Keep it in a scratch file; call it
  `BOT_TOKEN`. 📸 the permission selection (not the token).

**Done when:** you can log in as `admin`, `dev` and `bot`; `activit` and `sites` exist, each with team `devs`
containing `dev` and `bot`; you hold a `BOT_TOKEN`.

---

## Phase 2 — Packeton: admin, credentials, secrets

*Plan 2.2.*

- [ ] **2.1 Create the admin on the command line** (there is deliberately no `ADMIN_USER` in the Compose file):
  ```bash
  wfb exec packeton app packagist:user:manager admin --email=admin@example.test --password='<choose one>' --admin
  ```
  ✅ prints `User admin was created successfully, api token: ...` — that is the **Packeton API token**; call it
  `PACKETON_TOKEN`. (Show it again any time: `wfb exec packeton app packagist:user:manager admin --show-token`.)
- [ ] **2.2 Log in** at <http://packeton.test/login>. 📸 the empty home page and the *Profile* page (API token).
- [ ] **2.3 Anonymous access is off.**
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' http://packeton.test/packages.json     # 401
  curl -s -o /dev/null -w '%{http_code}\n' -u admin:$PACKETON_TOKEN http://packeton.test/packages.json   # 200
  ```
- [ ] **2.4 Let Packeton read the private Gitea repositories** (plan 2.2). Packeton uses Composer's `auth.json` in
  its Composer home. ⚠ For generic Git URLs the key must **include the port** (finding 3), so list both:
  ```bash
  BOT_TOKEN='<paste the bot token>'
  wfb exec -T packeton sh -c 'mkdir -p /data/composer && cat > /data/composer/auth.json' <<JSON
  { "http-basic": {
    "gitea.test:3000": { "username": "bot", "password": "$BOT_TOKEN" },
    "gitea.test":      { "username": "bot", "password": "$BOT_TOKEN" } } }
  JSON
  wfb exec -T packeton sh -c 'cat > /data/composer/config.json && chown -R www-data:www-data /data/composer' <<JSON
  { "config": { "secure-http": false } }
  JSON
  ```
  (`secure-http false` only because the lab is plain HTTP; production uses HTTPS.) 🧪 Packeton's *Admin →
  Credentials* page is the alternative for **SSH keys**; we did not exercise it. 📸 `cat` of the two files with the
  token masked.
- [ ] **2.5 Organization secrets** (Gitea, as `admin`): for **both** `activit` and `sites` → *Settings → Actions →
  Secrets → Add Secret*: `BOT_TOKEN` = the bot token, `PACKETON_TOKEN` = the Packeton admin token (the modules'
  Release job uses it). Projects get their own user's token as a repo secret instead (6.2b). 📸 the secrets list
  (values are hidden).

**Done when:** `curl -u admin:$PACKETON_TOKEN http://packeton.test/api/packages` returns `{"packageNames":[]}`.

---

## Phase 3 — The runner

*Plan 2.1 (runner image and label).*

- [ ] **3.1 The image.** `./lab bare up` already built `activit-runner:local` from
  [`ops/runner/Dockerfile`](../ops/runner/Dockerfile) (PHP 8.3, Composer, git, curl, jq, perl, patch, the `yaml`
  extension). 📸 the Dockerfile and `docker image ls activit-runner`.
  🧪 Plan 2.1 wants this image in Gitea's own container registry; we did **not** test that (the lab uses the local
  image).
- [ ] **3.2 Registration token.** As `admin`: *Site Administration → Actions → Runners → Create new runner* → copy
  the registration token. 📸 (hide the token)
- [ ] **3.3 Start the runner.**
  ```bash
  cd $REPO && ./lab bare runner <registration-token>
  ```
  ✅ After ~10 s the runner is listed as **Idle/Online** with labels `ubuntu-latest` and `activit-runner`. 📸
  ⚠ Workflows in this process use `runs-on: activit-runner` and **no `uses:` steps** (plan 2.4).

**Done when:** the runner is online in Site Administration.

---

## Phase 4 — `ci-tools`: the scripts every workflow calls

*Plan 2.1 / 2.4 / 12.* The stubs pin **different tags** of this repository, so tag the same commit with all of them.

- [ ] **4.1 Create the repo.** In `activit`: *New Repository* `ci-tools`, Private, **no** README / .gitignore /
  license (empty). 📸
- [ ] **4.2 Push the scripts** (as `admin`):
  ```bash
  cd $REPO/workspace
  git clone http://admin:<password>@gitea.test:3000/activit/ci-tools.git
  cp -a $REPO/seed/tools/ci-tools/. ci-tools/ && cd ci-tools
  git add -A && git commit -m "ci-tools: upstream, release, update-prs, checks, forward-port"
  git branch -M main && git push -u origin main
  for t in $(cat $REPO/seed/tools/ci-tools.tags); do git tag -a $t -m "ci-tools $t"; done
  git push origin --tags
  ```
  ✅ the repo shows `bin/upstream.sh`, `bin/release.sh`, `bin/update-prs.sh`, `bin/check-project.sh`,
  `bin/check-module.sh`, `bin/forward-port.sh`, `bin/release-reminder.sh`, `bin/commands.sh`, and twenty-nine tags
  (`v1.0.0` to `v1.9.10`). 📸
  *Why so many tags:* a tag is never moved, and the workflow stubs pin **`v1.9.10`** everywhere (module checks, project
  checks, upstream, commands, release, release reminder, forward-port). The older tags are history: each one is what a
  stub pinned at the time. The newest, `v1.9.1` (the `/release_major` command of task 9.1b), is added the same way. In your own setup you would publish real versions.

**Done when:** `git ls-remote --tags http://gitea.test:3000/activit/ci-tools.git` lists the twenty-nine tags.

---

## Phase 5 — The module repository, release 1.0.0

*Plan 4.* We use the module from [`seed/modules/ait_banners`](../seed/modules/ait_banners) (a sponsorship banner
block). Write your own if you prefer; it needs `composer.json` with `"type": "drupal-custom-module"`, no `version`
key, and name `activit/<repo>`.

- [ ] **5.1 Create the repo** `activit/ait_banners` (empty, Private). 📸
- [ ] **5.2 Protect release tags** (plan 2.1): repo → *Settings → Tags* → *Protected tags* → new rule, pattern `v*`,
  allowed users: `admin` and `bot`. 📸 ✅ later, `dev` cannot create tags. The bot tags only when a main dev replies
  `/release …` in a project PR (Phase 12); leave it out if releases must be tagged by hand (the bot then answers
  with the command to run).
- [ ] **5.3 Seed the module** (as `admin`), **without a tag yet**:
  ```bash
  cd $REPO/workspace
  git clone http://admin:<password>@gitea.test:3000/activit/ait_banners.git
  cd ait_banners
  cp -a $REPO/seed/modules/ait_banners/. .
  cp -a $REPO/seed/module-template/.gitea .          # the module's workflows: checks, release, forward-port, release-reminder, commands
  git add -A && git commit -m "Initial module"
  git branch -M main && git push -u origin main
  ```
  ⚠ Do this **before** the branch rules (5.5), otherwise the direct push to `main` is refused.
  ⚠ Do **not** tag yet: the Release job triggered by a tag waits for Packeton to list that version, so the package
  must be registered first (5.4).
- [ ] **5.4 Register it in Packeton and connect the webhook.**
  1. Packeton → *Submit*: repo type **VCS (auto)**, URL `http://gitea.test:3000/activit/ait_banners.git`,
     *Check*, then add. ✅ the package page lists `dev-main` (the tag comes in 5.4b). 📸
     ⚠ Register **before** you push the next tag (finding 6) and give Gitea a few seconds after a first push
     (finding 27).
  2. Gitea repo → *Settings → Webhooks → Add Webhook → Gitea*. Target URL:
     `http://packeton.test/api/update-package?username=admin&apiToken=<PACKETON_TOKEN>&composer_package_name=activit/ait_banners`,
     method POST, content type `application/json`, trigger **Custom events**: *Push*, *Branch or tag creation*,
     *Branch or tag deletion*. Save, then **Test Delivery**. ✅ *Recent Deliveries* shows HTTP 202. 📸
     ⚠ **Per repository**, not per organization: an org-wide webhook does not work with this Gitea + Packeton
     (finding 1). ⚠ Without 1.3 this is the delivery that fails with the egress error.
- [ ] **5.4b Tag 1.0.0** (as `admin`), now that Packeton and the webhook know the repository:
  ```bash
  git tag -a v1.0.0 -m "First release" && git push origin v1.0.0
  ```
  ✅ Packeton lists `v1.0.0` within seconds; in the module repo's *Actions* the **Release** run goes green (no
  projects exist yet, so it opens no PRs). 📸 ⚠ Findings 6 and 27 (order and timing).
  *Or in the web UI* (works the same: the Release job and Packeton's webhook fire; tested on 28.1). The **Tags** page
  has **no** create button. Instead:
  - **Code** tab → branch dropdown → select the **release line** (`main` here, `1.x` for a 1.x patch) → open the
    dropdown again → **Tags** tab → type `v1.0.0` → **Create tag v1.0.0**. The tag is cut from the branch you are on.
  - or **Releases → New Release** → type the new tag name → set **Target** → **Publish Release** (also creates a Gitea
    release entry, which we do not need; *Save Draft* creates no tag).
  ⚠ The target defaults to `main`: a 1.x patch tagged without switching to `1.x` releases the 2.x code as `1.1.x`.
  Only `admin` can create `v*` tags here too (5.2).
- [ ] **5.5 Branch rules** (repo → *Settings → Branches → Add new rule*):
  1. pattern `main`: **Disable Push**, **Enable Status Check** with the status check pattern `checks / checks (pull_request)`,
     and tick **Administrators must follow branch protection rules** (otherwise an admin can still force-merge a red PR).
  2. pattern `[0-9]*.x` (matches `1.x`, `2.x`, not `feat.x`): same status check and admin setting, but under *Push* choose
     **Allowlist Restricted Push** and add `admin` and `bot` under **Allowlisted users for pushing**. Creating a release
     line is a push: the main dev does it by hand, and the bot does it for `/release_major` (9.1b). Developers are
     refused. 📸 both rules
     ⚠ The status name only exists after the first run of the checks workflow (5.6); typing it into the rule is fine.
  Also *Settings → Repository → Pull Requests*: tick **Delete pull request branch after merge by default**. 
- [ ] **5.6 First pull request through the gate.** Prove the rules work:
  ```bash
  git switch -c chore/readme && echo "# ait_banners" > README.md
  git add -A && git commit -m "Add README" && git push -u origin chore/readme
  ```
  Open the PR in Gitea. ✅ *Checks* appear and run on the runner (a minute); the *Merge* button waits for green;
  📸 the PR with the green check and the Actions run log. Merge it. Try `git switch main && git push origin HEAD`
  with a local commit: ✅ rejected by branch protection. 📸

**Done when:** Packeton shows `activit/ait_banners` `v1.0.0`; the Release run is green; a PR to `main` ran the Checks and merged; a direct
push to `main` is refused; a `dev` user cannot push a `v*` tag.

---

## Phase 6 — Two Drupal 11 projects

*Plan 3 and 5.* Do the whole phase for `shop-a`, then repeat it for `shop-b`.

- [ ] **6.1 Two empty repos** in `sites`: `shop-a`, `shop-b` (Private, empty). 📸
  ⚠ The repository **topic** `activit-project` (the opt-in for automatic update PRs) cannot be set from the UI yet: an
  empty repo shows Gitea's "empty repository" page without the topics bar. Add it in 6.6, after the first push
  (**Manage Topics** on the repo home), or now through the API:
  `curl -u admin:<password> -X PUT http://gitea.test:3000/api/v1/repos/sites/shop-a/topics/activit-project` (204 = set).
- [ ] **6.2 Create the Drupal 11 project** (example for `shop-a`; do `shop-b` the same way):
  ```bash
  cd $REPO/workspace
  git clone http://admin:<password>@gitea.test:3000/sites/shop-a.git && cd shop-a
  ddev config --project-type=drupal11 --docroot=web --php-version=8.3 --project-name=shop-a --auto
  cat > .ddev/docker-compose.wfnet.yaml <<'YAML'
  # lets Composer in the web container reach packeton.test / gitea.test
  services:
    web:
      networks: [default, wf-net]
  networks:
    wf-net:
      external: true
  YAML
  rm -rf web                      # 'ddev config' creates a stub that create-project cannot use
  ddev start
  ddev composer create-project drupal/recommended-project:^11 . --no-interaction
  ```
  **Before the first `ddev start`, once per machine**, give every DDEV project the Packeton credential:
  ```bash
  mkdir -p ~/.ddev/homeadditions/.composer
  cat > ~/.ddev/homeadditions/.composer/auth.json <<JSON
  { "http-basic": { "packeton.test": { "username": "admin", "password": "<PACKETON_TOKEN>" } } }
  JSON
  chmod 600 ~/.ddev/homeadditions/.composer/auth.json
  ```
  DDEV copies `~/.ddev/homeadditions/` into each web container's home on every start.
  ⚠ Finding 36: `ddev composer config --global ...` is stored **inside the container** and is lost on `ddev poweroff`
  or a rebuild, after which Packeton answers 401. This file is the default for projects without their own user.
  Keep the file outside any repository (not in a project's `.ddev/`), so the token can never be committed.
  A project with its own Packeton user (6.2b) overrides this file with its own `auth.json` in the project folder.
  ⚠ Finding 35: if you run these through CI / ssh / an IDE task, append `</dev/null` to `ddev composer ...`,
  otherwise it hangs silently.
- [ ] **6.2b The project's own Packeton user** (plan 10). Each project logs in to Packeton as itself, so Packeton can
  limit what each project gets. The admin token stays with the modules.
  1. Create the user (quiet, so the token is not printed):
     `docker compose --project-directory $REPO/ops/bare -f $REPO/ops/bare/docker-compose.yml exec -T packeton app packagist:user:manager shop-a -q --email=shop-a@example.test --password=<random>`
  2. *Settings → My groups → Create group*: **Name** `shop-a`; tick **`activit/weather`**; **Version** `*` (or the
     constraint the project may take). Then *My users → `shop-a`*: **ACL Groups** `shop-a`, **Full read access** off.
     ✅ `curl -s -o /dev/null -w '%{http_code}' -u shop-a:<token> http://packeton.test/p2/activit/weather.json` prints `200`.
  3. Repo secret of `sites/shop-a` (it overrides the org secret): `PACKETON_TOKEN` = that user's API token, from
     `packagist:user:manager shop-a --show-token` (never pasted into a file that is committed).
  4. In the project's `checks.yml`, next to the token: `PACKETON_USER: shop-a` (ci-tools v1.9.7 and later; the default
     is `admin`, which the project's token no longer matches).
  5. In the project folder, git-ignored (add `auth.json` to `.git/info/exclude` or to the project's `.gitignore`), mode 600:
     `{ "http-basic": { "packeton.test": { "username": "shop-a", "password": "<token>" } } }`. DDEV's Composer reads it
     from the project root, so it takes precedence over the default file above.

- [ ] **6.3 Point the project at Packeton** (plan 2.5) and install the module:
  ```bash
  ddev composer config repositories.packeton '{"type":"composer","url":"http://packeton.test"}'
  ddev composer config secure-http false                 # lab only: plain HTTP
  ddev composer config preferred-install.'*' dist        # archives, never git clones (plan rule 4)
  ddev composer require drush/drush
  ddev composer require "activit/ait_banners:^1.0"
  find web/modules/custom/ait_banners -name .git          # must print nothing
  ```
  ✅ Composer prints `Installing activit/ait_banners (v1.0.0): Extracting archive` and the folder
  `web/modules/custom/ait_banners` exists (`drupal-custom-module` lands there with the stock installer paths).
  ⚠ Finding 8: if Composer prints *"could not be fully loaded ... authentication"* it silently used stale cache —
  fix the token before going on. 📸 the require output.
- [ ] **6.4 Install Drupal and enable the module:**
  ```bash
  mkdir -p config/sync
  ddev drush si standard -y --site-name="Shop A" --account-name=admin --account-pass=admin
  ```
  Now open `web/sites/default/settings.php` and, **above** the line
  `if (getenv('IS_DDEV_PROJECT') == 'true' && file_exists(__DIR__ . '/settings.ddev.php')) {`, add
  ```php
  $settings['config_sync_directory'] = '../config/sync';
  ```
  (`drush si` rewrites `settings.php`, so this must come **after** the install; finding 5.) Then:
  ```bash
  ddev drush en ait_banners -y
  ```
  and place the block: <https://shop-a.ddev.site:8443/user/login> (`admin`/`admin`) → *Structure → Block layout* →
  Olivero, region **Content Above** → *Place block* → **Sponsorship banner** → set a sponsor name
  (e.g. `Acme Corp` for shop-a, `Globex Ltd` for shop-b) → Save. 📸 the place-block dialog and the front page with
  the banner. Export the configuration:
  ```bash
  ddev drush cex -y
  ```
- [ ] **6.5 Workflows and .gitignore, then commit everything including `vendor/`** (plan rule 5):
  ```bash
  cp -a $REPO/seed/project-template/. .                  # adds .gitea/workflows: upstream.yml, checks.yml, commands.yml
  printf '%s\n' 'web/sites/default/files/' 'config/sync/.htaccess' > .gitignore
  git check-ignore -v vendor web/core web/modules/contrib web/modules/custom   # must print nothing
  git add -A && git commit -m "Initial project: Drupal 11, activit/ait_banners 1.0.0, vendor and web committed"
  git branch -M main && git push -u origin main
  ```
  ⚠ `drupal/recommended-project` ships **no** `.gitignore`; without line 1 Drupal's runtime files would be
  committed (finding 5). ⚠ `config/sync/.htaccess` is written lazily by Drupal and would leave the tree dirty
  (finding 28). 🧪 The push is large (25k+ files): that is expected.
- [ ] **6.6 Topic, protect `main`, delete merged branches**, all **after** the first push (finding 24/25): add the topic
  `activit-project` (**Manage Topics** on the repo home, unless you set it through the API in 6.1); branch rule `main`
  as in 5.5 (**Disable Push**, **Enable Status Check**, pattern `checks / checks (pull_request)`, **Administrators must
  follow branch protection rules**: nobody, not even an admin, can merge a red PR); *Settings → Repository
  → Pull Requests*: **Delete pull request branch after merge by default**.
  The first push also triggers *Upstream* and *Checks* runs on the push event. 📸 the Actions tab.

**Done when (both projects):** the front page shows the banner; `composer.lock` has `activit/ait_banners` `v1.0.0`;
`git status` is clean; a PR to `main` runs Checks and can be merged; `main` is protected.

> 🧪 **Shortcut for later rebuilds:** `ops/bin/new-drupal-project.sh` does 6.2–6.5 in one go (it needs the automated
> lab's state files, so it is not usable on this bare stack; the commands above are its content).

---

## Phase 7 — Release 1.1.0 with a hook

*Plan 6/8/9, "edit in the module's own repo": branch, PR, merge, tag.* We add `hook_ait_banners_banner_alter()`.

- [ ] **7.1 Branch in the module repo and apply the change:**
  ```bash
  cd $REPO/workspace/ait_banners && git switch main && git pull
  git switch -c feature/alter-hook
  git apply $REPO/manual/assets/ait_banners-1.1.0-alter-hook.patch
  git add -A && git commit -m "Add hook_ait_banners_banner_alter() extension point"
  git push -u origin feature/alter-hook
  ```
  (The patch changes `SponsorshipBannerBlock::build()` to call `moduleHandler->alter('ait_banners_banner', ...)`
  and documents the hook in `ait_banners.api.php`.)
- [ ] **7.2 Pull request → green Checks → merge.** 📸 the PR (note the module Checks: JSON, PHP and YAML syntax).
- [ ] **7.3 Tag 1.1.0 as the main dev:**
  ```bash
  git switch main && git pull
  git tag -a v1.1.0 -m "Extension point: hook_ait_banners_banner_alter()"
  git push origin v1.1.0
  ```
  ✅ Packeton lists `v1.1.0` within seconds (the webhook). 📸
- [ ] **7.4 Watch the Release job** (module repo → *Actions*): it checks the tag and `composer.json`, waits until
  Packeton lists the version, then opens **`update/ait_banners-1.1.0`** PRs in **both** projects, authored by `bot`.
  📸 the run log and the two PRs (body: diff stat + the 9.3/9.4 checklist).
- [ ] **7.5 Review and merge both update PRs** (plan 9): read the diff (the whole release is in the module folder),
  let *Checks* run, merge. Then in each project:
  ```bash
  git switch main && git pull && ddev drush updb -y && ddev drush cr
  ```
  ✅ `jq -r '.packages[]|select(.name=="activit/ait_banners")|.version' composer.lock` prints `v1.1.0` in both.
  📸 the merged PR and the diff of `composer.lock`.

**Done when:** both projects are on `v1.1.0` and still show their banner.

---

## Phase 8 — An extension package that uses the hook

*Plan 11, rule 8.* A **separate shared package** `activit/ait_banners_ribbon` requires `activit/ait_banners ^1.1`
and implements the new hook; only **shop-b** gets it.

- [ ] **8.1 Create the repo and apply the module checklist** (Appendix B): `activit/ait_banners_ribbon`.
  Seed it from the asset and tag 1.0.0:
  ```bash
  cd $REPO/workspace
  git clone http://admin:<password>@gitea.test:3000/activit/ait_banners_ribbon.git && cd ait_banners_ribbon
  cp -a $REPO/manual/assets/ait_banners_ribbon/. .
  cp -a $REPO/seed/module-template/.gitea .
  git add -A && git commit -m "Initial extension: ribbon above the banner"
  git branch -M main && git push -u origin main
  ```
  Then register it in Packeton and add its webhook (5.4 with `composer_package_name=activit/ait_banners_ribbon`),
  tag protection and branch rules (5.2, 5.5), and **only then** tag:
  ```bash
  git tag -a v1.0.0 -m "1.0.0" && git push origin v1.0.0
  ```
  📸 Packeton now lists two packages.
- [ ] **8.2 Install it in shop-b only**, through a branch and a PR:
  ```bash
  cd $REPO/workspace/shop-b && git switch main && git pull
  git switch -c feature/ribbon
  ddev composer require "activit/ait_banners_ribbon:^1.0"
  ddev drush en ait_banners_ribbon -y && ddev drush cex -y
  git add -A && git commit -m "Add the ribbon extension" && git push -u origin feature/ribbon
  ```
  PR → Checks → merge. ✅ the shop-b front page now shows **"FEATURED PARTNER"** above the banner; shop-a does not.
  📸 both sites side by side.
  ⚠ If the module were still 1.0.0 this would be refused: the extension requires `^1.1`.

**Done when:** shop-b shows the ribbon, shop-a does not; shop-b's lock has both packages.

---

## Phase 9 — 2.0.0, a refactor

*Plan 11 (release lines).* The hook is **renamed** (`ait_banners_banner` → `ait_banners_render`): a breaking change.

- [ ] **9.1 Create the 1.x line first, then develop 2.0 on `main`:**
  ```bash
  cd $REPO/workspace/ait_banners && git switch main && git pull
  git branch 1.x v1.1.0 && git push -u origin 1.x     # allowed: admin is on the push allowlist of [0-9]*.x; -u sets tracking
  git switch -c refactor/2.0
  git apply $REPO/manual/assets/ait_banners-2.0.0-refactor.patch
  git add -A && git commit -m "2.0: rename the alter hook, require Drupal 11"
  git push -u origin refactor/2.0
  ```
  PR → Checks → merge. 📸 `1.x` in the branch list (it is protected by the glob rule without anyone creating a
  rule for it: try a direct push as `dev`: refused).
- [ ] **9.1b Alternative to 9.1 and 9.2: `/release_major` does both in one reply** (ci-tools `v1.9.1` and later). Use it for the major itself, from a project that is still locked to 1.x:
  1. Make the breaking change in shop-a's copy of the module, as in 12.1 (the rename, or any change that needs 2.0). Commit
     it with a trailer line of its own: `Module-Major: 2` (optional: the version in step 2 decides, but the trailer keeps
     the history honest). Push the branch and open the PR into `main`.
     ✅ Upstream opens the module MR **into `main`**, although shop-a is locked to 1.x, because `1.x` does not exist yet. With
     the trailer the MR is aimed at the new major's line; without it, at the locked line when that exists, as in 12.2.
  2. Checks green on the module MR and on the project PR. Then, as the main dev, reply in the project PR:
     `/release_major activit/ait_banners v2.0.0`
  3. ✅ The bot creates `1.x` at `v1.1.0`, merges the module MR into `main` and tags `v2.0.0` on the merge commit. Its reply
     starts "New major `v2.0.0` released". The Release job then runs as in 9.3.
  4. ✅ A second `/release_major` for the same version is refused ("already exists … nothing done").
  The reply is refused, with the reason, unless all of these hold: the project is locked to the major before the new one;
  the version is `vN.0.0`, with N one above the lock; no `N.x` branch and no `vN.*` tag exist; `main` has no unreleased
  package change since its last release; the module MR goes into `main`, and is either open with green Checks or already
  merged (after `/merge`) with nothing unreleased before or after it on `main`.
  Then continue with 9.3 and 9.4 as written.

- [ ] **9.2 Tag 2.0.0:**
  ```bash
  git switch main && git pull && git tag -a v2.0.0 -m "2.0.0: hook renamed" && git push origin v2.0.0
  ```
- [ ] **9.3 Nothing happens to existing clients.** ✅ The Release job succeeds and opens **no** update PR in
  either project: both are on `^1.0`. 📸 the green run and the empty PR lists.
  **shop-a stays on the v1 line.** This is "client 1 did not pay for upgrades": nothing to do.
- [ ] **9.4 shop-b tries to upgrade and Composer refuses:**
  ```bash
  cd $REPO/workspace/shop-b && git switch main && git pull && git switch -c migrate/2.0
  ddev composer require "activit/ait_banners:^2.0"
  ```
  ✅ **Error:** Composer explains that `activit/ait_banners_ribbon 1.0.0` requires `activit/ait_banners ^1.1`,
  so `^2.0` cannot be installed. 📸 the error. This is the protection working.
  ⚠ What would happen **without** it (🧪 optional proof): the module would update, the extension would silently
  stop doing anything (the ribbon disappears, no error), because nobody calls the old hook name any more.
  Reset: `git restore . && git switch main`.
- [ ] **9.5 Release the extension for 2.0** (tag the old line first so it stays maintainable):
  ```bash
  cd $REPO/workspace/ait_banners_ribbon && git switch main && git pull
  git branch 1.x v1.0.0 && git push origin 1.x
  git switch -c release/2.0 && git apply $REPO/manual/assets/ait_banners_ribbon-2.0.0.patch
  git add -A && git commit -m "2.0: use hook_ait_banners_render_alter(), require ait_banners ^2.0"
  git push -u origin release/2.0
  ```
  PR → Checks → merge → `git switch main && git pull && git tag -a v2.0.0 -m "2.0.0" && git push origin v2.0.0`.
  ⚠ Release order matters: the extension's 2.0.0 can only be installed after the base's 2.0.0 exists (finding in
  [`plan-changes.md`](../plan-changes.md) item 17).
- [ ] **9.6 shop-b moves both packages together:**
  ```bash
  cd $REPO/workspace/shop-b && git switch main && git pull && git switch -c migrate/2.0
  ddev composer require "activit/ait_banners:^2.0" "activit/ait_banners_ribbon:^2.0"
  ddev drush updb -y && ddev drush cr && ddev drush cex -y
  git add -A && git commit -m "Move to ait_banners 2.0 and ribbon 2.0" && git push -u origin migrate/2.0
  ```
  PR → Checks → merge. ✅ shop-b shows the ribbon again, now on `v2.0.0`; shop-a is still `v1.1.0`.
  📸 `composer.lock` of both projects side by side.

**Done when:** shop-a is on `v1.1.0` (v1 line), shop-b on `v2.0.0` with the ribbon working.

---

## Phase 10 — Fix an old version and let it flow forward

*Plan 11, "fix for an old release line".* A fix is made **on the 1.x branch**, released as `v1.1.1`, and carried
**forward** to `main` automatically; a conflicting one needs a human.

- [ ] **10.1 A clean fix on 1.x:**
  ```bash
  cd $REPO/workspace/ait_banners && git fetch origin && git switch -c fix/sponsor-spacing origin/1.x
  echo '.ait-banner__sponsor { letter-spacing: 0.01em; }' >> css/banner.css
  git add -A && git commit -m "1.x: slight letter-spacing on the sponsor name"
  git push -u origin fix/sponsor-spacing
  ```
  Open the PR with **base branch `1.x`** (not `main`). ⚠ Gitea's *New Pull Request* page preselects `main` as the
  base: change the left dropdown to `1.x` and check that the PR shows exactly your one commit. Checks → merge.
- [ ] **10.2 Tag it on the 1.x branch:**
  ```bash
  git switch 1.x && git branch --set-upstream-to=origin/1.x 1.x && git pull && git tag -a v1.1.1 -m "1.1.1" && git push origin v1.1.1
  ```
  (Web UI instead: as in 5.4b, with the branch dropdown on **`1.x`**.)
  ✅ **Release job → update PR only in shop-a** (`update/ait_banners-1.1.1`): shop-b is on `^2.0`, so it is skipped.
  📸 the one PR and the empty list in shop-b. Merge it. shop-a is now on `v1.1.1`.
- [ ] **10.3 The forward-port.** Pushing to `1.x` triggered the **Forward-port** job: ✅ a PR
  `fwd/1.x/<sha>-to-main` ("Forward-port (1.x -> main): …") exists in the module repo. 📸 Its title and body.
  Let Checks run and merge it: the fix now exists on `main` too. The bot's comment on it offers `/merge` (merge only)
  and `/release v2.0.x` (merge **and** release, 10.4 in one step); main devs can reply either.
  *(If a `2.x` branch existed, it would target `2.x` first and then `main`: each merge triggers the next hop, and
  each hop asks for its own `/release`.)*
- [ ] **10.4 It reaches the 2.x client with the next 2.x release:**
  ```bash
  cd $REPO/workspace/ait_banners && git switch main && git pull
  git tag -a v2.0.1 -m "2.0.1: includes the forwarded 1.x fix" && git push origin v2.0.1
  ```
  ✅ update PR `update/ait_banners-2.0.1` in **shop-b** only. Merge it. 📸
  *(Or, instead of the tag commands: reply `/release v2.0.1` on the forward-port PR of 10.3. The bot tags the merge
  commit and lists what the release contains.)*
- [ ] **10.5 A fix that conflicts** (the 2.0 refactor touched the same line):
  ```bash
  git fetch origin && git switch -c fix/comment origin/1.x
  sed -i 's#other modules may alter the banner. See#other modules may alter the banner, see#' src/Plugin/Block/SponsorshipBannerBlock.php
  git add -A && git commit -m "1.x: punctuation in the extension point comment"
  git push -u origin fix/comment
  ```
  PR into `1.x` → Checks → merge → tag `v1.1.2` on `1.x`. ✅ shop-a gets its update PR as before (merge it: shop-a is now on `v1.1.2`), **but** the
  Forward-port job **fails** (red run) and opens an **issue** "Forward-port needed (1.x -> main)" that names the
  conflicting file and the exact commands to port it by hand. No PR is opened for it. 📸 the red run, the issue.
  Resolve it as the issue says (`git switch -c fwd/... origin/main && git cherry-pick -x -m 1 <sha>`, fix the
  conflict, PR). *This is the "2.0 conflicts because of the refactor" case: the system tells you and never guesses.*

**Done when:** shop-a `v1.1.2`, shop-b `v2.0.1`, a clean forward-port was merged, and one conflict produced an issue.

---

## Phase 11 — Lock a client and re-allow upgrades

*Plan 1 (the table), 9 and 11 ("Freeze a project").* Everything below is done on **shop-a**, as PRs.

| Goal | How | Effect |
| --- | --- | --- |
| **Stay on the v1 line** | constraint `^1.0` (what it already has) | 2.x is never installed; 1.x patch releases still arrive as update PRs |
| **Support expired: no more automatic update PRs** | remove the repository topic `activit-project` | the Release job skips it; it can still `composer update` by hand |
| **Freeze at an exact version** | constraint `1.1.2` (no `^`) | nothing moves it, not even a manual `composer update` |
| **Re-allow** | restore `^1.1`, re-add the topic | the next release opens an update PR again |

- [ ] **11.1 Lock to the v1 line.** `jq -r '.require["activit/ait_banners"]' composer.json` in shop-a prints `^1.0`.
  📸 composer.json. ✅ Nothing to do: this is the state since Phase 6, and 9.3 showed it holds.
- [ ] **11.2 Support expired.** Gitea → `sites/shop-a` → remove the topic `activit-project`. 📸 Release a tiny 1.x
  patch (`v1.1.3`, as in 10.1/10.2). ✅ Packeton lists `v1.1.3`, **no** update PR appears in shop-a.
  🧪 In shop-a: `ddev composer outdated --minor-only "activit/*"` lists `1.1.2 ! 1.1.3`: the project can still choose
  to take it by hand (that is the "we do not supply it automatically" case). Without `--minor-only` Composer shows
  the newest version of any major (`~ 2.0.1`, which `^1.0` does not allow).
- [ ] **11.3 Freeze at an exact version.**
  Pin it at the version it has **now** (read it from `composer.lock`: `v1.1.2` in this walkthrough; pinning an
  older number would be a downgrade):
  ```bash
  cd $REPO/workspace/shop-a && git switch main && git pull && git switch -c freeze/ait-banners
  ddev composer require "activit/ait_banners:1.1.2"
  git add -A && git commit -m "Freeze activit/ait_banners at 1.1.2" && git push -u origin freeze/ait-banners
  ```
  PR → Checks → merge. ✅ `composer.json` now has `"activit/ait_banners": "1.1.2"`; `ddev composer update
  activit/ait_banners` reports *Nothing to modify*. 📸 Re-add the topic and release another patch (`v1.1.4`):
  ✅ the Release job still opens **no** PR for shop-a (constraint `1.1.2` does not allow it).
- [ ] **11.4 Re-allow upgrades (they pay again).**
  ```bash
  git switch main && git pull && git switch -c unfreeze/ait-banners
  ddev composer require "activit/ait_banners:^1.1"
  git add -A && git commit -m "Allow 1.x updates again" && git push -u origin unfreeze/ait-banners
  ```
  PR → merge; make sure the topic `activit-project` is back. The catch-up happens in this PR already:
  `composer require` with the wider constraint installs the newest allowed version (here `v1.1.4`), so its lock diff
  covers everything the project missed. ✅ Release the next 1.x patch (`v1.1.5`, as in 10.1/10.2): shop-a receives
  its update PR again (`v1.1.4 -> 1.1.5`). 📸
  To move it to **2.x** as well (they bought the major): `ddev composer require "activit/ait_banners:^2.0"` in a PR
  (shop-a has no extension, so there is no conflict). ⚠ This is a deliberate act; no job does it.

**Done when:** you have seen all four rows of the table work, with screenshots.

---

## Phase 12 — Optional: edit in place inside a project

*Plan 6 and 7.* The other direction: a developer fixes the module **inside shop-a** and the *Upstream* job turns it
into a merge request in the module repo.

- [ ] **12.1 Edit the module inside shop-a** (as a developer would; a branch, then a PR):
  ```bash
  cd $REPO/workspace/shop-a &&
  git switch main && git pull &&
  git switch -c fix/banner-css &&
  printf '/* Hotfix made inside shop-a. */\n' >> web/modules/custom/ait_banners/css/banner.css &&
  git add -A && git commit -m "ait_banners: CSS note from shop-a" &&
  git push -u origin fix/banner-css
  ```
  Open the PR into `main` in Gitea. Everything else happens **in this PR**.
- [ ] **12.2 What the developer sees** (nothing to do but read):
  - one comment from `bot`: "**This pull request changes the shared module `activit/ait_banners`** … becomes mergeable
    when that change is released … Sent to the module repository as …/pulls/N (target `1.x`) … **Main devs:** review
    the change in …/pulls/N, then reply here with `/merge activit/ait_banners#N`". (The Upstream job runs on the push
    **and** when the PR is opened; shop-a is locked to 1.x and `1.x` exists, so the target is `1.x` (a commit that says `Module-Major: 2` targets `main`: 9.1b). If the module MR
    was already merged, the comment says so and asks for `/release` instead: no second MR.)
  - the project's own `.gitea/` folder is never sent upstream (ci-tools `v1.8.8`): only the module folder is compared.
  - the Checks are **red** on purpose ("drift in our own modules … expected for an in-place module change"), and the
    merge button refuses the PR, for admins too (5.5/6.6). 📸 the comment and the red check.
- [ ] **12.3 The main dev reviews and replies `/merge activit/ait_banners#N`** in the project PR. Review the change in
  the module MR first (the link in the comment). If its Checks are still running, the bot schedules the merge and
  Gitea merges it as soon as they pass; red Checks are refused. ✅ The bot answers "Merged …/pulls/N into
  `1.x` (requested by @admin)", and the *release-reminder* job adds "Module change merged … **Main devs:** reply here
  with `/release activit/ait_banners v1.1.y`" (the next patch version on `1.x`). 📸
  Only members of the `activit` **Owners** team (the main devs) can run the commands; anybody else gets "only main
  devs … can run": try it as `dev` if you like. (Merging the module MR in the module repo works too; the reminder
  then appears all the same.)
  The Forward-port job opens its `fwd/1.x/...` PR into `main` with a prompt: reply there **`/release v2.0.y`** to merge
  it and release it for the 2.x projects at once (the bot tags the merge commit and lists what the release contains;
  shop-b then gets its update PR), or `/merge` to merge only (then the bot asks for `/release` on the merged PR). 📸
  Back in shop-a's PR, a bot comment **"Where this change went"** lists every forward-port of the change with its
  state: open, merged, **released as `v2.0.y`**, or "does not apply cleanly" (with the issue). On every change it is
  posted again as the **last** comment of the PR (the previous copy is deleted). 📸
  Changes that touch only files outside the package (`.gitea/` workflows, `tests/`: `export-ignore`) are not
  released: their forward-port PR says "nothing to release, merge it", no reminder asks for `/release`, and
  `/release` refuses when nothing in the package changed since the latest tag (no empty update PRs).
  ⚠ If another in-place change to the **same lines** was merged into `1.x` since shop-a's release, `/merge` reports
  that Gitea refused the merge: the main dev resolves the conflict in the module MR. Ignore "This branch is
  out-of-date with the base branch" there: the bot branch is cut from the locked release on purpose.
- [ ] **12.4 The main dev replies `/release activit/ait_banners v1.1.y`.** ✅ The bot tags it on `1.x` ("Tagged
  `v1.1.y` on `1.x` …"), the Release job publishes it and adds it **to this PR**: one bot commit "Update
  activit/ait_banners to 1.1.y" and the comment "**Release `v1.1.y` … is now in this pull request** … review and merge"
  with the 9.3/9.4 checklist. The Checks turn **green**: merge the PR. 📸 the tag reply, the bot commit, the green PR.
  Then `git pull` locally (the bot added a commit). shop-a gets **no** separate update PR; other projects on 1.x do.
  `/release` refuses a version that exists or is not newer, one from another major line than the project's, and
  modules this PR does not change. If the bot is not on the protected-tag list (5.2), it answers with the exact
  command to tag by hand.
  The Release job falls back to a separate update PR `update/ait_banners-1.1.y` (and comments on the project PR) when:
  - **two or more** open PRs in the project change the module: each one whose change is in the release and that
    changes nothing else is **closed** as "Superseded by #N" and its branch deleted (*Restore branch* undoes it);
  - the bot **cannot push** to the branch (the developer pushed meanwhile; never forced): merge the update PR, then
    merge `main` into the branch;
  - the PR's module change is **not (fully) released** (pushed after the MR was merged): it stays open.
  If the PR conflicts with `main` after the update (`main` changed `composer.lock` meanwhile), the bot comments the
  exact commands to fix it (take main's version of the conflicted Composer files, `composer update <module>`).
  ⚠ Never commit to an `up/...` branch by hand: it is rebuilt on every push to the project pull request.
  ⚠ Projects and modules set up before ci-tools `v1.8.9` (README findings 37–41) need the new workflow files first:
  `upstream.yml` + `checks.yml` + `commands.yml` in the project; `release.yml`, `release-reminder.yml`,
  `forward-port.yml` and `commands.yml` on the module's release lines (ci-tools `v1.8.9`); and `bot` on the module's
  protected-tag list.
  Replies (`/merge`, `/release`) run the `commands.yml` of the repo's **default branch** (`main`): until it is there,
  a reply does nothing at all (no run, no answer). Merge the forward-port PR that carries the new workflows to `main`
  with the button, then post the reply again (Gitea reacts to new comments only).
---

## Phase 13 — Optional: external customers in Packeton

*Plan 10.* An external customer ("Unipo") never touches Gitea: they install from Packeton with their own token and
see only what their contract grants (packages, a version constraint, a freeze date). All in the Packeton UI as
`admin`: the top menu **Settings** holds **My users** and **My groups**.

- [ ] **13.1 The customer's group.** *Settings → My groups → **Create group***: **Name** `unipo`; leave **Update
  expiration** empty; in the package list tick **`activit/ait_banners`** and set its **Version** to `<2.0` (the
  contract covers the 1.x line). Save. 📸
- [ ] **13.2 The customer user.** *Settings → My users → **Create user***: **Username** `unipo`, an **Email**,
  **Enabled** ticked, **Password** empty ("Keep empty for only API access"), **Access expiration date** and **Update
  expiration date** empty, **Full read access** and **Maintainer** *not* ticked, **ACL Groups** `unipo`. Save. 📸
  Their API token (what you hand over with the repository URL):
  `docker compose --project-directory $REPO/ops/bare -f $REPO/ops/bare/docker-compose.yml exec packeton app packagist:user:manager unipo --show-token`
- [ ] **13.3 Test as the customer** (any machine that reaches Packeton):
  ```bash
  curl -s -u unipo:<token> http://packeton.test/p2/activit/ait_banners.json | jq -r '[.packages[][].version]|join(" ")'
  ```
  ✅ only `v1.0.0 … v1.1.x` (no 2.x, no `dev-` versions); without credentials HTTP 401; a package outside the
  grant (`activit/ait_banners_ribbon`) 404. In a customer project (`repositories: [{type: composer, url:
  http://packeton.test}]`, the token as `http-basic`), `composer require activit/ait_banners` takes the newest 1.x
  and `…:^2.0` fails.
- [ ] **13.4 Support ends: freeze.** *My users → `unipo`*: **Update expiration date** = a day (here: the day of the
  latest releases). ✅ the customer only sees versions released **before** that day and stays on them; the account
  keeps working. ⚠ Do **not** use **Access expiration date** for this: it locks them out. 📸
- [ ] **13.5 Renewal with 2.x.** Clear the user's **Update expiration date**; in *My groups → `unipo`* change the
  **Version** to `*`. ✅ the customer *sees* 2.x, but a project on `^1.1` stays on the newest 1.x with `composer update`
  ("Nothing to modify in lock file"); only `composer require activit/ait_banners:^2.0` moves it (finding 32). 📸
  ⚠ Finding 16: Packeton's metadata exposes the internal Gitea clone URL; hide it in the proxy in production.
  🧪 `./lab external` (automated lab only) shows the TLS-proxy topology.

---

## Appendix A — names that must match

The workflow stubs in `seed/` contain these literally. Use them, or edit the stubs consistently.

| Thing | Name |
| --- | --- |
| Gitea URL / Packeton URL | `http://gitea.test:3000` / `http://packeton.test` |
| Organizations | `activit` (modules, `ci-tools`), `sites` (projects) |
| Users | `admin` (main dev: tags, release lines), `dev`, `bot` (automation: tags `v*` for `/release`, creates and pushes `N.x` lines for `/release_major`) |
| Org secrets (both orgs) | `BOT_TOKEN`, `PACKETON_TOKEN` (admin token). Project repos: repo secret `PACKETON_TOKEN` of their own Packeton user (6.2b) |
| Runner label | `activit-runner` |
| ci-tools tags | `v1.9.10` everywhere (module and project workflows), including `/release_major` (9.1b) |
| Status check required on `main` and `[0-9]*.x` | `checks / checks (pull_request)` |
| Opt-in topic for update PRs | `activit-project` |
| Default branch | `main` |

## Appendix B — module repository checklist

For every module repo (`ait_banners`, `ait_banners_ribbon`, ...):

- [ ] repo in `activit`, Private; default branch `main`
- [ ] seeded with the module files **and** `seed/module-template/.gitea` (checks, release, forward-port, release-reminder, commands workflows)
- [ ] protected tag pattern `v*`, allowed users `admin` and `bot` (bot: for `/release`)
- [ ] branch rule `main` (disable push; status `checks / checks (pull_request)`; administrators must follow the rules)
- [ ] branch rule `[0-9]*.x` (push whitelist `admin` and `bot`; same status check; administrators must follow the rules)
- [ ] delete branch after merge
- [ ] registered in Packeton (Submit → VCS (auto))
- [ ] webhook to Packeton **with** `composer_package_name=activit/<repo>` (push, branch/tag creation, deletion)
- [ ] tagged `v1.0.0` by the main dev; Packeton lists it

## Appendix C — project repository checklist

For every project repo (`shop-a`, `shop-b`):

- [ ] repo in `sites`, Private; topic `activit-project` (while it should receive update PRs)
- [ ] `composer.json`: Packeton repository, `preferred-install: dist`, module constraint; `vendor/` and `web/` committed
- [ ] `.gitignore` has `web/sites/default/files/` and `config/sync/.htaccess`
- [ ] `.gitea/workflows/` has `upstream.yml`, `checks.yml` and `commands.yml` (from `seed/project-template`)
- [ ] branch rule `main` **after** the first push (disable push; status check; administrators must follow the rules);
  delete branch after merge
- [ ] Packeton credential available to DDEV through `~/.ddev/homeadditions/.composer/auth.json` (once per machine)

## Appendix D — troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Webhook delivery: `denied by egress policy` | task 1.3 (`EGRESS_MODE=lax`, `ALLOWED_HOST_LIST`) |
| Packeton: `Missing or invalid payload` / nothing indexes | org-wide or wrong hook: use the per-repo URL with `composer_package_name` (finding 1) |
| Packeton cannot clone a repo | task 2.4 (`auth.json`, host key with `:3000`); bot token scopes |
| Composer: package "could not be found", 401, or stale versions | Packeton credential missing in DDEV (lost after `ddev poweroff`: use `~/.ddev/homeadditions/.composer/auth.json`, 6.2), or silent 401 fallback (findings 8, 9, 36) |
| `ddev composer ...` hangs without output | stdin was an open pipe (CI/ssh): add `</dev/null` (finding 35) |
| First push to a project is rejected | you protected `main` before the first push (6.6) |
| PR cannot merge: "required status check" never appears | runner offline (phase 3) or the status name differs: it must be `checks / checks (pull_request)` |
| Workflow fails at `git clone .../ci-tools` | tag missing (4.2) or `BOT_TOKEN` secret not set on that organization |
| New repo/branch "not found" or "repository is empty" for ~a minute | Gitea's async bookkeeping (findings 25, 27, 34): wait, then retry |
| A `dev-up/...` version of a deleted branch lingers in Packeton | `wfb exec -u www-data packeton app packagist:update activit/<module> --delete-before` (finding 18) |
| `/release_major` refused: "is locked to …" | the project must be locked to the major before the new one (9.1b) |
| `/release_major` refused: "`N.x` already exists" or a `vN.*` tag exists | the major is already released: use `/release` on its line |
| `/release_major`: "Gitea refused to create `N-1.x`" | the bot is missing from the `[0-9]*.x` push allowlist (5.5, Appendix B) |
| Upstream opened the MR into `1.x` for a breaking change | the commit has no `Module-Major: N` trailer (9.1b); add it and push again |
| `/release_major` refused: "a commit of this pull request says another `Module-Major`" | a commit names a different major than the version: fix the trailer (its own line, exactly `Module-Major: N`) or the version |
| You want to start over | `./lab bare destroy` then `./lab bare up` |

## Appendix E — screenshot list

For the ops runbook, in order: Gitea wizard (1.1) · dashboard · users · organizations and teams · token permissions ·
egress error (optional) · Packeton home/profile · `auth.json` (masked) · secrets list · runner online · `ci-tools`
tags · module repo protected tags and the two branch rules · Packeton package page (1.0.0) · webhook deliveries ·
first PR with green Checks · direct push rejected · two projects' front pages · project topic · Actions runs ·
1.1.0 PR/tag/Release run/update PRs · ribbon on shop-b only · Composer conflict error (9.4) · both projects'
`composer.lock` after 2.0 · `1.x` and its protection · forward-port PR · conflict issue + red run · the four lock
states (11.1–11.4).
