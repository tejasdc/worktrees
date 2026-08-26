# Worktrees

This repository owns the project-agnostic `wt` manager. Keep the manager deterministic
and let each target repository own its setup in `scripts/worktree-bootstrap.sh`.

## Invariants

- `wt <name>` creates an isolated worktree from the remote default branch and prints only
  its path on stdout; user-facing output stays on stderr so the shell wrapper can `cd`.
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

## Verification

Run `bash -n scripts/worktree.sh scripts/install.sh templates/worktree-bootstrap.sh`, then
exercise `worktree.sh init` in a temporary Git repository and confirm a second invocation
does not overwrite the generated file.
