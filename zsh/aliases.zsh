# developer-scripts aliases
# Preserves muscle-memory from the old ~/scripts layout.
# These are optional — bin/ wrappers are on PATH as git-cleanup, brew-update, etc.

alias gitCleanup="$DEV_SCRIPTS/bin/git-cleanup"
alias gitSyncMaster="$DEV_SCRIPTS/bin/git-sync-master"
alias gitStashesPurge="$DEV_SCRIPTS/bin/git-purge-stashes"
alias gitOldest="$DEV_SCRIPTS/bin/git-oldest-branches"
alias gitDeleteMyRemoteBranches="$DEV_SCRIPTS/bin/git-delete-my-branches"
alias gitDiff="$DEV_SCRIPTS/bin/git-diff -b"
alias gitDiffS="$DEV_SCRIPTS/bin/git-diff -b -s"
alias brewUpdate="$DEV_SCRIPTS/bin/brew-update"
alias codeClimate="$DEV_SCRIPTS/bin/code-climate"
