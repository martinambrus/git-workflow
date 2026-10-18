# ci-tools

Scripts that every workflow of the shared-modules process calls. Workflows contain no `uses:` steps; they clone this
repository at a fixed tag and run a script (plan 2.4).

| Script | Run in | What it does |
| --- | --- | --- |
| `bin/upstream.sh` | project repo, every push | sends in-place module changes to a bot branch + merge request in the module repo |

```yaml
- name: Upstream
  env: { BOT_TOKEN: "${{ secrets.BOT_TOKEN }}" }
  run: |
    git clone -q --depth 1 --branch v1.0.0 "http://bot:${BOT_TOKEN}@gitea.test:3000/activit/ci-tools.git" /tmp/ci-tools
    GITEA_URL=... REPOSITORY=... BRANCH=... SHA=... /tmp/ci-tools/bin/upstream.sh
```

Tags are immutable; change a script and tag a new version, then bump the tag in the workflow stubs.

## Release and Update PRs (v1.1.0)

| Script | Run in | What it does |
| --- | --- | --- |
| `bin/release.sh` | module repo, tag `v*` | checks the tag and `composer.json`, waits until Packeton lists the version, then runs Update PRs; pre-release tags (`-rc.N`) stop after the checks |
| `bin/update-prs.sh <pkg> <tag>` | called by Release (or by hand) | for every repo with topic `activit-project`: `composer update <pkg>`, commit incl. `vendor/`, open PR `update/<module>-<ver>`; skips projects that do not require it, are already on it, are frozen, or whose constraint does not allow it |

Composer runs with a private cache and the job fails when Packeton answers 401 (Composer would otherwise fall back to stale
cache silently).

## Checks (v1.2.0)

| Script | Run in | What it does |
| --- | --- | --- |
| `bin/check-project.sh` | project repo, PRs into `main` + every push | 1 gitlinks / nested `.git`, 2 symlinks outside the project, 3 `dev-`/pre-release `activit/*` in the lock, 4 drift: reinstall from `composer.lock` in a clean checkout and compare |
| `bin/check-module.sh` | module repo, PRs | `composer.json` rules, PHP and YAML syntax |

Drift is a warning on plain branch pushes (own modules only) and a failure on PRs into `main` and on `main`. Composer's
generated files (autoloader suffix, `include_paths` order, hash constants) and CR-at-EOL differences are not compared
byte for byte; instead `vendor/composer/installed.json` is checked against `composer.lock`.

## Client patches (v1.3.0)

`bin/upstream.sh` reverses the project's `extra.patches` for a module (cweagans/composer-patches, plan section 11)
before comparing it with the locked release, so a client-only patch is never proposed to the shared module; only
real in-place edits are sent. A patch that cannot be reversed (edited on top of it, remote URL) makes the job fail
loudly instead of guessing.

## v1.3.1

The Upstream bot branch is now cut from the **locked tag**, as documented. Before, it was cut from the module
repository's default branch, which only worked while `main` still equalled the tag (found by the release-line
scenarios: a project on 1.x could not send a fix once `main` had moved to 2.0.0).

## Forward-port (v1.4.0)

| Script | Run in | What it does |
| --- | --- | --- |
| `bin/forward-port.sh` | module repo, push to a maintenance branch `<N>.x` | cherry-picks each new first-parent commit (a merged MR is taken with `-m 1`) onto the **next higher** `<M>.x`, or the default branch if there is none, on `fwd/<src>/<sha>-to-<target>`, and opens a PR. Merging that PR triggers the next hop (1.x -> 2.x -> main). Already-applied changes are skipped; a conflict opens an issue naming the files and fails the job. Idempotent (a marker in the PR/issue body). |

## Guided in-place edits (v1.5.0)

| Script | Run in | What it does |
| --- | --- | --- |
| `bin/upstream.sh` | project repo, every push and when a PR is opened | its comment on the project PR now says "do not merge" and lists what happens next; the module MR body carries an `upstream-source` marker |
| `bin/release-reminder.sh` | module repo, `pull_request: closed` | for a merged `up/...` MR: comment the next patch version (from `git describe` on the target line) with CLI and web-UI tag steps; tell the project PR |
| `bin/update-prs.sh` | called by Release | after opening an update PR: close project PRs (with the Upstream marker) whose own module diff reverse-applies to the release and that change nothing else, deleting their branch; otherwise comment what to do |
| `bin/check-project.sh` | project repo | a strict drift failure in our own modules points to the Upstream comment |

## The developer's PR becomes the update (v1.6.0)

