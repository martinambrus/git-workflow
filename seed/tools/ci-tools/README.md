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

