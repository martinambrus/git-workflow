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
