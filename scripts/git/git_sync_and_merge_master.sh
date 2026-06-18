#!/bin/bash

# Define emojis for visual clarity
FETCH="🔄"
BRANCH="🌿"
RESETA="🧭"
STASH="💾"
MERGE="🔀"
COMMIT="📝"
GOOD="✅ "
QUESTION="❓ "
WARN="⚠️"
GREAT="🎉"
FINISH="🏁"

# Define color codes
RED=$'\033[38;5;196m'
GREEN=$'\033[38;5;34m'
YELLOW=$'\033[38;5;208m'
BLUE=$'\033[38;5;33m'
CYAN=$'\033[38;5;45m'
BOLD=$'\033[1m'
RESETC=$'\033[0m'

info()    { echo -e "${BLUE}$1${RESETC}"; }
success() { echo -e "${GREEN}$1${RESETC}"; }
warn()    { echo -e "${YELLOW}$1${RESETC}"; }
error()   { echo -e "${RED}$1${RESETC}"; }
action()  { echo -e "${CYAN}$1${RESETC}"; }

# Always reset colors on exit (even on error/ctrl-c)
trap 'printf "\033[0m"' EXIT

# Store the current branch name
current_branch=$(git branch --show-current)

# Fetch latest from origin to ensure all refs are up to date (skip if already in sync)
action "$FETCH Checking if remote updates are available..."
if git fetch origin --dry-run 2>&1 | grep -q "up to date"; then
  info "$GOOD Already up to date with origin."
else
  action "$FETCH Fetching latest changes from origin..."
  git fetch origin
fi
echo ""

# Check if the current branch is master
if [ "$current_branch" = "master" ]; then
  info "$BRANCH Already on master branch. Syncing to remote..."
  git fetch origin 
  git reset --hard origin/master
  success "$GOOD Master is now exactly like origin."
else
  # Generate a unique stash name based on the current timestamp
  stash_name="autostash-$(date +%s)"

  # Stash changes in the current branch with the unique name
  action "$STASH Checking for local changes..."
  stash_result=$(git stash push -m "$stash_name")
  
  # Check if anything was stashed
  if [[ "$stash_result" != "No local changes to save" ]]; then
    info "$STASH Changes have been stashed as: $stash_name"
    stash_applied=true
  else
    info "$STASH No changes to stash."
    stash_applied=false
  fi

  # Update master ref directly without checking it out (worktree-safe)
  # This works in both worktrees (where master is checked out elsewhere)
  # and traditional repos (where we want to avoid branch switching overhead)
  echo ""
  action "$RESETA Checking master against origin..."

  # Ensure we have the latest remote ref (this always works)
  git fetch origin master:refs/remotes/origin/master 2>/dev/null

  local_hash=$(git rev-parse master 2>/dev/null || echo "none")
  remote_hash=$(git rev-parse origin/master 2>/dev/null || echo "none")

  if [ "$local_hash" = "$remote_hash" ]; then
    info "$GREAT  Master already matches origin. No update needed."
  else
    action "$RESETA Syncing master to exactly match origin (worktree-safe)..."
    # Use git update-ref to force update master branch (works even when checked out)
    git update-ref refs/heads/master refs/remotes/origin/master
    success "$GOOD Master is now exactly like origin."
  fi
  echo ""

  # Merge changes from master into the current branch
  action "$MERGE Merging master into $current_branch..."
  # Guard 1: if master is already contained in current branch, skip
  if git merge-base --is-ancestor master "$current_branch"; then
    echo ""
    success "$GOOD $current_branch already contains master. Nothing to merge."
  else
    # Prepare a non-committing merge; if it succeeds, decide whether to prompt
  if git merge master --no-ff --no-commit; then
      # Guard 2: Only prompt if a merge is actually in progress or there are staged changes
      if [ -f .git/MERGE_HEAD ] || ! git diff --cached --quiet; then
        info "$GOOD Merged master into $current_branch successfully (but not committed)."

    while true; do
      echo ""
      printf '%b' "${YELLOW}${QUESTION} Do you want to commit the merge changes? (y/n): ${RESETC}"
      read user_choice
      echo ""
      case "$user_choice" in
        y|Y )
          git commit -m "Merged master into $current_branch"
          success "$COMMIT Merge changes have been committed."
          break
          ;;
        n|N )
          warn "$WARN Merge changes have been staged but not committed. Please commit them manually if needed."
          break
          ;;
        * )
          warn "$WARN Please answer y (yes) or n (no)."
          ;;
      esac
    done
      else
        # This path would occur only if nothing ended up staged (highly unlikely after a merge),
        # but it's here for completeness.
        info "$GOOD No changes to commit from merge."
      fi

    # Apply the stashed changes, if any
    if $stash_applied; then
      action "$STASH Restoring stashed work..."
      echo ""
      # Find the stash index for the created stash
      stash_index=$(git stash list | grep "$stash_name" | awk -F: '{print $1}')
      echo ""
      if [ -n "$stash_index" ]; then
        if git stash pop "$stash_index"; then

          info "$GOOD Stashed changes from $stash_name have been reapplied."
        else
          error "$WARN Error applying stashed changes from $stash_name. Please resolve manually."
        fi
      else
        error "$WARN Could not find the stash named $stash_name. Please check manually."
      fi
    fi
  else
    warn "$WARN Merge conflicts detected. Please resolve conflicts manually."
    if $stash_applied; then
      warn "    $WARN Your work is still stashed as: $stash_name"
      warn "    After resolving conflicts and committing, restore it with:"
      info "    git stash pop"
    fi
  fi
fi
fi

echo ""
success "$FINISH Operation completed successfully. $FINISH"
