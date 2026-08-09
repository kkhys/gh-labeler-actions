# gh-labeler-actions

[![CI](https://github.com/kkhys/gh-labeler-actions/actions/workflows/ci.yml/badge.svg)](https://github.com/kkhys/gh-labeler-actions/actions/workflows/ci.yml)

GitHub Action for [gh-labeler](https://github.com/kkhys/gh-labeler) — declarative GitHub label management. Sync labels to a repository from a JSON/YAML config, preview changes as a plan, validate configs offline, and gate CI on label drift.

The action runs the [`gh-labeler` npm package](https://www.npmjs.com/package/gh-labeler) and republishes its machine-readable JSON envelope as step outputs and a job summary.

## Quick start

Declare your labels in `.github/labels.yml`:

```yaml
labels:
  - name: bug
    color: "#d73a4a"
    description: Something isn't working
  - name: enhancement
    color: "#a2eeef"
    aliases: [feature] # renames `feature` → `enhancement`, keeping history
```

Then sync on every change to the config:

```yaml
# .github/workflows/sync-labels.yml
name: Sync Labels

on:
  push:
    branches: [main]
    paths: [.github/labels.yml]
  workflow_dispatch:

permissions:
  contents: read
  issues: write

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: kkhys/gh-labeler-actions@v1
```

That is the whole setup: the repository comes from the workflow context, the token defaults to `github.token`, and the config is auto-detected from convention paths (`.gh-labeler.json`/`.yaml`/`.yml`, `.github/labels.json`/`.yaml`/`.yml`).

## Inputs

| Input                | Default               | Description                                                                                                                     |
| -------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `command`            | `sync`                | `sync` (apply), `plan` (read-only preview), or `validate` (offline config check, no token needed)                               |
| `repository`         | current repository    | Target repository as `owner/repo`                                                                                                |
| `token`              | `${{ github.token }}` | Token for API calls; needs `issues: write` for `sync`, `issues: read` for `plan`                                                 |
| `config`             | convention files      | Path to the label config file (JSON/YAML)                                                                                        |
| `from`               | —                     | Load the config from another repository (`owner/repo[:path]`); mutually exclusive with `config`                                  |
| `prune`              | follow config         | `true` deletes labels not declared in the config; `false` overrides a config-level `prune: true`                                 |
| `similarity`         | `true`                | `false` disables similarity-based rename detection (aliases still match)                                                         |
| `dry-run`            | `false`               | `sync` only: plan without applying changes                                                                                       |
| `check`              | `false`               | `plan` only: fail with exit code 6 when changes are pending (drift detection)                                                    |
| `gh-labeler-version` | `latest`              | npm version of gh-labeler to run; pin (e.g. `1.0.0`) for fully reproducible runs                                                 |
| `working-directory`  | `.`                   | Directory to run in; convention config files and relative `config` paths resolve from here                                       |

## Outputs

| Output       | Description                                                                                          |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| `status`     | `success`, `no_changes`, `partial_failure`, or `error`                                                |
| `exit-code`  | 0 success · 1 general error · 2 config error · 3 auth error · 4 repo not found · 5 partial failure · 6 drift |
| `created`    | Number of labels created                                                                              |
| `updated`    | Number of labels updated                                                                              |
| `renamed`    | Number of labels renamed                                                                              |
| `deleted`    | Number of labels deleted                                                                              |
| `kept`       | Number of labels already in sync                                                                      |
| `idempotent` | `true` when the sync made no changes because everything already matched                               |
| `json`       | Full JSON envelope (single line); parse with `fromJSON()` for anything not exposed above              |

Summary counts are empty for `validate`, whose envelope carries `config_source`, `label_count`, and `prune` instead (available via `json`).

Every run also writes a summary table (counts plus the individual operations) to the workflow job summary.

## Recipes

### Drift check on pull requests

Fail the build when repository labels have drifted from the config:

```yaml
permissions:
  contents: read
  issues: read

steps:
  - uses: actions/checkout@v5
  - uses: kkhys/gh-labeler-actions@v1
    with:
      command: plan
      check: true
```

### Preview on PR, apply on main

```yaml
- uses: kkhys/gh-labeler-actions@v1
  with:
    command: ${{ github.event_name == 'pull_request' && 'plan' || 'sync' }}
```

### Full mirror with prune

Delete every label the config does not declare. Nothing is deleted unless you opt in like this (or the config sets `prune: true`):

```yaml
- uses: kkhys/gh-labeler-actions@v1
  with:
    prune: true
```

### Central config for many repositories

Keep one label config in a central repository and fan out with a matrix. Targeting other repositories needs a PAT or GitHub App token with `issues: write` on the targets — `github.token` is scoped to the current repository only:

```yaml
jobs:
  sync:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        repo: [org/api, org/web, org/docs]
    steps:
      - uses: kkhys/gh-labeler-actions@v1
        with:
          repository: ${{ matrix.repo }}
          from: org/labels:.github/labels.yml
          token: ${{ secrets.LABEL_SYNC_TOKEN }}
```

No `actions/checkout` needed here: the config is fetched from the remote repository.

### Validate the config on every PR

Offline, no token, no API calls:

```yaml
- uses: actions/checkout@v5
- uses: kkhys/gh-labeler-actions@v1
  with:
    command: validate
```

### Use the outputs

```yaml
- uses: kkhys/gh-labeler-actions@v1
  id: labels
- run: |
    echo "status=${{ steps.labels.outputs.status }}"
    echo "created=${{ steps.labels.outputs.created }}"
    echo "repository=${{ fromJSON(steps.labels.outputs.json).repository }}"
```

## Permissions

| Command    | Required `GITHUB_TOKEN` permissions |
| ---------- | ----------------------------------- |
| `sync`     | `issues: write`                     |
| `plan`     | `issues: read`                      |
| `validate` | none (offline)                      |

## Behavior notes

- `sync` in this action never prompts (JSON mode is non-interactive by design) and is idempotent: a second run reports `no_changes`.
- Nothing is ever deleted unless the config flags a label `delete: true` or prune is enabled.
- Renames (via `aliases` or similarity) are atomic PATCH requests and preserve label history on issues and PRs.
- Transient API failures and rate limits are retried automatically.
- A checkout step is required whenever the config lives in the repository; with `from` it is not.
- The runner's Node.js is used when it is 22 or newer; otherwise Node.js 24 is set up automatically.

Full CLI and config reference, including the JSON envelope schema: [gh-labeler AGENTS.md](https://github.com/kkhys/gh-labeler/blob/main/AGENTS.md).

## License

[MIT](./LICENSE.md)
