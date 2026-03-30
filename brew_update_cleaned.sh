#!/usr/bin/env bash
set -euo pipefail  # Exit on error, undefined vars, pipeline failures

# Set Homebrew automation mode
export NONINTERACTIVE=1
export HOMEBREW_NO_AUTO_UPDATE=1  # We control updates

################################################################################
# Homebrew Update Script
# - Sudo availability detection (pre-flight check)
# - IT-managed cask exclusion (avoids sudo prompts)
# - Interactive force-replace for stale Caskroom apps
# - Preview before upgrade
# - Dry-run mode support
#
# KB0137814: Company policy blocks sudo for Homebrew upgrades
################################################################################

# Parse command line arguments
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
    DRY_RUN=true
fi

# Log file and backup locations
LOGFILE="$HOME/brew-update.log"
BREWFILE_BACKUP="$HOME/Brewfile.backup"

# ANSI color codes
GREEN='\033[0;32m'
YELLOW='\033[38;5;208m'
RED='\033[0;31m'
BLUE='\033[38;5;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No color / reset

# IT-managed casks that require sudo (typically installed by MDM)
# These will be excluded from Homebrew upgrades
IT_MANAGED_CASKS=(
    "docker-desktop"
    "visual-studio-code"
    "intellij-idea"
    "slack"
)

