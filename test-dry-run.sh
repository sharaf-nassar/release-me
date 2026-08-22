#!/usr/bin/env bash
set -euo pipefail

case "$(basename "$0")" in
  codex)
    printf '%s\n' "$@" > "$CODEX_ARGS_FILE"
    output_file=""
    while (($#)); do
      if [[ "$1" == "-o" ]]; then
        output_file="$2"
        break
      fi
      shift
    done
    [[ -n "$output_file" ]]
    if [[ -n "${CODEX_PROMPT_FILE:-}" ]]; then
      cat > "$CODEX_PROMPT_FILE"
    else
      cat > /dev/null
    fi
    printf '%s\n' "Generated dry-run notes." > "$output_file"
    exit
    ;;
  gh)
    : > "$GH_CALLED_FILE"
    exit 99
    ;;
  pre-receive)
    : > "$REMOTE_CALLED_FILE"
    cat > /dev/null
    exit
    ;;
esac

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

consumer="$test_root/consumer"
origin="$test_root/origin.git"
mock_bin="$test_root/bin"
mkdir -p "$consumer/tools" "$mock_bin"

git init --bare --quiet "$origin"
git -C "$consumer" init --quiet
git -C "$consumer" config user.name "Dry Run Test"
git -C "$consumer" config user.email "dry-run@example.com"
printf '%s\n' "initial" > "$consumer/change.txt"
git -C "$consumer" add change.txt
git -C "$consumer" commit --quiet -m "initial"
git -C "$consumer" tag -a v1.0.0 -m "Existing notes"
git -C "$consumer" remote add origin "$origin"
git -C "$consumer" push --quiet origin HEAD:main v1.0.0

ln -s "$repo_root" "$consumer/tools/release-me"
ln -s "$repo_root/test-dry-run.sh" "$mock_bin/codex"
ln -s "$repo_root/test-dry-run.sh" "$mock_bin/gh"
ln -s "$repo_root/test-dry-run.sh" "$origin/hooks/pre-receive"

printf '%s\n' "unreleased" >> "$consumer/change.txt"
git -C "$consumer" add change.txt
git -C "$consumer" commit --quiet -m "unreleased change"

export GH_CALLED_FILE="$test_root/gh-called"
export REMOTE_CALLED_FILE="$test_root/remote-called"
export CODEX_ARGS_FILE="$test_root/codex-args"
export CODEX_PROMPT_FILE="$test_root/codex-prompt"
tag_before=$(git -C "$consumer" rev-parse refs/tags/v1.0.0)

bump_output=$(cd "$consumer" && PATH="$mock_bin:$PATH" \
  ./tools/release-me/release.sh --ai codex bump --dry-run patch)
[[ "$bump_output" == *"Generated dry-run notes."* ]]
[[ "$bump_output" == *"No local tag was created or pushed."* ]]
grep -Fx -- "-C" "$CODEX_ARGS_FILE" > /dev/null
grep -Fx -- "$consumer" "$CODEX_ARGS_FILE" > /dev/null
if grep -Eq '^(-m|--model|-c|--config)$' "$CODEX_ARGS_FILE"; then
  exit 1
fi
if git -C "$consumer" rev-parse --verify refs/tags/v1.0.1 > /dev/null 2>&1; then
  exit 1
fi

override_output=$(cd "$consumer" && PATH="$mock_bin:$PATH" \
  ./tools/release-me/release.sh --ai codex bump --dry-run --version v1.2.3)
[[ "$override_output" == *"New version:     v1.2.3 (override)"* ]]
if git -C "$consumer" rev-parse --verify refs/tags/v1.2.3 > /dev/null 2>&1; then
  exit 1
fi

retag_output=$(cd "$consumer" && PATH="$mock_bin:$PATH" \
  ./tools/release-me/release.sh --ai codex retag --dry-run)
