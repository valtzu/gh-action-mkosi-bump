# gh-action-mkosi-bump

A GitHub Action that keeps [mkosi](https://github.com/systemd/mkosi) images
up-to-date, in the spirit of
[phips28/gh-action-bump-version](https://github.com/phips28/gh-action-bump-version)
but for mkosi instead of `npm version`.

It can:

1. Run `mkosi bump` (increment `mkosi.version`).
2. Update `Snapshot=` in your mkosi config from `mkosi latest-snapshot`.
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
          mode: both
          install-mkosi: "true"
          mkosi-version: "v27"
          pull-request: "true"
          pull-request-strategy: update
```

More examples in [`examples/`](examples/).

## Modes

| `mode`     | Effect                                                                  |
|------------|------------------------------------------------------------------------|
| `bump`     | runs `mkosi bump`                                                       |
| `snapshot` | runs `mkosi latest-snapshot` and rewrites `Snapshot=` if it changed     |
| `both`     | *(default)* both of the above                                           |

For `snapshot` mode the action finds the config file that already contains a
`Snapshot=` line (top-level `mkosi.conf` or any `mkosi.conf.d/*.conf`). If none
does, it writes one into `mkosi.conf` under `[Distribution]`. Override the target
with `mkosi-config`.

## PR vs direct commit (feature 4)

* `pull-request: false` *(default)* — commit straight to `target-branch`
  (or the branch the workflow runs on), then push, exactly like
  `gh-action-bump-version`.
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
| `mode` | `both` | `bump`, `snapshot`, or `both` |
| `working-directory` | `.` | where the mkosi config lives / mkosi is invoked |
| `mkosi-config` | *(auto)* | config file whose `Snapshot=` to update |
| `mkosi-args` | | extra global args for every mkosi call, e.g. `--distribution debian` |
| `latest-snapshot-args` | | extra args for `mkosi latest-snapshot` |
| `install-mkosi` | `false` | `pip install` mkosi before running |
| `mkosi-version` | *(latest)* | tag/branch (`v27`, `main`) or PEP 440 specifier (`>=25,<26`) |

### Commit / tag (same semantics as gh-action-bump-version)
| Input | Default | Description |
|-------|---------|-------------|
| `git-user-name` | `github-actions[bot]` | commit author name |
| `git-user-email` | `…github-actions[bot]@users.noreply.github.com` | commit author email |
| `commit-message` | `ci: bump mkosi packages to {{version}}` | template |
| `tag-prefix` / `tag-suffix` | | wraps the tag and `{{version}}` |
| `skip-tag` | `false` | don't create a tag |
| `skip-commit` | `false` | don't commit (implies skip-tag/skip-push) |
| `skip-push` | `false` | don't push |
| `commit-no-verify` | `false` | `git commit --no-verify` |
| `target-branch` | *(current)* | branch to commit on in non-PR mode |

Template placeholders: `{{version}}`, `{{snapshot}}`, `{{old_version}}`,
`{{old_snapshot}}`, and `{{summary}}` (PR body only).

### Pull request
| Input | Default | Description |
|-------|---------|-------------|
| `pull-request` | `false` | open/update a PR instead of committing to the branch |
| `pull-request-strategy` | `update` | `update` (one rolling PR) or `new` (PR per bump) |
| `pull-request-branch` | `mkosi-bump` | head branch |
| `base-branch` | *(default branch)* | PR base |
| `pull-request-title` | `ci: bump mkosi packages to {{version}}` | template |
| `pull-request-body` | `{{summary}}` | template |
| `pull-request-labels` | | comma-separated labels |
| `github-token` | `${{ github.token }}` | token for push + `gh` |

## Outputs

`changed`, `old-version`, `new-version`, `version` (with prefix/suffix),
`old-snapshot`, `new-snapshot`, `new-tag`, `pull-request-number`,
`pull-request-url`.

## Permissions

* Direct commit / push: `permissions: contents: write`.
* PR mode: also `pull-requests: write`.

## Development

```bash
bash tests/run.sh          # fast unit tests, uses a fake mkosi (no network)
bash tests/integration.sh  # runs against the real `mkosi` on PATH
```

CI ([`.github/workflows/test.yml`](.github/workflows/test.yml)) runs the
integration test against a matrix of real mkosi versions (`v23.1` … `v27` and
`main`), because mkosi's CLI moves fast.

## License

MIT
