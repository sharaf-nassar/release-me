#!/usr/bin/env bash
set -euo pipefail

CODEX_MODEL="gpt-5.5"
CODEX_REASONING_EFFORT="xhigh"
CODEX_SERVICE_TIER="fast"
CODEX_PROGRESS_LINES=20
CODEX_PROGRESS_SCAN_LINES=200
CODEX_PROGRESS_INTERVAL_SECONDS=0.1

usage() {
  local exit_code="${1:-1}"
  cat << 'EOF'
Usage: ./release.sh [--ai auto|codex|claude] <command> [args]

Options:
  --ai <auto|codex|claude>  Select the CLI used for release notes (default: auto)

Commands:
  bump <major|minor|patch>   Create and push a new version tag
  bump --version vX.Y.Z      Create and push an explicit version tag
  retag                      Delete the GitHub release and replace the latest tag
  latest                     Show the latest version tag

Examples:
  ./release.sh --ai auto bump patch   # Prefer Codex, fall back to Claude
  ./release.sh --ai claude bump patch # Force Claude for release notes
  ./release.sh bump patch            # v0.2.1 -> v0.2.2
  ./release.sh bump --version v1.2.3 # Use an explicit tag
  ./release.sh bump minor            # v0.2.1 -> v0.3.0
  ./release.sh bump major            # v0.2.1 -> v1.0.0
  ./release.sh retag             # Delete the GitHub release and re-point latest tag
  ./release.sh latest            # Print latest tag
EOF
  exit "$exit_code"
}

get_latest_tag() {
  git tag --sort=-v:refname | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }'
}

parse_version() {
  local tag="$1"
  echo "${tag#v}"
}

print_bump_usage() {
  echo "Usage: ./release.sh bump <major|minor|patch>"
  echo "       ./release.sh bump --version vX.Y.Z"
}

is_semver_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
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
    -m "$CODEX_MODEL" \
    -c "model_reasoning_effort=\"$CODEX_REASONING_EFFORT\"" \
    -c "service_tier=\"$CODEX_SERVICE_TIER\"" \
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

  local range
  if [[ -z "$prev_tag" ]]; then
    range="HEAD"
  else
    range="${prev_tag}..HEAD"
  fi

  local commits changed_files diff_stat
  commits=$(git log "$range" --pretty=format:"- %s%n%b" --no-merges)
  changed_files=$(git diff "${prev_tag:-$(git rev-list --max-parents=0 HEAD)}..HEAD" --name-status)
  diff_stat=$(git diff "${prev_tag:-$(git rev-list --max-parents=0 HEAD)}..HEAD" --stat)

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

cmd_bump() {
  local part=""
  local version_override=""

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
    if [[ $# -gt 0 ]]; then
      echo "Do not pass major, minor, or patch when using --version." >&2
      print_bump_usage
      exit 1
    fi
  else
    part="$1"
    if [[ ! "$part" =~ ^(major|minor|patch)$ ]]; then
      print_bump_usage
      exit 1
    fi
    shift
    if [[ $# -gt 0 ]]; then
      if [[ "$1" == "--version" ]]; then
        echo "Do not pass major, minor, or patch when using --version." >&2
      else
        echo "Unknown argument for bump: $1" >&2
      fi
      print_bump_usage
      exit 1
    fi
  fi

  if [[ -n "$version_override" ]] && ! is_semver_tag "$version_override"; then
    echo "Invalid value for --version: $version_override" >&2
    echo "--version must use the existing tag format: vMAJOR.MINOR.PATCH" >&2
    exit 1
  fi

  local latest current new_tag
  latest=$(get_latest_tag)
  if [[ -z "$latest" ]]; then
    current="0.0.0"
  else
    current=$(parse_version "$latest")
  fi

  if [[ -n "$version_override" ]]; then
    new_tag="$version_override"
  else
    new_tag="v$(bump_version "$current" "$part")"
  fi

  if git rev-parse -q --verify "refs/tags/${new_tag}" > /dev/null 2>&1; then
    echo "Tag ${new_tag} already exists." >&2
    exit 1
  fi

  echo "Current version: ${current}"
  if [[ -n "$version_override" ]]; then
    echo "New version:     ${new_tag} (override)"
  else
    echo "New version:     ${new_tag}"
  fi
  echo ""

  local ai_cli
  ai_cli=$(resolve_ai_cli "$AI_CLI")

  echo "Generating release notes with ${ai_cli}..."
  local notes
  notes=$(generate_notes "$latest" "$new_tag" "$ai_cli")
  echo ""
  echo "--- Release Notes ---"
  echo "$notes"
  echo "---------------------"
  echo ""

  read -rp "Create and push tag ${new_tag}? [Y/n] " confirm
  if [[ "$confirm" == [nN] ]]; then
    echo "Aborted."
    exit 0
  fi

  git tag -a --cleanup=verbatim "${new_tag}" -m "Release ${new_tag}

${notes}"
  git push origin "${new_tag}"
  echo "Pushed ${new_tag} - CI release workflow will start automatically."
}

cmd_retag() {
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

  echo "This will re-point $tag to HEAD ($(git rev-parse --short HEAD))."
  echo "WARNING: This deletes the GitHub release and remote tag, then re-pushes the tag."
  echo ""

  # Extract previous release notes from the existing tag annotation
  local prev_notes
  prev_notes=$(git tag -l --format='%(contents:body)' "$tag" | sed '/^$/d')

  local notes
  if [[ -n "$prev_notes" ]]; then
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
  echo ""

  read -rp "Continue? [Y/n] " confirm
  if [[ "$confirm" == [nN] ]]; then
    echo "Aborted."
    exit 0
  fi

  delete_github_release_for_tag "$tag"
  git tag -d "$tag"
  git tag -a --cleanup=verbatim "$tag" -m "Release ${tag}

${notes}"
  git push origin ":refs/tags/$tag"
  git push origin "$tag"
  echo "Re-tagged $tag to $(git rev-parse --short HEAD) locally and remotely."
}

cmd_latest() {
  local latest
  latest=$(get_latest_tag)
  if [[ -z "$latest" ]]; then
    echo "No version tags found."
  else
    echo "$latest ($(parse_version "$latest"))"
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

[[ $# -lt 1 ]] && usage 1

command="$1"
shift

case "$command" in
  bump) cmd_bump "$@" ;;
  retag) cmd_retag "$@" ;;
  latest) cmd_latest "$@" ;;
  *) usage ;;
esac
