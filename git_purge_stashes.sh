#!/bin/bash

# Display all existing stashes without invoking a pager
echo "Current stashes:"
git --no-pager stash list

# Check if there are any stashes before continuing
if git stash list | grep -q 'stash@{'; then
    # Confirm with the user before purging
    echo "Do you really want to delete all stashes? This cannot be undone."
    read -p "Type 'yes' to confirm: " confirmation
    if [ "$confirmation" = "yes" ]; then
        # Purge all stashes
        git stash clear
        echo "All stashes have been deleted."
    else
        echo "Operation cancelled."
    fi
else
    echo "No stashes to delete."
fi
