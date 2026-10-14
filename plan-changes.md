# Plan changes from the pilot lab

*For the Elmont call. Maps what the lab found to the sections of [`shared-drupal-modules-workflow.md`](shared-drupal-modules-workflow.md).
Evidence: finding numbers refer to the numbered list in [`README.md`](README.md); "e2e" means a step of `./lab e2e`
(about 110 assertions, passed on three complete from-scratch runs; see the README for the one unexplained flake, finding 34).*

Legend: **FIX** the plan is wrong or fails as written · **ADD** missing rule or step · **CLARIFY** correct but ambiguous ·
**OK** confirmed unchanged · **OPEN** not verified here.

## 1. Summary

| # | Section | Type | Change in one line | Evidence |
| --- | --- | --- | --- | --- |
| 1 | 1 (rule 3), 2.1, 4.3, 12, App. B | **FIX** | No organization-wide webhook to Packeton: use a per-repository hook with `composer_package_name`, created with the module | F1, F2 |
| 2 | 2.1 | **FIX** | Gitea 28 blocks webhooks to private addresses by default; set the egress policy | F2 |
| 3 | 12 (check 4), 14.4 | **FIX** | "Reinstall and diff everything" fails on every project: `vendor/` is not byte-reproducible | F12 |
| 4 | 6.5, App. A | **FIX** | The Upstream bot branch must be cut from the **locked tag**; the workflow glue got this wrong | F29 |
| 5 | 11 ("client-only change", second choice) | **FIX** | A patched shared module looks like an in-place edit: Upstream must reverse declared patches | F22 |
| 6 | 2.2 | **CLARIFY** | How Packeton reads private Gitea repos (token in `auth.json`, host key includes the port; or SSH key) | F3 |
| 7 | 2.5, 3 | **ADD** | Project template: `.gitignore` entries, `allow-plugins`, committed `settings.php` | F5, F23, F28 |
| 8 | 2.3, 9, 12 | **ADD** | Composer silently uses stale cache on a 401: fail CI on it; set credentials per project | F8, F9 |
| 9 | 4.3, 4.4 | **CLARIFY** | Register the package first, then tag; allow for async visibility of new branches | F6, F25, F27 |
| 10 | 10 | **ADD** | Packeton leaks the internal Gitea clone URL to customers | F16 |
| 11 | 10 | **CLARIFY** | Two different expiries; re-subscription is a grant change **plus** a deliberate migration | F17, F32 |
| 12 | 11 ("fix for an old release line"), 6.5 | **ADD** | Generalise to `<major>.x`; release lines are auto-protected (glob rule); fixes are forward-ported automatically (1.x -> 2.x -> main), conflicts become issues | F30, F31, F33 |
| 13 | 11 ("test unreleased code") | **ADD** | `dev-up/...` works; add `@dev`, cleanup of bot branches and of Packeton's stale dev versions | F13, F18 |
| 14 | 12 (Release, Update PRs) | **ADD** | Runner image needs Composer; pre-releases open no PRs; skip rules for pinned/major/expired | F11, F19 |
| 15 | 9.3 | **CLARIFY** | The update PR in the developing project only shows no module diff if the fix is already on `main` | F10 |
| 16 | 12 (Checks), 2.1 | **ADD** | Required status context names, protection applies to admins, check cost and runner capacity | F14, F15, F24 |
| 17 | 11 (new) | **ADD** | Shared **extension packages**: they block a base major upgrade until compatible; migrate together | e2e L4, L7 |
| 18 | 11 ("client-only change", first choice) | **OK** + note | Extension module in the project verified; one Drupal gotcha worth documenting | F21 |
| 19 | 7.1, 3 | **CLARIFY** | A fresh clone has no database: `drush si --existing-config` rebuilds from committed config | README "Drupal projects" |
| 20 | 14.4, 14.5 | **FIX** | Update the status lists: what is confirmed, what changed, what is built | section 4 below |
| 21 | 2.3, 12 | **ADD** | `ddev` (and anything that wraps it) hangs silently on an inherited open stdin in unattended runs: close stdin in scripts/CI | F35 |
| 22 | 4.3, 4.4, 12 | **ADD** | After a first push Gitea lags in more than one way (branch record, repository `empty` flag): never read or protect a repo immediately | F25, F27, F34 |

## 2. Details by plan section

### Section 1 (rules) and 2.1 (Gitea and runners)

