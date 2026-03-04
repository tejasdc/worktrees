#!/usr/bin/env bash
#
# worktree.sh — Git worktree manager for parallel development
#
# Usage:
#   worktree.sh <name>              Create a new worktree
#   worktree.sh list                List all worktrees with status
#   worktree.sh cleanup             Remove worktrees whose branches are merged
#
# Designed to be workspace-agnostic. Works with any git repo.
# All user-facing output goes to stderr. Only the worktree path goes to stdout
# (for shell function cd and Claude hook integration).

set -euo pipefail

# Require bash 4+ for associative arrays
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Error: worktree.sh requires bash 4+. You have bash ${BASH_VERSION}." >&2
  echo "On macOS: brew install bash" >&2
  exit 1
fi

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()     { echo -e "$*" >&2; }
info()    { log "${BLUE}$*${NC}"; }
success() { log "${GREEN}$*${NC}"; }
warn()    { log "${YELLOW}$*${NC}"; }
error()   { log "${RED}$*${NC}"; }

get_repo_root() {
  # If we're inside a worktree, resolve to the MAIN repo root (not the worktree root).
  # git rev-parse --show-toplevel returns the worktree root, but --git-common-dir
  # returns the main repo's .git directory regardless of where we are.
  local common_dir
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1

  # --git-common-dir returns:
  #   ".git"            → we're in the main repo (relative)
  #   "/abs/path/.git"  → we're in a worktree (absolute path to main .git)
  if [ "$common_dir" = ".git" ]; then
    git rev-parse --show-toplevel 2>/dev/null
  else
    echo "${common_dir%/.git}"
  fi
}

get_worktree_dir() {
  echo "$(get_repo_root)/.worktrees"
}

# Resolve the merge target ref (origin/main, origin/master, or fallback to HEAD)
get_merge_target() {
  local repo_root="$1"
  for ref in origin/main origin/master; do
    if git -C "$repo_root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      echo "$ref"
      return 0
    fi
  done
  echo "HEAD"
}

# Check if a branch is fully merged into a target ref
is_branch_merged() {
  local repo_root="$1" branch="$2" target="$3"
  git -C "$repo_root" merge-base --is-ancestor "$branch" "$target" 2>/dev/null
}

# Count commits in a range, safe under pipefail
count_commits() {
  local repo="$1" range="$2"
  git -C "$repo" rev-list --count "$range" 2>/dev/null || echo 0
}

