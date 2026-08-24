# plugin-ci-workflows

Shared CI workflows and composite actions for Matomo plugin repositories.

## Why this exists

Every Matomo plugin repository currently carries its own copy of the same CI definitions. A typical plugin has `matomo-ai-checklist.yml`, `matomo-tests.yml`, `phpcs.yml` and often `phpstan.yml` under `.github/workflows/`, and apart from the plugin name they are near-identical from one repository to the next. Changing how a check runs — a runner label, a PHP version, a cache key — means opening the same pull request against dozens of repositories and waiting for dozens of approvals.

Holding those definitions here means a change is made once. Plugin repositories keep only a thin caller that says which checks to run.

This repository is public for a reason. A reusable workflow stored in a **private** repository is resolved against that repository's Actions access policy when the caller's workflow is parsed, which happens before any job starts and before any secret is available. Public and internal caller repositories therefore cannot use one at all — the run fails with "workflow was not found" and zero jobs, and no access setting fixes it. Keeping the shared definitions in a public repository avoids that class of failure entirely, whatever the visibility of the plugin repository calling in.

## What lives here

| Path | Contents |
| --- | --- |
| `.github/workflows/plugin-*.yml` | Reusable workflows, called with `uses:` at job level. Each one defines a complete job. |
| `.github/workflows/*.yml` | Everything else here is this repository's own CI, not offered to callers. |
| `actions/` | Composite actions, called with `uses:` at step level. Each one defines steps you drop into a job you have written yourself. |
| `scripts/`, `hooks/`, `artifacts/` | Files the workflows above check this repository out to use. |

Reach for a reusable workflow when the whole job is the same everywhere, and a composite action when the caller needs its own matrix, permissions or surrounding steps.

The `plugin-` prefix is what marks a workflow as part of the public surface. Anything without it — the checklist gate, the script tests — runs against this repository only, and may change without notice to callers.

## Catalogue

| Name | Kind | Purpose |
| --- | --- | --- |
| [`plugin-phpcs.yml`](#phpcs) | Reusable workflow | Checks the plugin against the Matomo coding standards |
| [`plugin-phpstan.yml`](#phpstan) | Reusable workflow | Runs PHPStan against the plugin, on one or more Matomo targets |
| [`plugin-license-check.yml`](#license-check) | Reusable workflow | Checks the LICENSE file and source file license headers |

### PHPCS

Runs the plugin's own `phpcs.xml` against the [matomo-coding-standards](https://github.com/matomo-org/matomo-coding-standards) ruleset, and annotates the pull request with any violations.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `plugin-name` | yes | — | Name of the plugin, e.g. `LoginLdap` |
| `php-version` | no | `matomo6_min_php` | A literal version, or one of the shared aliases. PHPCS itself needs at least 7.4, so `matomo5_min_php` is too low to use here. |
| `scripts-ref` | no | `main` | Ref of `matomo-org/github-action-tests` for the version resolver |

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

Prefer an alias to a literal PHP version wherever a workflow accepts one. The aliases resolve through `resolve_php_version.sh` in `github-action-tests`, so when a Matomo major's floor or ceiling moves, every caller follows without a pull request each.

### PHPStan

Analyses the plugin with PHPStan against a checked-out Matomo. By default it runs twice, against the oldest Matomo the plugin's `plugin.json` supports and against the newest, which is what catches a plugin calling a core API that does not exist yet on its own floor.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `plugin-name` | yes | — | Name of the plugin, e.g. `LoginLdap` |
| `dependent-plugins` | no | `''` | Space-separated repository slugs to check out, e.g. `innocraft/plugin-Funnels` |
| `php-version` | no | `matomo5_min_php` | A literal version, or one of the shared aliases `matomo5_min_php`, `matomo5_max_php`, `matomo6_min_php`, `matomo6_max_php` |
| `matomo-targets` | no | min and max | JSON array of `{target, php}` objects, one analysis run each |
| `scripts-ref` | no | `main` | Ref of `matomo-org/github-action-tests` for the shared helper scripts |
| `workflows-ref` | no | `main` | Ref of this repository for the pre-push hook and the PHPStan bootstrap |
| `verify-hook` | no | `false` | Fail when the plugin's `.git-hooks-matomo/pre-push` differs from the canonical copy in `hooks/`. Opt in once the plugin's hook has been synced. |

`TESTS_ACCESS_TOKEN` is an optional secret, needed only when `dependent-plugins` names a private repository.

```yaml
name: PHPStan check
on: pull_request

jobs:
  phpstan:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-phpstan.yml@main
    with:
      plugin-name: MyPlugin
    secrets: inherit
```

Set `php-version` per target when the targets span Matomo majors — a Matomo 6 checkout cannot be bootstrapped by the PHP 7.2 that Matomo 5 still allows:

```yaml
    with:
      plugin-name: MyPlugin
      matomo-targets: >-
        [{"target": "minimum_required_matomo", "php": "matomo5_min_php"},
         {"target": "maximum_supported_matomo", "php": "matomo6_min_php"}]
```

A plugin that guards a newer core API behind `class_exists` can put the resulting ignores in `phpstan-min-matomo.neon`; the minimum leg uses that config in place of `phpstan.neon` when it exists.

#### Where the pieces live

This workflow checks out two repositories. The shared helpers that Matomo core CI uses as well — `checkout_matomo.sh`, `checkout_dependent_plugins.sh` and `resolve_php_version.sh` — stay in [`github-action-tests`](https://github.com/matomo-org/github-action-tests) and come from `scripts-ref`. The plugin-only pieces, `hooks/pre-push` and `artifacts/bootstrap-phpstan.php`, live here and come from `workflows-ref`.

A reusable workflow does not bring its own repository into the caller's workspace, which is why this repository has to be checked out explicitly even though the workflow is defined in it.

### License check

Checks that the repository ships a `LICENSE` file matching the license declared in `plugin.json`, and that source files (`*.php`, `*.js`, `*.ts`, `*.vue`) carry the matching header: the GPL header for OSS plugins, the InnoCraft EULA header for premium ones.

A file carrying the opposite header fails the check. Files with no recognised header are reported as warnings by default. Glob patterns listed in a `.license-check-ignore` file at the repository root are skipped, which is how bundled third-party files under their own license are excluded.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `fail-on-missing-header` | no | `false` | Treat source files with no recognised header as errors rather than warnings |
| `script-ref` | no | `main` | Ref of this repository to take `license_check.sh` from. When pinning the workflow to a SHA, pass the same SHA here. |

```yaml
name: License check
on: pull_request

jobs:
  license-check:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-license-check.yml@main
```

The check script lives at `scripts/bash/license_check.sh` and is covered by `tests/license_check_test.sh`, which runs on every pull request to this repository.

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
