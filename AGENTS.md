# Worktrees

This repository owns the project-agnostic `wt` manager. Keep the manager deterministic
and let each target repository own its setup in `scripts/worktree-bootstrap.sh`.

## Invariants

- `wt <name>` creates an isolated worktree from the remote default branch and prints only
  its path on stdout; user-facing output stays on stderr so the shell wrapper can `cd`.
- `scripts/install.sh` symlinks `~/.local/bin/wt` and the compatibility
  `~/.local/bin/worktree.sh` command to this checkout for agents and non-interactive
  sessions. The shell function is optional convenience, never the only way `wt` exists.
- `wt init` only installs the canonical scaffold. It never overwrites an existing project
  bootstrap, and the generated script becomes part of the target repository.
- Dependency commands, generated files, special local config, and service-specific ports
  belong in the target repository's bootstrap—not in the global manager.
- Ordinary worktree creation must not require a skill. The setup-only skill is for the
  first agent adapting or repairing a repository bootstrap.
- Preserve `.wt/` compatibility and the legacy `.worktrees/` read path.
- Manager bookkeeping must not dirty the shared checkout. Ignore `.wt/` through the common
  Git directory's local exclude; tracked ignore changes belong only to explicit project setup.
- A failed project bootstrap is a failed create. Preserve the worktree for diagnosis, return
  the bootstrap status, and never print the normal readiness message.
- Help is read-only. Cleanup requires explicit names. Cleanup and delete refuse tracked,
  untracked, or ignored local files and running processes; inspect provenance before
  removing such files separately. See `README.md` under Cleanup and Delete.
- Process-use scans tolerate only paths that vanish with an exited process; other scan
  failures refuse removal. See `README.md` under Cleanup and Delete.

## Verification

Run `bash -n scripts/worktree.sh scripts/install.sh templates/worktree-bootstrap.sh`, then
`bash tests/worktree-manager.sh`. The focused test covers non-overwriting init, clean
worktree creation, terminal bootstrap failure, cleanup and deletion safety, and
non-interactive PATH discovery of `wt`.
