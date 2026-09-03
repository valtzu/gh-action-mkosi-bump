# gh-action-mkosi-bump

A GitHub Action that keeps [mkosi](https://github.com/systemd/mkosi) images
up-to-date, in the spirit of
[phips28/gh-action-bump-version](https://github.com/phips28/gh-action-bump-version)
but for mkosi instead of `npm version`.

It can:

1. Run `mkosi bump` (increment `mkosi.version`).
2. Update `Snapshot=` (`[Distribution]`) and/or `ToolsTreeSnapshot=` (`[Build]`)
   in your mkosi config from `mkosi latest-snapshot`.
3. Commit / tag / push the result, the same way `gh-action-bump-version` does.
4. Or open a pull request instead — either **one rolling PR** that gets amended
   on every run, or **a fresh PR per bump**.

> Tagging PRs that contain security updates is planned but not implemented yet.

## Quick start

Keep a single rolling PR up to date every night:

```yaml
name: mkosi package updates
on:
  schedule: [{ cron: "0 3 * * *" }]
  workflow_dispatch:
permissions:
  contents: write
  pull-requests: write
jobs:
  bump:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: valtzu/gh-action-mkosi-bump@v1
        with:
          bump-version: "true"          # run `mkosi bump`
          bump-snapshot: "true"         # update Snapshot= from `mkosi latest-snapshot`
          install-mkosi: "true"
          mkosi-version: "v27"
          pull-request: "true"
          pull-request-strategy: update
```

More examples in [`examples/`](examples/).

## What it updates

Three independent switches — enable any combination (at least one):

| Input | Default | Effect |
|-------|---------|--------|
| `bump-version` | `true` | `true` runs `mkosi bump` → increments `mkosi.version`. `patch` / `minor` / `major` instead increment that component of the latest `X.Y.Z` git tag and leave `mkosi.version` alone (for when it is a `git describe` script); in these modes the run is a no-op (`changed=false`, no tag, no dispatch) unless a snapshot moved **or** the working tree differs from that last tag - so an unchanged repo produces no release. `false` leaves the version untouched. |
| `bump-snapshot` | `true` | runs `mkosi latest-snapshot`, rewrites `Snapshot=` in `[Distribution]` if it changed |
| `bump-tools-tree-snapshot` | `false` | runs `mkosi latest-snapshot`, rewrites `ToolsTreeSnapshot=` in `[Build]` if it changed |

For each snapshot setting the action finds the config file that already contains
that line (top-level `mkosi.conf` or any `mkosi.conf.d/*.conf`); if none does, it
writes one into `mkosi.conf` under the right section. Override the target file
with `mkosi-config`.

`mkosi latest-snapshot` resolves the snapshot for the *image* distribution. For
`ToolsTreeSnapshot` you usually need `tools-tree-latest-snapshot-args` to point it
at the tools-tree distribution, e.g. `--distribution debian --release testing`.

## PR vs direct commit (feature 4)

* `pull-request: false` *(default)* — commit straight to `target-branch`
  (or the branch the workflow runs on), then push, exactly like
  `gh-action-bump-version`. Set `dispatch-workflow` to a workflow file name to
  `workflow_dispatch` it afterwards against the new tag (or the branch, if
  nothing was tagged) — a tag pushed with `GITHUB_TOKEN` does not start
  `on: push` runs, so this is how you kick a release build without a PAT.
* `pull-request: true` with:
  * `pull-request-strategy: update` *(default)* — always uses the branch
    `pull-request-branch` (default `mkosi-bump`), force-pushes it and reuses the
    existing open PR. Each run replaces the previous bump commit, so you get one
    continuously-updated PR.
  * `pull-request-strategy: new` — appends the new version + snapshot to the
    branch name and opens a separate PR every time.

## Inputs

### What to update
| Input | Default | Description |
|-------|---------|-------------|
| `bump-version` | `true` | run `mkosi bump` |
| `bump-snapshot` | `true` | update `Snapshot=` (`[Distribution]`) from `mkosi latest-snapshot` |
| `bump-tools-tree-snapshot` | `false` | update `ToolsTreeSnapshot=` (`[Build]`) from `mkosi latest-snapshot` |
| `working-directory` | `.` | where the mkosi config lives / mkosi is invoked |
| `mkosi-config` | *(auto)* | config file whose snapshot setting(s) to update |
| `mkosi-args` | | extra global args for every mkosi call, e.g. `--distribution debian` |
| `latest-snapshot-args` | | extra args for `mkosi latest-snapshot` when resolving `Snapshot=` |
| `tools-tree-latest-snapshot-args` | *(= latest-snapshot-args)* | ditto for `ToolsTreeSnapshot=`, e.g. `--distribution debian --release testing` |
| `install-mkosi` | `false` | `pip install` mkosi before running |
| `mkosi-version` | *(latest)* | tag/branch (`v27`, `main`) or PEP 440 specifier (`>=25,<26`) |

### Commit / tag (same semantics as gh-action-bump-version)
| Input | Default | Description |
|-------|---------|-------------|
| `git-user-name` | `github-actions[bot]` | commit author name |
| `git-user-email` | `…github-actions[bot]@users.noreply.github.com` | commit author email |
| `commit-message` | *(auto)* | template; defaults to `Release {{version}}` on a version bump, else `Update mkosi package snapshot` |
| `tag-prefix` / `tag-suffix` | | wraps the tag and `{{version}}` |
| `skip-tag` | `false` | don't create a tag |
| `skip-commit` | `false` | don't commit (implies skip-tag/skip-push) |
| `skip-push` | `false` | don't push |
| `commit-no-verify` | `false` | `git commit --no-verify` |
| `target-branch` | *(current)* | branch to commit on in non-PR mode |
| `dispatch-workflow` | | non-PR mode: `workflow_dispatch` this workflow after the push, against the new tag / branch |

Template placeholders: `{{version}}`, `{{snapshot}}`, `{{tools_tree_snapshot}}`,
`{{old_version}}`, `{{old_snapshot}}`, and `{{summary}}` (PR body only).

### Pull request
| Input | Default | Description |
|-------|---------|-------------|
| `pull-request` | `false` | open/update a PR instead of committing to the branch |
| `pull-request-strategy` | `update` | `update` (one rolling PR) or `new` (PR per bump) |
| `pull-request-branch` | `mkosi-bump` | head branch |
| `base-branch` | *(default branch)* | PR base |
| `pull-request-title` | *(auto)* | template; same default as `commit-message` |
| `pull-request-body` | `{{summary}}` | template |
| `pull-request-labels` | | comma-separated labels |
| `github-token` | `${{ github.token }}` | token for push + `gh` |

## Outputs

`changed`, `old-version`, `new-version`, `version` (with prefix/suffix),
`old-snapshot`, `new-snapshot`, `old-tools-tree-snapshot`,
`new-tools-tree-snapshot`, `new-tag`, `pull-request-number`, `pull-request-url`.

## Permissions

* Direct commit / push: `permissions: contents: write`.
* PR mode: also `pull-requests: write`.
* `dispatch-workflow`: also `actions: write`.

## GitHub-hosted runner notes

* **User namespaces.** `mkosi latest-snapshot` fetches over the network inside
  mkosi's sandbox, which needs unprivileged user namespaces. GitHub-hosted Ubuntu
  runners block those by default (`prctl … Operation not permitted`). When a
  snapshot bump is requested the action relaxes this automatically via
  `sudo -n sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` (best effort).
  On runners without passwordless sudo, run that yourself in an earlier step.
  `bump-version`-only runs don't need it.
* **`ToolsTree=default`.** With a default tools tree configured, `mkosi
  latest-snapshot` would look for `curl` *inside* the (usually unbuilt) tools tree
  and fail with `curl not found`. The action passes `--tools-tree=` to those calls
  so the host's `curl` is used instead. To force the tools tree anyway, append
  your own `--tools-tree=<path>` via `latest-snapshot-args`.

## Development

```bash
bash tests/run.sh          # fast unit tests, uses a fake mkosi (no network)
bash tests/integration.sh  # runs against the real `mkosi` on PATH
```

CI ([`.github/workflows/test.yml`](.github/workflows/test.yml)) runs the
integration test against a matrix of real mkosi versions (`v26`, `v27`, `main`),
because mkosi's CLI moves fast. `Snapshot=` / `mkosi latest-snapshot` were
introduced in mkosi v26, so that is the minimum supported version for snapshot
mode; `bump` mode works with older mkosi too.

## License

MIT
