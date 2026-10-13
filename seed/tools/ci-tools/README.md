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
