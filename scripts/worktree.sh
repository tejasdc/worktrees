#!/usr/bin/env bash
#
# worktree.sh — Git worktree manager for parallel development
#
# Usage:
#   worktree.sh <name>              Create a new worktree
#   worktree.sh init                Add a project bootstrap scaffold
#   worktree.sh list                List all worktrees with status
#   worktree.sh cleanup <name>      Remove a named merged worktree if clean
#   worktree.sh delete <name>       Remove a named clean worktree (even if unmerged)
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

get_script_dir() {
  local source="${BASH_SOURCE[0]}"
  local source_dir

  while [ -L "$source" ]; do
    source_dir=$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)
    source=$(readlink "$source")
    [[ "$source" != /* ]] && source="$source_dir/$source"
  done

  cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd
}

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
  echo "$(get_repo_root)/.wt"
}

# Returns all worktree directories that exist (current .wt + legacy .worktrees)
# Outputs one path per line (safe for paths with spaces)
get_all_worktree_dirs() {
  local repo_root="$1"
  [ -d "$repo_root/.wt" ] && printf '%s\n' "$repo_root/.wt"
  [ -d "$repo_root/.worktrees" ] && printf '%s\n' "$repo_root/.worktrees"
  return 0
}

# Find a worktree by name across both .wt and .worktrees
find_worktree_path() {
  local repo_root="$1"
  local name="$2"
  for dir in "$repo_root/.wt" "$repo_root/.worktrees"; do
    if [ -d "$dir/$name" ] && [ -e "$dir/$name/.git" ]; then
      echo "$dir/$name"
      return 0
    fi
  done
  return 1
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

# Paths every other process on this machine runs in or holds open, read once per cleanup.
# Checking only the caller's own directory let one agent's cleanup delete a worktree another
# agent's compile and browser were running in (thinkering, 2026-11-06: uv_cwd crash).
# One find over /proc: a readlink per open file took minutes with ~650 processes.
# Elsewhere (macOS) lsof answers the same question.
IN_USE_PATHS=""
IN_USE_READ=0
IN_USE_CHECK_AVAILABLE=0
read_in_use_paths() {
  [ "$IN_USE_READ" = 1 ] && return
  IN_USE_READ=1
  if [ -d /proc/self ]; then
    local scan_errors raw_paths find_status scan_acceptable=0 diagnostic
    scan_errors=$(mktemp) || return
    if raw_paths=$(LC_ALL=C find /proc/[0-9]*/cwd /proc/[0-9]*/fd -maxdepth 1 -type l -printf '%l\n' 2>"$scan_errors"); then
      find_status=0
    else
      find_status=$?
    fi
    if [ "$find_status" -eq 0 ]; then
      scan_acceptable=1
    elif [ "$find_status" -eq 1 ] && [ -r /proc/self/cwd ] && [ -s "$scan_errors" ]; then
      # A PID may exit after the shell expands /proc paths but before find opens them.
      # Other errors leave process visibility uncertain and must refuse removal.
      scan_acceptable=1
      while IFS= read -r diagnostic; do
        if ! [[ "$diagnostic" =~ ^find:\ .*/proc/[0-9]+/(cwd|fd)(/[0-9]+)?[^/]*:\ No\ such\ file\ or\ directory$ ]]; then
          scan_acceptable=0
          break
        fi
      done < "$scan_errors"
    fi
    rm -f "$scan_errors"
    if [ "$scan_acceptable" = 1 ] && [ -n "$raw_paths" ] &&
      IN_USE_PATHS=$(printf '%s\n' "$raw_paths" | sed 's/ (deleted)$//' | sort -u); then
      IN_USE_CHECK_AVAILABLE=1
    fi
  else
    local lsof_path
    if [ -x /usr/sbin/lsof ]; then
      lsof_path=/usr/sbin/lsof
    else
      lsof_path=$(command -v lsof 2>/dev/null || true)
    fi
    if [ -n "$lsof_path" ] && IN_USE_PATHS=$("$lsof_path" -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u); then
      IN_USE_CHECK_AVAILABLE=1
    fi
  fi
}

# Whether any process runs inside the worktree or holds a file in it open. The calling
# shell's own directory is handled separately by is_cwd_inside.
worktree_in_use() {
  local wt_real
  wt_real=$(cd "$1" && pwd -P) || return 1
  read_in_use_paths
  [ "$IN_USE_CHECK_AVAILABLE" = 1 ] || return 2
  printf '%s\n' "$IN_USE_PATHS" | awk -v p="$wt_real" '$0 == p || index($0, p "/") == 1 { found = 1 } END { exit !found }'
}

