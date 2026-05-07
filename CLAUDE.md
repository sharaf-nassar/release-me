# release-me Repo Instructions

This repository ships a shared release script that is meant to be consumed as a
git submodule from other repositories. Keep changes portable across downstream
projects and avoid assumptions that only hold for one consumer.

Canonical repository URL: `https://github.com/sharaf-nassar/release-me`

## Submodule Context

- The consuming repository is the release target. This repository only stores
  the shared tooling.
- `release.sh` is expected to be invoked from the consuming repo root through a
  submodule path such as `./tools/release-me/release.sh`.
- Do not validate normal usage by `cd`-ing into the submodule. The script runs
  `git` commands against the current working directory, so running it inside the
  submodule targets the wrong repository.
- Keep command examples and docs aligned with submodule-style invocation.
- Preserve the assumption that the consuming repo has an `origin` remote and
  semver tags in `vMAJOR.MINOR.PATCH` format.

## Maintenance Rules

- Keep `release.sh` Bash-only and lightweight. Avoid adding nonstandard
  dependencies unless the user explicitly asks for them.
- Keep the script generic. Do not add project-specific release logic,
  app-specific heuristics, CI-vendor assumptions, or downstream branding.
- Treat semver tags as the contract. `get_latest_tag` should continue to look at
  `vMAJOR.MINOR.PATCH` tags only.
- `bump --version` is an exact semver-tag override and remains scoped to
  `bump`. It must not require or accept `major`, `minor`, or `patch`. Do not
  extend it to `retag` unless the user explicitly requests it.
- `retag` is latest-only by design. Do not reintroduce arbitrary-tag retagging
  unless the user explicitly requests that behavior.
- `retag` must delete the existing GitHub Release for the latest tag before
  deleting and re-pushing the remote tag. Keep this separate from tag cleanup so
  release deletion cannot accidentally replace the explicit git tag flow.
- Keep release-note generation focused on user-visible changes unless the user
  asks to broaden the scope.
- Keep generated release notes in annotated tags with Git cleanup disabled so
  Markdown heading lines beginning with `#` are preserved.

## Docs And Verification

- When CLI behavior changes, update `release.sh --help`, `README.md`, and this
  file together when relevant.
- Keep `.pre-commit-config.yaml`, `.markdownlint-cli2.yaml`, and
  `.editorconfig` aligned with the repo's actual file types and standards.
- Re-read `release.sh` before editing if the file may have changed during the
  session.
- After changing `release.sh`, run at least `bash -n release.sh`. If behavior
  changed, also run the narrowest command that proves the new behavior.
- After changing hook config or repo-wide text/style rules, run
  `pre-commit run --all-files`.
- Do not claim the submodule workflow works unless you validated it from a
  temporary consuming-repo setup or an equivalent targeted check.
