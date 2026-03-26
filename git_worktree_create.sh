#!/bin/bash
set -euo pipefail  # Strict mode: exit on error, undefined vars, pipe failures

# Debug mode support
if [[ "${1:-}" == "--debug" ]] || [[ "${DEBUG:-}" == "1" ]]; then
    set -x  # Enable command tracing
    DEBUG_MODE=1
else
    DEBUG_MODE=0
fi

# Define emojis for visual clarity
ROCKET="🚀"
FOLDER="📁"
BRANCH="🌿"
FETCH="🔄"
GOOD="✅"
WARN="⚠️"
ERROR="❌"
QUESTION="❓"
FINISH="🏁"
MAGNIFY="🔍"

# Define color codes
RED=$'\033[38;5;196m'
GREEN=$'\033[38;5;34m'
YELLOW=$'\033[38;5;208m'
BLUE=$'\033[38;5;33m'
CYAN=$'\033[38;5;45m'
BOLD=$'\033[1m'
RESETC=$'\033[0m'

info()    { printf '%b\n' "${BLUE}$1${RESETC}" >&2; }
success() { printf '%b\n' "${GREEN}$1${RESETC}" >&2; }
warn()    { printf '%b\n' "${YELLOW}$1${RESETC}" >&2; }
error()   { printf '%b\n' "${RED}$1${RESETC}" >&2; }
action()  { printf '%b\n' "${CYAN}$1${RESETC}" >&2; }
debug()   { [[ $DEBUG_MODE -eq 1 ]] && printf '%b\n' "${CYAN}[DEBUG] $1${RESETC}" >&2 || true; }

# Always reset colors on exit (even on error/ctrl-c)
trap 'printf "\033[0m" >&2' EXIT

# Constants
VALID_TYPES=("feat" "fix" "chore")
WORKTREES_DIR=""  # Detected dynamically per repo

# ═══════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════

check_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        error "$ERROR Not in a git repository!"
        exit 1
    fi
    success "$GOOD Found git repository"
}

detect_worktrees_base_dir() {
    action "$MAGNIFY Detecting worktrees directory..."

    # Get list of existing worktrees
    local worktree_list
    worktree_list=$(git worktree list --porcelain 2>/dev/null || echo "")

    # Extract worktree paths (excluding the main repo)
    local worktree_paths
    worktree_paths=$(echo "$worktree_list" | grep "^worktree " | sed 's/^worktree //' | tail -n +2)

    if [ -n "$worktree_paths" ]; then
        # Worktrees exist - infer the base directory
        local first_worktree
        first_worktree=$(echo "$worktree_paths" | head -n 1)

        # Extract base directory by going up from worktree path
        # Assumes structure: /path/to/worktrees/[type]/[worktree-name]
        # We want: /path/to/worktrees
        local base_dir
        base_dir=$(dirname "$(dirname "$first_worktree")")

        # Verify this is actually a worktrees directory
        if [[ "$(basename "$base_dir")" == "worktrees" ]]; then
            WORKTREES_DIR="$base_dir"
            info "$MAGNIFY Detected worktrees directory: $WORKTREES_DIR"
        else
            # Fallback: use sibling worktrees directory
            local repo_root
            repo_root=$(git rev-parse --show-toplevel)
            WORKTREES_DIR="$(dirname "$repo_root")/worktrees"
            warn "$WARN Could not infer worktrees location from existing worktrees"
            info "$MAGNIFY Using default: $WORKTREES_DIR"
        fi
    else
        # No worktrees exist - use default sibling directory
        local repo_root
        repo_root=$(git rev-parse --show-toplevel)
        WORKTREES_DIR="$(dirname "$repo_root")/worktrees"
        info "$MAGNIFY No existing worktrees found"
        info "$MAGNIFY Using default location: $WORKTREES_DIR"
    fi
}

check_worktrees_dir() {
    if [ ! -d "$WORKTREES_DIR" ]; then
        warn "$WARN Worktrees directory does not exist: $WORKTREES_DIR"
        printf '\n' >&2
        printf '%b' "${YELLOW}${QUESTION} Create worktrees directory? (y/n): ${RESETC}" >&2
        read -r create_choice </dev/tty
        printf '\n' >&2

        case "$create_choice" in
            y|Y)
                mkdir -p "$WORKTREES_DIR"
                success "$GOOD Created worktrees directory: $WORKTREES_DIR"
                ;;
            *)
                error "$ERROR Cannot proceed without worktrees directory"
                exit 1
                ;;
        esac
    else
        success "$GOOD Worktrees directory exists"
    fi
}

# ═══════════════════════════════════════════════
# MASTER BRANCH UPDATE
# ═══════════════════════════════════════════════