# A branch that never received a commit of its own sits on main's history and so reads as
# "merged", although it is new work that has not started committing yet. Its reflog holds
# only the creation entry until its first commit, merge or reset.
branch_never_committed() {
  local repo_root="$1" branch="$2" entries
  entries=$(git -C "$repo_root" reflog show --format=%H "refs/heads/$branch" -- 2>/dev/null | wc -l)
  [ "$entries" -le 1 ]
}

# Git's ordinary status omits ignored files, including copied .env files and build output.
# Treat any tracked, untracked, or ignored file as local work until its provenance is
# inspected and it is removed separately. A failed status check must also refuse removal.
worktree_has_local_files() {
  local status tracked_flags
  status=$(git -C "$1" status --porcelain=v1 --untracked-files=all --ignored=matching) || return 0
  [ -n "$status" ] && return 0
  # assume-unchanged and skip-worktree can hide edited tracked files from status.
  tracked_flags=$(git -C "$1" ls-files -v) || return 0
  [[ "$tracked_flags" =~ (^|$'\n')[a-zS]\  ]]
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
  local common_git_dir
  common_git_dir=$(git -C "$repo_root" rev-parse --git-common-dir)
  if [[ "$common_git_dir" != /* ]]; then
    common_git_dir="$repo_root/${common_git_dir#./}"
  fi
  local local_exclude="$common_git_dir/info/exclude"

  if ! git -C "$repo_root" check-ignore -q ".wt/" 2>/dev/null; then
    mkdir -p "$(dirname "$local_exclude")"
    printf '\n/.wt/\n' >> "$local_exclude"
    success "Ignored .wt/ in this repository's local Git exclude"
  fi
}

# ─── Init Command ────────────────────────────────────────────────────────────

cmd_init() {
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null) || true
  if [ -z "$project_root" ]; then
    error "Error: not inside a git repository"
    exit 1
  fi

  local bootstrap_script="$project_root/scripts/worktree-bootstrap.sh"
  if [ -e "$bootstrap_script" ]; then
    warn "Bootstrap already exists: $bootstrap_script"
    warn "No files changed"
    return 0
  fi

  local template_path
  template_path="$(get_script_dir)/../templates/worktree-bootstrap.sh"
  if [ ! -f "$template_path" ]; then
    error "Error: bootstrap template not found: $template_path"
    error "Reinstall wt from the canonical worktrees checkout"
    exit 1
  fi

  mkdir -p "$(dirname "$bootstrap_script")"
  cp "$template_path" "$bootstrap_script"
  chmod +x "$bootstrap_script"

  if ! git -C "$project_root" check-ignore -q ".worktree-env" 2>/dev/null; then
    printf '\n/.worktree-env\n' >> "$project_root/.gitignore"
  fi

  success "Created scripts/worktree-bootstrap.sh"
  info "Adapt it to this repository, then commit it with /.worktree-env in .gitignore"
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

  # Check if worktree already exists (in .wt or legacy .worktrees)
  local existing_path
  if existing_path=$(find_worktree_path "$repo_root" "$name"); then
    warn "Worktree '$name' already exists at $existing_path"
    warn "Switching to existing worktree"
    echo "$existing_path"
    exit 0
  fi

  # Check if branch name is taken (in a different worktree or checked out)
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    error "Error: branch '$branch_name' already exists"
    error "Use a different name, or delete the branch first: git branch -D $branch_name"
    exit 1
  fi

  # Ensure .wt/ is gitignored
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
      local bootstrap_exit_code=$?
      error "Bootstrap failed (exit code $bootstrap_exit_code); worktree preserved at $worktree_path"
      error "Retry with: cd $worktree_path && bash scripts/worktree-bootstrap.sh"
      exit "$bootstrap_exit_code"
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
  log "  ${DIM}To clean:${NC} wt cleanup $name"
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

  local repo_name
  repo_name=$(basename "$repo_root")

  log ""
  log "${BOLD}Worktrees in $repo_name${NC}"
  log "${DIM}────────────────────────────────────────${NC}"

  # Collect all worktree directories (current + legacy)
  local -a wt_dirs
  mapfile -t wt_dirs < <(get_all_worktree_dirs "$repo_root")

  if [ ${#wt_dirs[@]} -eq 0 ]; then
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

  for worktree_dir in "${wt_dirs[@]}"; do
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

      # Show legacy marker for .worktrees paths
      local legacy_marker=""
      if [[ "$worktree_dir" == */.worktrees ]]; then
        legacy_marker=" ${DIM}(legacy)${NC}"
      fi

      log "  ${BOLD}$wt_name${NC}${current_marker}${legacy_marker}"
      log "    Branch: $branch"
      log "    Status: $merge_status"
      log "    Path:   $wt_path"
      log ""
    done
  done

  if [ $count -eq 0 ]; then
    log "  ${DIM}No worktrees found${NC}"
    log ""
    log "  Create one with: ${BLUE}wt my-feature${NC}"
  else
    log "${DIM}────────────────────────────────────────${NC}"
    log "  Total: $count worktree(s)"
    if [ $merged_count -gt 0 ]; then
      log "  ${GREEN}$merged_count merged${NC} — run ${BLUE}wt cleanup <name>${NC} for each one you own"
    fi
  fi
  log ""
}

