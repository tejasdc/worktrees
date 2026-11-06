#!/usr/bin/env bash

set -euo pipefail

BASH_BIN_DIR="$(dirname "$BASH")"
PATH="$BASH_BIN_DIR:$PATH"
export PATH

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANAGER="${WT_MANAGER:-$PROJECT_ROOT/scripts/worktree.sh}"
INSTALLER="$PROJECT_ROOT/scripts/install.sh"
TEST_ROOT="$(mktemp -d)"
ACTIVE_PROCESS_PID=""

cleanup() {
  if [ -n "$ACTIVE_PROCESS_PID" ]; then
    kill "$ACTIVE_PROCESS_PID" 2>/dev/null || true
    wait "$ACTIVE_PROCESS_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

create_repository() {
  local name="$1"
  local repository="$TEST_ROOT/$name"
  local origin="$TEST_ROOT/$name-origin.git"

  mkdir -p "$repository"
  git -C "$repository" init -b main --quiet
  git -C "$repository" config user.name "Worktree Tests"
  git -C "$repository" config user.email "worktree-tests@example.invalid"
  printf '# test\n' > "$repository/README.md"
  git -C "$repository" add README.md
  git -C "$repository" commit -m "initial" --quiet
  git clone --bare "$repository" "$origin" --quiet
  git -C "$repository" remote add origin "$origin"
  git -C "$repository" push -u origin main --quiet

  printf '%s\n' "$repository"
}

mark_worktree_merged() {
  local repository="$1" worktree_path="$2"
  local branch
  branch="$(git -C "$worktree_path" branch --show-current)"
  printf '%s\n' "$branch" > "$worktree_path/$branch.txt"
  git -C "$worktree_path" add "$branch.txt"
  git -C "$worktree_path" commit -m "complete $branch" --quiet
  git -C "$repository" merge --no-ff --quiet -m "merge $branch" "$branch"
  git -C "$repository" push origin main --quiet
}

test_init_is_non_overwriting() {
  local repository
  repository="$(create_repository init)"

  (cd "$repository" && "$MANAGER" init >/dev/null 2>&1 < /dev/null) || fail "wt init failed"
  [ -x "$repository/scripts/worktree-bootstrap.sh" ] || fail "bootstrap was not created"
  grep -Fqx '/.worktree-env' "$repository/.gitignore" || fail ".worktree-env was not ignored"

  printf '\n# preservation marker\n' >> "$repository/scripts/worktree-bootstrap.sh"
  (cd "$repository" && "$MANAGER" init >/dev/null 2>&1 < /dev/null) || fail "second wt init failed"
  grep -Fq '# preservation marker' "$repository/scripts/worktree-bootstrap.sh" || fail "existing bootstrap was overwritten"
}

test_create_keeps_shared_checkout_clean() {
  local repository
  repository="$(create_repository clean-create)"

  local worktree_path
  worktree_path="$(cd "$repository" && "$MANAGER" isolated-task 2>/dev/null)"
  [ -d "$worktree_path" ] || fail "worktree was not created"
  [ -z "$(git -C "$repository" status --porcelain)" ] || fail "shared checkout became dirty"
  grep -Fqx '/.wt/' "$repository/.git/info/exclude" || fail ".wt was not locally ignored"
}

test_bootstrap_failure_is_terminal() {
  local repository
  repository="$(create_repository failed-bootstrap)"
  mkdir -p "$repository/scripts"
  printf '#!/usr/bin/env bash\nexit 23\n' > "$repository/scripts/worktree-bootstrap.sh"
  chmod +x "$repository/scripts/worktree-bootstrap.sh"
  git -C "$repository" add scripts/worktree-bootstrap.sh
  git -C "$repository" commit -m "add failing bootstrap" --quiet
  git -C "$repository" push origin main --quiet

  local stdout_file="$TEST_ROOT/failure.stdout"
  local stderr_file="$TEST_ROOT/failure.stderr"
  local exit_code=0
  (cd "$repository" && "$MANAGER" broken > "$stdout_file" 2> "$stderr_file") || exit_code=$?

  [ "$exit_code" -eq 23 ] || fail "bootstrap exit status was not propagated"
  [ ! -s "$stdout_file" ] || fail "failed create emitted a success path"
  ! grep -Fq 'Ready!' "$stderr_file" || fail "failed create claimed readiness"
  [ -d "$repository/.wt/broken" ] || fail "failed worktree was not preserved"
}

test_cleanup_preserves_dirty_merged_worktree() {
  local repository
  repository="$(create_repository dirty-cleanup)"

  local worktree_path
  worktree_path="$(cd "$repository" && "$MANAGER" dirty-task 2>/dev/null)"
  local clean_worktree_path
  clean_worktree_path="$(cd "$repository" && "$MANAGER" clean-task 2>/dev/null)"
  mark_worktree_merged "$repository" "$worktree_path"
  mark_worktree_merged "$repository" "$clean_worktree_path"
  printf 'local edit\n' >> "$worktree_path/README.md"
  printf 'untracked work\n' > "$worktree_path/notes.txt"

  (cd "$repository" && "$MANAGER" cleanup dirty-task clean-task) && fail "cleanup claimed all named worktrees were removed"
  [ -e "$worktree_path/.git" ] || fail "cleanup removed a dirty merged worktree"
  [ ! -e "$clean_worktree_path" ] || fail "cleanup kept a clean merged worktree"
  grep -Fqx 'local edit' <(tail -n 1 "$worktree_path/README.md") || fail "tracked edits were lost"
  grep -Fqx 'untracked work' "$worktree_path/notes.txt" || fail "untracked file was lost"
}

test_help_and_missing_scope_never_remove_worktrees() {
  local repository
  repository="$(create_repository help-safety)"
  local worktree_path
  worktree_path="$(cd "$repository" && "$MANAGER" eligible 2>/dev/null)"
  mark_worktree_merged "$repository" "$worktree_path"

  (cd "$repository" && "$MANAGER" cleanup --help >/dev/null 2>&1) || fail "cleanup help failed"
  (cd "$repository" && "$MANAGER" cleanup help >/dev/null 2>&1) || fail "cleanup word help failed"
  (cd "$repository" && "$MANAGER" cleanup eligible --help >/dev/null 2>&1) || fail "cleanup target help failed"
  (cd "$repository" && "$MANAGER" delete eligible --help >/dev/null 2>&1) || fail "delete target help failed"
  (cd "$repository" && "$MANAGER" cleanup >/dev/null 2>&1) && fail "cleanup without a target succeeded"
  [ -e "$worktree_path/.git" ] || fail "help or unscoped cleanup removed a worktree"

  (cd "$repository" && "$MANAGER" cleanup eligible >/dev/null 2>&1) || fail "explicit cleanup failed"
  [ ! -e "$worktree_path" ] || fail "explicit cleanup kept an eligible worktree"
}

test_cleanup_and_delete_preserve_ignored_files() {
  local repository
  repository="$(create_repository ignored-safety)"
  printf '/local-output/\n' >> "$repository/.git/info/exclude"
  local cleanup_path delete_path
  cleanup_path="$(cd "$repository" && "$MANAGER" cleanup-ignored 2>/dev/null)"
  delete_path="$(cd "$repository" && "$MANAGER" delete-ignored 2>/dev/null)"
  mark_worktree_merged "$repository" "$cleanup_path"
  mkdir -p "$cleanup_path/local-output" "$delete_path/local-output"
  printf 'keep me\n' > "$cleanup_path/local-output/unsaved.txt"
  printf 'keep me too\n' > "$delete_path/local-output/unsaved.txt"

  (cd "$repository" && "$MANAGER" cleanup cleanup-ignored >/dev/null 2>&1) && fail "cleanup claimed ignored work was removed"
  (cd "$repository" && "$MANAGER" delete delete-ignored >/dev/null 2>&1) && fail "delete accepted ignored work"
  [ -e "$cleanup_path/.git" ] || fail "cleanup removed ignored work"
  [ -e "$delete_path/.git" ] || fail "delete removed ignored work"
  grep -Fqx 'keep me' "$cleanup_path/local-output/unsaved.txt" || fail "cleanup lost ignored content"
  grep -Fqx 'keep me too' "$delete_path/local-output/unsaved.txt" || fail "delete lost ignored content"
}

test_in_use_guard_works_without_sbin_on_path() {
  local repository
  repository="$(create_repository in-use-guard)"
  local worktree_path
  worktree_path="$(cd "$repository" && "$MANAGER" active-task 2>/dev/null)"
  mark_worktree_merged "$repository" "$worktree_path"
  local bash_bin_dir
  bash_bin_dir="$(dirname "$BASH")"
  local minimal_path="$bash_bin_dir:/usr/bin:/bin"

  if [ ! -d /proc/self ]; then
    PATH="$minimal_path" command -v lsof >/dev/null 2>&1 && fail "test PATH unexpectedly finds lsof"
    [ -x /usr/sbin/lsof ] || fail "macOS lsof is not installed at /usr/sbin/lsof"
  fi

  local ready_file="$TEST_ROOT/active-task.ready"
  (cd "$worktree_path" && : > "$ready_file" && exec sleep 60) >/dev/null 2>&1 &
  ACTIVE_PROCESS_PID=$!
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$ready_file" ] && break
    sleep 0.05
  done
  [ -e "$ready_file" ] || fail "process did not enter the active worktree"

  local cleanup_output="$TEST_ROOT/in-use-cleanup.output"
  if (cd "$repository" && PATH="$minimal_path" "$MANAGER" cleanup active-task >"$cleanup_output" 2>&1); then
    fail "cleanup accepted a worktree used by a running process"
  fi
  grep -Fq "a running process is using it" "$cleanup_output" || fail "cleanup did not report the active process"
  [ -e "$worktree_path/.git" ] || fail "cleanup removed a worktree used by a running process"

  local delete_output="$TEST_ROOT/in-use-delete.output"
  if (cd "$repository" && PATH="$minimal_path" "$MANAGER" delete active-task >"$delete_output" 2>&1); then
    fail "delete accepted a worktree used by a running process"
  fi
  grep -Fq "a running process is using worktree" "$delete_output" || fail "delete did not report the active process"
  [ -e "$worktree_path/.git" ] || fail "delete removed a worktree used by a running process"

  kill "$ACTIVE_PROCESS_PID" 2>/dev/null || true
  wait "$ACTIVE_PROCESS_PID" 2>/dev/null || true
  ACTIVE_PROCESS_PID=""
  (cd "$repository" && PATH="$minimal_path" "$MANAGER" delete active-task >/dev/null 2>&1) || fail "delete did not succeed after the process exited"
  [ ! -e "$worktree_path" ] || fail "delete kept a clean worktree after the process exited"
}

test_proc_scan_only_tolerates_exited_pids() {
  [ -d /proc/self ] || return 0
  local repository
  repository="$(create_repository proc-scan-errors)"
  local gone_path denied_path silent_path
  gone_path="$(cd "$repository" && "$MANAGER" exited-pid 2>/dev/null)"
  denied_path="$(cd "$repository" && "$MANAGER" denied-pid 2>/dev/null)"
  silent_path="$(cd "$repository" && "$MANAGER" silent-failure 2>/dev/null)"
  mark_worktree_merged "$repository" "$gone_path"
  mark_worktree_merged "$repository" "$denied_path"
  mark_worktree_merged "$repository" "$silent_path"

  local fake_bin="$TEST_ROOT/fake-find"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/bin/bash' \
    'printf "%s\n" /tmp/unrelated-process-path' \
    'printf "%s\n" "find: /proc/999999/fd: No such file or directory" >&2' \
    'exit 1' > "$fake_bin/find"
  chmod +x "$fake_bin/find"
  (cd "$repository" && PATH="$fake_bin:$PATH" "$MANAGER" cleanup exited-pid >/dev/null 2>&1) || fail "transient exited PID blocked cleanup"
  [ ! -e "$gone_path" ] || fail "transient exited PID kept clean worktree"

  printf '%s\n' '#!/bin/bash' \
    'printf "%s\n" /tmp/unrelated-process-path' \
    'printf "%s\n" "find: /proc/999999/fd: Permission denied" >&2' \
    'exit 1' > "$fake_bin/find"
  (cd "$repository" && PATH="$fake_bin:$PATH" "$MANAGER" cleanup denied-pid >/dev/null 2>&1) && fail "permission error was treated as a complete process scan"
  [ -e "$denied_path/.git" ] || fail "permission error removed a worktree"

  printf '%s\n' '#!/bin/bash' \
    'printf "%s\n" /tmp/unrelated-process-path' \
    'exit 1' > "$fake_bin/find"
  (cd "$repository" && PATH="$fake_bin:$PATH" "$MANAGER" cleanup silent-failure >/dev/null 2>&1) && fail "silent scan failure was treated as complete"
  [ -e "$silent_path/.git" ] || fail "silent scan failure removed a worktree"
}

test_hidden_tracked_edits_and_changed_branches_are_kept() {
  local repository
  repository="$(create_repository hidden-and-branch)"
  local hidden_path skipped_path changed_path
  hidden_path="$(cd "$repository" && "$MANAGER" hidden-edits 2>/dev/null)"
  skipped_path="$(cd "$repository" && "$MANAGER" skipped-edits 2>/dev/null)"
  changed_path="$(cd "$repository" && "$MANAGER" changed-branch 2>/dev/null)"
  mark_worktree_merged "$repository" "$hidden_path"
  mark_worktree_merged "$repository" "$skipped_path"
  git -C "$hidden_path" update-index --assume-unchanged README.md
  printf 'hidden edit\n' >> "$hidden_path/README.md"
  git -C "$skipped_path" update-index --skip-worktree README.md
  printf 'skipped edit\n' >> "$skipped_path/README.md"
  git -C "$changed_path" switch -c feature/important --quiet
  printf 'important commit\n' > "$changed_path/important.txt"
  git -C "$changed_path" add important.txt
  git -C "$changed_path" commit -m important --quiet

  (cd "$repository" && "$MANAGER" cleanup hidden-edits >/dev/null 2>&1) && fail "cleanup accepted a hidden tracked edit"
  (cd "$repository" && "$MANAGER" cleanup skipped-edits >/dev/null 2>&1) && fail "cleanup accepted a skip-worktree edit"
  (cd "$repository" && "$MANAGER" delete hidden-edits >/dev/null 2>&1) && fail "delete accepted a hidden tracked edit"
  (cd "$repository" && "$MANAGER" delete changed-branch >/dev/null 2>&1) && fail "delete accepted a switched branch"
  [ -e "$hidden_path/.git" ] || fail "hidden tracked edit was removed"
  [ -e "$skipped_path/.git" ] || fail "skip-worktree edit was removed"
  [ -e "$changed_path/.git" ] || fail "switched branch worktree was removed"
  git -C "$repository" show-ref --verify --quiet refs/heads/feature/important || fail "switched branch tip was lost"
}

test_delete_removes_clean_named_worktree() {
  local repository
  repository="$(create_repository clean-delete)"
  local worktree_path
  worktree_path="$(cd "$repository" && "$MANAGER" done-task 2>/dev/null)"
  (cd "$repository" && "$MANAGER" delete done-task >/dev/null 2>&1) || fail "clean named delete failed"
  [ ! -e "$worktree_path" ] || fail "clean named delete kept the worktree"
  ! git -C "$repository" show-ref --verify --quiet refs/heads/worktree-done-task || fail "clean named delete kept the branch"
}

test_installer_exposes_wt_without_shell_rc() {
  local test_home="$TEST_ROOT/installer-home"
  local bash_bin_dir
  bash_bin_dir="$(dirname "$BASH")"
  local test_path="$test_home/.local/bin:$bash_bin_dir:/usr/bin:/bin"
  mkdir -p "$test_home/.local/bin"
  touch "$test_home/.zshrc"

  HOME="$test_home" SHELL=/bin/zsh bash "$INSTALLER" >/dev/null
  HOME="$test_home" SHELL=/bin/zsh bash "$INSTALLER" >/dev/null

  [ -L "$test_home/.local/bin/wt" ] || fail "installer did not create the wt command"
  [ -L "$test_home/.local/bin/worktree.sh" ] || fail "installer removed the compatibility command"
  [ "$(PATH="$test_path" command -v wt)" = "$test_home/.local/bin/wt" ] || \
    fail "wt is not discoverable on PATH without sourcing a shell rc"
  PATH="$test_path" wt --help >/dev/null 2>&1 || \
    fail "the installed wt command is not executable"
  PATH="$test_path" worktree.sh --help >/dev/null 2>&1 || \
    fail "the compatibility worktree.sh command is not executable"
}

test_init_is_non_overwriting
test_create_keeps_shared_checkout_clean
test_bootstrap_failure_is_terminal
test_cleanup_preserves_dirty_merged_worktree
test_help_and_missing_scope_never_remove_worktrees
test_cleanup_and_delete_preserve_ignored_files
test_in_use_guard_works_without_sbin_on_path
test_proc_scan_only_tolerates_exited_pids
test_hidden_tracked_edits_and_changed_branches_are_kept
test_delete_removes_clean_named_worktree
test_installer_exposes_wt_without_shell_rc

printf 'PASS: worktree manager focused tests\n'
