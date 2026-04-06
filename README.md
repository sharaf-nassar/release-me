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
./release.sh bump --version v1.2.3
./release.sh bump minor
./release.sh bump major
./release.sh retag
./release.sh latest
```

The symlink should live at the consuming repo root and point to
`tools/release-me/release.sh`.

Do not `cd` into the submodule before running the script. The script uses
`git` commands against the current working directory, so running it from inside
the submodule would tag the submodule repository instead of the consuming
project.

## Commands

- `bump <major|minor|patch>` creates the next semver tag, generates release
  notes, creates an annotated tag, and pushes it to `origin`.
- `bump --version vX.Y.Z` uses the exact semver tag you provide instead of
  calculating the next version. The override must use the existing tag format
  and cannot be combined with `major`, `minor`, or `patch`.
- `retag` always re-points the latest semver tag to the current `HEAD`. Any
  extra positional arguments are ignored for backward compatibility.
- `latest` prints the latest semver tag in `vX.Y.Z` format.

## Release Notes

Release notes are generated from commit subjects plus a `git diff --stat`
summary. The prompt is intentionally strict:

- It includes only user-visible features and capabilities.
- It omits bug fixes, refactors, dependency updates, CI changes, and other
  internal-only work.
- If there are no user-facing changes, it emits a maintenance-release message.

AI backend selection:

- `--ai auto` prefers `codex` and falls back to `claude`.
- `--ai codex` forces Codex.
- `--ai claude` forces Claude.

## Requirements

- `git`
- `pre-commit` for local development
- An `origin` remote on the consuming repository
- At least one of:
  - `codex`
  - `claude`

If no semver tags exist yet, `bump` starts from `v0.0.0` and creates the first
release tag from there. With `--version`, `bump` skips that calculation and
uses the explicit tag you pass.
