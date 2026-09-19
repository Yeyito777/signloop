#!/usr/bin/env bash
# Shared, macOS Bash 3.2-compatible helpers. No GNU readlink dependency.

WORKTREE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SIGNLOOP_CHECKOUT="$(git -C "$WORKTREE_SCRIPT_DIR" rev-parse --show-toplevel)"
SIGNLOOP_COMMON_GIT="$(git -C "$SIGNLOOP_CHECKOUT" rev-parse --path-format=absolute --git-common-dir)"
SIGNLOOP_ROOT="$(cd "$SIGNLOOP_COMMON_GIT/.." && pwd -P)"

worktree_die() { printf 'signloop: %s\n' "$*" >&2; exit 1; }

# Deliberately support conventional, non-bare repositories only.
[[ -d "$SIGNLOOP_ROOT/.git" ]] || worktree_die "Expected a main checkout with a .git directory."

validate_worktree_name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] ||
    worktree_die "Use a simple worktree name (letters, digits, dots, underscores, hyphens)."
  git check-ref-format --branch "$1" >/dev/null 2>&1 ||
    worktree_die "Invalid branch name: $1"
}

resolve_worktree_dir() {
  local input="${1:-}" name
  [[ -n "$input" ]] || worktree_die "A worktree name or path is required."
  case "$input" in
    "$SIGNLOOP_ROOT/.worktrees/"*) name="${input#"$SIGNLOOP_ROOT/.worktrees/"}" ;;
    .worktrees/*) name="${input#.worktrees/}" ;;
    *) name="$input" ;;
  esac
  validate_worktree_name "$name"
  [[ ! -L "$SIGNLOOP_ROOT/.worktrees" ]] || worktree_die ".worktrees must not be a symlink."
  [[ ! -L "$SIGNLOOP_ROOT/.worktrees/$name" ]] || worktree_die "Worktree must not be a symlink."
  printf '%s/.worktrees/%s\n' "$SIGNLOOP_ROOT" "$name"
}

require_registered_worktree() {
  git -C "$SIGNLOOP_ROOT" worktree list --porcelain |
    grep -Fqx "worktree $1" || worktree_die "Not a registered worktree: $1"
}

# Copy, never link, mutable dependency trees. APFS clone copies are fast and
# space-efficient; a normal copy is used on other filesystems.
copy_artifact() {
  local source="$1" destination="$2"
  [[ -e "$source" && ! -e "$destination" && ! -L "$destination" ]] || return 0
  mkdir -p "$(dirname "$destination")"
  if [[ "$(uname -s)" == Darwin ]]; then
    cp -cR "$source" "$destination" 2>/dev/null && return 0
  fi
  # If clone-copy partially succeeded, merge contents rather than nesting dirs.
  if [[ -d "$source" ]]; then
    mkdir -p "$destination"
    cp -R "$source/." "$destination/"
  else
    cp "$source" "$destination"
  fi
}

seed_dependency_artifacts() {
  local target="$1"
  [[ "$target" != "$SIGNLOOP_ROOT" ]] || return 0
  # Do not seed a different dependency version after changing branches.
  cmp -s "$SIGNLOOP_ROOT/ios/scripts/bootstrap.sh" "$target/ios/scripts/bootstrap.sh" || return 0
  copy_artifact "$SIGNLOOP_ROOT/ios/Vendor" "$target/ios/Vendor"
  copy_artifact "$SIGNLOOP_ROOT/ios/Signloop/Resources/hand_landmarker.task" \
    "$target/ios/Signloop/Resources/hand_landmarker.task"
}

bootstrap_worktree() {
  local target="$1"
  command -v xcodegen >/dev/null || worktree_die "Install XcodeGen first: brew install xcodegen"
  [[ -f "$target/ios/scripts/bootstrap.sh" ]] || worktree_die "This revision has no iOS bootstrap script."
  seed_dependency_artifacts "$target"
  (cd "$target" && bash ios/scripts/bootstrap.sh)
}
