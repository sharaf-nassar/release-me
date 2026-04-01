#!/usr/bin/env bash
set -euo pipefail

CODEX_MODEL="gpt-5.4"
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
  retag                      Replace the latest tag locally and remotely
  latest                     Show the latest version tag

Examples:
  ./release.sh --ai auto bump patch   # Prefer Codex, fall back to Claude
  ./release.sh --ai claude bump patch # Force Claude for release notes
  ./release.sh bump patch        # v0.2.1 -> v0.2.2
  ./release.sh bump minor        # v0.2.1 -> v0.3.0
  ./release.sh bump major        # v0.2.1 -> v1.0.0
  ./release.sh retag             # Re-point the latest tag to current HEAD
  ./release.sh latest            # Print latest tag
EOF
  exit "$exit_code"
}

get_latest_tag() {
  git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1
}

parse_version() {
  local tag="$1"
  echo "${tag#v}"
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

  local commits diff_stat
  commits=$(git log "$range" --pretty=format:"- %s" --no-merges)
  diff_stat=$(git diff "${prev_tag:-$(git rev-list --max-parents=0 HEAD)}..HEAD" --stat)

  local prompt
  prompt=$(
    cat << PROMPT
You are writing release notes for this repo.

Focus ONLY on new features and capabilities that are visible in the app.
For each feature, write a bold heading and 1-2 sentences describing what it does.
Write directly about the feature, not from the user's perspective — avoid "you can",
"your", "lets you". Example: "Review and approve suggestions with a diff preview"
not "You can now review and approve suggestions".

OMIT entirely: bug fixes, refactors, dependency updates, CI changes, internal
architecture changes, performance improvements, and anything not visible in the app.
If a commit is purely technical with no visible impact, skip it.

Output format — a flat list under a single "## What's New" heading. No sub-sections.
If there are zero visible changes, output "Maintenance release — no user-facing changes."

Version: ${new_tag}
Previous version: ${prev_tag:-"(first release)"}

Commits:
${commits}

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
      notes=$(claude -p --model haiku --output-format text --no-session-persistence "$prompt" 2> /dev/null)
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

cmd_bump() {
  local part="${1:-}"
  if [[ -z "$part" || ! "$part" =~ ^(major|minor|patch)$ ]]; then
    echo "Usage: ./release.sh bump <major|minor|patch>"
    exit 1
  fi

  local latest current new_version
  latest=$(get_latest_tag)
  if [[ -z "$latest" ]]; then
    current="0.0.0"
  else
    current=$(parse_version "$latest")
  fi

  new_version=$(bump_version "$current" "$part")
  echo "Current version: ${current}"
  echo "New version:     v${new_version}"
  echo ""

  local ai_cli
  ai_cli=$(resolve_ai_cli "$AI_CLI")

  echo "Generating release notes with ${ai_cli}..."
  local notes
  notes=$(generate_notes "$latest" "v${new_version}" "$ai_cli")
  echo ""
  echo "--- Release Notes ---"
  echo "$notes"
  echo "---------------------"
  echo ""

  read -rp "Create and push tag v${new_version}? [Y/n] " confirm
  if [[ "$confirm" == [nN] ]]; then
    echo "Aborted."
    exit 0
  fi

  git tag -a "v${new_version}" -m "Release v${new_version}

${notes}"
  git push origin "v${new_version}"
  echo "Pushed v${new_version} - CI release workflow will start automatically."
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
  prev_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -v "^${tag}$" | head -n1)

  local ai_cli
  ai_cli=$(resolve_ai_cli "$AI_CLI")

  echo "This will re-point $tag to HEAD ($(git rev-parse --short HEAD))."
  echo "WARNING: This deletes the tag on the remote and re-pushes it."
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

  git tag -d "$tag"
  git tag -a "$tag" -m "Release ${tag}

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
