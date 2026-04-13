#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# git_oldest_branches.sh
# Lists remote git branches sorted by last commit (oldest first)
# Full branch names, rounded time since, color-coded age
# -----------------------------------------------------------------------------

git fetch origin --prune >/dev/null 2>&1

# Get remote branches (strip symbolic refs and whitespace)
branches=$(git -c color.branch=never branch -r | awk '!/->/ { sub(/^[ \t]+/, ""); print }')

# --- helpers ------------------------------------------------------------------

# Convert seconds into rounded human-readable form (wks/mos)
time_rounded() {
  local secs=$1
  local days=$((secs / 86400))
  local weeks=$(( (days + 3) / 7 ))     # round to nearest week
  local months=$(( (days + 15) / 30 ))  # round to nearest month

  if (( days < 45 )); then
    printf "%d wks" "$weeks"
  else
    printf "%d mos" "$months"
  fi
}

# Choose color based on age in months
age_color() {
  local secs=$1
  local months=$((secs / 2592000))  # seconds in ~1 month
  if   (( months < 2 )); then printf "\033[32m"   # green
  elif (( months < 4 )); then printf "\033[38;5;208m"   # orange
  else                       printf "\033[31m"   # red
  fi
}

RESET="\033[0m"

git_field() {
  local fmt=$1 ref=$2
  git show -s --no-show-signature --format="$fmt" "$ref" 2>/dev/null || true
}

# --- collect data -------------------------------------------------------------

declare -a rows=()
now_epoch=$(date +%s)
max_branch_len=0

while IFS= read -r branch; do
  branch=$(echo "$branch" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  (( ${#branch} > max_branch_len )) && max_branch_len=${#branch}

  commit_epoch=$(git_field "%ct" "$branch")
  [[ -z "$commit_epoch" ]] && continue

  commit_date=$(git_field "%cs" "$branch" | cut -d'T' -f1)
  author_name=$(git_field "%an" "$branch")

  diff=$(( now_epoch - commit_epoch ))
  rounded=$(time_rounded "$diff")

  rows+=( "$branch|$commit_date|$rounded|$author_name|$diff" )
done <<< "$branches"

if (( ${#rows[@]} == 0 )); then
  echo "No remote branches found."
  exit 0
fi

# Sort oldest first
sorted=$(printf "%s\n" "${rows[@]}" | sort -t'|' -nk5)

# --- layout -------------------------------------------------------------------

BRANCH_W=$(( max_branch_len + 2 ))
DATE_W=12
SINCE_W=10
AUTHOR_W=25
TOTAL_W=$(( BRANCH_W + DATE_W + SINCE_W + AUTHOR_W + 3 ))

# --- output -------------------------------------------------------------------

echo -e "Remote Branches:\n"
printf "%-${BRANCH_W}s %-${DATE_W}s %-${SINCE_W}s %-${AUTHOR_W}s\n" \
  "Branch Name" "Last Commit" "Since" "Author"
printf '%*s\n' "$TOTAL_W" '' | tr ' ' '-'

while IFS='|' read -r name date since author secs; do
  color=$(age_color "$secs")
  printf "%b%-${BRANCH_W}s %-${DATE_W}s %-${SINCE_W}s %-${AUTHOR_W}s%b\n" \
    "$color" "$name" "$date" "$since" "$author" "$RESET"
done <<< "$sorted"