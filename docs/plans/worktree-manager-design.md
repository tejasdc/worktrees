# Worktree Manager — Design Document

**Date:** 2026-03-02
**Status:** Design approved, ready for implementation

---

## Feature Overview

A workspace-agnostic Git worktree management tool that enables developers and AI agents to work in fully isolated branches with zero-friction setup. One command creates an isolated workspace with all necessary configuration files copied automatically.

**Golden UX:**
```bash
wt my-feature            # Creates worktree, copies .env/keys, cd's into it
# ... work with any agent (Claude, Codex, Cursor) or manually ...
wt cleanup               # Removes only worktrees whose branches are merged
```

---

## Background

### The Problem

When running 3-4+ parallel AI agent sessions on the same codebase:
1. **File conflicts** — Two agents editing the same file simultaneously leads to corrupted state
2. **Commit contamination** — Agent A stages and commits Agent B's uncommitted changes via `git add -A`
3. **Manual orchestration** — User must mentally track which agents can commit, creating hesitation to start new sessions
4. **Uncertainty** — No way to know in advance if a new session will conflict with existing ones

### Why Worktrees

Git worktrees provide **filesystem-level isolation** — each worktree is a separate directory with its own working tree, staging area, and branch. Changes in one worktree physically cannot affect another. Unlike git cloning, worktrees share the same object store (commits, history, remotes), so there's no duplication of the heavy git data.

### Why Not Just Better Discipline

CLAUDE.md already says "NEVER use git add -A" and "ALWAYS add files by explicit path." Agents sometimes forget. The failure mode is silent (bad commit pushed, CI breaks, manual cleanup required). Worktrees eliminate the entire category of problem by making cross-session interference physically impossible.

---

## Requirements

1. **Single-command creation** — `wt my-feature` creates a fully functional worktree
2. **Workspace-agnostic** — Works with any git repo, no hardcoded paths or project-specific knowledge
3. **Tool-agnostic** — Works with Claude, Codex, Cursor, or manual terminal use
4. **Auto-discovery of config files** — Finds and copies .env files and SSH keys without manual specification
5. **Safe cleanup** — Only removes worktrees whose branches are merged into main
6. **Auto-navigation** — Shell function cd's into the worktree after creation
7. **Zero dependencies** — Pure bash + git. No npm, no Python, no external tools beyond jq (for Claude hook)

---

## Assumptions

1. The user is on macOS or Linux with bash/zsh
2. Git is installed and the command is run inside a git repository
3. The repo has a remote named `origin` with a `main` branch
4. `.worktrees/` is (or will be) in `.gitignore`
5. Gitignored files that match our patterns (.env*, *.pem, *.key, *.pub, keys/ dirs) are local secrets worth copying
6. AI agents understand standard git workflows (commit, push, create PR) without special instructions
7. node_modules and build artifacts are NOT needed at worktree creation time — agents install/build when needed

---

## Brainstorming & Investigation Findings

### Research Conducted

1. **Git worktree mechanics** — Full deep-dive into shared vs isolated state, branch exclusivity, cleanup semantics. See `tmp/research/git-worktree-mechanics.md`.

2. **Claude Code's built-in worktree support** — `claude --worktree` flag, WorktreeCreate/WorktreeRemove hooks, subagent isolation. See `tmp/research/claude-code-worktree-builtin.md`.

3. **Project compatibility analysis** — Scanned Cortex monorepo for path dependencies, untracked files, relative path handling. All compatible, no blockers.

4. **Existing tools** — Evaluated compound-engineering's `worktree-manager.sh` (only copies root .env files, interactive prompts break automation) and superpowers `using-git-worktrees` skill (generic, no file copying).

### Key Findings

- **Git worktrees share the object store** — creating one is instant (<1 sec), disk cost is only the tracked source files (~50MB for a typical project, NOT the full repo + node_modules)
- **Untracked/gitignored files are NOT in worktrees** — .env files, node_modules, SSH keys, databases all absent. Must be explicitly copied.
- **Agents don't need to know they're in a worktree** — from their perspective, it's a normal git repo on a feature branch. Standard git commands (branch, push, log) work identically.
- **Branch exclusivity** — git enforces that a branch can only be checked out in one worktree at a time, preventing weird conflicts
- **Claude has WorktreeCreate/WorktreeRemove hooks** — can integrate later as a thin wrapper around our standalone script