# Load additional exclusions from config file if it exists
EXCLUDE_CONFIG="$HOME/scripts/.brew-exclude-casks"
if [ -f "$EXCLUDE_CONFIG" ]; then
    while IFS= read -r cask; do
        # Skip empty lines and comments
        [[ -z "$cask" || "$cask" =~ ^#.*$ ]] && continue
        IT_MANAGED_CASKS+=("$cask")
    done < "$EXCLUDE_CONFIG"
fi

# Track start time
START_TIME=$(date +%s)

# Function to print bordered messages
print_message() {
    local COLOR=$1
    local MESSAGE=$2
    echo -e "${COLOR}######################################${NC}"
    echo -e "${COLOR}### ${MESSAGE}${NC}"
    echo -e "${COLOR}######################################${NC}"
}

# Function to print section headers
print_section() {
    echo ""
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}────────────────────────────────────────${NC}"
}

# Dry run mode notification
if [ "$DRY_RUN" = true ]; then
    print_message "${MAGENTA}" "DRY RUN MODE - No changes will be made"
    echo "This will show what would happen without actually doing it."
    echo ""
fi

################################################################################
# Pre-flight: Check sudo availability
################################################################################
SUDO_AVAILABLE=false
# Test sudo without triggering set -e (commands in if conditions are exempt)
if sudo -n true 2>/dev/null; then
    SUDO_AVAILABLE=true
    echo -e "${GREEN}✓ Sudo access available${NC}"
else
    echo -e "${YELLOW}⚠ Sudo access blocked (company policy KB0137814)${NC}"
    echo -e "${YELLOW}  Cask upgrades requiring sudo will be skipped${NC}"
    echo -e "${YELLOW}  Only formulae (CLI tools) will be upgraded${NC}"
    echo ""
fi

# Starting Homebrew update process
print_message "${YELLOW}" "Starting Homebrew Update Process"
{
    echo "========================================"
    echo "Homebrew Update: $(date)"
    echo "========================================"
    echo ""
} > "$LOGFILE"

################################################################################
# STEP 1: Backup current Brewfile
################################################################################
print_section "Creating Brewfile Backup"
echo -e "${YELLOW}Saving current package list for rollback safety...${NC}"
if [ "$DRY_RUN" = false ]; then
    set +e
    brew bundle dump --file="$BREWFILE_BACKUP" --force 2>&1 | tee -a "$LOGFILE"
    backup_status=$?
    set -e
    if [ $backup_status -ne 0 ]; then
        print_message "${RED}" "ERROR: Brewfile backup failed!"
        echo "Error occurred at: $(date)" >> "$LOGFILE"
        exit 1
    fi
    echo -e "${GREEN}✓ Backup saved to: $BREWFILE_BACKUP${NC}"
    echo "Brewfile backup created: $(date)" >> "$LOGFILE"
else
    echo -e "${BLUE}[DRY RUN] Would create Brewfile backup at: $BREWFILE_BACKUP${NC}"
fi

################################################################################
# STEP 2: Run Homebrew Doctor
################################################################################
print_section "Running Homebrew Doctor"
# Capture output and status separately (doctor may return non-zero for warnings)
set +e  # Temporarily disable exit on error for doctor check
doctor_output=$(brew doctor 2>&1)
doctor_status=$?
set -e  # Re-enable exit on error

if [ $doctor_status -eq 0 ]; then
    echo -e "${GREEN}✓ Homebrew is healthy!${NC}"
    echo "brew doctor: OK" >> "$LOGFILE"
elif echo "$doctor_output" | grep -q "Your system is ready to brew"; then
    echo -e "${GREEN}✓ Your system is ready to brew${NC}"
    echo "brew doctor: ready to brew" >> "$LOGFILE"
else
    echo -e "${YELLOW}⚠ Homebrew doctor found some issues:${NC}"
    echo "$doctor_output" | tee -a "$LOGFILE"

    # Check for critical issues
    if echo "$doctor_output" | grep -qi "error\|fatal\|critical"; then
        print_message "${RED}" "CRITICAL ISSUES DETECTED!"
        echo -e "${YELLOW}Review the issues above before proceeding.${NC}"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted by user" | tee -a "$LOGFILE"
            exit 1
        fi
    fi
fi

################################################################################
# STEP 3: Update Homebrew
################################################################################
print_section "Updating Homebrew"
echo -e "${YELLOW}Fetching latest package information...${NC}"
if [ "$DRY_RUN" = false ]; then
    set +e  # Temporarily disable for tee pipeline
    update_output=$(brew update 2>&1 | tee -a "$LOGFILE")
    update_status=$?
    set -e
    if [ $update_status -ne 0 ]; then
        print_message "${RED}" "ERROR: brew update failed!"
        echo "Error occurred at: $(date)" >> "$LOGFILE"
        exit 1
    fi

    if echo "$update_output" | grep -q "Already up-to-date"; then
        echo -e "${GREEN}✓ Homebrew is already up-to-date${NC}"
    else
        echo -e "${GREEN}✓ Homebrew updated successfully${NC}"
    fi
else
    echo -e "${BLUE}[DRY RUN] Would run: brew update${NC}"
fi

################################################################################
# STEP 4: Preview Outdated Packages
################################################################################
print_section "Checking for Outdated Packages"

# Require jq for JSON parsing
if ! command -v jq >/dev/null 2>&1; then
    print_message "${RED}" "Error: jq is required"
    echo "Install with: brew install jq"
    exit 1
fi

# Single JSON call (faster, more reliable)
OUTDATED_JSON=$(brew outdated --json=v2 --greedy 2>/dev/null)

formulae_count=$(echo "$OUTDATED_JSON" | jq '.formulae | length')
casks_count=$(echo "$OUTDATED_JSON" | jq '.casks | length')

# Format for display
outdated_formulae=$(echo "$OUTDATED_JSON" | jq -r '.formulae[] | "\(.name) \(.installed_versions[0]) -> \(.current_version)"')
outdated_casks=$(echo "$OUTDATED_JSON" | jq -r '.casks[] | "\(.name) \(.installed_versions[0]) -> \(.current_version)"')

total_outdated=$((formulae_count + casks_count))

if [ $total_outdated -eq 0 ]; then
    print_message "${GREEN}" "All packages are up-to-date!"
    echo "No outdated packages found: $(date)" >> "$LOGFILE"

    # Skip to cleanup if nothing to upgrade
    print_section "Cleaning up"
    if [ "$DRY_RUN" = false ]; then
        cleanup_output=$(brew cleanup -s 2>&1)
        echo "$cleanup_output" >> "$LOGFILE"

        # Extract disk space saved
        space_saved=$(echo "$cleanup_output" | grep -o "[0-9.]*[KMGT]B" | tail -1)
        if [ -n "$space_saved" ]; then
            echo -e "${GREEN}✓ Cleanup complete - freed: $space_saved${NC}"
        else
            echo -e "${GREEN}✓ Cleanup complete${NC}"
        fi
    else
        echo -e "${BLUE}[DRY RUN] Would run: brew cleanup -s${NC}"
    fi

    # Calculate elapsed time
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    print_message "${GREEN}" "Homebrew Update Complete"
    echo -e "${CYAN}Total time: ${ELAPSED}s${NC}"
    exit 0
fi

echo -e "${YELLOW}Found $total_outdated outdated package(s):${NC}"
echo ""

if [ $formulae_count -gt 0 ]; then
    echo -e "${CYAN}Formulae ($formulae_count):${NC}"
    echo "$outdated_formulae" | while read -r line; do
        echo -e "  ${YELLOW}•${NC} $line"
    done
    echo ""
fi

if [ $casks_count -gt 0 ]; then
    echo -e "${CYAN}Casks ($casks_count):${NC}"
    echo "$outdated_casks" | while read -r line; do
        echo -e "  ${YELLOW}•${NC} $line"
    done
    echo ""
fi

# Log outdated packages
{
    echo "Outdated packages before upgrade:"
    echo "Formulae:"
    echo "$outdated_formulae"
    echo "Casks:"
    echo "$outdated_casks"
    echo ""
} >> "$LOGFILE"

if [ "$DRY_RUN" = true ]; then
    print_message "${BLUE}" "DRY RUN: Would upgrade $total_outdated package(s)"
    echo "Run without --dry-run to perform actual upgrade"
    exit 0
fi

################################################################################
# STEP 5: Upgrade Packages
################################################################################
print_section "Upgrading Packages"

# Build fast lookup map for IT-managed casks
declare -A IT_CASK_MAP
for cask in "${IT_MANAGED_CASKS[@]}"; do
    IT_CASK_MAP[$cask]=1
done

upgraded_formula_list=""
upgraded_cask_list=""
upgrade_status=0

# Upgrade formulae (doesn't require sudo — always safe to run)
if [ $formulae_count -gt 0 ]; then
    echo -e "${CYAN}Upgrading $formulae_count formulae...${NC}" | tee -a "$LOGFILE"
    set +e
    formula_output=$(brew upgrade --formula 2>&1)
    brew_exit_status=$?
    set -e
    echo "$formula_output" >> "$LOGFILE"

    if [ $brew_exit_status -ne 0 ]; then
        upgrade_status=1
        echo -e "${YELLOW}Warning: Some formula upgrades failed${NC}" | tee -a "$LOGFILE"
        echo "$formula_output" | sed 's/^/    /'
    else
        echo -e "${GREEN}✓ Formulae upgraded successfully${NC}"
        upgraded_formula_list="$outdated_formulae"
    fi

    # Check for unexpected sudo requests
    if echo "$formula_output" | grep -qE '(Password:|sudo:|\[sudo\]|need.*administrator|require.*sudo)'; then
        echo -e "${RED}⚠ UNEXPECTED SUDO REQUEST during formula upgrade!${NC}"
        echo -e "${YELLOW}Check $LOGFILE for details${NC}"
    fi
fi

# Upgrade casks (behavior depends on sudo availability)
if [ "$SUDO_AVAILABLE" = false ]; then
    # No sudo — skip all casks
    if [ $casks_count -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Skipping all casks due to sudo restrictions${NC}" | tee -a "$LOGFILE"
        echo -e "${CYAN}Skipped Casks ($casks_count):${NC}"
        echo "$outdated_casks" | while read -r line; do
            echo -e "  ${YELLOW}⊘${NC} $line ${RED}(requires sudo)${NC}"
        done | tee -a "$LOGFILE"
    fi
else
    # Upgrade casks individually, excluding IT-managed ones
    if [ $casks_count -gt 0 ]; then
        echo "" | tee -a "$LOGFILE"
        echo -e "${CYAN}Upgrading casks (excluding IT-managed)...${NC}" | tee -a "$LOGFILE"

        current=0
        total=$(echo "$outdated_casks" | wc -l | tr -d ' ')

        while read -r cask_line; do
            cask_name=$(echo "$cask_line" | awk '{print $1}')
            ((current++)) || true

            # Skip if in IT-managed list
            if [[ -n "${IT_CASK_MAP[$cask_name]:-}" ]]; then
                echo -e "${CYAN}[$current/$total]${NC} ${YELLOW}Skipping: $cask_name (IT-managed)${NC}" | tee -a "$LOGFILE"
                continue
            fi

            # Show progress
            echo -e "${CYAN}[$current/$total]${NC} Upgrading $cask_name..." | tee -a "$LOGFILE"

            # Upgrade this cask
            set +e
            cask_output=$(brew upgrade --cask "$cask_name" --greedy 2>&1)
            brew_exit_status=$?
            set -e
            echo "$cask_output" >> "$LOGFILE"

            if [ $brew_exit_status -ne 0 ]; then
                # Check for "already an App at" error — offer to force replace
                if echo "$cask_output" | grep -q "It seems there is already an App at"; then
                    echo -e "${YELLOW}  $cask_name: existing app detected in Caskroom${NC}"
                    read -p "  Force replace $cask_name? (y/N): " -n 1 -r < /dev/tty
                    echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        set +e
                        cask_output=$(brew upgrade --cask "$cask_name" --greedy --force 2>&1)
                        brew_exit_status=$?
                        set -e
                        echo "$cask_output" >> "$LOGFILE"

                        if [ $brew_exit_status -eq 0 ]; then
                            echo -e "${GREEN}  ✓ $cask_name force-upgraded${NC}"
                            upgraded_cask_list+="$cask_name"$'\n'
                        else
                            upgrade_status=1
                            echo -e "${RED}  Failed to force-upgrade $cask_name:${NC}" | tee -a "$LOGFILE"
                            echo "$cask_output" | sed 's/^/    /'
                        fi
                    else
                        upgrade_status=1
                        echo -e "${YELLOW}  Skipped $cask_name${NC}" | tee -a "$LOGFILE"
                    fi
                else
                    upgrade_status=1
                    echo -e "${RED}  Failed to upgrade $cask_name:${NC}" | tee -a "$LOGFILE"
                    echo "$cask_output" | sed 's/^/    /'
                fi
            else
                echo -e "${GREEN}  ✓ $cask_name upgraded${NC}"
                upgraded_cask_list+="$cask_name"$'\n'
            fi

            # Check for unexpected sudo requests
            if echo "$cask_output" | grep -qE '(Password:|sudo:|\[sudo\]|need.*administrator|require.*sudo)'; then
                echo -e "${RED}⚠ UNEXPECTED SUDO REQUEST for $cask_name!${NC}"
            fi
        done <<< "$outdated_casks"
    fi
fi

################################################################################
# STEP 6: Summary of Changes
################################################################################
print_section "Summary of Changes"

# Trim trailing newlines from tracked lists
upgraded_formula_list=$(echo "$upgraded_formula_list" | sed '/^$/d')
upgraded_cask_list=$(echo "$upgraded_cask_list" | sed '/^$/d')

# Count upgraded packages
if [ -z "$upgraded_formula_list" ]; then
    upgraded_formulae_count=0
else
    upgraded_formulae_count=$(echo "$upgraded_formula_list" | wc -l | tr -d ' ')
fi

if [ -z "$upgraded_cask_list" ]; then
    upgraded_casks_count=0
else
    upgraded_casks_count=$(echo "$upgraded_cask_list" | wc -l | tr -d ' ')
fi

if [ "$upgraded_formulae_count" -gt 0 ]; then
    echo -e "${GREEN}Upgraded Formulae ($upgraded_formulae_count):${NC}"
    echo "$upgraded_formula_list" | while read -r line; do
        echo -e "  ${GREEN}✓${NC} $line"
    done | tee -a "$LOGFILE"
    echo ""
fi

if [ "$upgraded_casks_count" -gt 0 ]; then
    echo -e "${GREEN}Upgraded Casks ($upgraded_casks_count):${NC}"
    echo "$upgraded_cask_list" | while read -r line; do
        echo -e "  ${GREEN}✓${NC} $line"
    done | tee -a "$LOGFILE"
    echo ""
fi

if [ "$upgraded_formulae_count" -eq 0 ] && [ "$upgraded_casks_count" -eq 0 ]; then
    echo -e "${YELLOW}No packages were upgraded${NC}" | tee -a "$LOGFILE" || true
    echo ""
fi

################################################################################
# STEP 7: Remove orphaned dependencies
################################################################################
print_section "Removing orphaned dependencies"

autoremove_output=$(brew autoremove 2>&1 || true)
echo "$autoremove_output" >> "$LOGFILE"

if echo "$autoremove_output" | grep -q "Autoremoving"; then
    echo -e "${GREEN}✓ Orphaned dependencies removed${NC}"
    echo "$autoremove_output" | sed 's/^/    /'
else
    echo -e "${GREEN}✓ No orphaned dependencies${NC}"
fi

################################################################################
# STEP 8: Cleanup
################################################################################
print_section "Cleaning up"
echo -e "${YELLOW}Removing old versions and clearing cache...${NC}"

cleanup_output=$(brew cleanup -s 2>&1 || true)
echo "$cleanup_output" >> "$LOGFILE"

# Extract disk space saved
space_saved=$(echo "$cleanup_output" | grep -o "[0-9.]*[KMGT]B" | tail -1 || echo "")
if [ -n "$space_saved" ]; then
    echo -e "${GREEN}✓ Cleanup complete - freed: $space_saved${NC}"
else
    echo -e "${GREEN}✓ Cleanup complete${NC}"
fi

################################################################################
# FINAL SUMMARY
################################################################################
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
print_message "${GREEN}" "Homebrew Update Complete"
echo ""
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}           FINAL SUMMARY${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${YELLOW}Total packages upgraded:${NC} $((upgraded_formulae_count + upgraded_casks_count))"
echo -e "${YELLOW}  • Formulae:${NC} $upgraded_formulae_count"
echo -e "${YELLOW}  • Casks:${NC} $upgraded_casks_count"
if [ -n "$space_saved" ]; then
    echo -e "${YELLOW}Disk space freed:${NC} $space_saved"
fi
if [ $MINUTES -gt 0 ]; then
    echo -e "${YELLOW}Total time:${NC} ${MINUTES}m ${SECONDS}s"
else
    echo -e "${YELLOW}Total time:${NC} ${SECONDS}s"
fi
echo -e "${YELLOW}Log file:${NC} $LOGFILE"
echo -e "${YELLOW}Brewfile backup:${NC} $BREWFILE_BACKUP"
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo ""

# Report upgrade errors if any occurred
if [ $upgrade_status -ne 0 ]; then
    echo -e "${RED}⚠ SOME UPGRADES FAILED${NC}"
    echo -e "${YELLOW}Check $LOGFILE for details${NC}"
    echo -e "${YELLOW}Failed casks may need manual intervention${NC}"
    echo ""
fi

# Log final summary
{
    echo ""
    echo "========================================"
    echo "Update completed: $(date)"
    echo "Total packages upgraded: $((upgraded_formulae_count + upgraded_casks_count))"
    echo "Time elapsed: ${ELAPSED}s"
    if [ $upgrade_status -ne 0 ]; then
        echo "Status: Completed with errors"
    else
        echo "Status: Success"
    fi
    echo "========================================"
} >> "$LOGFILE"

# Exit with appropriate status code
exit $upgrade_status