# Check if pwd is inside a worktree path (handles subdirectories)
is_cwd_inside() {
  local wt_path="$1"
  local wt_real pwd_real
  wt_real=$(cd "$wt_path" && pwd -P)
  pwd_real=$(pwd -P)
  [[ "$pwd_real" == "$wt_real" || "$pwd_real" == "$wt_real"/* ]]
}

# ─── File Discovery ──────────────────────────────────────────────────────────
#
# Copies gitignored .env* files from the main repo to the new worktree.
# Only copies files that are both matching .env* and gitignored.
#
# For project-specific files (keys, certs, etc.), use scripts/worktree-bootstrap.sh.

discover_and_copy_files() {
  local repo_root="$1"
  local worktree_path="$2"
  local copied=0

  log ""
  info "Copying .env files..."
  log ""

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if git -C "$repo_root" check-ignore -q "$file" 2>/dev/null; then
      copy_file_preserving_structure "$repo_root" "$worktree_path" "$file"
      copied=$((copied + 1))
    fi
  done < <(cd "$repo_root" && find . -maxdepth 3 -name '.env*' ! -name '.env.example' -type f 2>/dev/null)

  log ""
  if [ $copied -gt 0 ]; then
    success "Copied $copied .env file(s)"
  else
    warn "No gitignored .env files found to copy"
  fi
}

copy_file_preserving_structure() {
  local repo_root="$1"
  local worktree_path="$2"
  local relative_path="$3"

  # Strip leading ./ if present
  relative_path="${relative_path#./}"

  local source="$repo_root/$relative_path"
  local dest="$worktree_path/$relative_path"
  local dest_dir
  dest_dir=$(dirname "$dest")

  # Skip if destination already exists (shouldn't happen on fresh worktree, but be safe)
  if [ -f "$dest" ]; then
    log "  ${DIM}skip${NC}  $relative_path (already exists)"
    return
  fi

  mkdir -p "$dest_dir"
  cp "$source" "$dest"

  # Preserve file permissions
  chmod --reference="$source" "$dest" 2>/dev/null || \
    chmod "$(stat -f '%Lp' "$source" 2>/dev/null || stat -c '%a' "$source" 2>/dev/null)" "$dest" 2>/dev/null || true

  log "  ${GREEN}copy${NC}  $relative_path"
}

# ─── Gitignore Check ─────────────────────────────────────────────────────────

ensure_gitignored() {
  local repo_root="$1"
  local gitignore="$repo_root/.gitignore"

  if git -C "$repo_root" check-ignore -q ".worktrees/" 2>/dev/null; then
    return 0
  fi

  # .worktrees is not gitignored — add it
  warn ".worktrees/ is not in .gitignore — adding it"
  echo ".worktrees/" >> "$gitignore"
  success "Added .worktrees/ to .gitignore"
}

# ─── Create Command ──────────────────────────────────────────────────────────

cmd_create() {
  local name="$1"

  # Validate: name is safe
  if [ -z "$name" ]; then
    error "Error: worktree name cannot be empty"
    exit 1
  fi
  if [[ "$name" =~ [/\\\ ] ]]; then
    error "Error: worktree name cannot contain slashes, backslashes, or spaces"
    error "Use dashes instead: wt my-feature"
    exit 1
  fi
  if [[ "$name" =~ ^\. ]]; then
    error "Error: worktree name cannot start with a dot"
    exit 1
  fi

  # Validate: inside a git repo
  local repo_root
  repo_root=$(get_repo_root)
  if [ -z "$repo_root" ]; then
    error "Error: not inside a git repository"
    exit 1
  fi

  local repo_name
  repo_name=$(basename "$repo_root")

  local worktree_dir
  worktree_dir=$(get_worktree_dir)
  local worktree_path="$worktree_dir/$name"
  local branch_name="worktree-$name"

  log ""
  log "${BOLD}Creating worktree: $name${NC}"
  log "${DIM}────────────────────────────────────────${NC}"
  log "  Repo:      $repo_name"
  log "  Branch:    $branch_name"
  log "  Location:  $worktree_path"
  log "  Base:      origin/main"
  log ""

  # Check if worktree already exists
  if [ -d "$worktree_path" ]; then
    # It exists — just print the path so wt() can cd into it
    warn "Worktree '$name' already exists at $worktree_path"
    warn "Switching to existing worktree"
    echo "$worktree_path"
    exit 0
  fi

  # Check if branch name is taken (in a different worktree or checked out)
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    error "Error: branch '$branch_name' already exists"
    error "Use a different name, or delete the branch first: git branch -D $branch_name"
    exit 1
  fi

  # Ensure .worktrees/ is gitignored
  ensure_gitignored "$repo_root"

  # Fetch latest main
  info "Fetching origin/main..."
  if git -C "$repo_root" fetch origin main --quiet 2>/dev/null; then
    success "Fetched latest main"
  else
    warn "Could not fetch origin/main — branching from local main"
  fi

  # Determine base branch
  local base_ref="origin/main"
  if ! git -C "$repo_root" rev-parse --verify "$base_ref" &>/dev/null; then
    # Try origin/master as fallback
    base_ref="origin/master"
    if ! git -C "$repo_root" rev-parse --verify "$base_ref" &>/dev/null; then
      # Last resort: use HEAD
      base_ref="HEAD"
      warn "No origin/main or origin/master found — branching from HEAD"
    fi
  fi

  # Create worktree directory
  mkdir -p "$worktree_dir"

  # Create the worktree
  info "Creating git worktree..."
  if ! git -C "$repo_root" worktree add -b "$branch_name" "$worktree_path" "$base_ref" >/dev/null 2>&1; then
    error "Failed to create worktree"
    exit 1
  fi
  success "Worktree created"

  # Discover and copy config files
  discover_and_copy_files "$repo_root" "$worktree_path"

  # Run project-specific bootstrap if it exists
  local bootstrap_script="$worktree_path/scripts/worktree-bootstrap.sh"
  if [ -f "$bootstrap_script" ]; then
    log ""
    info "Running project bootstrap script..."
    log ""
    if bash "$bootstrap_script" >&2; then
      success "Project bootstrap completed"
    else
      warn "Bootstrap script exited with errors (exit code $?)"
      warn "You may need to run it manually: cd $worktree_path && bash scripts/worktree-bootstrap.sh"
    fi
  else
    log ""
    log "  ${DIM}No bootstrap script found at scripts/worktree-bootstrap.sh${NC}"
    log "  ${DIM}Add one to auto-install dependencies on worktree creation${NC}"
  fi

  # Summary
  log ""
  log "${DIM}────────────────────────────────────────${NC}"
  success "Ready! Worktree '$name' is set up"
  log ""
  log "  ${DIM}Branch:${NC}   $branch_name"
  log "  ${DIM}Path:${NC}     $worktree_path"
  log ""
  log "  ${DIM}To push:${NC}  git push -u origin $branch_name"
  log "  ${DIM}To clean:${NC} wt cleanup"
  log ""

  # Print path to stdout (for shell function cd / Claude hook)
  echo "$worktree_path"
}

# ─── List Command ────────────────────────────────────────────────────────────

cmd_list() {
  local repo_root
  repo_root=$(get_repo_root)
  if [ -z "$repo_root" ]; then
    error "Error: not inside a git repository"
    exit 1
  fi

  local worktree_dir
  worktree_dir=$(get_worktree_dir)
  local repo_name
  repo_name=$(basename "$repo_root")

  log ""
  log "${BOLD}Worktrees in $repo_name${NC}"
  log "${DIM}────────────────────────────────────────${NC}"

  if [ ! -d "$worktree_dir" ]; then
    log "  ${DIM}No worktrees found${NC}"
    log ""
    log "  Create one with: ${BLUE}wt my-feature${NC}"
    log ""
    return
  fi

  # Fetch to check merge status accurately
  local merge_target
  merge_target=$(get_merge_target "$repo_root")
  if [[ "$merge_target" == origin/* ]]; then
    git -C "$repo_root" fetch origin "${merge_target#origin/}" --quiet 2>/dev/null || true
  fi

  local count=0
  local merged_count=0

  for wt_path in "$worktree_dir"/*/; do
    [ ! -d "$wt_path" ] && continue
    # Check it's actually a git worktree (has .git file)
    [ ! -e "$wt_path/.git" ] && continue

    count=$((count + 1))
    local wt_name
    wt_name=$(basename "$wt_path")
    local branch
    branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    # Check if merged into main
    local merge_status
    if is_branch_merged "$repo_root" "$branch" "$merge_target"; then
      merge_status="${GREEN}merged${NC}"
      merged_count=$((merged_count + 1))
    else
      # Check if branch has been pushed to remote
      if ! git -C "$repo_root" rev-parse --verify "origin/$branch" &>/dev/null; then
        # Remote branch doesn't exist — never pushed
        local local_commits
        local_commits=$(count_commits "$wt_path" "$merge_target..HEAD")
        if [ "$local_commits" -gt 0 ] 2>/dev/null; then
          merge_status="${YELLOW}active${NC} ($local_commits unpushed)"
        else
          merge_status="${DIM}empty${NC} (no changes)"
        fi
      else
        # Remote branch exists — check if local is ahead
        local unpushed
        unpushed=$(count_commits "$wt_path" "origin/$branch..HEAD")
        if [ "$unpushed" -gt 0 ] 2>/dev/null; then
          merge_status="${YELLOW}active${NC} ($unpushed unpushed)"
        else
          local ahead
          ahead=$(count_commits "$wt_path" "$merge_target..HEAD")
          if [ "$ahead" -gt 0 ] 2>/dev/null; then
            merge_status="${BLUE}pushed${NC} ($ahead commits ahead of main)"
          else
            merge_status="${DIM}empty${NC} (no changes)"
          fi
        fi
      fi
    fi

    # Check if this is our current directory
    local current_marker=""
    if is_cwd_inside "$wt_path" 2>/dev/null; then
      current_marker=" ${GREEN}(current)${NC}"
    fi

    log "  ${BOLD}$wt_name${NC}${current_marker}"
    log "    Branch: $branch"
    log "    Status: $merge_status"
    log "    Path:   $wt_path"
    log ""
  done

  if [ $count -eq 0 ]; then
    log "  ${DIM}No worktrees found${NC}"
    log ""
    log "  Create one with: ${BLUE}wt my-feature${NC}"
  else
    log "${DIM}────────────────────────────────────────${NC}"
    log "  Total: $count worktree(s)"
    if [ $merged_count -gt 0 ]; then
      log "  ${GREEN}$merged_count merged${NC} — run ${BLUE}wt cleanup${NC} to remove"
    fi
  fi
  log ""
}

# ─── Cleanup Command ─────────────────────────────────────────────────────────

cmd_cleanup() {
  local repo_root
  repo_root=$(get_repo_root)
  if [ -z "$repo_root" ]; then
    error "Error: not inside a git repository"
    exit 1
  fi

  local worktree_dir
  worktree_dir=$(get_worktree_dir)

  if [ ! -d "$worktree_dir" ]; then
    info "No worktrees to clean up"
    return
  fi

  log ""
  log "${BOLD}Cleaning up merged worktrees${NC}"
  log "${DIM}────────────────────────────────────────${NC}"

  # Fetch to check merge status accurately
  local merge_target
  merge_target=$(get_merge_target "$repo_root")
  if [[ "$merge_target" == origin/* ]]; then
    git -C "$repo_root" fetch origin "${merge_target#origin/}" --quiet 2>/dev/null || true
  fi

  local removed=0
  local kept=0

  for wt_path in "$worktree_dir"/*/; do
    [ ! -d "$wt_path" ] && continue
    [ ! -e "$wt_path/.git" ] && continue

    local wt_name
    wt_name=$(basename "$wt_path")
    local branch
    branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    # Skip if we're currently inside this worktree (or a subdirectory of it)
    if is_cwd_inside "$wt_path" 2>/dev/null; then
      warn "  skip  $wt_name (you are currently in this worktree)"
      kept=$((kept + 1))
      continue
    fi

    # Check if branch is merged into main
    if is_branch_merged "$repo_root" "$branch" "$merge_target"; then
      # Merged — safe to remove
      if git -C "$repo_root" worktree remove --force "$wt_path" 2>/dev/null; then
        git -C "$repo_root" branch -d "$branch" >/dev/null 2>&1 || true
        success "  remove  $wt_name (branch $branch merged)"
        removed=$((removed + 1))
      else
        warn "  skip  $wt_name (failed to remove worktree)"
        kept=$((kept + 1))
      fi
    else
      log "  ${DIM}keep${NC}    $wt_name (branch $branch not merged)"
      kept=$((kept + 1))
    fi
  done

  log ""
  log "${DIM}────────────────────────────────────────${NC}"
  if [ $removed -gt 0 ]; then
    success "Removed $removed worktree(s)"
  fi
  if [ $kept -gt 0 ]; then
    info "$kept worktree(s) still active (not merged)"
  fi
  if [ $removed -eq 0 ] && [ $kept -eq 0 ]; then
    info "No worktrees to clean up"
  fi

  # Clean up empty .worktrees directory
  if [ -d "$worktree_dir" ] && [ -z "$(ls -A "$worktree_dir" 2>/dev/null)" ]; then
    rmdir "$worktree_dir" 2>/dev/null || true
  fi

  log ""
}

# ─── Help ────────────────────────────────────────────────────────────────────

cmd_help() {
  cat >&2 << 'EOF'
worktree — Git worktree manager for parallel development

Usage:
  wt <name>              Create a new worktree and cd into it
  wt list                List all worktrees with branch and merge status
  wt cleanup             Remove worktrees whose branches are merged into main
  wt help                Show this help

What happens on create:
  1. Creates a git worktree at .worktrees/<name>/
  2. Creates branch worktree-<name> from origin/main
  3. Copies gitignored .env* files from main repo
  4. Runs scripts/worktree-bootstrap.sh if present (project-specific setup)
  5. Prints the worktree path (shell function auto-cd's)

What happens on cleanup:
  - Only removes worktrees whose branches are merged into main
  - Unmerged worktrees are kept (safe by default)

Examples:
  wt auth-refactor       Create worktree for auth work
  wt list                See all worktrees and their status
  wt cleanup             Remove merged worktrees

EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  local command="${1:-}"

  if [ -z "$command" ]; then
    cmd_help
    exit 0
  fi

  case "$command" in
    list|ls)
      cmd_list
      ;;
    cleanup|clean)
      cmd_cleanup
      ;;
    help|--help|-h)
      cmd_help
      ;;
    -*)
      error "Unknown flag: $command"
      cmd_help
      exit 1
      ;;
    *)
      # Default action: create a worktree with this name
      cmd_create "$command"
      ;;
  esac
}

main "$@"
