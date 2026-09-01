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

The examples below use `secrets: inherit` for brevity. [Codex review](#codex-review) is the exception and names its two secrets explicitly, because `inherit` hands every secret the calling repository can see to a workflow defined in another repository.

The `plugin-` prefix is what marks a workflow as part of the public surface. Anything without it — the checklist gate, the script tests — runs against this repository only, and may change without notice to callers.

## Catalogue

| Name | Kind | Purpose |
| --- | --- | --- |
| [`plugin-phpcs.yml`](#phpcs) | Reusable workflow | Checks the plugin against the Matomo coding standards |
| [`plugin-phpstan.yml`](#phpstan) | Reusable workflow | Runs PHPStan against the plugin, on one or more Matomo targets |
| [`plugin-license-check.yml`](#license-check) | Reusable workflow | Checks the LICENSE file and source file license headers |
| [`plugin-ai-checklist.yml`](#ai-checklist) | Reusable workflow | Runs the org checklist gate against the pull request description |
| [`plugin-ci.yml`](#plugin-ci) | Reusable workflow | The whole pull request check set behind one caller |
| [`plugin-codex-review.yml`](#codex-review) | Reusable workflow | Runs the Codex pull request review when a maintainer applies the trigger label |
| [`hooks/pre-push`](#the-pre-push-hook) | Local git hook | Runs PHPStan over a push's own changed files, before the push leaves the machine |

### Plugin CI

Runs PHPCS, PHPStan, the license check and the AI checklist gate from a single caller, so a plugin repository carries its name and nothing else, and a check added here reaches every plugin without a pull request against any of them.

```yaml
name: CI

on:
  pull_request:
    types: [opened, synchronize, reopened, edited]

permissions:
  actions: read
  contents: read
  pull-requests: read

jobs:
  ci:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-ci.yml@main
    with:
      plugin-name: LoginLdap
    secrets: inherit
```

Checks are opt **out**, through `skip-phpcs`, `skip-phpstan`, `skip-license-check` and `skip-ai-checklist`. Opt-in switches would leave a newly added check running nowhere until every caller added a line, which is the problem this workflow exists to remove. Every input the individual workflows take is passed through; the two that take a PHP version are named `phpcs-php-version` and `phpstan-php-version`.

The caller subscribes to `edited` so the checklist gate re-runs when someone fixes a description. Consuming that action is opt **in** per job, so the code checks ignore it rather than re-analysing an unchanged tree, and a check added later ignores it too unless its author decides otherwise. `tests/plugin_ci_invariants_test.sh` enforces both defaults.

The permissions above are the union of what the four checks need. That is the cost of one caller: a plugin that only wants PHPCS previously needed no scopes at all.

#### What it does not cover

[Codex review](#codex-review) stays a separate workflow in each plugin, deliberately. It runs on `pull_request_target` with secrets available and gated on a label, while every check above runs on `pull_request`. One file declaring both events means the code checks need an `if:` excluding `pull_request_target`, or they execute pull request code in a context that can read secrets — a missing condition there is a credential leak rather than a red build. Its `automation-paths` guard also names `.github/workflows/codex-review.yml` as a file requiring human review before a review runs, and a differently named wrapper drops that control. Its wrapper is a stable file, so the per-plugin cost is paid once while the review logic keeps living here.

**Pinning does not reach through this workflow.** GitHub does not accept an expression in a `uses:` reference, so the calls below are fixed at `@main`: a caller that pins `plugin-ci.yml` to a tag still runs `main` versions of the checks themselves. A repository that needs to hold a check steady — a plugin mid-migration to a new Matomo major, say — should call the individual workflows directly and pin those, rather than use this one.

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
| `php-version` | no | `matomo6_min_php` | A literal version, or one of the shared aliases `matomo5_min_php`, `matomo5_max_php`, `matomo6_min_php`, `matomo6_max_php`. The default clears Matomo 6's floor of 8.1: a plugin declaring `>=6.0.0-b1` resolves both legs to `6.x-dev` until 6.0.0 is tagged, and 7.2 cannot bootstrap it. |
| `matomo-targets` | no | min and max | JSON array of `{target, php}` objects, one analysis run each |
| `scripts-ref` | no | `main` | Ref of `matomo-org/github-action-tests` for the shared helper scripts |
| `workflows-ref` | no | `main` | Ref of this repository for the pre-push hook and the PHPStan bootstrap |
| `verify-hook` | no | `false` | Fail when the plugin's `.git-hooks-matomo/pre-push` differs from the canonical copy in `hooks/`. Turn it on once that copy has been synced — see [The pre-push hook](#the-pre-push-hook). |

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

### AI checklist

Runs [`github-action-checklist-gate`](https://github.com/matomo-org/github-action-checklist-gate) against the pull request description, which is what enforces the two AI attestation items in the pull request template. No inputs.

The gate reads the pull request description, so the caller has to grant `actions: read` and `pull-requests: read` in its own `permissions` block — a called workflow cannot widen the caller's token.

```yaml
name: AI Checklist
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]

permissions:
  actions: read
  pull-requests: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  AiChecklist:
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-ai-checklist.yml@main
```

The `edited` trigger matters: without it the gate does not re-run when someone fills the checklist in, and the check stays red.
### Codex review

Runs an AI review over a pull request when someone applies the `codex-review` label, and posts the result as a pull request review. The review itself — preflight checks, prompt, output schema and posting — lives in composite actions in `innocraft/github-action-tests-private`, which this workflow checks out with `TESTS_ACCESS_TOKEN`.

That indirection is not a style choice. GitHub resolves a reusable workflow from the callee repository's Actions access policy at workflow-parse time, before any job or secret exists, and that policy cannot grant a **public** caller access to a workflow in a private repository — the run fails with "workflow was not found" and no jobs. Composite actions have no such restriction once a token has checked them out. This workflow exists so that the job structure a plugin repository cannot import lives somewhere it can.

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `plugin-name` | no | read from `plugin.json` | Name of the plugin, e.g. `LoginLdap`. Passing it keeps the name out of the untrusted pull request. |
| `trigger-label` | no | `codex-review` | Label that triggers the review. The caller's own `if:` condition names the label too, so change both together or the caller never invokes this workflow. |
| `allowed-owners` | no | `matomo-org,innocraft` | Comma-separated repository owners allowed to run a review |
| `automation-paths` | no | the caller's `codex-review.yml` and `.github/codex/` | Paths that must receive human review before Codex runs |
| `review-actions-ref` | no | `main` | Ref of `innocraft/github-action-tests-private` to run. When pinning this workflow to a SHA, pin the actions too. |
| `matomo-core-repository` | no | `matomo-org/matomo` | Core repository checked out for read-only review context |
| `matomo-core-ref` | no | derived from the base branch | Core ref checked out for read-only review context. A pull request against `6.x-dev` is reviewed against 6.x core; a base branch that names no core branch falls back to `5.x-dev`. |
| `matomo-agent-skills-ref` | no | `main` | Ref of `matomo-org/matomo-agent-skills` to install |
| `codex-model` | no | `gpt-5.6-sol` | Model passed to `openai/codex-action` |
| `codex-effort` | no | `xhigh` | Reasoning effort passed to `openai/codex-action` |

| Secret | Required | Description |
| --- | --- | --- |
| `OPENAI_API_KEY` | yes | Supplied by the calling repository or organization; this repository ships no key |
| `TESTS_ACCESS_TOKEN` | yes | Read access to the review actions repository. A caller's `GITHUB_TOKEN` cannot read a private repository. |

```yaml
# Save as .github/workflows/codex-review.yml. The automation-paths default names that exact
# path as a file that must get human review before Codex runs; a wrapper saved under another
# name silently loses that guard.
name: Codex Review

on:
  # nosec — label-gated; this wrapper runs no pull request code
  pull_request_target:
    types: [labeled]

permissions:
  contents: none

jobs:
  codex-review:
    # Keep this condition. Every job below gates on the label too, but this workflow's
    # cancel-in-progress concurrency group is claimed as soon as it is instantiated, so without it
    # an unrelated label cancels a review already running on the same pull request.
    # This label must match `trigger-label` below, which defaults to codex-review.
    if: ${{ github.event.label.name == 'codex-review' }}
    uses: matomo-org/plugin-ci-workflows/.github/workflows/plugin-codex-review.yml@main
    permissions:
      actions: read
      contents: read
      issues: write
      pull-requests: write
    with:
      plugin-name: MyPlugin
    secrets:
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
      TESTS_ACCESS_TOKEN: ${{ secrets.TESTS_ACCESS_TOKEN }}
```

Name the two secrets rather than using `secrets: inherit` here: `inherit` would hand every secret the plugin repository can see to a workflow defined in another repository, and this one only needs those two.

Two things differ from the other workflows in this catalogue. It is the only one triggered by `pull_request_target`, so the caller must keep that wrapper free of any step that checks out or runs pull request code. And it is the only one that runs with write permissions on the calling repository, which is why `main` here is protected — anyone who can change this file changes what runs with `issues: write` and `pull-requests: write` on every plugin pull request.

Who can start a review: the label is a trigger, not an authorisation check. Anyone with triage access or above on the calling repository can apply it, and the workflow does not test the labeller's permission. What it does enforce is `allowed-owners`, and the preflight step refuses pull requests from forks — failing closed when it cannot identify the repository — because this workflow never checks out fork code. A review therefore costs OpenAI credits at the discretion of anyone already trusted with triage on the repository.

Refs into our own organisations — the review actions and the agent skills — track `main` on purpose, as they do elsewhere in this repository. Third-party actions are pinned to a full commit SHA. The distinction matters more here than in the other workflows, because these jobs hold `OPENAI_API_KEY`, `TESTS_ACCESS_TOKEN` and write permission on the calling repository, so a change to either of those repositories takes effect on the next review with those credentials in scope. Pin `review-actions-ref` and `matomo-agent-skills-ref` to SHAs for a caller that needs that fixed.

The security model, the trust boundaries and the review prompt are documented in `review/README.md` in the review actions repository.

## The pre-push hook

`hooks/pre-push` runs PHPStan over the files a push actually changes, before the push leaves the machine. It is a developer convenience, not a gate: CI analyses the whole repository regardless, and never executes this hook.

This file is the canonical copy. Each plugin ships its own under `.git-hooks-matomo/`, and git runs it because `core.hooksPath` in that clone names the directory:

```bash
git config core.hooksPath .git-hooks-matomo
```

`add-git-hooks-to-plugins.sh` in [`matomo-developer-tools`](https://github.com/innocraft/matomo-developer-tools) does that across a checkout, and the standard DDEV environment script already calls it, so a developer who set the environment up that way has the hooks running already.

The path stays repository-relative on purpose. An absolute path pointing outside the repository breaks the moment that directory is moved or renamed — and it breaks silently, because git runs no hook and reports nothing when `core.hooksPath` names somewhere that does not exist. A push then succeeds with no checks and no warning, which is worse than running a hook that is out of date. Keeping the copy in the repository also means someone who clones a single plugin gets the hook with it, without cloning this repository as well.

### Keeping a plugin's copy in sync

The cost of a copy per repository is drift, and those copies currently sit at several different vintages. Sync one by taking this file:

```bash
cp path/to/plugin-ci-workflows/hooks/pre-push .git-hooks-matomo/pre-push
```

Then set `verify-hook: true` in that plugin's PHPStan caller, which fails the build when the two differ, so the copy cannot drift again unnoticed. Set it only after syncing: the check is a hard failure, not a warning.

The hook works out for itself which plugin it is in, from the repository root git reports, so the same file works unmodified in every plugin. Where it cannot find a `plugins/` directory above it — any repository that is not a Matomo plugin — it prints a line saying so and exits 0.

### Finding plugins where the hook never runs

Shipping the file is not the same as running it: a plugin whose `core.hooksPath` is unset has the hook and no way to reach it, and because nothing runs, nothing says so. On a push that succeeds, the hook looks at its sibling plugins and names any that ship a copy without the setting, at most once a day:

```
NOTE: 3 plugin(s) ship a pre-push hook that never runs, because
      core.hooksPath is not set in them: AbTesting ActivityLog Cohorts
      Activate with add-git-hooks-to-plugins.sh from matomo-developer-tools.
```

It only reads, never writes. A plugin that ships no hook is left out of the report entirely, because there is nothing there to activate and setting `core.hooksPath` to a directory that does not exist is worse than leaving it alone: git then runs no hook at all — including anything the repository keeps in `.git/hooks` — and reports nothing when it does so.

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

Pinning the `uses:` reference alone is not a full pin. `plugin-phpcs.yml` and `plugin-phpstan.yml` also run helper scripts checked out at `scripts-ref`, and `plugin-phpstan.yml` and `plugin-license-check.yml` take files from this repository at `workflows-ref` and `script-ref`. Those default to `main`, so a caller that pins only the workflow still executes mutable helper code. A caller that needs an immutable pin has to set every ref it uses — and `scripts-ref` takes a SHA from `github-action-tests`, which is a different repository with different SHAs. One thing stays mutable regardless: `plugin-phpcs.yml` installs `matomo-org/matomo-coding-standards:dev-master`, deliberately, so that a coding-standards change reaches the fleet without a pull request per repository. No input pins it, so a fully immutable PHPCS run is not on offer — pin the rest and accept that one, or run PHPCS from your own pinned install.

## Contributing

`main` is protected. Changes land through a pull request with at least one approval, and only the `plugin-reviewers` team can merge.

Because callers tracking `@main` pick a change up on their next run, with no release step in between, a merge here is a deployment. Check what a change does to an existing caller before merging it.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
