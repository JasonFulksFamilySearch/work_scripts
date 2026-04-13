#!/bin/bash

# Fetch the latest updates from the remote
echo "Fetching the latest updates from the remote repository..."
git fetch --all

# Get the list of remote branches
echo "Retrieving the list of remote branches..."
remote_branches=$(git branch -r | grep -v '\->')

echo "Retrieving the list of local branches..."
local_branches=$(git branch -l)


# Get the current user's Git config name
current_user=$(git config user.name)
echo "Current Git user: $current_user"

# Function to calculate the time difference in seconds
time_diff_seconds() {
    local now=$(date +%s)
    local commit_time=$(git show -s --format=%ct "$1")
    local diff=$((now - commit_time))
    echo $diff
}

# Function to format the time difference
time_diff_readable() {
    local diff=$1

    if [ $diff -lt 60 ]; then
        echo "$diff seconds"
    elif [ $diff -lt 3600 ]; then
        echo "$((diff / 60)) minutes"
    elif [ $diff -lt 86400 ]; then
        echo "$((diff / 3600)) hrs"
    elif [ $diff -lt 604800 ]; then
        echo "$((diff / 86400)) days"
    elif [ $diff -lt 2592000 ]; then
        echo "$((diff / 604800)) wks"
    else
        echo "$((diff / 2592000)) months"
    fi
}

# Array to store user-specific branch information
declare -a user_branches

echo ""
echo "Processing remote branches to identify those authored by $current_user..."
# Loop through each branch and get the last commit details
for branch in $remote_branches; do
    branch_name="${branch#origin/}"


    # Check if the branch is in the local repo or checked out in a worktree
    if echo "$local_branches" | grep -qw "$branch_name"; then
        echo "    Branch $branch_name is local and will not be considered."
        continue
    fi

    # Check if branch is used by a worktree
    if git worktree list --porcelain | grep -q "branch refs/heads/$branch_name"; then
        echo "    Branch $branch_name is checked out in a worktree and will not be considered."
        continue
    fi
    
    last_commit=$(git log -1 --format="%H %ct %an" "$branch")
    commit_hash=$(echo "$last_commit" | awk '{print $1}')
    commit_time=$(echo "$last_commit" | awk '{print $2}')
    author=$(echo "$last_commit" | awk '{print $3,$4}')
    time_since_commit_seconds=$(time_diff_seconds "$commit_hash")
    time_since_commit_readable=$(time_diff_readable "$time_since_commit_seconds")
    
    
    # Check if the current user was the last author
    if [[ "$author" == "$current_user" ]]; then
        echo "Adding branch $branch_name to deletion consideration."
        user_branches+=("$branch|$commit_time|$time_since_commit_readable")
    fi
done

if [ ${#user_branches[@]} -eq 0 ]; then
    echo ""
    echo ""
    RED=$'\e[0;31m'
    NC=$'\e[0m'
    echo "${RED}No branches found for deletion consideration.${NC}"
    exit 0
fi


# Print user-specific branch information and prompt for deletion
for branch_info in "${user_branches[@]}"; do
    IFS='|' read -r branch_name commit_time time_since_commit_readable <<< "$branch_info"
    echo "\n======================================"
    echo "Branch: $branch_name"
    echo "Last commit: $(date -d "@$commit_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$commit_time" '+%Y-%m-%d %H:%M:%S')"
    echo "Time since last commit: $time_since_commit_readable"
    echo "======================================"
    read -p "Do you want to delete this remote branch? (y/n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        echo "Deleting branch $branch_name from remote..."
        git push origin --delete "${branch_name#*/}"
        echo "Branch $branch_name deleted."
    else
        echo "Branch $branch_name not deleted."
    fi
    echo "--------------------------------------"
done
echo ""
echo "Script execution completed."
