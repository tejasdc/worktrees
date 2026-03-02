# wt — Git Worktree Manager

Single-command worktree creation with automatic config file copying. Built for parallel AI agent development.

```bash
wt my-feature            # Create worktree, copy .env/keys, cd into it
wt list                  # Show all worktrees with merge status
wt cleanup               # Remove worktrees whose branches are merged
```

## Why

When running 3-4+ parallel AI agent sessions (Claude, Codex, Cursor) on the same codebase:
- File conflicts between agents editing the same file
- Commit contamination via `git add -A` staging another agent's changes
- Manual orchestration overhead tracking which agents can safely commit

Git worktrees provide filesystem-level isolation. Each worktree is a separate directory with its own working tree, staging area, and branch — changes in one physically cannot affect another.

## Install

```bash
git clone git@github.com:tejasdc/worktrees.git ~/workspace/worktrees
bash ~/workspace/worktrees/scripts/install.sh
source ~/.zshrc  # or ~/.bashrc
```

Requires bash 4+ (macOS: `brew install bash`).

## What It Does

### Create (`wt <name>`)

1. Creates git worktree at `.worktrees/<name>/`
2. Creates branch `worktree-<name>` from `origin/main`
3. Discovers and copies gitignored config files:
   - `.env*` files (max 3 levels deep, excludes `.env.example`)
   - `*.pem`, `*.key`, `*.pub` files
   - Directories named `keys/`
4. Prints the worktree path (shell function auto-cd's)

Only copies files that are **both** matching the patterns **and** gitignored (local secrets, not tracked files).

### List (`wt list`)

Shows all worktrees with status:
- **merged** — branch is merged into main, safe to clean up
- **active** (N unpushed) — has local commits not pushed
- **pushed** (N commits ahead) — pushed but not yet merged
- **empty** — no changes from main

### Cleanup (`wt cleanup`)

Removes only worktrees whose branches are merged into main. Unmerged worktrees are always kept.

## How It Works

```
~/.local/bin/worktree.sh          <- Standalone script (all logic)
    ^                ^
    |                |
Shell function       Claude hook
(wt, auto-cd)       (future, optional)
```

- **Workspace-agnostic** — works with any git repo, no hardcoded paths
- **Tool-agnostic** — works with Claude, Codex, Cursor, or manual terminal use
- **stdout/stderr discipline** — user output to stderr, machine output (path) to stdout
- **Works from inside worktrees** — `wt second-feature` from inside `.worktrees/first-feature/` correctly creates at the main repo root

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Branch from `origin/main` (not HEAD) | Prevents cascading dependencies between worktrees |
| `worktree-` branch prefix | Prevents collisions with real branches |
| Merge-gated cleanup only | Auto-merging is dangerous; only clean up what's merged |
| No `create` subcommand | `wt my-feature` is cleaner than `wt create my-feature` |
| Defer node_modules copy | Agents install when they need to build/test; saves 3-5 min on creation |
| Dynamic file discovery via `git check-ignore` | Workspace-agnostic; works with any repo layout |

## File Structure

```
worktrees/
├── scripts/
│   ├── worktree.sh      # Main script (globally installed via symlink)
│   └── install.sh       # Installer (symlink + shell function)
└── docs/
    └── plans/
        └── worktree-manager-design.md   # Full design document
```