update_master_branch() {
    printf '\n' >&2
    action "$FETCH Updating master branch from origin..."

    # Ensure we have the latest remote ref (worktree-safe)
    git fetch origin master:refs/remotes/origin/master 2>/dev/null || {
        error "$ERROR Failed to fetch master from origin"
        exit 1
    }

    local local_hash
    local remote_hash
    local_hash=$(git rev-parse master 2>/dev/null || echo "none")
    remote_hash=$(git rev-parse origin/master 2>/dev/null || echo "none")

    if [ "$local_hash" = "$remote_hash" ]; then
        info "$GOOD Master already up to date with origin"
    else
        # Use git update-ref to force update master branch (works even when checked out)
        git update-ref refs/heads/master refs/remotes/origin/master || {
            error "$ERROR Failed to update master branch"
            exit 1
        }
        success "$GOOD Master updated successfully!"
    fi
}

# ═══════════════════════════════════════════════
# USER INPUT FUNCTIONS
# ═══════════════════════════════════════════════

prompt_branch_type() {
    debug "Entering prompt_branch_type function"
    # Output to stderr so it's not captured by command substitution
    printf '\n' >&2
    info "$BRANCH Select branch type:" >&2
    printf '  1) feat  - New feature\n' >&2
    printf '  2) fix   - Bug fix\n' >&2
    printf '  3) chore - Maintenance/refactor\n' >&2
    printf '\n' >&2
    debug "Menu displayed, waiting for input..."

    while true; do
        printf '%b' "${CYAN}Enter choice (1-3): ${RESETC}" >&2
        debug "About to read input..."
        read -r type_choice </dev/tty
        debug "Received input: $type_choice"
        printf '\n' >&2

        case "$type_choice" in
            1)
                echo "feat"
                return 0
                ;;
            2)
                echo "fix"
                return 0
                ;;
            3)
                echo "chore"
                return 0
                ;;
            *)
                warn "$WARN Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done
}

prompt_ticket_number() {
    printf '\n' >&2
    while true; do
        printf '%b' "${CYAN}Enter ticket number (e.g., ARC-3582): ${RESETC}" >&2
        read -r ticket_input </dev/tty
        printf '\n' >&2

        # Trim whitespace
        ticket_input=$(echo "$ticket_input" | xargs)

        # Validate format: uppercase letters, hyphen, digits
        if [[ "$ticket_input" =~ ^[A-Z]+-[0-9]+$ ]]; then
            echo "$ticket_input"
            return 0
        else
            warn "$WARN Invalid ticket format. Expected format: UPPERCASE-NUMBER (e.g., ARC-3582)"
        fi
    done
}

prompt_ticket_number_optional() {
    printf '\n' >&2
    while true; do
        printf '%b' "${CYAN}Enter ticket number (or press Enter to skip): ${RESETC}" >&2
        read -r ticket_input </dev/tty
        printf '\n' >&2

        # Trim whitespace
        ticket_input=$(echo "$ticket_input" | xargs)

        # Empty is valid — no ticket
        if [ -z "$ticket_input" ]; then
            echo ""
            return 0
        fi

        # Validate format: uppercase letters, hyphen, digits
        if [[ "$ticket_input" =~ ^[A-Z]+-[0-9]+$ ]]; then
            echo "$ticket_input"
            return 0
        else
            warn "$WARN Invalid ticket format. Expected format: UPPERCASE-NUMBER (e.g., ARC-3582) or blank to skip"
        fi
    done
}

prompt_description() {
    printf '\n' >&2
    info "Description format: lowercase-with-hyphens (kebab-case)"
    printf '  Examples: inline-file-type, user-auth-fix, test-coverage\n' >&2
    printf '\n' >&2

    while true; do
        printf '%b' "${CYAN}Enter branch description: ${RESETC}" >&2
        read -r description_input </dev/tty
        printf '\n' >&2

        # Trim whitespace
        description_input=$(echo "$description_input" | xargs)

        # Sanitize to kebab-case:
        # 1. Insert hyphen before capital letters (camelCase → kebab-case)
        # 2. Convert to lowercase
        # 3. Replace spaces and underscores with single hyphen
        # 4. Remove non-alphanumeric except hyphens
        # 5. Collapse multiple consecutive hyphens into one
        # 6. Trim leading/trailing hyphens
        description_sanitized=$(echo "$description_input" | \
            sed 's/\([a-z0-9]\)\([A-Z]\)/\1-\2/g' | \
            tr '[:upper:]' '[:lower:]' | \
            sed -E 's/[_ ]+/-/g' | \
            sed 's/[^a-z0-9-]//g' | \
            sed -E 's/-+/-/g' | \
            sed 's/^-//;s/-$//')

        if [ -z "$description_sanitized" ]; then
            warn "$WARN Description cannot be empty"
        else
            # Show what it will become if different from input
            if [ "$description_input" != "$description_sanitized" ]; then
                info "  → Converted to: $description_sanitized"
            fi
            echo "$description_sanitized"
            return 0
        fi
    done
}