### Options Explored

| Option | Description | Verdict |
|--------|-------------|---------|
| **Claude --worktree only** | Use Claude's built-in worktree, add hook for bootstrap | Rejected — locks us to Claude, doesn't work for Codex/Cursor |
| **Full repo clone per session** | Clone repo for each parallel session | Rejected — duplicates entire git history, slow, wasteful |
| **Wrapper around compound-engineering script** | Extend existing worktree-manager.sh | Rejected — interactive prompts, only copies root .env, too opinionated |
| **Standalone script + optional Claude hook** | Our own script, tool-agnostic, Claude integration optional | **Selected** |
| **APFS copy-on-write for node_modules** | `cp -c` to instantly clone node_modules | Considered but deferred — not needed at creation time, agents install on demand |
| **.worktreerc config file for extra files** | Project-specific config listing additional files to copy | Deferred — adds setup friction. Current patterns (.env + keys) cover 95% of cases |

### Tradeoffs Made

| Tradeoff | Decision | Rationale |
|----------|----------|-----------|
| Hardcoded paths vs dynamic discovery | Dynamic discovery | Workspace-agnostic, works with any repo |
| Copy node_modules at creation vs defer | Defer | Agents don't need it to edit code. Install when they need to build/test. Saves 3-5 min on creation. |
| Merge to main on cleanup vs merge-gated cleanup | Merge-gated | Auto-merging is dangerous (conflicts). Only cleanup merged worktrees. |
| `create` subcommand vs default action | Default action | `wt my-feature` is cleaner than `wt create my-feature` |
| `worktree-` branch prefix vs no prefix | With prefix | Prevents collisions with real branches, makes worktree branches identifiable |
| Branch from HEAD vs origin/main | origin/main | Prevents cascading dependencies between worktree branches in parallel workflows |

---

## Selected Approach

### Architecture

```
scripts/worktree.sh               ← Standalone script (all logic)
    ▲                ▲
    │                │
Claude hook          Shell function (wt)
(optional, later)    (auto-cd wrapper)
```

### Commands

```bash
wt my-feature            # Create worktree, copy config files, cd into it
wt list                  # Show all worktrees with branch and merge status
wt cleanup               # Remove all worktrees whose branches are merged into main
```

### Naming Convention

| Input | Derived |
|-------|---------|
| User provides: `my-feature` | Worktree dir: `.worktrees/my-feature/` |
| | Git branch: `worktree-my-feature` |
| | Remote branch: `origin/worktree-my-feature` |

### File Discovery (Workspace-Agnostic)

The script discovers files to copy using three patterns, all filtered through `git check-ignore` (only copies gitignored files):

1. **Environment files:** `find . -maxdepth 3 -name '.env*' ! -name '.env.example'`
2. **Key/certificate files:** `find . -maxdepth 3 \( -name '*.pem' -o -name '*.key' -o -name '*.pub' \)`
3. **Key directories:** `find . -maxdepth 3 -type d -name 'keys'` (copied entirely)

The `git check-ignore` filter ensures we only copy files that are:
- Matching our patterns AND
- Gitignored (local secrets, not tracked files the worktree already has)

### Creation Flow

```
wt my-feature
    │
    ├── 1. Validate: inside git repo, name not taken, .worktrees/ is gitignored
    │
    ├── 2. Fetch latest: git fetch origin main
    │
    ├── 3. Create worktree: git worktree add -b worktree-my-feature .worktrees/my-feature origin/main
    │
    ├── 4. Discover & copy config files (env + keys, filtered by git check-ignore)
    │       Preserves directory structure: backend/.env → .worktrees/my-feature/backend/.env
    │
    ├── 5. Print worktree path to stdout
    │
    └── 6. Shell function captures path, cd's into it
```

### Cleanup Flow

