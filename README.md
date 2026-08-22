# release-me

Shared release script for keeping the same tag-and-release-notes flow across
multiple repositories.

This repository is intended to be added as a git submodule inside a consuming
project, then invoked from that project's root so all git operations apply to
the consuming repo rather than the submodule repo.

Canonical repository URL: `https://github.com/sharaf-nassar/release-me`

## Install

Add the submodule to a stable path in the consuming repository:

```bash
git submodule add https://github.com/sharaf-nassar/release-me tools/release-me
ln -s tools/release-me/release.sh release.sh
git add tools/release-me release.sh
git commit -m "chore: add release-me submodule"
```

When updating the shared script later:

```bash
git submodule update --remote --merge tools/release-me
git add tools/release-me
git commit -m "chore: update release-me"
```

## Development

Install the local git hooks after cloning this repository:

```bash
pre-commit install --install-hooks
pre-commit run --all-files
```

The repo uses strict hooks for Bash, Markdown, YAML, whitespace, typo checking,
and pre-commit self-validation. Some hooks auto-fix files in place.

## Usage

With the root-level symlink in place, run the script from the consuming
repository root:

```bash
./release.sh bump patch
./release.sh bump --dry-run patch
./release.sh bump --version v1.2.3
./release.sh bump minor
./release.sh bump major
./release.sh retag
./release.sh retag --dry-run
./release.sh latest
```

For an npm monorepo with `.release-me.json`, include the package name:

```bash
./release.sh bump patch proper-base
./release.sh bump --dry-run minor proper-flow
./release.sh bump --version v1.0.0 proper-base
./release.sh latest proper-base
```

The symlink should live at the consuming repo root and point to
`tools/release-me/release.sh`.

Do not `cd` into the submodule before running the script. The script uses
`git` commands against the current working directory, so running it from inside
the submodule would tag the submodule repository instead of the consuming
project.

## npm package configuration

Repositories opt into package-aware npm releases with `.release-me.json` at the
consuming repository root:

```json
{
  "type": "npm",
  "branch": "main",
  "packages": {
    "proper-base": "proper-base/package.json",
    "proper-flow": "proper-flow/package.json"
  }
}
```

The package argument must match the selected manifest's `name`. Manifest paths
must be tracked, repository-relative package JSON files. Package mode requires
Node.js and npm; repositories without this file keep the original repository
release behavior and dependencies.

Package tags use `<package>-vMAJOR.MINOR.PATCH`. A non-dry-run package bump:

1. Requires the configured release branch and a clean worktree.
1. Generates package-scoped release notes from that package's path.
1. Updates only the selected `package.json` version.
1. Runs `npm pack --dry-run`, commits the version, and creates an annotated tag.
1. Atomically pushes the release branch and package tag to `origin`.

If validation or the atomic push fails, the local release commit and tag are
rolled back. npm package tags cannot be retagged because published registry
versions are immutable; create a patch release instead.

## Commands

- `bump <major|minor|patch>` creates the next semver tag, generates release
  notes, creates an annotated tag, and pushes it to `origin`.
- `bump --version vX.Y.Z` uses the exact semver tag you provide instead of
  calculating the next version. The override must use the existing tag format
  and cannot be combined with `major`, `minor`, or `patch`.
- `bump --dry-run <major|minor|patch>` and
  `bump --dry-run --version vX.Y.Z` generate and display release notes without
  creating or pushing a tag.
- `retag` deletes the existing GitHub Release for the latest semver tag when one
  exists, then re-points that tag to the current `HEAD`. It requires an
  authenticated GitHub CLI (`gh`) with write access so stale release records and
  assets are removed before the tag is pushed again. Any extra positional
  arguments are ignored for backward compatibility.
- `retag --dry-run` regenerates and displays release notes for the latest tag
  without changing the GitHub Release or any local or remote tag.
- `latest` prints the latest semver tag in `vX.Y.Z` format.
- In npm mode, `bump` requires a trailing configured package name and `latest`
  requires one package name. The latest tag and release-note range are scoped
  to that package. `retag` is disabled.

## Release Notes

Release notes are generated from commit details, changed file names, and a
`git diff --stat` summary. The prompt favors a customer-facing product
announcement over a raw changelog:

- It opens directly with a short description of the biggest user-facing value
  in the release, with no top-level title or heading.
- It groups useful changes into `Highlights`, `Improvements`, `Fixes`, and
  `Upgrade Notes` sections when those sections have meaningful content.
- It includes user-visible fixes and upgrade notes, but omits refactors,
  dependency updates, CI changes, test-only work, and other internal-only work.
- It avoids generic phrases such as "various fixes and improvements."
- If there are no user-facing changes, it emits a maintenance-release message.

Generated Markdown is stored directly in the annotated tag message with Git
cleanup disabled. The script does not prepend a release title, so workflows that
read the full tag annotation get the generated body without a duplicate version
heading. Git cleanup remains disabled to preserve Markdown headings such as
`### Highlights`, which Git would otherwise treat as comment lines.

If a GitHub Actions workflow publishes the release from the tag annotation,
restore the remote tag object after `actions/checkout` before reading it.
Checkout may replace the local tag ref with a lightweight tag pointing at the
commit, which makes `git tag --format='%(contents)'` return the commit body
instead of the release notes.

AI backend selection:

- `--ai auto` prefers `codex` and falls back to `claude`.
- `--ai codex` forces Codex.
- `--ai claude` forces Claude.
- Codex runs from `PATH` and uses its normal user and consuming-project
  configuration, including configured model, provider, and reasoning effort.

## Requirements

- `git`
- Node.js and npm only for repositories with `.release-me.json`
- `pre-commit` for local development
- An `origin` remote on the consuming repository
- At least one of:
  - `codex`
  - `claude`

If no semver tags exist yet, `bump` starts from `v0.0.0` and creates the first
release tag from there. With `--version`, `bump` skips that calculation and
uses the explicit tag you pass.