# ─── Cleanup Command ─────────────────────────────────────────────────────────

cmd_cleanup() {
  if [ "$#" -eq 0 ]; then
    error "Error: name at least one worktree to clean up"
    error "Usage: wt cleanup <name> [name…]"
    return 2
  fi
  local name
  for name in "$@"; do
    if [[ "$name" == -* || "$name" == */* || "$name" == . || "$name" == .. || -z "$name" ]]; then
      error "Error: invalid worktree name: $name"
      return 2
    fi
  done
  local repo_root
  repo_root=$(get_repo_root)
  if [ -z "$repo_root" ]; then
    error "Error: not inside a git repository"
    exit 1
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

  local wt_path wt_name branch in_use_status
  for wt_name in "$@"; do
      if ! wt_path=$(find_worktree_path "$repo_root" "$wt_name"); then
        warn "  skip  $wt_name (worktree not found)"
        kept=$((kept + 1))
        continue
      fi
      branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

      if [ "$branch" != "worktree-$wt_name" ]; then
        warn "  skip  $wt_name (branch $branch is not this manager's branch for that name)"
        kept=$((kept + 1))
        continue
      fi

      # Skip if we're currently inside this worktree (or a subdirectory of it)
      if is_cwd_inside "$wt_path" 2>/dev/null; then
        warn "  skip  $wt_name (you are currently in this worktree)"
        kept=$((kept + 1))
        continue
      fi

      # Refuse to remove any worktree with local files, including ignored files.
      if worktree_has_local_files "$wt_path"; then
        warn "  skip  $wt_name (worktree has tracked, untracked, or ignored files, or status failed)"
        kept=$((kept + 1))
        continue
      fi

      if worktree_in_use "$wt_path"; then
        warn "  skip  $wt_name (a running process is using it)"
        kept=$((kept + 1))
        continue
      else
        in_use_status=$?
        if [ "$in_use_status" -eq 2 ]; then
          warn "  skip  $wt_name (could not verify whether a running process is using it)"
          kept=$((kept + 1))
          continue
        fi
      fi

      if branch_never_committed "$repo_root" "$branch"; then
        log "  ${DIM}keep${NC}    $wt_name (branch $branch has no commits yet; wt delete removes it)"
        kept=$((kept + 1))
        continue
      fi

      # Check if branch is merged into main
      if is_branch_merged "$repo_root" "$branch" "$merge_target"; then
        # Remove without force as a second guard against tracked or untracked
        # changes arriving between the status check and removal.
        if git -C "$repo_root" worktree remove "$wt_path" 2>/dev/null; then
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
    info "$kept worktree(s) kept (current, unmerged, or with local changes)"
  fi
  if [ $removed -eq 0 ] && [ $kept -eq 0 ]; then
    info "No worktrees to clean up"
  fi

  log ""
  [ "$kept" -eq 0 ]
}

# ─── Delete Command ──────────────────────────────────────────────────────────

cmd_delete() {
  local name="${1:-}"
  local in_use_status

  if [ -z "$name" ]; then
    error "Error: worktree name required"
    error "Usage: wt delete <name>"
    exit 1
  fi
  if [ "$#" -ne 1 ] || [[ "$name" == -* || "$name" == */* || "$name" == . || "$name" == .. ]]; then
    error "Error: usage is wt delete <name>"
    return 2
  fi

  local repo_root
  repo_root=$(get_repo_root)
  if [ -z "$repo_root" ]; then
    error "Error: not inside a git repository"
    exit 1
  fi

  # Find the worktree across both directories
  local wt_path
  if ! wt_path=$(find_worktree_path "$repo_root" "$name"); then
    error "Error: worktree '$name' not found"
    error "Run 'wt list' to see available worktrees"
    exit 1
  fi

  local branch
  branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  if [ "$branch" != "worktree-$name" ]; then
    error "Error: branch '$branch' is not this manager's branch for '$name'"
    return 1
  fi

  # Refuse to delete if we're inside it
  if is_cwd_inside "$wt_path" 2>/dev/null; then
    error "Error: you are currently inside worktree '$name'"
    error "cd out of it first, then run: wt delete $name"
    exit 1
  fi

  if worktree_has_local_files "$wt_path"; then
    error "Error: worktree '$name' has tracked, untracked, or ignored files, or status failed"
    error "Inspect their provenance and remove them separately before deleting this worktree"
    return 1
  fi

  if worktree_in_use "$wt_path"; then
    error "Error: a running process is using worktree '$name'"
    return 1
  else
    in_use_status=$?
    if [ "$in_use_status" -eq 2 ]; then
      error "Error: cannot verify whether a running process is using worktree '$name'; refusing deletion"
      return 1
    fi
  fi

  log ""
  log "${BOLD}Deleting worktree: $name${NC}"
  log "${DIM}────────────────────────────────────────${NC}"
  log "  Branch:  $branch"
  log "  Path:    $wt_path"
  log ""

  # Remove the worktree
  if git -C "$repo_root" worktree remove "$wt_path" 2>/dev/null; then
    success "Worktree removed"
  else
    error "Failed to remove worktree; it and its branch were kept"
    return 1
  fi

  # Delete the branch (force, since it may be unmerged).
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    if ! git -C "$repo_root" branch -D "$branch" >/dev/null 2>&1; then
      error "Worktree removed, but branch '$branch' could not be deleted"
      return 1
    fi
    success "Branch '$branch' deleted"
  fi

  # Clean up empty parent directories
  local parent_dir
  parent_dir=$(dirname "$wt_path")
  if [ -d "$parent_dir" ] && [ -z "$(ls -A "$parent_dir" 2>/dev/null)" ]; then
    rmdir "$parent_dir" 2>/dev/null || true
  fi

  log ""
  success "Done — worktree '$name' deleted"
  log ""
}

