# release-me — repo guide for agents

Shared Bash release tool consumed as a git submodule: `release.sh` (bump /
retag / latest — AI-generated release notes + semver tags) and
`test-dry-run.sh` (mocked integration harness). No app, no server, no
package manifests. No Beads, no lat.md.

## Build, test, gates

All local-only (no CI in this repo):

```bash
pre-commit install --install-hooks   # once
pre-commit run --all-files           # shellcheck(style), shfmt -i 2 -ci -sr,
                                     # markdownlint, typos, hygiene, bash -n release.sh
./test-dry-run.sh                    # dry-run regression harness (temp repos + mocked codex/gh)
```

Several hooks auto-fix files (shfmt, markdownlint --fix, typos
--write-changes) — rerun until clean, then stage the fixes.

## Gotchas

- The tool runs from the CONSUMING repo root via a `release.sh` symlink;
  running inside this repo tags this repo. Test behavior changes with
  `./test-dry-run.sh` or `--dry-run`, never a real `bump`.
- Non-dry-run `bump` creates and PUSHES an annotated tag; `retag` deletes
  the GitHub Release and remote tag before recreating them (needs
  authenticated `gh`). Treat both as production actions.
- `--ai auto` prefers `codex` (`codex exec --ephemeral`), falls back to
  `claude`. Requirements: git, an `origin` remote, one of codex/claude.
- Version tags are strictly `vMAJOR.MINOR.PATCH`; tagless repos start at
  `v0.0.0`.
- Consumer release workflows must re-fetch the annotated tag after
  `actions/checkout` (checkout can leave a lightweight tag without the
  generated notes).
