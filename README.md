# plugin-ci-workflows

Shared CI workflows and composite actions for Matomo plugin repositories.

## Why this exists

Every Matomo plugin repository currently carries its own copy of the same CI definitions. A typical plugin has `matomo-ai-checklist.yml`, `matomo-tests.yml`, `phpcs.yml` and often `phpstan.yml` under `.github/workflows/`, and apart from the plugin name they are near-identical from one repository to the next. Changing how a check runs — a runner label, a PHP version, a cache key — means opening the same pull request against dozens of repositories and waiting for dozens of approvals.

Holding those definitions here means a change is made once. Plugin repositories keep only a thin caller that says which checks to run.

This repository is public for a reason. A reusable workflow stored in a **private** repository is resolved against that repository's Actions access policy when the caller's workflow is parsed, which happens before any job starts and before any secret is available. Public and internal caller repositories therefore cannot use one at all — the run fails with "workflow was not found" and zero jobs, and no access setting fixes it. Keeping the shared definitions in a public repository avoids that class of failure entirely, whatever the visibility of the plugin repository calling in.

## What lives here

| Path | Contents |
| --- | --- |
| `.github/workflows/` | Reusable workflows, called with `uses:` at job level. Each one defines a complete job. |
| `actions/` | Composite actions, called with `uses:` at step level. Each one defines steps you drop into a job you have written yourself. |

Reach for a reusable workflow when the whole job is the same everywhere, and a composite action when the caller needs its own matrix, permissions or surrounding steps.

Nothing has been published yet. The catalogue below fills in as checks move across.

## Catalogue

| Name | Kind | Purpose |
| --- | --- | --- |
| [`plugin-phpcs.yml`](#phpcs) | Reusable workflow | Checks the plugin against the Matomo coding standards |

### PHPCS

Runs the plugin's own `phpcs.xml` against the [matomo-coding-standards](https://github.com/matomo-org/matomo-coding-standards) ruleset, and annotates the pull request with any violations.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `plugin-name` | yes | — | Name of the plugin, e.g. `LoginLdap` |
| `php-version` | no | `7.4` | PHP version the job runs on |

```yaml
name: PHPCS check
on: pull_request

jobs:
  phpcs:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-phpcs.yml@main
    with:
      plugin-name: MyPlugin
```

The plugin repository supplies the ruleset: the job runs `phpcs --standard=phpcs.xml`, so a `phpcs.xml` must exist at the repository root.

## Using a reusable workflow

```yaml
jobs:
  phpcs:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/<workflow-file>.yml@main
    with:
      plugin-name: YourPlugin
    secrets: inherit
```

## Using a composite action

```yaml
jobs:
  checks:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - uses: matomo-org/plugin-ci-workflows/actions/<action-name>@main
        with:
          plugin-name: YourPlugin
```

## Pinning

Callers may track `@main` or pin to a tag.

Tracking `@main` is the default for Matomo plugin repositories, and it is what makes a single change here reach the whole fleet at once. The trade-off is that a mistake also reaches the whole fleet at once, so treat `main` as production.

Pin to a tag where a repository needs to hold a check steady — for example while a plugin is mid-migration to a new Matomo major version and cannot yet take an updated check.

## Contributing

`main` is protected. Changes land through a pull request with at least one approval, and only the `plugin-reviewers` team can merge.

Because callers tracking `@main` pick a change up on their next run, with no release step in between, a merge here is a deployment. Check what a change does to an existing caller before merging it.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
