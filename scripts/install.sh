#!/usr/bin/env bash
#
# Install the worktree manager globally
#
# What this does:
# 1. Symlinks worktree.sh to ~/.local/bin/worktree.sh
# 2. Adds the `wt` shell function to ~/.zshrc (or ~/.bashrc)
#
# The `wt` function wraps the script to enable auto-cd into worktrees
# (scripts can't change the parent shell's directory).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKTREE_SCRIPT="$SCRIPT_DIR/worktree.sh"
INSTALL_PATH="$HOME/.local/bin/worktree.sh"

# ─── Shell Function Definition ───────────────────────────────────────────────

SHELL_FUNCTION='
# ─── wt: Git worktree manager ───────────────────────────────────────────────
# Creates isolated worktrees for parallel development.
# Source: https://github.com/... (worktree manager)
wt() {
  if ! command -v worktree.sh &>/dev/null; then
    echo "Error: worktree.sh not found on PATH. Run the installer again." >&2
    return 1
  fi

  # For create (default command), capture the path and cd into it
  if [ $# -ge 1 ] && [ "$1" != "list" ] && [ "$1" != "ls" ] && \
     [ "$1" != "cleanup" ] && [ "$1" != "clean" ] && \
     [ "$1" != "delete" ] && [ "$1" != "rm" ] && \
     [ "$1" != "help" ] && [ "$1" != "--help" ] && [ "$1" != "-h" ]; then
    local output
    output=$(worktree.sh "$@")
    local exit_code=$?

    if [ $exit_code -eq 0 ] && [ -n "$output" ] && [ -d "$output" ]; then
      cd "$output"
      echo -e "\033[0;32mNow in:\033[0m $(pwd)"
      echo -e "\033[2mBranch:\033[0m $(git branch --show-current 2>/dev/null || echo unknown)"
    else
      # If output is not a directory path, just print it (error message)
      [ -n "$output" ] && echo "$output"
      return $exit_code
    fi
  else
    # For list, cleanup, help — just run normally (output goes to stderr)
    worktree.sh "$@"
  fi
}
# ─── end wt ─────────────────────────────────────────────────────────────────
'

# ─── Marker for detecting existing installation ──────────────────────────────
MARKER_START="# ─── wt: Git worktree manager"
MARKER_END="# ─── end wt"

# ─── Install ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Installing worktree manager${NC}"
echo -e "${DIM}────────────────────────────────────────${NC}"

# Step 1: Symlink script to ~/.local/bin
echo ""
echo -e "${BLUE}Step 1: Installing script${NC}"

mkdir -p "$HOME/.local/bin"

if [ -L "$INSTALL_PATH" ]; then
  # Already a symlink — update it
  rm "$INSTALL_PATH"
  echo -e "  ${YELLOW}Updating existing symlink${NC}"
elif [ -f "$INSTALL_PATH" ]; then
  echo -e "  ${YELLOW}Replacing existing file at $INSTALL_PATH${NC}"
  rm "$INSTALL_PATH"
fi

ln -s "$WORKTREE_SCRIPT" "$INSTALL_PATH"
echo -e "  ${GREEN}Symlinked:${NC} $INSTALL_PATH → $WORKTREE_SCRIPT"

# Step 2: Add shell function to rc file
echo ""
echo -e "${BLUE}Step 2: Installing shell function${NC}"

# Detect shell — use $SHELL to pick the right rc file
SHELL_RC=""
case "${SHELL##*/}" in
  zsh)  [ -f "$HOME/.zshrc" ]  && SHELL_RC="$HOME/.zshrc" ;;
  bash) [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc" ;;
esac
# Fallback: try both if $SHELL didn't resolve
if [ -z "$SHELL_RC" ]; then
  if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
  fi
fi
if [ -z "$SHELL_RC" ]; then
  echo -e "  ${YELLOW}Could not find ~/.zshrc or ~/.bashrc${NC}"
  echo -e "  ${YELLOW}Add the following function to your shell config manually:${NC}"
  echo "$SHELL_FUNCTION"
  echo ""
  exit 0
fi

# Check if already installed — safely remove old version between markers
if grep -Fq "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
  if grep -Fq "$MARKER_END" "$SHELL_RC" 2>/dev/null; then
    # Both markers present — safe to remove between them
    local_tmp=$(mktemp)
    awk -v start="$MARKER_START" -v end="$MARKER_END" '
      index($0, start) { skip=1; next }
      index($0, end)   { skip=0; next }
      !skip            { print }
    ' "$SHELL_RC" > "$local_tmp"
    mv "$local_tmp" "$SHELL_RC"
    echo -e "  ${YELLOW}Removed old wt function${NC}"
  else
    echo -e "  ${RED}Found wt start marker without end marker in $SHELL_RC${NC}" >&2
    echo -e "  ${RED}Please manually remove the old wt function and re-run the installer${NC}" >&2
    exit 1
  fi
fi

# Append new version
echo "$SHELL_FUNCTION" >> "$SHELL_RC"
echo -e "  ${GREEN}Added wt function to $SHELL_RC${NC}"

# Summary
echo ""
echo -e "${DIM}────────────────────────────────────────${NC}"
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo -e "  Reload your shell:  ${BLUE}source $SHELL_RC${NC}"
echo ""
echo -e "  Then try:"
echo -e "    ${BLUE}wt my-feature${NC}     Create a worktree"
echo -e "    ${BLUE}wt list${NC}           List worktrees"
echo -e "    ${BLUE}wt cleanup${NC}        Remove merged worktrees"
echo ""
