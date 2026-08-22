#!/usr/bin/env bash
set -euo pipefail

CODEX_PROGRESS_LINES=20
CODEX_PROGRESS_SCAN_LINES=200
CODEX_PROGRESS_INTERVAL_SECONDS=0.1

usage() {
  local exit_code="${1:-1}"
  cat << 'EOF'
Usage: ./release.sh [--ai auto|codex|claude] <command> [args]

Options:
  --ai <auto|codex|claude>  Select the CLI used for release notes (default: auto)
  Codex uses the executable from PATH and its normal user/project configuration.

Commands without .release-me.json:
  bump [--dry-run] <major|minor|patch>
                             Create and push a new version tag
  bump [--dry-run] --version vX.Y.Z
                             Create and push an explicit version tag
  retag [--dry-run]          Delete the GitHub release and replace the latest tag
  latest                     Show the latest version tag

Commands with npm-style .release-me.json:
  bump [--dry-run] <major|minor|patch> <package>
                             Commit a package version and push its tag
  bump [--dry-run] --version vX.Y.Z <package>
                             Commit and tag an explicit package version
  latest <package>           Show the latest package version tag

Examples:
  ./release.sh --ai auto bump patch   # Prefer Codex, fall back to Claude
  ./release.sh --ai claude bump patch # Force Claude for release notes
  ./release.sh bump patch             # v0.2.1 -> v0.2.2
  ./release.sh bump --dry-run patch   # Generate notes without creating a tag
  ./release.sh bump --version v1.2.3  # Use an explicit tag
  ./release.sh bump minor             # v0.2.1 -> v0.3.0
  ./release.sh bump major             # v0.2.1 -> v1.0.0
  ./release.sh retag                  # Delete the GitHub release and re-point latest tag
  ./release.sh retag --dry-run        # Regenerate notes without changing the release or tag
  ./release.sh latest                 # Print latest tag
  ./release.sh bump patch my-package  # my-package-v1.2.4 in npm mode
  ./release.sh latest my-package      # Print latest package tag
EOF
  exit "$exit_code"
}

RELEASE_CONFIG_FILE=".release-me.json"
RELEASE_MODE="legacy"
RELEASE_BRANCH=""
RELEASE_PACKAGE=""
RELEASE_PACKAGE_MANIFEST=""
RELEASE_PACKAGE_PATH=""
RELEASE_PACKAGE_VERSION=""
RELEASE_TAG_PREFIX="v"

is_semver_version() {
  local version="$1"
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

is_semver_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

get_latest_tag() {
  local prefix="${1:-v}"
  local tag version
  while IFS= read -r tag; do
    version="${tag#"$prefix"}"
    if is_semver_version "$version"; then
      printf '%s\n' "$tag"
      return
    fi
  done < <(git tag --list "${prefix}*" --sort=-v:refname)
}

parse_version() {
  local tag="$1" prefix="${2:-v}"
  printf '%s\n' "${tag#"$prefix"}"
}

print_bump_usage() {
  if [[ "$RELEASE_MODE" == "npm" ]]; then
    echo "Usage: ./release.sh bump [--dry-run] <major|minor|patch> <package>"
    echo "       ./release.sh bump [--dry-run] --version vX.Y.Z <package>"
  else
    echo "Usage: ./release.sh bump [--dry-run] <major|minor|patch>"
    echo "       ./release.sh bump [--dry-run] --version vX.Y.Z"
  fi
}

bump_version() {
  local version="$1" part="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$version"

  case "$part" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
    *)
      echo "Invalid part: $part" >&2
      exit 1
      ;;
  esac
}

compare_versions() {
  local left="$1" right="$2"
  local l_major l_minor l_patch r_major r_minor r_patch
  IFS='.' read -r l_major l_minor l_patch <<< "$left"
  IFS='.' read -r r_major r_minor r_patch <<< "$right"

  if ((l_major != r_major)); then
    ((l_major < r_major)) && echo -1 || echo 1
  elif ((l_minor != r_minor)); then
    ((l_minor < r_minor)) && echo -1 || echo 1
  elif ((l_patch != r_patch)); then
    ((l_patch < r_patch)) && echo -1 || echo 1
  else
    echo 0
  fi
}