**1. Webhook (FIX, rule 3, 2.1 last bullet, 4.3, section 12 first row, Appendix B).** The plan relies on one organization
webhook that covers every module repository. With Gitea 28.1 and current Packeton this does not work:
the `gitea` payload carries `repository.url` (the API URL), which Packeton's generic parser cannot match to a package
(`406 Missing or invalid payload`), and Gitea's `packagist` hook type is hard-wired to `packagist.org` and cannot
be created through the API (it would have sent pushes to the public internet).
*Change:* create a **per-repository** hook of type `gitea` pointing at
`/api/update-package?username=<u>&apiToken=<t>&composer_package_name=<org>/<module>`, events push/create/delete, as part of
"create a module" (4.3). Re-evaluate Packeton's Gitea OAuth integration if an org-level mechanism is a hard requirement
(not tried). *Evidence:* F1, smoke test, every release in e2e.

**2. Egress policy (FIX, 2.1).** Gitea 28 refuses webhooks and migrations to private addresses.
*Change:* add to the Gitea setup: `[security] EGRESS_MODE = lax` and `ALLOWED_HOST_LIST = private,loopback` (or the
explicit Packeton host in production). *Evidence:* F2.

**16 (part). Branch protection (ADD, 2.1 last bullets).** "Protect `main` ... checks required" works and binds admins
too (verified: direct push rejected for `admin` and `dev`; merge blocked with 405 while the check fails).
Add: the required status context is named `<workflow> / <job> (<event>)` (`checks / checks (pull_request)`) and
exists only after the first run, so the workflow stub must land before the rule is meaningful; an empty repo
cannot be protected before its first push; protect `main` only once it exists (and wait for Gitea to list it).
*Evidence:* F15, F24, F25.

**23 (part). Runner image (ADD, 2.1 second bullet).** The image needs, beyond the plan's list: Composer, `jq`, `patch`,
`perl` (drift normalisation) and the PHP `yaml` extension (YAML syntax check; it would have caught the
quoted-colon bug in the first module release, F7). Pushing the image to Gitea's own container registry was **not**
tested (the lab uses a locally built image). *OPEN.*

**2.4 workflows without github.com (OK).** Run-only workflows work: clone `ci-tools` and the repository with the bot
token, `github.server_url`, `github.repository`, `github.ref_name`, `github.head_ref`, `github.base_ref`,
`github.event_name` resolve. Keep the token out of URLs and logs by passing it through `GIT_CONFIG_*` env.

### Section 2.2 (Packeton), 2.3 (developer machines)

**6. Reading private Gitea repos (CLARIFY, 2.2).** The lab used Composer `auth.json` in Packeton's Composer home with
HTTP basic for the bot token; for generic Git URLs **the key must include the port** (`gitea.test:3000`). The plan's
"read-only deploy key" (SSH) was not exercised. Pick one and document the exact steps.

**8. Silent stale-cache fallback (ADD, 2.3, 9, 12).** When Packeton answers 401, Composer prints one warning, uses
stale cache and **exits 0**; `composer update` then reports "Nothing to modify" and a new release is never seen.
*Change:* every CI job that runs Composer uses a private cache and fails on "could not be fully loaded" /
"required authentication"; developer instructions mention it. *Evidence:* F8 (hit in practice after a token rotation).

**9. DDEV credentials are per project (ADD, 2.3).** DDEV's `composer config --global` is stored per project container,
so the Packeton token must be set in every project, not once per machine. *Evidence:* F9.

**21. Unattended `ddev` (ADD, 2.3 and CI notes).** `ddev composer ...` launched with stdin as an open pipe or socket that
never sends data (CI runners, `ssh host cmd`, IDE tasks, `xargs`) blocks for ever **without printing anything**; with
`</dev/null` the same command finishes in seconds. Interactive terminals are not affected, so it only shows up in
automation. Any script or pipeline that drives DDEV must close stdin. *Evidence:* F35.

**19 (part). Developer onboarding (CLARIFY, 7.1).** "A plain git clone is all a developer needs" is true for code, but
the **database is not in Git**. Document `drush si --existing-config` (rebuilds the site from the committed
`config/sync`; content is not preserved) or whatever dump process the team uses.

### Section 2.5 and 3 (project template, create a project)

