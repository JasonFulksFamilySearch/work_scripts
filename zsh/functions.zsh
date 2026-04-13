# developer-scripts functions
# Functions that require shell context (e.g., cd) and cannot be external scripts.

# Create a git worktree and cd into it.
# Usage: workBranch feat ARC-1234 description
workBranch() {
  local dir
  dir=$("$DEV_SCRIPTS/bin/git-worktree-create" "$@")
  if [ $? -eq 0 ] && [ -n "$dir" ]; then
    cd "$dir"
  fi
}