load_release_mode() {
  local repo_root
  repo_root=$(get_repo_root)
  if [[ ! -f "$repo_root/$RELEASE_CONFIG_FILE" ]]; then
    return
  fi

  if ! command -v node > /dev/null 2>&1; then
    echo "$RELEASE_CONFIG_FILE requires Node.js." >&2
    return 1
  fi

  IFS=$'\t' read -r RELEASE_MODE RELEASE_BRANCH < <(
    node - "$repo_root/$RELEASE_CONFIG_FILE" << 'NODE'
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (config.type !== "npm") {
  throw new Error(`${process.argv[2]}: type must be \"npm\"`);
}
if (!config.branch || typeof config.branch !== "string" || /[\t\n]/.test(config.branch)) {
  throw new Error(`${process.argv[2]}: branch must be a non-empty string`);
}
if (!config.packages || typeof config.packages !== "object" || Array.isArray(config.packages)) {
  throw new Error(`${process.argv[2]}: packages must be an object`);
}
process.stdout.write(`npm\t${config.branch}\n`);
NODE
  )
}

resolve_npm_package() {
  local package="$1" repo_root output
  repo_root=$(get_repo_root)
  output=$(
    node - "$repo_root/$RELEASE_CONFIG_FILE" "$repo_root" "$package" << 'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [configPath, root, requested] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
const manifest = config.packages[requested];
if (typeof manifest !== "string" || !manifest) {
  throw new Error(`Unknown release package: ${requested}`);
}
if (manifest.includes("\t") || manifest.includes("\n") || path.isAbsolute(manifest)) {
  throw new Error(`Invalid manifest path for ${requested}`);
}
const absolute = path.resolve(root, manifest);
const relative = path.relative(root, absolute);
if (!relative || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
  throw new Error(`Manifest path escapes the repository: ${manifest}`);
}
const packageJson = JSON.parse(fs.readFileSync(absolute, "utf8"));
if (packageJson.name !== requested) {
  throw new Error(`Config package ${requested} points to ${packageJson.name || "an unnamed package"}`);
}
if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(packageJson.version)) {
  throw new Error(`${requested} must use a stable MAJOR.MINOR.PATCH version`);
}
if (!/^[a-z0-9][a-z0-9._-]*$/.test(requested)) {
  throw new Error(`${requested} is not supported in package tag names`);
}
process.stdout.write([relative.split(path.sep).join("/"), packageJson.name, packageJson.version].join("\t"));
NODE
  ) || return 1

  IFS=$'\t' read -r RELEASE_PACKAGE_MANIFEST RELEASE_PACKAGE RELEASE_PACKAGE_VERSION <<< "$output"
  RELEASE_PACKAGE_PATH="${RELEASE_PACKAGE_MANIFEST%/package.json}"
  if [[ "$RELEASE_PACKAGE_PATH" == "$RELEASE_PACKAGE_MANIFEST" ]]; then
    RELEASE_PACKAGE_PATH="."
  fi
  RELEASE_TAG_PREFIX="${RELEASE_PACKAGE}-v"

  git check-ref-format "refs/tags/${RELEASE_TAG_PREFIX}0.0.0" > /dev/null
}

get_repo_root() {
  git rev-parse --show-toplevel 2> /dev/null || pwd
}

should_skip_codex_progress_line() {
  local line="$1"

  [[ -z "${line//[[:space:]]/}" ]] && return 0

  case "$line" in
    "OpenAI Codex "*)
      return 0
      ;;
    "--------" | "user" | "codex" | "tokens used")
      return 0
      ;;
    workdir:* | model:* | provider:* | approval:* | sandbox:* | "reasoning effort:"* | "reasoning summaries:"* | "session id:"*)
      return 0
      ;;
    hook:* | mcp:* | "user cancelled MCP tool call" | "bwrap:"*)
      return 0
      ;;
  esac

  if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*codex_ ]]; then
    return 0
  fi

  return 1
}

