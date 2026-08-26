#!/usr/bin/env bash

set -euo pipefail

WORKTREE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_GIT_DIR="$(git -C "$WORKTREE_ROOT" rev-parse --git-common-dir)"
if [[ "$COMMON_GIT_DIR" != /* ]]; then
  COMMON_GIT_DIR="$(cd "$WORKTREE_ROOT/$COMMON_GIT_DIR" && pwd)"
fi
MAIN_REPO_ROOT="${COMMON_GIT_DIR%/.git}"

copy_from_main() {
  local relative_path="$1"
  local source_path="$MAIN_REPO_ROOT/$relative_path"
  local destination_path="$WORKTREE_ROOT/$relative_path"

  [ -e "$source_path" ] || return 0
  [ -e "$destination_path" ] && return 0

  mkdir -p "$(dirname "$destination_path")"
  cp -R -P "$source_path" "$destination_path"
}

stable_port() {
  local base_port="$1"
  local range_size="${2:-1000}"
  local identity="$MAIN_REPO_ROOT:$WORKTREE_ROOT"
  local raw_hash

  raw_hash="$(printf '%s' "$identity" | cksum | awk '{print $1}')"
  printf '%s\n' "$((base_port + raw_hash % range_size))"
}

install_dependencies() {
  # Replace this no-op with the repository's lockfile-respecting install command.
  # Examples: npm ci; pnpm install --frozen-lockfile; uv sync --frozen.
  :
}

configure_worktree() {
  # Copy project-local files not covered by wt's automatic .env copying:
  # copy_from_main "path/to/local-file"

  # Allocate stable per-worktree ports and expose them to dev/test commands:
  # APP_PORT="$(stable_port 4001)"
  # printf 'export APP_PORT=%q\n' "$APP_PORT" > "$WORKTREE_ROOT/.worktree-env"
  :
}

install_dependencies
configure_worktree