| Script | What changed |
| --- | --- |
| `bin/update-prs.sh` | when exactly one open project PR carries the Upstream marker for the package and its own module diff reverse-applies to the release: `composer update <package>` on **that** branch, one commit, plain push (never forced), a comment with the 9.3/9.4 checklist, and a conflict recipe if Gitea reports the PR unmergeable afterwards. Otherwise a separate update PR as before (v1.5.0 close/comment logic) |
| `bin/upstream.sh` | no merge request when the target line already contains the change (merged, not released); the project PR comment says so |
| comments | "Do not merge this pull request yet … the Release job adds the release to this pull request" |

## Commands in the project PR (v1.7.0)

| Script | Run in | What it does |
| --- | --- | --- |
| `bin/commands.sh` | project repo, `issue_comment` (`commands.yml`) | `/merge <org>/<module>#<n>`: merge the module MR the Upstream job opened for this PR (Checks green); `/release <org>/<module> v<x.y.z>`: tag it on the project's line (`<major>.x` or `main`). Main devs only (Owners team of the module org); the comment is read by id, never interpolated into a shell |
| `lib/common.sh` | | `next_version` (next patch on a line), `is_main_dev` (Owners team membership) |

## Releasing forward-ports from their PR (v1.8.0)

| Script | What changed |
| --- | --- |
| `bin/forward-port.sh` | comments on each forward-port PR: reply `/release vX.Y.Z` (merge + release) or `/merge`; adds the hop to the origin project PR's overview (also "already there" and conflicts) |
| `bin/commands.sh` | in module repos, on forward-port PRs: `/merge`; `/release vX.Y.Z` merges and tags the merge commit (or tags the line's head if merged already) and lists what the release contains |
| `bin/release-reminder.sh` | a merged forward-port: overview "released as vX" or "not released yet" plus a `/release` prompt |
| `lib/common.sh` | `origin_of` (project PR behind a module commit, across hops), `overview` (one updatable comment), `latest_tag` (line-aware) |
| `commands.yml` | now also in the module template |

**v1.8.1:** `origin_of` also finds a merged project PR whose branch was deleted (Gitea reports `head.ref` as
`refs/pull/<n>/head` then; `head.label` keeps the branch name).

**v1.8.2:** a merged forward-port counts as released when any release on its line contains it (`released_in`);
`/release` on a merged forward-port refuses an empty release (already released, or nothing new on the line).

**v1.8.3:** the forward-port prompt says "merge with the button" while the default branch has no `commands.yml`
(replies would do nothing there).

**v1.8.4:** the overview comment in the project PR moves to the end of the conversation on every update (posted
anew, the old copy deleted).

**v1.8.5:** CI-only changes (nothing in the package archive differs, `export-ignore` applied) get no release prompt
or reminder, and `/release` refuses them (`package_changed`).

**v1.8.6:** Upstream does not re-push an identical bot branch (same parent and tree), so the MR's Checks do not restart;
`/merge` while Checks are running schedules Gitea's merge-when-checks-succeed.

**v1.8.7:** `commands.sh` routes by the pull request, not by the repository's org: a forward-port PR (its body carries
`<!-- forward-port:… -->`) goes to the module path, every other PR to the project path. Project repositories live in the
same org as the modules, so before this every project-PR command was answered with the forward-port message.

**v1.8.8:** `upstream.sh` ignores the project's `.gitea/` folder when it compares a module with its release. That folder
is CI (`export-ignore` in the module, not part of the package), so a pinned workflow copy in a project's module folder
no longer opens a merge request in the module repository.

**v1.8.9:** `update-prs.sh` checks whether a project pull request's module change is in the release without its
`.gitea/` files (CI, excluded from the package): the module part of a pull request that also bumped the pins is no longer
rejected, so the Release job adds the release to that pull request instead of opening a separate update pull request.

**v1.9.2:** `bin/check-project.sh` no longer skips the drift check silently. A project with a committed `composer.lock`
but no committed `vendor/composer/installed.json` is a warning on feature branches and a failure on pull requests into
`main` and on `main`: the drift check cannot compare the module folders without `vendor/`.

**v1.9.1:** a new major can be sent from a project still locked to the old one. `bin/upstream.sh` reads a
`Module-Major: N` line in the project's commit messages for the module (N above the locked major) and targets `<N>.x`
if it exists, else `main`. Without the line it targets the locked major's line as before. Before, a breaking change
sent from a 1.x project always went to `1.x`.

`bin/commands.sh` gets `/release_major <org>/<module> vN.0.0`, the first release of a new major, from a project pull
request whose commits say `Module-Major: N`. Refused unless the project is locked to N-1, the module has no `N.x`
line and no `vN.*` tag, main's last release of N-1 is the newest thing on main, and the module merge request into `main`
is open with green Checks. Then it creates `<N-1>.x` at that release, merges the merge request and tags `vN.0.0` on the
merge commit. The bot may create release lines (`ops/bin/lib.sh`: the `[0-9]*.x` rule whitelists it).