**7. Template contents (ADD).** `drupal/recommended-project` ships **no `.gitignore`**, so Drupal's runtime files would
be committed. The template needs `web/sites/default/files/` and `config/sync/.htaccess` ignored (Drupal writes the
latter lazily, after the scaffold's commit, and would leave the tree dirty), a committed config sync directory
(`$settings['config_sync_directory'] = '../config/sync'` placed **before** DDEV's include), `settings.php` committed
(as rule 5 implies), and `allow-plugins` for anything the template uses (`cweagans/composer-patches`).
*Evidence:* F5, F23, F28. `git check-ignore` in section 3 is correct and still worth running.

### Section 4 (create a module)

**9. Order and timing (CLARIFY, 4.3/4.4).** Registering a package **after** its first tag was pushed works
(registration indexes existing tags), but the webhook only fires for registered packages, so "register, then tag" is
the clean order. A just-pushed branch is not visible to Gitea's API/raw-file endpoints for a few seconds; scripts
must wait for `main` before registering or protecting. The lag has **two** parts: the branch record and the
repository's `empty` flag; the raw-file API kept answering "repository is empty" for well over 18 seconds after a push
under CI load. Any automation that reads or protects a repository right after its first push must wait for both
(`GET /repos/<r>` reports `"empty": false`). *Evidence:* F6, F25, F27, F34.

**CLARIFY (4.2).** `export-ignore` is honoured by Packeton's archives (verified: no `tests/`, `.gitea/`,
`.gitattributes` in the installed package; no false drift against `git archive` of the tag). Keep the `.gitattributes`
rule, including `/.gitea`. *OK.*

### Section 6 (work on the module) and Appendix A (upstream script)

**4. Bot branch from the locked tag (FIX, 6.5, Appendix A).** Appendix A clones the module at the tag; the workflow
glue built from it cloned the default branch instead and then created the bot branch there. It worked only while
`main` equalled the tag; once `main` moved on, a client on the older line could not send a fix
(`patch does not apply`). *Change:* state in 6.5 and in "what the workflow still has to add" that the bot branch is
cut from the **locked tag** (`git switch -c <bot-branch> refs/tags/<tag>`), and add the scenario "main is ahead of the
locked tag" to the test list. *Evidence:* F29, e2e L6.

**12 (part). Target branch (CLARIFY, 6.5).** The plan says "1.x if that branch exists, otherwise main"; the working rule
is **`<locked major>.x` if that branch exists, else `main`**. Verified for `1.x` and for `2.x`. *Evidence:* F30, e2e L6, L9.


**24. Guide the in-place edit flow (ADD, 6.5, 8.1, 9).** A developer who edits a module inside a project has a project
PR that must never be merged, and nothing told them so; after the release they had to know to close it. *Change:*
(a) the Upstream job's comment on the project PR says "do not merge" and lists the three steps that follow; the
failing drift check points to it; the job also runs when the PR is opened (F37); (b) when a merge request from the
Upstream job is merged, a `release-reminder` job comments the next version and how to tag it, and tells the project
PR; (c) the Release job adds the release to the developer's own PR (one `composer update` commit on its branch) so
that PR turns green and is merged; it falls back to a separate update PR (closing superseded module-only PRs) when
several PRs change the module, the branch moved, or the change is not fully released; (d) the Upstream job opens no
second merge request for a change that is merged but not released; (e) protection rules block admins from
force-merging red PRs; (f) main devs reply `/merge …` and `/release …` in the project PR and the bot
merges the module MR and tags the release (Owners team only); (g) forward-port PRs ask for `/release` (merge + tag)
or `/merge`, and the project PR tracks every hop in one comment. *Evidence:* F38 (v1.5.0), F39 (v1.6.0), F40 (v1.7.0),
F41 (v1.8.0), e2e step 3 and L6.

### Section 8 and 9 (release, apply a release)

**15. 9.3 wording (CLARIFY).** "In the project that developed the change the module folder should hardly change" holds
only if the fix is already on that project's `main` (or you update on the feature branch). If the feature branch has
not merged yet, the update PR on `main` shows the whole release in the module folder; both merge cleanly because the
content is identical. *Evidence:* F10.

**8.3 tags (OK).** Only main devs can create `v*` tags (verified: the bot's tag push is rejected). Tag on the
maintenance branch for patch releases of an old line; the Release job triggers on the tag event regardless of branch.

**9 (OK).** `composer update <module>` replaces an edited module folder without prompting (dist install);
`composer update --lock` is needed after hand-editing `extra.patches` (content hash). *Evidence:* F23.

### Section 10 (external customers)

**11. Expiry and re-subscription (CLARIFY).** Packeton has two expiries: **`expiredUpdatesAt`** (the plan's behaviour:
the customer is frozen on what was released before the date) and a user's **`expireAt`** (account expiry: locked out
entirely). State which one the contract maps to. A **re-subscription** is two separate acts: widen the grant / clear
the expiry in Packeton (the customer can now *see* the new line), and a deliberate `composer require ^2.0` on the
client side (nothing moves by itself; `composer update` stays within the constraint). Verified for an external
customer and for an internal client (topic added back). *Evidence:* F17, F32, e2e L8, L9.

**10. Internal hostname leak (ADD).** Packeton publishes the internal Gitea clone URL as `source.url` in every
package's metadata and has no setting to hide it. Customers install dist archives only, but the hostname is
disclosed. *Change:* rewrite it in the TLS proxy (lab: `sub_filter`) or use an internal-only hostname.
*Evidence:* F16.

**OK (10, 2.2).** Verified in a separate-network topology: customers reach only the TLS proxy (Gitea and Packeton's
internal address unreachable), dist URLs carry the external scheme and host (Packeton honours `X-Forwarded-*`),
a grant constraint (`<1.1`, `<2.0`) is enforced including at `composer require`, anonymous access is 401.
*OPEN:* real internet exposure, a publicly trusted certificate, rate limits.

### Section 11 (special cases)

**12. Old release line (ADD).** Verified end to end with a real `2.0.0` and real `1.x`/`2.x` branches, and now
automated where the pilot first had manual gaps:
create the line from its last tag (only the main dev can: a push); **protection is automatic** through one glob rule
`[0-9]*.x` per module repo (PR only, Checks required; the main dev is on the push whitelist because creating the
branch is a push, like for tags; the module `checks.yml` triggers on `*.x`); the Upstream MR targets that branch;
tag the patch release **on that branch**; the Release job opens update PRs only for clients that opted in and are on
that line. **Forward-porting is automated** by the `forward-port` job (ci-tools v1.4.0): a change merged into `1.x` is
cherry-picked onto the next higher line (or `main`) as a PR, each merge triggers the next hop, and a conflict opens
an issue instead of guessing. *Evidence:* F30 to F33, e2e L3, L6, L9.

**13. Unreleased code in another project (ADD).** `composer require activit/<m>:dev-up/<project>/<branch>@dev` installs
exactly the bot branch (verified in a real project, locked to the branch's commit). Add: the `@dev` flag, that
`composer.lock` with a `dev-` version is rejected on PRs into `main` (verified), and housekeeping: Packeton **keeps**
the `dev-` version of a deleted branch until `packagist:update <pkg> --delete-before`; enable "delete branch after
merge" on module repos and prune periodically (`./lab prune`). *Evidence:* F13, F18.

**5. Client-only change, second choice (FIX).** A client patch applied by `cweagans/composer-patches` is
**reproducible** (the drift check passes) but looks like an in-place edit to the Upstream job, which then opened a
green merge request proposing the client's patch to the shared module. *Change:* Upstream reverses the module's
`extra.patches` before comparing (implemented in `ci-tools` v1.3.0; patches that cannot be reversed or are remote
URLs fail the job loudly). Also document: `allow-plugins` per project, `composer update --lock` after editing
`extra.patches`. *Evidence:* F22, F23.

**18. Client-only change, first choice (OK).** An extension module inside the project works as the plan says: it is
invisible to Upstream (not an `activit/*` package), passes the Checks gate (not Composer-managed, so a clean reinstall
leaves it), and can add form fields and rendering through core hooks. One Drupal gotcha worth putting in the
guidance: core's block `#pre_render` unsets `#block`, so read what you need in `hook_block_view_*_alter` and carry it
on the build array. *Evidence:* F21.

**17. Shared extension packages (ADD, new case).** A separate shared package that requires the base module
(`"activit/base": "^1.0"`) behaves correctly, and the plan should describe it: Composer **refuses** the base's major
upgrade in a project that has the extension until the extension releases a version requiring the new major; the
extension's `2.0.0` can only be installed after the base's `2.0.0` exists in Packeton (release order: base, then
extension); Update PRs do not move the extension to its new major automatically (its constraint is `^1.0`); the
client migrates both with one `composer require base:^2.0 ext:^2.0` PR. *Evidence:* e2e L4, L7.

**Third-party modules, freeze (OK).** A project pinned to an exact version is skipped by Update PRs ("its constraint
'1.1.1' does not allow 1.1.2") even while it keeps the topic; the topic is only needed to stop the PR attempt noise.

### Section 12 (what Gitea automates)

**14. Release and Update PRs (ADD).** Behaviour verified: the Release job checks the tag and `composer.json`, waits
for Packeton, then opens `update/<module>-<version>` PRs for topic-carrying projects, authored by the bot, with the
module diff stat and the 9.3/9.4 checklist; re-running does nothing; a malformed tag fails; a pre-release tag
(`-rc.N`) stops after the checks and opens no PRs (Packeton does list pre-releases in its stable metadata; customers
only get them when their `minimum-stability` allows it). The runner image needs Composer (the job validates
`composer.json` and runs `composer update` per project). *Evidence:* F11, F19.

**3. Check 4, drift (FIX).** After a clean `composer install` from the lock, real package code is identical but
Composer's *generated* files differ (autoloader suffix, `include_paths.php` order, `DrupalInstalled::VERSIONS_HASH`, the
root package's reference) and one shipped file differs only by CRLF. Compare package files; ignore Composer-generated
metadata and CR-at-EOL; additionally verify that the committed `vendor/composer/installed.json` matches
`composer.lock` (same packages, versions, references). Severity as the plan says: warning on branch pushes for our own
modules, failure on PRs into `main`. *Evidence:* F12, negative tests (own edit, third-party edit, symlink, gitlink,
`dev-` in the lock all fail as designed).

**16 (part). Cost (ADD).** Each Checks run reinstalls core (about a minute locally); push and PR events both fire for a
PR branch; with `capacity: 2` runs queue. Size runners accordingly. *Evidence:* F14.

**Checks 1, 2, 3, 5 (OK).** Gitlinks and nested `.git`, symlinks outside the project, `dev-`/pre-release versions of
our modules in the lock on `main`, and the module-side check (valid JSON, no `version` key, name matches, plus PHP and
YAML syntax) behave as specified.

### Section 14 (decisions and verification status)

**20. Rewrite 14.4 and 14.5.** See the next section.

## 3. Things to add to the decisions list (14.1)

1. **Maintenance branch policy:** which lines exist and how long they live; the main-dev account that may create/push
   release lines (whitelisted, like tag creation); who reviews and merges forward-port PRs and handles the conflict issues.
2. **Customer expiry model:** `expiredUpdatesAt` (freeze) vs account expiry, per contract.
3. **Where Packeton reads from:** token vs deploy key, and who rotates it (a rotation silently breaks CI without the
   401 check).
4. **Org-level webhook:** accept per-repository hooks created at module creation, or invest in Packeton's Gitea OAuth
   integration.

## 4. Status of section 14.4 after the pilot

| 14.4 item | Result |
| --- | --- |
| Actions enabled, runner works with our own image | **OK** with a locally built image; Gitea's container registry **OPEN** |
| Org webhook reaches Packeton, new tag appears within a minute or two | **FIX**: per-repo hook works (seconds); org hook does not (item 1) |
| Packeton archives leave out `export-ignore` files | **OK** |
| `dev-` versions incl. slashes install | **OK** (item 13) |
| Customer limits: constraint, release date, expiry freeze | **OK** (item 11); release-date semantics tested with back-dated releases |
| Packeton external over HTTPS, Gitea internal | **OK** in a separated-network topology; internet exposure **OPEN** |
| Bot token scopes sufficient | **OK**: `write:repository`, `write:issue`, `write:organization`, `read:user`; the bot also needs write access via a team on the project repos |
| Run-only workflows clone `ci-tools` and the repo | **OK** |
| `drupal-custom-module` lands in `web/modules/custom/` | **OK** with the stock installer paths |
| `composer update` replaces an edited folder without prompting | **OK** |
| `composer-patches` with committed `vendor/` | **OK** with caveats (items 5, 7) |
| CI drift check reproduces committed `vendor/` | **FIX** as stated (item 3) |
| Speed and ergonomics on the largest project | **OPEN**: the lab projects are small |

14.5 "still to build" is now built in the lab: webhook setup (changed), Checks, Release, Update PRs, the Upstream workflow,
the runner image and the template material (`seed/`). What remains for Elmont is productionising it: the templates in
Gitea, the registry image, HTTPS in front of Packeton, runner sizing, and the decisions in section 3.