```
wt cleanup
    │
    ├── 1. List all worktrees in .worktrees/
    │
    ├── 2. For each: check if branch is merged into origin/main
    │       git branch --merged origin/main | grep worktree-<name>
    │
    ├── 3. Merged → git worktree remove + git branch -d
    │       Not merged → skip, report "my-feature: not merged, keeping"
    │
    └── 4. Report summary: "Removed 3 worktrees, 2 still active"
```

### Shell Function (wt)

The `wt` function wraps the script to enable cd-ing into the worktree (scripts can't change parent shell directory):

```bash
# Added to ~/.zshrc or ~/.bashrc
wt() {
  # Locate script relative to the git repo root
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$repo_root" ]; then
    echo "Error: not in a git repository"
    return 1
  fi

  local script="$repo_root/scripts/worktree.sh"
  if [ ! -f "$script" ]; then
    echo "Error: scripts/worktree.sh not found in repo root"
    return 1
  fi

  local output
  output=$(bash "$script" "$@")
  local exit_code=$?

  if [ $exit_code -eq 0 ] && [ "$1" != "list" ] && [ "$1" != "cleanup" ] && [ -d "$output" ]; then
    cd "$output"
    echo "Now in: $(pwd) (branch: $(git branch --show-current))"
  else
    echo "$output"
  fi
}
```

Note: The script must be installed per-repo at `scripts/worktree.sh`. The shell function finds it dynamically from the git root. This means ANY repo that has the script gets worktree support — no global installation needed.

### Claude Hook Integration (Future, Optional)

When ready, add a thin Claude hook that calls the same script:

```
.claude/hooks/worktree-create.sh:
  Reads JSON input (name) from stdin
  Calls scripts/worktree.sh with the name
  Passes stdout through (worktree path)

.claude/settings.json:
  hooks.WorktreeCreate → .claude/hooks/worktree-create.sh
```

This makes `claude -w my-feature` use our script with full .env/keys copying instead of Claude's default bare worktree.

---

## Implementation Plan

### Step 1: Create `scripts/worktree.sh`

Core script with three commands:
- Default (create): validate inputs → fetch origin/main → git worktree add → discover & copy files → print path
- `list`: enumerate .worktrees/, show branch names, merge status (merged/active)
- `cleanup`: find merged worktrees, remove them, report results

Key implementation details:
- Use `git check-ignore -q` to filter file discovery results
- Use `git rev-parse --show-toplevel` to find repo root
- Use `git branch --merged origin/main` to check merge status
- Preserve relative directory structure when copying files
- All user-facing output to stderr, only worktree path to stdout (for shell function and Claude hook compatibility)
- Handle edge cases: name already taken, .worktrees/ not gitignored (auto-fix), no origin remote

### Step 2: Create shell function installer

A small script or instructions to add the `wt` function to the user's shell config (~/.zshrc or ~/.bashrc). Could be:
- A `setup.sh` script that appends the function
- Or just documented instructions in the README

### Step 3: Add .worktrees/ to .gitignore (per-repo)

The script should check for this on first run and offer to add it if missing (like the compound-engineering script does). Non-interactive: if not gitignored, add it automatically and report.

### Step 4: Test with real scenarios

- Create worktree in Cortex monorepo (has subdirectory .env files + keys/ dir)
- Create worktree in a simple single-package repo
- Verify agents (Claude, Codex) can work normally in the worktree
- Verify push/PR flow works from worktree
- Verify cleanup only removes merged worktrees

### Step 5 (Future): Claude WorktreeCreate hook

Thin wrapper calling `scripts/worktree.sh`. Deferred until core script is proven.

---

## Open Items / Future Considerations

1. **`.worktreerc` config file** — For projects that need additional files copied beyond .env and keys. Deferred until we hit a case that needs it.
2. **APFS copy-on-write for node_modules** — `cp -c` for near-instant cloning on macOS. Deferred since agents install on demand.
3. **Deterministic port assignment** — Hash branch name to assign unique dev server ports per worktree. Not needed yet.
4. **`wt resume my-feature`** — cd back into an existing worktree without recreating. Could be useful. Simple to add later.
5. **Auto-gitignore for new repos** — Script could create `.worktrees/` entry in `.gitignore` automatically on first use.
6. **Claude --worktree default** — GitHub issue #27616 requests a settings.json option. When available, could replace the shell alias for Claude users.