# ═══════════════════════════════════════════════
# CONFLICT DETECTION
# ═══════════════════════════════════════════════

check_branch_exists() {
    local branch_name="$1"

    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
        error "$ERROR Branch already exists: $branch_name"
        printf '\n' >&2
        warn "Existing branches with similar names:"
        git branch --list | grep -i "$(echo "$branch_name" | cut -d'/' -f2 | cut -d'-' -f1-2)" || printf '  (none found)\n' >&2
        printf '\n' >&2
        exit 1
    fi
}

check_worktree_exists() {
    local worktree_path="$1"

    # Check filesystem
    if [ -d "$worktree_path" ]; then
        error "$ERROR Worktree directory already exists: $worktree_path"
        exit 1
    fi

    # Check git worktree registry
    if git worktree list | grep -q "$worktree_path"; then
        error "$ERROR Worktree already registered: $worktree_path"
        exit 1
    fi
}

# ═══════════════════════════════════════════════
# WORKTREE CREATION
# ═══════════════════════════════════════════════

create_worktree() {
    local type="$1"
    local ticket="$2"
    local description="$3"

    # Construct names
    local branch_name worktree_dir_name
    if [ -n "$ticket" ]; then
        branch_name="${type}/${ticket}-${description}"
        worktree_dir_name="${ticket}-${description}"
    else
        branch_name="${type}/${description}"
        worktree_dir_name="${description}"
    fi
    local worktree_path="${WORKTREES_DIR}/${type}/${worktree_dir_name}"

    # Display summary
    printf '\n' >&2
    printf '═══════════════════════════════════════════════\n' >&2
    info "${BOLD}Creating worktree with the following details:${RESETC}"
    printf '═══════════════════════════════════════════════\n' >&2
    printf '  Branch name:     %s\n' "$branch_name" >&2
    printf '  Worktree path:   %s\n' "$worktree_path" >&2
    printf '  Based on:        master\n' >&2
    printf '═══════════════════════════════════════════════\n' >&2
    printf '\n' >&2

    # Confirm with user
    printf '%b' "${YELLOW}${QUESTION} Create this worktree? (y/n): ${RESETC}" >&2
    read -r confirm_choice </dev/tty
    printf '\n' >&2

    case "$confirm_choice" in
        y|Y)
            # Proceed with creation
            ;;
        *)
            warn "$WARN Worktree creation cancelled by user"
            exit 0
            ;;
    esac

    # Run conflict checks
    check_branch_exists "$branch_name"
    check_worktree_exists "$worktree_path"

    # Create type subfolder if missing
    local type_dir="${WORKTREES_DIR}/${type}"
    if [ ! -d "$type_dir" ]; then
        mkdir -p "$type_dir"
        info "$FOLDER Created type directory: $type_dir"
    fi

    # Create worktree
    action "$ROCKET Creating worktree..."
    if git worktree add "$worktree_path" -b "$branch_name" master >&2; then
        success "$GOOD Worktree created successfully!"

        # Output path to stdout so callers (e.g., workBranch wrapper) can capture it
        echo "$worktree_path"

        printf '\n' >&2

        # Show next steps
        info "$FINISH Next steps:"
        printf '  1. cd %s\n' "$worktree_path" >&2
        printf '  2. Start working on your changes\n' >&2
        printf '  3. Commit and push when ready\n' >&2
        printf '\n' >&2

        # Show current worktrees
        info "Current worktrees:"
        git worktree list >&2
    else
        error "$ERROR Failed to create worktree"
        exit 1
    fi
}

# ═══════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════

main() {
    # Display header
    printf '\n' >&2
    printf '═══════════════════════════════════════════════\n' >&2
    info "${BOLD}${ROCKET} Git Worktree Creation Script${RESETC}"
    printf '═══════════════════════════════════════════════\n' >&2

    # Pre-flight checks
    check_git_repo
    detect_worktrees_base_dir
    check_worktrees_dir

    # Update master branch
    update_master_branch

    # Gather user input
    local type
    type=$(prompt_branch_type)
    success "$GOOD Selected type: $type"

    local ticket
    if [ "$type" = "chore" ]; then
        ticket=$(prompt_ticket_number_optional)
        if [ -n "$ticket" ]; then
            success "$GOOD Valid ticket number: $ticket"
        else
            info "$GOOD No ticket — chore branch without JIRA ticket"
        fi
    else
        ticket=$(prompt_ticket_number)
        success "$GOOD Valid ticket number: $ticket"
    fi

    local description
    description=$(prompt_description)
    success "$GOOD Description: $description"

    # Create worktree
    create_worktree "$type" "$ticket" "$description"

    # Completion message
    printf '\n' >&2
    success "$FINISH Script completed successfully!"
    printf '\n' >&2
}

# Run main function
main