# ─── Help ────────────────────────────────────────────────────────────────────

cmd_help() {
  cat >&2 << 'EOF'
worktree — Git worktree manager for parallel development

Usage:
  wt <name>              Create a new worktree and cd into it
  wt init                Add a project-owned bootstrap scaffold
  wt list                List all worktrees with branch and merge status
  wt cleanup <name> ... Remove named, merged, clean worktrees
  wt delete <name>       Remove a named clean worktree (even if unmerged)
  wt help                Show this help

What happens on create:
  1. Creates a git worktree at .wt/<name>/
  2. Creates branch worktree-<name> from origin/main
  3. Copies gitignored .env* files from main repo
  4. Runs scripts/worktree-bootstrap.sh if present (project-specific setup)
  5. Prints the worktree path (shell function auto-cd's)

What happens on init:
  - Copies the canonical scaffold to scripts/worktree-bootstrap.sh
  - Adds /.worktree-env to .gitignore
  - Never overwrites an existing bootstrap

What happens on cleanup:
  - Requires explicit worktree names and removes only merged branches
  - Keeps worktrees with tracked, untracked, or ignored files, or running processes

What happens on delete:
  - Removes a named clean worktree and its branch regardless of merge status
  - Refuses local files, running processes, or the current worktree

Note: list, cleanup, and delete scan both .wt/ and legacy .worktrees/ directories.

Examples:
  wt init                Scaffold first-time project setup
  wt auth-refactor       Create worktree for auth work
  wt list                See all worktrees and their status
  wt cleanup old-feature  Remove one merged, clean worktree
  wt delete old-feature  Remove one clean worktree, even if unmerged

EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  local command="${1:-}"

  # Help is read-only even when supplied after a destructive command or target.
  local arg
  for arg in "$@"; do
    if [[ "$arg" == help || "$arg" == --help || "$arg" == -h ]]; then
      cmd_help
      return 0
    fi
  done

  if [ -z "$command" ]; then
    cmd_help
    exit 0
  fi

  case "$command" in
    init|setup)
      cmd_init
      ;;
    list|ls)
      cmd_list
      ;;
    cleanup|clean)
      shift
      cmd_cleanup "$@"
      ;;
    delete|rm)
      shift
      cmd_delete "$@"
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
