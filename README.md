# wt — Git Worktree Manager

Single-command worktree creation with automatic `.env` copying and project bootstrap. Built for parallel AI agent development.

```bash
wt my-feature            # Create worktree, copy .env, run bootstrap, cd into it
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
3. Copies gitignored `.env*` files from the main repo (excludes `.env.example`)
4. Runs `scripts/worktree-bootstrap.sh` if present (project-specific setup)
5. Prints the worktree path (shell function auto-cd's)

Only copies `.env*` files that are gitignored (local secrets, not tracked files the worktree already has).

For project-specific files (SSH keys, certificates, etc.), add the copying logic to your `scripts/worktree-bootstrap.sh`.

### Project Bootstrap Hook

If the repo contains `scripts/worktree-bootstrap.sh`, it runs automatically after `.env` copying. Use it for anything project-specific:
- Install dependencies (`npm install`, `bundle install`)
- Copy SSH keys or certificates
- Generate clients (Prisma, protobuf)
- Allocate dev server ports

The bootstrap script is **project-owned** (lives in the repo, not in `wt`). The `wt` tool just looks for and runs it. This keeps `wt` project-agnostic.

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
| Only copy `.env*` (not keys/certs) | `.env` is universal; project-specific files belong in the bootstrap script |
| Bootstrap hook via convention (`scripts/worktree-bootstrap.sh`) | Project owns its setup; `wt` stays agnostic |
| Bootstrap stdout redirected to stderr | Keeps stdout clean for path output that the shell function reads for auto-cd |

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
