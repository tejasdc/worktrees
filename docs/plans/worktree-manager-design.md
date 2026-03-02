# Worktree Manager — Design Document

**Date:** 2026-03-02
**Status:** Implemented and published — https://github.com/tejasdc/worktrees

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
~/.local/bin/worktree.sh          ← Standalone script (global symlink)
    ▲                ▲
    |                |
Shell function       Claude hook
(wt, auto-cd)       (future, optional)
```

The script lives at `scripts/worktree.sh` in the repo and is symlinked to `~/.local/bin/worktree.sh` by the installer. The `wt()` shell function finds it via PATH (`command -v worktree.sh`).

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
    ├── 2. Fetch merge target (origin/main or origin/master)
    │
    ├── 3. For each: check if branch is merged using merge-base --is-ancestor
    │       Skip if cwd is inside this worktree (is_cwd_inside prefix match)
    │
    ├── 4. Merged → git worktree remove + git branch -d (verify remove succeeded)
    │       Not merged → skip, report "my-feature: not merged, keeping"
    │
    └── 5. Report summary: "Removed 3 worktrees, 2 still active"
            Clean up empty .worktrees/ directory if all removed
```

### Shell Function (wt)

The `wt` function wraps the globally-installed script to enable cd-ing into the worktree (scripts can't change parent shell directory):

```bash
# Added to ~/.zshrc or ~/.bashrc by install.sh
wt() {
  if ! command -v worktree.sh &>/dev/null; then
    echo "Error: worktree.sh not found on PATH. Run the installer again." >&2
    return 1
  fi

  # For create (default command), capture the path and cd into it
  if [ $# -ge 1 ] && [ "$1" != "list" ] && [ "$1" != "ls" ] && \
     [ "$1" != "cleanup" ] && [ "$1" != "clean" ] && \
     [ "$1" != "help" ] && [ "$1" != "--help" ] && [ "$1" != "-h" ]; then
    local output
    output=$(worktree.sh "$@")
    local exit_code=$?

    if [ $exit_code -eq 0 ] && [ -n "$output" ] && [ -d "$output" ]; then
      cd "$output"
      echo -e "\033[0;32mNow in:\033[0m $(pwd)"
      echo -e "\033[2mBranch:\033[0m $(git branch --show-current 2>/dev/null || echo unknown)"
    else
      [ -n "$output" ] && echo "$output"
      return $exit_code
    fi
  else
    # For list, cleanup, help — just run normally (output goes to stderr)
    worktree.sh "$@"
  fi
}
```

The script is installed globally at `~/.local/bin/worktree.sh` via symlink, and the shell function finds it via PATH (`command -v`). This means `wt` works from any git repo without per-repo installation.

### Claude Hook Integration (Future, Optional)

When ready, add a thin Claude hook that calls the globally-installed script:

```
.claude/hooks/worktree-create.sh:
  Reads JSON input (name) from stdin
  Calls worktree.sh (found via PATH) with the name
  Passes stdout through (worktree path)

.claude/settings.json:
  hooks.WorktreeCreate → .claude/hooks/worktree-create.sh
```

This makes `claude -w my-feature` use our script with full .env/keys copying instead of Claude's default bare worktree.

---

## Implementation Plan (Completed)

### Step 1: Create `scripts/worktree.sh` — DONE

Core script with three commands + help, plus these key implementation details:

- **Repo root resolution:** `git rev-parse --git-common-dir` (NOT `--show-toplevel`) to correctly resolve to the main repo even when run from inside an existing worktree
- **Merge detection:** `git merge-base --is-ancestor` (NOT `git branch --merged | grep`) for correct semantic check without substring matching bugs
- **Merge target:** `get_merge_target()` helper tries `origin/main`, then `origin/master`, then falls back to `HEAD`
- **Commit counting:** `git rev-list --count` with `|| echo 0` for pipefail safety (NOT `git log | wc -l`)
- **Current worktree detection:** `is_cwd_inside()` prefix match on resolved paths (handles subdirectories, not just exact equality)
- **Input validation:** Rejects names with slashes, backslashes, spaces, or leading dots
- **Bash 4+ check:** Script requires bash 4+ for associative arrays (`local -A`). Exits early with install instructions on macOS system bash 3.2
- **Idempotent creation:** If worktree already exists, prints path and exits 0 (shell function cd's into it)
- **Symlink-safe copy:** `cp -R -P` preserves symlinks instead of dereferencing them
- **Cleanup verification:** Checks that `git worktree remove` actually succeeded before deleting the branch

### Step 2: Create installer (`scripts/install.sh`) — DONE

- Symlinks `scripts/worktree.sh` to `~/.local/bin/worktree.sh`
- Adds `wt()` shell function to `~/.zshrc` or `~/.bashrc` with marker-based idempotent installation
- Uses `$SHELL` env var to detect correct rc file (not just file existence)
- Verifies both start AND end markers exist before awk rewrite (prevents rc file truncation if markers are corrupt)

### Step 3: Auto-gitignore — DONE

Script checks `git check-ignore -q .worktrees/` on every create. If not gitignored, appends `.worktrees/` to `.gitignore` automatically.

### Step 4: Testing — DONE

- Tested in Cortex monorepo (subdirectory .env files + keys/ dir)
- Verified create → list → cleanup cycle with both empty and committed worktrees
- Verified worktree-from-worktree creation (the `--git-common-dir` fix)
- Verified unpushed branches show correct status (the pipefail fix)
- Verified cleanup only removes merged worktrees and skips current worktree

### Step 5: Codex Review — DONE

Codex found 7 issues, all applied:
1. **High:** `merge-base --is-ancestor` replaces `git branch --merged | grep`
2. **High:** `rev-list --count` replaces `git log | wc -l` pipelines
3. **High:** `is_cwd_inside()` prefix match replaces exact equality
4. **Medium:** Conditional cleanup success (verify `git worktree remove` succeeded)
5. **Medium:** `cp -R -P` for symlink safety
6. **Medium:** Installer verifies both markers before awk rewrite
7. **Low:** `$SHELL`-based rc file detection

### Step 6 (Future): Claude WorktreeCreate hook

Thin wrapper calling `worktree.sh` (found via PATH). Deferred until core script is proven.

---

## Open Items / Future Considerations

1. **`.worktreerc` config file** — For projects that need additional files copied beyond .env and keys. Deferred until we hit a case that needs it.
2. **APFS copy-on-write for node_modules** — `cp -c` for near-instant cloning on macOS. Deferred since agents install on demand.
3. **Deterministic port assignment** — Hash branch name to assign unique dev server ports per worktree. Not needed yet.
4. ~~**`wt resume my-feature`** — cd back into an existing worktree without recreating.~~ **DONE** — creation is idempotent. Running `wt my-feature` when it already exists prints the path and the shell function cd's into it.
5. ~~**Auto-gitignore for new repos** — Script could create `.worktrees/` entry in `.gitignore` automatically on first use.~~ **DONE** — `ensure_gitignored()` checks and auto-adds on every create.
6. **Claude --worktree default** — GitHub issue #27616 requests a settings.json option. When available, could replace the shell alias for Claude users.