render_codex_panel_line() {
  local text="$1" width="$2"
  local visible="$text"
  if ((${#visible} > width)); then
    visible="${visible:0:width}"
  fi
  printf '| %-*s |\n' "$width" "$visible" >&2
}

print_codex_raw_error_log() {
  local log_file="$1"
  echo "Codex raw stderr (last ${CODEX_PROGRESS_LINES} lines):" >&2
  tail -n "$CODEX_PROGRESS_LINES" "$log_file" >&2 || true
}

render_codex_progress_panel() {
  local log_file="$1" frame="$2" start_time="$3" state="${4:-running}"
  local cols="${COLUMNS:-}"
  if [[ -z "$cols" ]]; then
    cols=$(tput cols 2> /dev/null || echo 80)
  fi
  if ((cols < 40)); then
    cols=40
  fi

  local inner_width=$((cols - 4))
  local panel_height=$((CODEX_PROGRESS_LINES + 4))
  local elapsed=$(($(date +%s) - start_time))
  local spinner_frames="|/-\\"
  local spinner="${spinner_frames:frame%4:1}"
  local status_line
  local title_line="Recent activity (last ${CODEX_PROGRESS_LINES} lines)"

  case "$state" in
    success)
      status_line="[done] Codex finished generating release notes in ${elapsed}s"
      ;;
    error)
      status_line="[fail] Codex failed while generating release notes after ${elapsed}s"
      ;;
    *)
      status_line="[${spinner}] Generating release notes with Codex... ${elapsed}s"
      ;;
  esac

  if [[ "${CODEX_PROGRESS_RENDERED:-0}" -eq 1 ]]; then
    printf '\033[%dA\r' "$panel_height" >&2
  fi

  printf '%s\n' "$status_line" >&2

  local border
  printf -v border '%*s' "$inner_width" ''
  border=${border// /-}
  printf '+-%s-+\n' "$border" >&2
  render_codex_panel_line "$title_line" "$inner_width"

  local lines=()
  while IFS= read -r line; do
    if ! should_skip_codex_progress_line "$line"; then
      lines+=("$line")
    fi
  done < <(tail -n "$CODEX_PROGRESS_SCAN_LINES" "$log_file" 2> /dev/null | sed $'s/\r//g; s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g')

  if ((${#lines[@]} > CODEX_PROGRESS_LINES)); then
    lines=("${lines[@]: -CODEX_PROGRESS_LINES}")
  fi

  if [[ ${#lines[@]} -eq 0 ]]; then
    lines+=("(waiting for Codex activity)")
  fi

  local i
  for ((i = 0; i < CODEX_PROGRESS_LINES; i++)); do
    if ((i < ${#lines[@]})); then
      render_codex_panel_line "${lines[$i]}" "$inner_width"
    else
      render_codex_panel_line "" "$inner_width"
    fi
  done

  printf '+-%s-+\n' "$border" >&2
  CODEX_PROGRESS_RENDERED=1
}

run_codex_with_progress() {
  local prompt="$1" output_file="$2"
  local prompt_file log_file pid status frame start_time repo_root

  prompt_file=$(mktemp)
  log_file=$(mktemp)
  printf '%s\n' "$prompt" > "$prompt_file"
  repo_root=$(get_repo_root)

  codex exec \
    --ephemeral \
    --color never \
    -C "$repo_root" \
    -o "$output_file" \
    - < "$prompt_file" > /dev/null 2> "$log_file" &
  pid=$!

  start_time=$(date +%s)
  frame=0
  CODEX_PROGRESS_RENDERED=0

  local interactive_progress=0
  if [[ -t 2 && "${TERM:-}" != "dumb" ]]; then
    interactive_progress=1
    printf '\033[?25l' >&2
  fi

  trap 'kill "$pid" 2>/dev/null || true; if (( interactive_progress )); then printf "\033[?25h" >&2; fi; rm -f "$prompt_file" "$log_file"; exit 130' INT TERM

  while kill -0 "$pid" 2> /dev/null; do
    if ((interactive_progress)); then
      render_codex_progress_panel "$log_file" "$frame" "$start_time" "running"
    fi
    sleep "$CODEX_PROGRESS_INTERVAL_SECONDS"
    frame=$((frame + 1))
  done

  wait "$pid"
  status=$?

  if ((interactive_progress)); then
    if ((status == 0)); then
      render_codex_progress_panel "$log_file" "$frame" "$start_time" "success"
    else
      render_codex_progress_panel "$log_file" "$frame" "$start_time" "error"
    fi
    printf '\033[?25h' >&2
    if ((status != 0)); then
      print_codex_raw_error_log "$log_file"
    fi
  elif ((status != 0)); then
    print_codex_raw_error_log "$log_file"
  fi

  trap - INT TERM
  rm -f "$prompt_file" "$log_file"
  return "$status"
}

generate_notes() {
  local prev_tag="$1" new_tag="$2" ai_cli="$3"
  local package_name="${4:-}" package_path="${5:-}"

  local range diff_base
  if [[ -z "$prev_tag" ]]; then
    range="HEAD"
    diff_base=$(git hash-object -t tree /dev/null)
  else
    range="${prev_tag}..HEAD"
    diff_base="$prev_tag"
  fi

  local commits changed_files diff_stat
  if [[ -n "$package_path" ]]; then
    commits=$(git log "$range" --pretty=format:"- %s%n%b" --no-merges -- "$package_path")
    changed_files=$(git diff "$diff_base" HEAD --name-status -- "$package_path")
    diff_stat=$(git diff "$diff_base" HEAD --stat -- "$package_path")
  else
    commits=$(git log "$range" --pretty=format:"- %s%n%b" --no-merges)
    changed_files=$(git diff "$diff_base" HEAD --name-status)
    diff_stat=$(git diff "$diff_base" HEAD --stat)
  fi

  local prompt
  prompt=$(
    cat << PROMPT
You are writing customer-facing GitHub release notes for this repo.

Write for people deciding whether to use or upgrade to this release. Make the
release sound useful and easy to scan without hype, filler, or implementation
jargon. Translate code changes into product value. If the source material does
not prove a claim, do not invent it.

Prioritize:
1. New user-visible capabilities and workflows.
2. Meaningful improvements to existing behavior.
3. User-visible bug fixes or reliability improvements.
4. Breaking changes, migration steps, or required user action.

Omit internal-only work: refactors, dependency bumps, CI changes, formatting,
test-only changes, tool churn, and commit hashes. Never write generic phrases
like "various fixes and improvements".

Use this Markdown structure, omitting sections that have no meaningful items.
Do not include a top-level title, heading, or version line at the start of the
notes — begin directly with the description paragraph below. Do not mention the
version tag (e.g., "${new_tag}", "v1.2.3", or any "vX.Y.Z" string) anywhere in
the opening paragraph; the release title already shows it. The first sentence
must start with the change itself, not the version.

Open with 2-3 short sentences that summarize the biggest user-facing value in
this release. Mention the strongest feature first. If there are no user-facing
changes, output only: "Maintenance release — no user-facing changes."

### Highlights
- **Benefit-led headline** - One or two plain-language sentences explaining
  what changed, why it matters, and how users benefit.

### Improvements
- **Result-focused headline** - One sentence about an improved workflow,
  clearer behavior, or smoother experience.

### Fixes
- **Issue users no longer hit** - One sentence explaining what is now more
  reliable, clearer, or less error-prone.

### Upgrade Notes
- Required user action, breaking behavior, compatibility notes, or migration
  guidance. Be concrete and direct.

Rules:
- Do not include empty sections.
- Prefer 3-7 total bullets across all sections.
- Merge related commits into one readable item.
- If a bullet only describes implementation, omit it.
- Use active, specific language. Avoid "you can" as the default sentence shape.
- Keep each bullet self-contained and under 40 words when possible.
- Do not include "Full changelog", contributor lists, file names, or commit hashes.

Package: ${package_name:-"(repository release)"}
Version: ${new_tag}
Previous version: ${prev_tag:-"(first release)"}

Commit details:
${commits}

Changed files:
${changed_files}

Files changed:
${diff_stat}
PROMPT
  )

  local notes
  case "$ai_cli" in
    codex)
      local output_file
      output_file=$(mktemp)
      if run_codex_with_progress "$prompt" "$output_file"; then
        notes=$(cat "$output_file")
      else
        rm -f "$output_file"
        echo "Failed to generate release notes with Codex." >&2
        return 1
      fi
      rm -f "$output_file"
      ;;
    claude)
      notes=$(claude -p --model claude-opus-4-7 --output-format text --no-session-persistence "$prompt" 2> /dev/null)
      ;;
    *)
      echo "Unknown AI CLI: $ai_cli" >&2
      return 1
      ;;
  esac

  if [[ -z "${notes//[[:space:]]/}" ]]; then
    echo "Release notes generation returned no output with ${ai_cli}." >&2
    return 1
  fi

  echo "$notes"
}

create_release_tag() {
  local tag="$1" notes="$2"

  git tag -a --cleanup=verbatim "$tag" -m "$notes"
}

extract_release_notes_from_tag() {
  local tag="$1"
  local contents legacy_header

  contents=$(git tag -l --format='%(contents)' "$tag")
  legacy_header="Release ${tag}"$'\n\n'

  if [[ "$contents" == "$legacy_header"* ]]; then
    contents="${contents#"$legacy_header"}"
  fi

  printf '%s\n' "$contents"
}

resolve_ai_cli() {
  local preference="${1:-auto}"

  case "$preference" in
    auto)
      if command -v codex > /dev/null 2>&1; then
        echo "codex"
      elif command -v claude > /dev/null 2>&1; then
        echo "claude"
      else
        echo "Neither codex nor claude is installed. Install one of them or use --ai to choose an available CLI." >&2
        return 1
      fi
      ;;
    codex | claude)
      if ! command -v "$preference" > /dev/null 2>&1; then
        echo "Requested AI CLI '$preference' is not installed." >&2
        return 1
      fi
      echo "$preference"
      ;;
    *)
      echo "Invalid value for --ai: $preference" >&2
      return 1
      ;;
  esac
}

delete_github_release_for_tag() {
  local tag="$1"

  if ! command -v gh > /dev/null 2>&1; then
    echo "Retagging requires the GitHub CLI (gh) so the existing GitHub release can be deleted." >&2
    echo "Install gh and authenticate it with write access to this repository." >&2
    return 1
  fi

  local lookup_output lookup_status=0
  lookup_output=$(gh release view "$tag" --json tagName --jq .tagName 2>&1) || lookup_status=$?

  if ((lookup_status == 0)); then
    echo "Deleting GitHub release for $tag..."
    gh release delete "$tag" --yes
    return 0
  fi

  if ((lookup_status == 4)); then
    echo "GitHub CLI is not authenticated. Run 'gh auth login' before retagging." >&2
    return 1
  fi

  if [[ "$lookup_output" == *"release not found"* || "$lookup_output" == *"Not Found"* ]]; then
    echo "No GitHub release found for $tag."
    return 0
  fi

  echo "Failed to check GitHub release for $tag:" >&2
  echo "$lookup_output" >&2
  return 1
}

require_clean_npm_release_state() {
  local current_branch
  git ls-files --error-unmatch "$RELEASE_CONFIG_FILE" "$RELEASE_PACKAGE_MANIFEST" > /dev/null 2>&1 || {
    echo "$RELEASE_CONFIG_FILE and $RELEASE_PACKAGE_MANIFEST must be tracked." >&2
    return 1
  }
  current_branch=$(git symbolic-ref --quiet --short HEAD) || {
    echo "npm releases require an attached branch." >&2
    return 1
  }
  if [[ "$current_branch" != "$RELEASE_BRANCH" ]]; then
    echo "npm releases must run on $RELEASE_BRANCH, not $current_branch." >&2
    return 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "npm releases require a clean working tree." >&2
    return 1
  fi
}

ensure_remote_tag_absent() {
  local tag="$1" status=0
  git ls-remote --exit-code --tags origin "refs/tags/$tag" > /dev/null 2>&1 || status=$?
  case "$status" in
    0)
      echo "Remote tag ${tag} already exists." >&2
      return 1
      ;;
    2) return 0 ;;
    *)
      echo "Could not check remote tag $tag." >&2
      return 1
      ;;
  esac
}

set_package_version() {
  local manifest="$1" version="$2"
  node - "$manifest" "$version" << 'NODE'
const fs = require("node:fs");
const [manifest, version] = process.argv.slice(2);
const packageJson = JSON.parse(fs.readFileSync(manifest, "utf8"));
packageJson.version = version;
fs.writeFileSync(manifest, `${JSON.stringify(packageJson, null, 2)}\n`);
NODE
}

publish_npm_release_tag() {
  local new_tag="$1" new_version="$2" notes="$3" original_head="$4"
  local branch local_tag_created=0
  branch=$(git symbolic-ref --quiet --short HEAD)

  set_package_version "$RELEASE_PACKAGE_MANIFEST" "$new_version"
  if ! (
    cd "$RELEASE_PACKAGE_PATH"
    npm pack --dry-run > /dev/null
  ); then
    git restore -- "$RELEASE_PACKAGE_MANIFEST"
    return 1
  fi

  local changed_path
  while IFS= read -r changed_path; do
    [[ -z "$changed_path" || "$changed_path" == "$RELEASE_PACKAGE_MANIFEST" ]] && continue
    git restore -- "$RELEASE_PACKAGE_MANIFEST"
    echo "Package validation changed an unexpected file: $changed_path" >&2
    return 1
  done < <({
    git diff --name-only
    git ls-files --others --exclude-standard
  } | sort -u)

  git add "$RELEASE_PACKAGE_MANIFEST"
  if ! git commit -m "chore: release ${RELEASE_PACKAGE} v${new_version}"; then
    echo "Release commit failed; the version change remains staged for inspection." >&2
    return 1
  fi

  if ! create_release_tag "$new_tag" "$notes"; then
    git reset --hard "$original_head"
    return 1
  fi
  local_tag_created=1

  if ! git push --atomic origin "HEAD:refs/heads/$branch" "refs/tags/$new_tag"; then
    if ((local_tag_created)); then
      git tag -d "$new_tag" > /dev/null 2>&1 || true
    fi
    git reset --hard "$original_head"
    echo "Atomic push failed; restored the local branch and tag state." >&2
    return 1
  fi

  echo "Pushed $branch and $new_tag atomically - CI release workflow will start automatically."
}

cmd_bump() {
  local part=""
  local version_override=""
  local package_arg=""
  local dry_run=0

  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi

  if [[ $# -eq 0 ]]; then
    print_bump_usage
    exit 1
  fi

  if [[ "$1" == "--version" ]]; then
    if [[ $# -lt 2 ]]; then
      echo "Missing value for --version" >&2
      print_bump_usage
      exit 1
    fi
    version_override="$2"
    shift 2
  else
    part="$1"
    if [[ ! "$part" =~ ^(major|minor|patch)$ ]]; then
      print_bump_usage
      exit 1
    fi
    shift
  fi

  if [[ "$RELEASE_MODE" == "npm" ]]; then
    if [[ $# -ne 1 ]]; then
      print_bump_usage
      exit 1
    fi
    package_arg="$1"
    resolve_npm_package "$package_arg"
  elif [[ $# -gt 0 ]]; then
    if [[ "$1" == "--version" ]]; then
      echo "Do not pass major, minor, or patch when using --version." >&2
    else
      echo "Unknown argument for bump: $1" >&2
    fi
    print_bump_usage
    exit 1
  fi

  if [[ -n "$version_override" ]] && ! is_semver_tag "$version_override"; then
    echo "Invalid value for --version: $version_override" >&2
    echo "--version must use the existing tag format: vMAJOR.MINOR.PATCH" >&2
    exit 1
  fi

  local latest current new_version new_tag
  latest=$(get_latest_tag "$RELEASE_TAG_PREFIX")
  if [[ "$RELEASE_MODE" == "npm" ]]; then
    current="$RELEASE_PACKAGE_VERSION"
    if [[ -n "$latest" ]] && [[ "$(parse_version "$latest" "$RELEASE_TAG_PREFIX")" != "$current" ]]; then
      echo "$RELEASE_PACKAGE manifest version $current does not match latest tag $latest." >&2
      exit 1
    fi
  elif [[ -z "$latest" ]]; then
    current="0.0.0"
  else
    current=$(parse_version "$latest")
  fi

  if [[ -n "$version_override" ]]; then
    new_version="${version_override#v}"
  else
    new_version=$(bump_version "$current" "$part")
  fi
  new_tag="${RELEASE_TAG_PREFIX}${new_version}"

  local version_comparison
  version_comparison=$(compare_versions "$new_version" "$current")
  if [[ "$RELEASE_MODE" == "npm" ]] && ((version_comparison <= 0)); then
    echo "New version $new_version must be greater than $current." >&2
    exit 1
  fi

  if git rev-parse -q --verify "refs/tags/${new_tag}" > /dev/null 2>&1; then
    echo "Tag ${new_tag} already exists." >&2
    exit 1
  fi
  if [[ "$RELEASE_MODE" == "npm" ]]; then
    ensure_remote_tag_absent "$new_tag"
  fi

  if [[ "$RELEASE_MODE" == "npm" ]] && ((dry_run == 0)); then
    require_clean_npm_release_state
  fi

  echo "Current version: ${current}"
  if [[ -n "$version_override" ]]; then
    echo "New version:     ${new_tag} (override)"
  else
    echo "New version:     ${new_tag}"
  fi
  if [[ "$RELEASE_MODE" == "npm" ]]; then
    echo "Package:         ${RELEASE_PACKAGE} (${RELEASE_PACKAGE_PATH})"
  fi
  echo ""

  local ai_cli
  ai_cli=$(resolve_ai_cli "$AI_CLI")

  echo "Generating release notes with ${ai_cli}..."
  local notes
  notes=$(generate_notes "$latest" "$new_tag" "$ai_cli" "$RELEASE_PACKAGE" "$RELEASE_PACKAGE_PATH")
  echo ""
  echo "--- Release Notes ---"
  echo "$notes"
  echo "---------------------"
  echo ""

  if ((dry_run)); then
    if [[ "$RELEASE_MODE" == "npm" ]]; then
      echo "Dry run complete. No package version, commit, or tag was changed."
    else
      echo "Dry run complete. No local tag was created or pushed."
    fi
    return
  fi

  local original_head
  original_head=$(git rev-parse HEAD)
  read -rp "Create and push ${new_tag}? [Y/n] " confirm
  if [[ "$confirm" == [nN] ]]; then
    echo "Aborted."
    exit 0
  fi

  if [[ "$RELEASE_MODE" == "npm" ]]; then
    if [[ "$(git rev-parse HEAD)" != "$original_head" ]]; then
      echo "HEAD changed while preparing the release; start again." >&2
      exit 1
    fi
    require_clean_npm_release_state
    publish_npm_release_tag "$new_tag" "$new_version" "$notes" "$original_head"
  else
    create_release_tag "$new_tag" "$notes"
    if ! git push origin "${new_tag}"; then
      git tag -d "$new_tag" > /dev/null 2>&1 || true
      return 1
    fi
    echo "Pushed ${new_tag} - CI release workflow will start automatically."
  fi
}

cmd_retag() {
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
  fi

  if [[ "$RELEASE_MODE" == "npm" ]]; then
    echo "retag is disabled for npm packages because published versions are immutable." >&2
    echo "Create a new patch release instead." >&2
    exit 1
  fi

  local latest
  latest=$(get_latest_tag)
  if [[ -z "$latest" ]]; then
    echo "No version tags found."
    exit 1
  fi

  local tag="$latest"

  # Find the tag before this one for release notes range
  local prev_tag
  prev_tag=$(git tag --sort=-v:refname | awk -v tag="$tag" '$0 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ && $0 != tag { print; exit }')

  local ai_cli
  ai_cli=$(resolve_ai_cli "$AI_CLI")

  if ((dry_run)); then
    echo "Dry run: $tag would be re-pointed to HEAD ($(git rev-parse --short HEAD))."
  else
    echo "This will re-point $tag to HEAD ($(git rev-parse --short HEAD))."
    echo "WARNING: This deletes the GitHub release and remote tag, then re-pushes the tag."
  fi
  echo ""

  local notes
  if ((dry_run)); then
    echo "Generating release notes with ${ai_cli}..."
    notes=$(generate_notes "$prev_tag" "$tag" "$ai_cli")
    echo ""
    echo "--- Release Notes ---"
    echo "$notes"
    echo "---------------------"
  else
    # Extract previous release notes from the existing tag annotation
    local prev_notes
    prev_notes=$(extract_release_notes_from_tag "$tag")

    if [[ -n "${prev_notes//[[:space:]]/}" ]]; then
      echo "--- Previous Release Notes ---"
      echo "$prev_notes"
      echo "------------------------------"
      echo ""
      read -rp "Use previous release notes? [Y/n] " use_prev
      if [[ "$use_prev" == [nN] ]]; then
        echo ""
        echo "Generating new release notes with ${ai_cli}..."
        notes=$(generate_notes "$prev_tag" "$tag" "$ai_cli")
        echo ""
        echo "--- New Release Notes ---"
        echo "$notes"
        echo "-------------------------"
      else
        notes="$prev_notes"
      fi
    else
      echo "No previous release notes found on $tag."
      echo ""
      echo "Generating release notes with ${ai_cli}..."
      notes=$(generate_notes "$prev_tag" "$tag" "$ai_cli")
      echo ""
      echo "--- Release Notes ---"
      echo "$notes"
      echo "---------------------"
    fi
  fi
  echo ""

  if ((dry_run)); then
    echo "Dry run complete. No GitHub release or local or remote tag was changed."
    return
  fi

  read -rp "Continue? [Y/n] " confirm
  if [[ "$confirm" == [nN] ]]; then
    echo "Aborted."
    exit 0
  fi

  delete_github_release_for_tag "$tag"
  git tag -d "$tag"
  create_release_tag "$tag" "$notes"
  git push origin ":refs/tags/$tag"
  git push origin "$tag"
  echo "Re-tagged $tag to $(git rev-parse --short HEAD) locally and remotely."
}

cmd_latest() {
  if [[ "$RELEASE_MODE" == "npm" ]]; then
    if [[ $# -ne 1 ]]; then
      echo "Usage: ./release.sh latest <package>" >&2
      exit 1
    fi
    resolve_npm_package "$1"
  elif [[ $# -gt 0 ]]; then
    echo "latest does not accept arguments without $RELEASE_CONFIG_FILE." >&2
    exit 1
  fi

  local latest
  latest=$(get_latest_tag "$RELEASE_TAG_PREFIX")
  if [[ -z "$latest" ]]; then
    if [[ "$RELEASE_MODE" == "npm" ]]; then
      echo "No version tags found for $RELEASE_PACKAGE."
    else
      echo "No version tags found."
    fi
  else
    echo "$latest ($(parse_version "$latest" "$RELEASE_TAG_PREFIX"))"
  fi
}

AI_CLI="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ai)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --ai" >&2
        usage 1
      fi
      AI_CLI="$2"
      shift 2
      ;;
    -h | --help)
      usage 0
      ;;
    *)
      break
      ;;
  esac
done

load_release_mode

[[ $# -lt 1 ]] && usage 1

command="$1"
shift

case "$command" in
  bump) cmd_bump "$@" ;;
  retag) cmd_retag "$@" ;;
  latest) cmd_latest "$@" ;;
  *) usage ;;
esac
