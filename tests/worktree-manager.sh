#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANAGER="$PROJECT_ROOT/scripts/worktree.sh"
INSTALLER="$PROJECT_ROOT/scripts/install.sh"
TEST_ROOT="$(mktemp -d)"

cleanup() {
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

test_installer_exposes_wt_without_shell_rc() {
  local test_home="$TEST_ROOT/installer-home"
  mkdir -p "$test_home/.local/bin"
  touch "$test_home/.zshrc"

  HOME="$test_home" SHELL=/bin/zsh bash "$INSTALLER" >/dev/null
  HOME="$test_home" SHELL=/bin/zsh bash "$INSTALLER" >/dev/null

  [ -L "$test_home/.local/bin/wt" ] || fail "installer did not create the wt command"
  [ -L "$test_home/.local/bin/worktree.sh" ] || fail "installer removed the compatibility command"
  [ "$(PATH="$test_home/.local/bin:/usr/bin:/bin" command -v wt)" = "$test_home/.local/bin/wt" ] || \
    fail "wt is not discoverable on PATH without sourcing a shell rc"
  PATH="$test_home/.local/bin:/usr/bin:/bin" wt --help >/dev/null 2>&1 || \
    fail "the installed wt command is not executable"
  PATH="$test_home/.local/bin:/usr/bin:/bin" worktree.sh --help >/dev/null 2>&1 || \
    fail "the compatibility worktree.sh command is not executable"
}

test_init_is_non_overwriting
test_create_keeps_shared_checkout_clean
test_bootstrap_failure_is_terminal
test_installer_exposes_wt_without_shell_rc

printf 'PASS: worktree manager focused tests\n'