[[ "$retag_output" == *"Generated dry-run notes."* ]]
[[ "$retag_output" == *"No GitHub release or local or remote tag was changed."* ]]
[[ "$(git -C "$consumer" rev-parse refs/tags/v1.0.0)" == "$tag_before" ]]
[[ ! -e "$GH_CALLED_FILE" ]]
[[ ! -e "$REMOTE_CALLED_FILE" ]]

branch=$(git -C "$consumer" branch --show-current)
mkdir -p "$consumer/packages/demo"
printf '%s\n' '{"name":"demo","version":"1.2.0"}' > "$consumer/packages/demo/package.json"
printf '%s\n' 'module.exports = "initial";' > "$consumer/packages/demo/index.js"
printf '%s\n' "sibling" > "$consumer/sibling.txt"
cat > "$consumer/.release-me.json" << EOF
{
  "type": "npm",
  "branch": "$branch",
  "packages": {
    "demo": "packages/demo/package.json"
  }
}
EOF
git -C "$consumer" add .release-me.json packages sibling.txt tools/release-me
git -C "$consumer" commit --quiet -m "add npm release package"
git -C "$consumer" tag -a demo-v1.2.0 -m "Demo 1.2.0"
git -C "$consumer" push --quiet origin "HEAD:$branch" demo-v1.2.0

printf '%s\n' "sibling-only" >> "$consumer/sibling.txt"
git -C "$consumer" add sibling.txt
git -C "$consumer" commit --quiet -m "change sibling only"
printf '%s\n' 'module.exports = "changed";' > "$consumer/packages/demo/index.js"
git -C "$consumer" add packages/demo/index.js
git -C "$consumer" commit --quiet -m "improve demo package"
rm -f "$REMOTE_CALLED_FILE" "$CODEX_PROMPT_FILE"

npm_dry_output=$(cd "$consumer" && PATH="$mock_bin:$PATH" \
  ./tools/release-me/release.sh --ai codex bump --dry-run patch demo)
[[ "$npm_dry_output" == *"New version:     demo-v1.2.1"* ]]
[[ "$npm_dry_output" == *"No package version, commit, or tag was changed."* ]]
[[ "$(node -p "require('$consumer/packages/demo/package.json').version")" == "1.2.0" ]]
[[ ! -e "$REMOTE_CALLED_FILE" ]]
grep -F "packages/demo/index.js" "$CODEX_PROMPT_FILE" > /dev/null
if grep -F "sibling.txt" "$CODEX_PROMPT_FILE" > /dev/null; then
  exit 1
fi

latest_output=$(cd "$consumer" && ./tools/release-me/release.sh latest demo)
[[ "$latest_output" == "demo-v1.2.0 (1.2.0)" ]]
if (cd "$consumer" && ./tools/release-me/release.sh latest unknown > /dev/null 2>&1); then
  exit 1
fi
if (cd "$consumer" && ./tools/release-me/release.sh retag demo > /dev/null 2>&1); then
  exit 1
fi

printf '\n' | (cd "$consumer" && PATH="$mock_bin:$PATH" \
  ./tools/release-me/release.sh --ai codex bump patch demo > /dev/null)
[[ "$(node -p "require('$consumer/packages/demo/package.json').version")" == "1.2.1" ]]
[[ "$(git -C "$consumer" log -1 --pretty=%s)" == "chore: release demo v1.2.1" ]]
[[ "$(git -C "$consumer" rev-parse HEAD)" == "$(git --git-dir="$origin" rev-parse "refs/heads/$branch")" ]]
[[ "$(git -C "$consumer" rev-parse 'demo-v1.2.1^{commit}')" == "$(git --git-dir="$origin" rev-parse 'demo-v1.2.1^{commit}')" ]]
[[ "$(git -C "$consumer" cat-file -t demo-v1.2.1)" == "tag" ]]
[[ -e "$REMOTE_CALLED_FILE" ]]
[[ ! -e "$GH_CALLED_FILE" ]]

echo "dry-run and npm release checks passed"
