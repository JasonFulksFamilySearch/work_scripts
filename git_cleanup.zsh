#!/bin/zsh

# ═══════════════════════════════════════════════
# Git Cleanup Script — JIRA Dev-Status Enhanced
# Phases: Pre-flight → Discovery & Enrichment →
#         Report & Cleanup → Remote-only listing →
#         Repo cleanup → Stash purge → Summary
# ═══════════════════════════════════════════════

# Define emojis
FETCH="🔄"
BRANCH="🌿"
GOOD="✅"
WARN="⚠️"
ERROR="❌"
QUESTION="❓"
FINISH="🏁"
MAGNIFY="🔍"
CLEANUP="🗑️"
JIRA_ICON="🎫"
CHART="📊"

# Color codes
RED=$'\033[38;5;196m'
GREEN=$'\033[38;5;34m'
YELLOW=$'\033[38;5;208m'
BLUE=$'\033[38;5;33m'
CYAN=$'\033[38;5;45m'
GRAY=$'\033[38;5;240m'
BOLD=$'\033[1m'
RESETC=$'\033[0m'

# Output helpers
info()    { printf '%b\n' "${BLUE}$1${RESETC}" >&2; }
success() { printf '%b\n' "${GREEN}$1${RESETC}" >&2; }
warn()    { printf '%b\n' "${YELLOW}$1${RESETC}" >&2; }
error()   { printf '%b\n' "${RED}$1${RESETC}" >&2; }
action()  { printf '%b\n' "${CYAN}$1${RESETC}" >&2; }

# Section header — creates strong visual break between phases
section_header() {
  local title="$1" emoji="$2" subtitle="$3"
  printf '\n\n' >&2
  printf '%b\n' "${BOLD}${BLUE}══════════════════════════════════════════════════${RESETC}" >&2
  printf '%b\n' "${BOLD}  ${emoji}  ${title}${RESETC}" >&2
  if [[ -n "$subtitle" ]]; then
    printf '%b\n' "${GRAY}  ${subtitle}${RESETC}" >&2
  fi
  printf '%b\n' "${BOLD}${BLUE}══════════════════════════════════════════════════${RESETC}" >&2
}

# Item separator with progress counter
item_separator() {
  local current="$1" total="$2"
  printf '\n' >&2
  printf '%b\n' "${GRAY}  ── [${current} of ${total}] ──────────────────────────────────${RESETC}" >&2
}

# Format size from KB to human-readable
format_size() {
  local kb=$1
  if (( kb >= 1048576 )); then
    printf '%.1f GB' $(( kb / 1048576.0 ))
  elif (( kb >= 1024 )); then
    printf '%.1f MB' $(( kb / 1024.0 ))
  else
    printf '%d KB' "$kb"
  fi
}

# Truncate a string to max length, appending ... if truncated
truncate_str() {
  local str="$1" max="$2"
  if (( ${#str} > max )); then
    echo "${str:0:$((max - 3))}..."
  else
    echo "$str"
  fi
}

# Always reset colors on exit
trap 'printf "\033[0m"' EXIT

# ── Branch record schema ──
# All BR_* arrays are indexed in parallel. Index i represents one branch.
# ALWAYS use _add_branch_record() to append — never append to arrays individually.
#
#   BR_NAME            Branch name (e.g., feat/ARC-1234-description)
#   BR_TYPE            "worktree" | "local" | "local+remote"
#   BR_WORKTREE_PATH   Worktree filesystem path, or "" if not a worktree
#   BR_TICKET          JIRA key (e.g., ARC-1234) or ""
#   BR_TICKET_ID       JIRA numeric ID or ""
#   BR_TICKET_STATUS   JIRA status name or ""
#   BR_TICKET_SUMMARY  JIRA summary or ""
#   BR_PR_MERGED       Count of merged PRs or ""
#   BR_PR_OPEN         Count of open PRs or ""
#   BR_PR_DECLINED     Count of declined PRs or ""
#   BR_COMMIT_COUNT    Commits linked in dev panel or ""
#   BR_ON_REMOTE       "yes" | "no"
#   BR_MERGED_MASTER   "yes" | "no"
#   BR_HAS_CHANGES     "staged" | "modified" | "clean" | "n/a" | "dir gone"
#   BR_WT_DIR_MISSING  "yes" | "no" | "n/a"
#   BR_RECOMMENDATION  "DELETE" | "KEEP" | "WARN_DELETE"
#   BR_REASON          Human-readable reason for recommendation
#   BR_DELETE_SCOPE    "local+remote" | "local" | "none"

typeset -a BR_NAME BR_TYPE BR_WORKTREE_PATH BR_TICKET BR_TICKET_ID
typeset -a BR_TICKET_STATUS BR_TICKET_SUMMARY
typeset -a BR_PR_MERGED BR_PR_OPEN BR_PR_DECLINED BR_COMMIT_COUNT
typeset -a BR_ON_REMOTE BR_MERGED_MASTER BR_HAS_CHANGES BR_WT_DIR_MISSING
typeset -a BR_RECOMMENDATION BR_REASON BR_DELETE_SCOPE
typeset -A JIRA_CACHE        # ticket -> "numericId|status|summary"
typeset -A JIRA_DEV_CACHE    # ticket -> "mergedPRs|openPRs|declinedPRs|commits"
typeset -A REMOTE_BRANCHES   # branch_name -> 1

# ── Global stats ──
typeset -i STAT_BRANCHES_SCANNED=0 STAT_WORKTREES_SCANNED=0
typeset -i STAT_JIRA_QUERIED=0 STAT_DEVSTATUS_QUERIED=0 STAT_DEVSTATUS_SKIPPED=0
typeset -i STAT_RECOMMEND_DELETE=0 STAT_RECOMMEND_WARN=0 STAT_RECOMMEND_KEEP=0
typeset -i STAT_DELETED_LOCAL=0 STAT_DELETED_REMOTE=0 STAT_WORKTREES_REMOVED=0 STAT_SKIPPED=0
typeset -i STAT_REMOTE_ONLY=0
typeset    STAT_JIRA_STATUS="skipped"
typeset -i STAT_DISK_BEFORE=0 STAT_DISK_AFTER=0
typeset    STAT_STASH="kept"
typeset -i STAT_STASH_COUNT=0
typeset -i STAT_API_CALLS=0

# ── Default branch & dev-status availability ──
typeset DEFAULT_BRANCH="master"
typeset -i DEV_STATUS_AVAILABLE=1
typeset GH_REPO=""  # owner/repo slug, detected in preflight

# ── Done statuses (used by enrichment and decision matrix) ──
DONE_STATUSES=("Done" "Closed" "Resolved" "Released" "Cancelled" "Won't Do" "Won't Fix")

# ── Branches to always exclude from cleanup ──
EXCLUDED_BRANCHES=("chore/pr-review")

# ═══════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════

_delete_remote_branch() {
  local branch="$1"
  if [[ -n "$GH_REPO" ]]; then
    # URL-encode slashes in branch name (e.g., feat/ARC-1234 → feat%2FARC-1234)
    local encoded_branch="${branch//\//%2F}"
    gh api --method DELETE "repos/${GH_REPO}/git/refs/heads/${encoded_branch}" 2>/dev/null
  else
    git push origin --delete --no-verify "$branch" 2>/dev/null
  fi
}

extract_jira_ticket() {
  local branch_name="$1"
  if [[ "$branch_name" =~ ([A-Z]+-[0-9]+) ]]; then
    echo "${match[1]}"
  fi
}

_load_remote_branches() {
  local line
  while IFS= read -r line; do
    # Format: <sha>\trefs/heads/<branch_name>
    local ref="${line##*/}"
    REMOTE_BRANCHES[$ref]=1
  done < <(git ls-remote --heads origin 2>/dev/null)
}

branch_exists_remote() {
  [[ -n "${REMOTE_BRANCHES[$1]:-}" ]]
}

_add_branch_record() {
  # Usage: _add_branch_record <name> <type> <wt_path> <on_remote> <merged_master> <has_changes> <wt_dir_missing>
  BR_NAME+=("$1")
  BR_TYPE+=("$2")
  BR_WORKTREE_PATH+=("${3:-}")
  BR_TICKET+=("$(extract_jira_ticket "$1")")
  BR_TICKET_ID+=("")
  BR_TICKET_STATUS+=("")
  BR_TICKET_SUMMARY+=("")
  BR_PR_MERGED+=("")
  BR_PR_OPEN+=("")
  BR_PR_DECLINED+=("")
  BR_COMMIT_COUNT+=("")
  BR_ON_REMOTE+=("$4")
  BR_MERGED_MASTER+=("$5")
  BR_HAS_CHANGES+=("${6:-n/a}")
  BR_WT_DIR_MISSING+=("${7:-n/a}")
  BR_RECOMMENDATION+=("")
  BR_REASON+=("")
  BR_DELETE_SCOPE+=("")
}

check_worktree_changes() {
  local path="$1"
  [[ ! -d "$path" ]] && { echo "dir gone"; return; }

  local porcelain
  porcelain=$(cd "$path" && git status --porcelain 2>/dev/null)

  if [[ -z "$porcelain" ]]; then
    echo "clean"
  elif echo "$porcelain" | grep -q '^[MADRC]'; then
    echo "staged"
  else
    echo "modified"
  fi
}

_is_done_status() {
  local check_status="$1"
  for ds in "${DONE_STATUSES[@]}"; do
    [[ "$check_status" == "$ds" ]] && return 0
  done
  return 1
}

# ═══════════════════════════════════════════════
# PRE-FLIGHT
# ═══════════════════════════════════════════════

preflight() {
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    error "$ERROR Not in a git repository!"
    exit 1
  fi
  success "$GOOD Found git repository"

  action "$FETCH Fetching latest remote state and pruning stale refs..."
  git fetch --quiet --prune
  success "$GOOD Remote state updated"

  # Detect default branch (master vs main vs other)
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [[ -z "$DEFAULT_BRANCH" ]]; then
    if git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
      DEFAULT_BRANCH="master"
    elif git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
      DEFAULT_BRANCH="main"
    else
      DEFAULT_BRANCH="master"
    fi
  fi
  info "  Default branch: $DEFAULT_BRANCH"

  # Detect GitHub repo slug for gh API calls
  GH_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
  if [[ -n "$GH_REPO" ]]; then
    info "  GitHub repo: $GH_REPO"
  else
    warn "  $WARN Could not detect GitHub repo — remote branch deletion will fall back to git push"
  fi
}

# ═══════════════════════════════════════════════
# JIRA API FUNCTIONS
# ═══════════════════════════════════════════════

load_jira_config() {
  if [[ -z "${JIRA_EMAIL:-}" ]] || [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    return 1
  fi
  JIRA_BASE_URL="${JIRA_BASE_URL:-https://icseng.atlassian.net}"
  # Strip trailing slash to prevent double-slash in API paths
  JIRA_BASE_URL="${JIRA_BASE_URL%/}"
  return 0
}

test_jira_connection() {
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/api/3/myself" 2>/dev/null)
  STAT_API_CALLS=$((STAT_API_CALLS + 1))
  [[ "$http_code" == "200" ]]
}

bulk_query_jira() {
  # Collect unique tickets from BR_TICKET
  local -A seen_tickets
  local -a ticket_list
  for ticket in "${BR_TICKET[@]}"; do
    [[ -z "$ticket" ]] && continue
    [[ -n "${seen_tickets[$ticket]:-}" ]] && continue
    seen_tickets[$ticket]=1
    ticket_list+=("$ticket")
  done

  local total=${#ticket_list[@]}
  [[ $total -eq 0 ]] && return

  STAT_JIRA_QUERIED=$total

  # Build JQL IN clause
  local jql_keys=""
  for ticket in "${ticket_list[@]}"; do
    [[ -n "$jql_keys" ]] && jql_keys+=", "
    jql_keys+="$ticket"
  done

  action "  $MAGNIFY Fetching $total JIRA ticket(s) in bulk..."

  local response
  response=$(curl -s \
    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"jql\": \"key in ($jql_keys)\", \"fields\": [\"status\", \"summary\"], \"maxResults\": 100}" \
    "${JIRA_BASE_URL}/rest/api/3/search/jql" 2>/dev/null)
  STAT_API_CALLS=$((STAT_API_CALLS + 1))

  [[ -z "$response" ]] && { warn "  $WARN Empty response from JIRA search"; return 1; }

  # Parse each issue from the response
  local parsed_count=0

  if command -v jq &>/dev/null; then
    local issue_count
    issue_count=$(echo "$response" | jq -r '.issues | length // 0' 2>/dev/null)
    [[ "$issue_count" == "0" || -z "$issue_count" ]] && { warn "  $WARN No issues returned from JIRA"; return 1; }

    local key id jira_status summary
    for (( idx=0; idx < issue_count; idx++ )); do
      key=$(echo "$response" | jq -r ".issues[$idx].key // empty" 2>/dev/null)
      id=$(echo "$response" | jq -r ".issues[$idx].id // empty" 2>/dev/null)
      jira_status=$(echo "$response" | jq -r ".issues[$idx].fields.status.name // empty" 2>/dev/null)
      summary=$(echo "$response" | jq -r ".issues[$idx].fields.summary // empty" 2>/dev/null)
      [[ -z "$key" ]] && continue
      JIRA_CACHE[$key]="${id}|${jira_status}|${summary}"
      parsed_count=$((parsed_count + 1))
    done
  elif command -v python3 &>/dev/null; then
    # Use process substitution instead of pipe to avoid subshell variable loss
    local line
    while IFS= read -r line; do
      local key="${line%%|*}"
      local rest="${line#*|}"
      [[ -z "$key" ]] && continue
      JIRA_CACHE[$key]="$rest"
      parsed_count=$((parsed_count + 1))
    done < <(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for issue in d.get('issues', []):
        key = issue.get('key', '')
        iid = issue.get('id', '')
        status = issue.get('fields', {}).get('status', {}).get('name', '')
        summary = issue.get('fields', {}).get('summary', '')
        if key:
            print(f'{key}|{iid}|{status}|{summary}')
except: pass" 2>/dev/null)
  else
    warn "  $WARN Neither jq nor python3 found. Cannot parse JIRA response."
    return 1
  fi

  success "  $GOOD Fetched $parsed_count ticket(s)"
}

query_jira_dev_status() {
  local numeric_id="$1" ticket="$2"

  # Skip if endpoint already known to be unavailable
  [[ $DEV_STATUS_AVAILABLE -eq 0 ]] && return 1

  # Check cache
  if [[ -n "${JIRA_DEV_CACHE[$ticket]:-}" ]]; then
    echo "${JIRA_DEV_CACHE[$ticket]}"
    return 0
  fi

  sleep 0.3

  local response http_code tmp_file
  tmp_file=$(mktemp)
  http_code=$(curl -s -o "$tmp_file" -w "%{http_code}" \
    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${JIRA_BASE_URL}/rest/dev-status/1.0/issue/summary?issueId=${numeric_id}" 2>/dev/null)
  response=$(<"$tmp_file")
  rm -f "$tmp_file"
  STAT_API_CALLS=$((STAT_API_CALLS + 1))

  # Handle endpoint failure — disable for rest of run
  if [[ "$http_code" != "200" ]]; then
    DEV_STATUS_AVAILABLE=0
    warn "  $WARN Dev-status API returned $http_code — falling back to ticket status only"
    return 1
  fi

  # Validate response shape
  local has_structure
  if command -v jq &>/dev/null; then
    has_structure=$(echo "$response" | jq -r 'if .summary.pullrequest then "yes" else "no" end' 2>/dev/null)
  elif command -v python3 &>/dev/null; then
    has_structure=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if 'pullrequest' in d.get('summary', {}) else 'no')
except: print('no')" 2>/dev/null)
  fi

  if [[ "$has_structure" != "yes" ]]; then
    DEV_STATUS_AVAILABLE=0
    warn "  $WARN Dev-status API response shape unexpected — falling back to ticket status only"
    return 1
  fi

  # Parse PR and commit counts
  local merged_count open_count declined_count commit_count
  if command -v jq &>/dev/null; then
    merged_count=$(echo "$response" | jq -r '.summary.pullrequest.overall.merged // 0' 2>/dev/null)
    open_count=$(echo "$response" | jq -r '.summary.pullrequest.overall.open // 0' 2>/dev/null)
    declined_count=$(echo "$response" | jq -r '.summary.pullrequest.overall.declined // 0' 2>/dev/null)
    commit_count=$(echo "$response" | jq -r '.summary.repository.overall.count // 0' 2>/dev/null)
  elif command -v python3 &>/dev/null; then
    local parsed
    parsed=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    pr = d.get('summary',{}).get('pullrequest',{}).get('overall',{})
    repo = d.get('summary',{}).get('repository',{}).get('overall',{})
    print(f\"{pr.get('merged',0)}|{pr.get('open',0)}|{pr.get('declined',0)}|{repo.get('count',0)}\")
except: print('0|0|0|0')" 2>/dev/null)
    merged_count="${parsed%%|*}"
    local rest="${parsed#*|}"
    open_count="${rest%%|*}"
    rest="${rest#*|}"
    declined_count="${rest%%|*}"
    commit_count="${rest#*|}"
  fi

  # Default any empty values to 0
  merged_count="${merged_count:-0}"
  open_count="${open_count:-0}"
  declined_count="${declined_count:-0}"
  commit_count="${commit_count:-0}"

  JIRA_DEV_CACHE[$ticket]="${merged_count}|${open_count}|${declined_count}|${commit_count}"
  echo "${merged_count}|${open_count}|${declined_count}|${commit_count}"
  return 0
}

# ═══════════════════════════════════════════════
# PHASE 1: DISCOVERY & ENRICHMENT
# ═══════════════════════════════════════════════

discover_branches() {
  section_header "Phase 1: Discovery & Enrichment" "$MAGNIFY" "Scanning worktrees and branches..."

  # Load all remote branches in one call
  action "  $FETCH Loading remote branch list..."
  _load_remote_branches
  STAT_API_CALLS=$((STAT_API_CALLS + 1))

  local main_worktree current_dir current_branch
  main_worktree=$(git worktree list --porcelain | head -n 1 | sed 's/^worktree //')
  current_dir=$(pwd -P)
  current_branch=$(git rev-parse --abbrev-ref HEAD)

  # ── Scan worktrees ──
  local porcelain_output
  porcelain_output=$(git worktree list --porcelain 2>/dev/null)

  local wt_path="" wt_branch="" wt_detached=0
  local -a discovered_branches

  _process_worktree_block() {
    [[ -z "$wt_path" ]] && return
    [[ "$wt_path" == "$main_worktree" ]] && { wt_path=""; return; }
    [[ "$wt_path" == "$current_dir" ]] && { wt_path=""; return; }

    if [[ $wt_detached -eq 1 ]]; then
      wt_path=""
      return
    fi

    [[ -z "$wt_branch" ]] && { wt_path=""; return; }

    # Skip excluded branches
    for excl in "${EXCLUDED_BRANCHES[@]}"; do
      [[ "$wt_branch" == "$excl" ]] && { wt_path=""; return; }
    done

    STAT_WORKTREES_SCANNED=$((STAT_WORKTREES_SCANNED + 1))
    discovered_branches+=("$wt_branch")

    local on_remote="no"
    branch_exists_remote "$wt_branch" && on_remote="yes"

    local merged="no"
    git merge-base --is-ancestor "$wt_branch" "$DEFAULT_BRANCH" 2>/dev/null && merged="yes"

    local dir_missing="no"
    [[ ! -d "$wt_path" ]] && dir_missing="yes"

    local changes
    if [[ "$dir_missing" == "yes" ]]; then
      changes="dir gone"
    else
      changes=$(check_worktree_changes "$wt_path")
    fi

    _add_branch_record "$wt_branch" "worktree" "$wt_path" "$on_remote" "$merged" "$changes" "$dir_missing"
    wt_path=""
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == worktree\ * ]]; then
      wt_path="${line#worktree }"
      wt_branch=""
      wt_detached=0
    elif [[ "$line" == branch\ * ]]; then
      wt_branch="${line#branch refs/heads/}"
    elif [[ "$line" == "detached" ]]; then
      wt_detached=1
    elif [[ -z "$line" ]]; then
      _process_worktree_block
    fi
  done <<< "$porcelain_output"
  _process_worktree_block

  # ── Scan local branches (non-worktree) ──
  for branch in $(git for-each-ref --format '%(refname:short)' refs/heads/); do
    [[ "$branch" == "$current_branch" ]] && continue
    [[ "$branch" == "$DEFAULT_BRANCH" ]] && continue

    # Skip excluded branches
    local is_excluded=0
    for excl in "${EXCLUDED_BRANCHES[@]}"; do
      [[ "$branch" == "$excl" ]] && { is_excluded=1; break; }
    done
    [[ $is_excluded -eq 1 ]] && continue

    # Skip branches already discovered via worktrees
    local already_found=0
    for db in "${discovered_branches[@]}"; do
      [[ "$db" == "$branch" ]] && { already_found=1; break; }
    done
    [[ $already_found -eq 1 ]] && continue

    local on_remote="no"
    branch_exists_remote "$branch" && on_remote="yes"

    local merged="no"
    git merge-base --is-ancestor "$branch" "$DEFAULT_BRANCH" 2>/dev/null && merged="yes"

    local br_type="local"
    [[ "$on_remote" == "yes" ]] && br_type="local+remote"

    _add_branch_record "$branch" "$br_type" "" "$on_remote" "$merged" "n/a" "n/a"
  done

  # ── Scan remote-only branches (only those where we were last committer) ──
  local my_email
  my_email=$(git config user.email)

  local ref_line ref_short ref_email branch_name
  while IFS=$'\t' read -r ref_short ref_email; do
    branch_name="${ref_short#origin/}"

    [[ "$branch_name" == "HEAD" ]] && continue
    [[ "$branch_name" == "$ref_short" ]] && continue
    [[ "$branch_name" == "$current_branch" ]] && continue
    [[ "$branch_name" == "$DEFAULT_BRANCH" ]] && continue

    # Only include branches where we were the last committer
    [[ "$ref_email" != "$my_email" ]] && continue

    # Skip excluded branches
    local is_excluded=0
    for excl in "${EXCLUDED_BRANCHES[@]}"; do
      [[ "$branch_name" == "$excl" ]] && { is_excluded=1; break; }
    done
    [[ $is_excluded -eq 1 ]] && continue

    # Skip branches already discovered (have a local branch)
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      continue
    fi

    local merged="no"
    git merge-base --is-ancestor "origin/$branch_name" "$DEFAULT_BRANCH" 2>/dev/null && merged="yes"

    _add_branch_record "$branch_name" "remote-only" "" "yes" "$merged" "n/a" "n/a"
    STAT_REMOTE_ONLY=$((STAT_REMOTE_ONLY + 1))
  done < <(git for-each-ref --format='%(refname:short)%09%(authoremail:trim)' refs/remotes/origin/)

  STAT_BRANCHES_SCANNED=${#BR_NAME[@]}

  # Count branches with tickets
  local ticket_count=0
  for t in "${BR_TICKET[@]}"; do
    [[ -n "$t" ]] && ticket_count=$((ticket_count + 1))
  done

  success "  $GOOD Found ${STAT_BRANCHES_SCANNED} branch(es) (${STAT_WORKTREES_SCANNED} worktrees, ${STAT_REMOTE_ONLY} remote-only, ${ticket_count} with JIRA tickets)"
}

enrich_jira() {
  if ! load_jira_config; then
    STAT_JIRA_STATUS="skipped (no credentials)"
    printf '\n' >&2
    warn "  $WARN JIRA enrichment skipped — credentials not configured"
    info "  To enable, set these environment variables:"
    info "    export JIRA_EMAIL='your-email@familysearch.org'"
    info "    export JIRA_API_TOKEN='your-api-token'"
    info "    export JIRA_BASE_URL='https://icseng.atlassian.net'  # optional"
    return
  fi

  action "  $MAGNIFY Testing JIRA connection..."
  if ! test_jira_connection; then
    STAT_JIRA_STATUS="skipped (connection failed)"
    warn "  $WARN Check your JIRA_EMAIL and JIRA_API_TOKEN."
    return
  fi

  STAT_JIRA_STATUS="checked"

  # Pass 1: Bulk ticket fetch (1 API call)
  bulk_query_jira

  # Populate branch records from cache
  local total=${#BR_NAME[@]}
  local ticket cached numeric_id rest ticket_status summary

  for (( i=1; i <= total; i++ )); do
    ticket="${BR_TICKET[$i]}"
    [[ -z "$ticket" ]] && continue

    cached="${JIRA_CACHE[$ticket]:-}"
    [[ -z "$cached" ]] && continue

    # Parse: numericId|status|summary
    numeric_id="${cached%%|*}"
    rest="${cached#*|}"
    ticket_status="${rest%%|*}"
    summary="${rest#*|}"

    BR_TICKET_ID[$i]="$numeric_id"
    BR_TICKET_STATUS[$i]="$ticket_status"
    BR_TICKET_SUMMARY[$i]="$summary"
  done

  # Pass 2: Selective dev-status (only for active tickets)
  local dev_total=0 dev_done=0
  local -a dev_indices

  for (( i=1; i <= total; i++ )); do
    ticket="${BR_TICKET[$i]}"
    [[ -z "$ticket" ]] && continue
    numeric_id="${BR_TICKET_ID[$i]}"
    [[ -z "$numeric_id" ]] && continue
    ticket_status="${BR_TICKET_STATUS[$i]}"

    # Skip done tickets — dev-status won't change the recommendation
    if _is_done_status "$ticket_status"; then
      STAT_DEVSTATUS_SKIPPED=$((STAT_DEVSTATUS_SKIPPED + 1))
      continue
    fi

    dev_indices+=($i)
  done

  dev_total=${#dev_indices[@]}

  if [[ $dev_total -gt 0 ]]; then
    action "  $MAGNIFY Checking dev-status for $dev_total active ticket(s)..."

    local dev_count=0
    for idx in "${dev_indices[@]}"; do
      dev_count=$((dev_count + 1))
      local ticket="${BR_TICKET[$idx]}"
      local numeric_id="${BR_TICKET_ID[$idx]}"

      printf '\r%b' "  ${GRAY}${MAGNIFY} Dev-status ${dev_count} of ${dev_total}: ${ticket}...${RESETC}" >&2

      local result
      result=$(query_jira_dev_status "$numeric_id" "$ticket") || continue

      STAT_DEVSTATUS_QUERIED=$((STAT_DEVSTATUS_QUERIED + 1))

      # Parse: mergedPRs|openPRs|declinedPRs|commits
      local merged="${result%%|*}"
      local rest="${result#*|}"
      local open="${rest%%|*}"
      rest="${rest#*|}"
      local declined="${rest%%|*}"
      local commits="${rest#*|}"

      BR_PR_MERGED[$idx]="$merged"
      BR_PR_OPEN[$idx]="$open"
      BR_PR_DECLINED[$idx]="$declined"
      BR_COMMIT_COUNT[$idx]="$commits"
    done

    # Clear progress line
    printf '\r%80s\r' '' >&2
  fi

  success "  $GOOD JIRA enrichment complete (${STAT_API_CALLS} API calls)"
}

# ═══════════════════════════════════════════════
# DECISION MATRIX
# ═══════════════════════════════════════════════

apply_decision_matrix() {
  local total=${#BR_NAME[@]}
  local recommendation reason scope
  local on_remote merged has_changes dir_missing ticket ticket_status
  local pr_merged pr_open pr_declined base_scope

  for (( i=1; i <= total; i++ )); do
    recommendation=""
    reason=""
    scope="none"

    on_remote="${BR_ON_REMOTE[$i]}"
    merged="${BR_MERGED_MASTER[$i]}"
    has_changes="${BR_HAS_CHANGES[$i]}"
    dir_missing="${BR_WT_DIR_MISSING[$i]}"
    ticket="${BR_TICKET[$i]}"
    ticket_status="${BR_TICKET_STATUS[$i]}"
    pr_merged="${BR_PR_MERGED[$i]:-0}"
    pr_open="${BR_PR_OPEN[$i]:-0}"
    pr_declined="${BR_PR_DECLINED[$i]:-0}"

    # Determine delete scope based on branch type and remote presence
    local br_type="${BR_TYPE[$i]}"
    if [[ "$br_type" == "remote-only" ]]; then
      base_scope="remote"
    elif [[ "$on_remote" == "yes" ]]; then
      base_scope="local+remote"
    else
      base_scope="local"
    fi

    # Decision logic in priority order
    if [[ "$dir_missing" == "yes" ]]; then
      recommendation="DELETE"
      reason="worktree directory missing"
      scope="$base_scope"

    elif [[ "$pr_open" -gt 0 ]] 2>/dev/null; then
      recommendation="KEEP"
      reason="Open PR(s)"

    elif [[ "$pr_merged" -gt 0 ]] 2>/dev/null; then
      if [[ "$has_changes" == "staged" ]]; then
        recommendation="WARN_DELETE"
        reason="PR merged but worktree has staged (uncommitted) changes"
        scope="$base_scope"
      elif [[ "$has_changes" == "modified" ]]; then
        recommendation="WARN_DELETE"
        reason="PR merged but worktree has modified files"
        scope="$base_scope"
      else
        recommendation="DELETE"
        reason="All PRs merged"
        scope="$base_scope"
      fi

    elif [[ -n "$ticket" && "$pr_declined" -gt 0 ]] 2>/dev/null; then
      if _is_done_status "$ticket_status"; then
        recommendation="DELETE"
        reason="PR(s) declined, ticket $ticket_status"
        scope="$base_scope"
      else
        recommendation="KEEP"
        reason="PR(s) declined, ticket active ($ticket_status) — may be reworked"
      fi

    elif [[ -n "$ticket" && -n "$ticket_status" ]]; then
      if _is_done_status "$ticket_status"; then
        recommendation="DELETE"
        reason="Ticket $ticket_status, no dev activity"
        scope="$base_scope"
      else
        recommendation="KEEP"
        reason="Ticket active ($ticket_status)"
      fi

    elif [[ -z "$ticket" ]]; then
      # No JIRA ticket — fall back to git-only heuristics
      if [[ "$on_remote" == "no" ]] || [[ "$merged" == "yes" ]]; then
        recommendation="DELETE"
        reason="No JIRA ticket; not on remote / merged into $DEFAULT_BRANCH"
        scope="$base_scope"
      else
        recommendation="KEEP"
        reason="No JIRA ticket; still on remote, not merged"
      fi

    else
      # Ticket exists but JIRA returned no data — fall back to git heuristics
      if [[ "$on_remote" == "no" ]] || [[ "$merged" == "yes" ]]; then
        recommendation="DELETE"
        reason="Ticket not found in JIRA; not on remote / merged into $DEFAULT_BRANCH"
        scope="$base_scope"
      else
        recommendation="KEEP"
        reason="Ticket not found in JIRA; still on remote, not merged"
      fi
    fi

    BR_RECOMMENDATION[$i]="$recommendation"
    BR_REASON[$i]="$reason"
    BR_DELETE_SCOPE[$i]="$scope"

    case "$recommendation" in
      DELETE)      STAT_RECOMMEND_DELETE=$((STAT_RECOMMEND_DELETE + 1)) ;;
      WARN_DELETE) STAT_RECOMMEND_WARN=$((STAT_RECOMMEND_WARN + 1)) ;;
      KEEP)        STAT_RECOMMEND_KEEP=$((STAT_RECOMMEND_KEEP + 1)) ;;
    esac
  done
}

# ═══════════════════════════════════════════════
# PHASE 2: REPORT & CLEANUP
# ═══════════════════════════════════════════════

print_report_table() {
  local total=${#BR_NAME[@]}

  section_header "Phase 2: Branch Analysis Report" "$CHART" "Scanned $total branch(es)"

  if [[ $total -eq 0 ]]; then
    success "  $GOOD No branches to analyze."
    return
  fi

  printf '\n' >&2

  # Column widths
  local -i COL_NUM=4 COL_WT=4 COL_RMT=5 COL_BRANCH=40 COL_TICKET=12 COL_STATUS=12 COL_PRS=12 COL_CHG=10 COL_ACT=6

  # Table header
  printf '%b' "  ${BOLD}" >&2
  printf "%-${COL_NUM}s %-${COL_WT}s %-${COL_RMT}s %-${COL_BRANCH}s %-${COL_TICKET}s %-${COL_STATUS}s %-${COL_PRS}s %-${COL_CHG}s %s" \
    "#" "WT" "Rmt" "Branch" "Ticket" "Status" "PRs(M/O/D)" "Changes" "Action" >&2
  printf '%b\n' "${RESETC}" >&2

  printf '  %b' "${GRAY}" >&2
  printf "%-${COL_NUM}s %-${COL_WT}s %-${COL_RMT}s %-${COL_BRANCH}s %-${COL_TICKET}s %-${COL_STATUS}s %-${COL_PRS}s %-${COL_CHG}s %s" \
    "──" "──" "───" "────────────────────────────────────────" "────────────" "────────────" "────────────" "──────────" "──────" >&2
  printf '%b\n' "${RESETC}" >&2

  local branch_display ticket_display status_display pr_display changes_display wt_display rmt_display
  local rec action_color action_display

  for (( i=1; i <= total; i++ )); do
    branch_display=$(truncate_str "${BR_NAME[$i]}" $((COL_BRANCH - 2)))
    ticket_display="${BR_TICKET[$i]:---}"
    status_display=$(truncate_str "${BR_TICKET_STATUS[$i]:---}" $((COL_STATUS - 2)))

    # Worktree indicator column
    wt_display=""
    [[ "${BR_TYPE[$i]}" == "worktree" ]] && wt_display="✓"

    # Remote indicator column
    rmt_display=""
    if [[ "${BR_ON_REMOTE[$i]}" == "yes" ]]; then
      rmt_display="✓"
    else
      rmt_display="${RED}✗${RESETC}"
    fi

    pr_display="--"
    if [[ -n "${BR_PR_MERGED[$i]}" ]]; then
      pr_display="${BR_PR_MERGED[$i]}/${BR_PR_OPEN[$i]}/${BR_PR_DECLINED[$i]}"
    fi

    changes_display="${BR_HAS_CHANGES[$i]:-n/a}"
    rec="${BR_RECOMMENDATION[$i]}"

    # Color-code the action column
    action_color=""
    action_display=""
    case "$rec" in
      DELETE)      action_color="$RED"; action_display="DELETE" ;;
      WARN_DELETE) action_color="$YELLOW"; action_display="WARN" ;;
      KEEP)        action_color="$GREEN"; action_display="KEEP" ;;
    esac

    printf '  ' >&2
    printf "%-${COL_NUM}s " "$i" >&2
    printf "%-${COL_WT}s " "$wt_display" >&2
    printf '%b%-4s' "$rmt_display" "" >&2
    printf "%-${COL_BRANCH}s " "$branch_display" >&2
    printf "%-${COL_TICKET}s " "$ticket_display" >&2
    printf "%-${COL_STATUS}s " "$status_display" >&2
    printf "%-${COL_PRS}s " "$pr_display" >&2
    printf "%-${COL_CHG}s " "$changes_display" >&2
    printf '%b%s%b' "$action_color" "$action_display" "$RESETC" >&2
    printf '\n' >&2
  done

  # Footer
  printf '  %b' "${GRAY}" >&2
  printf "%-${COL_NUM}s %-${COL_WT}s %-${COL_RMT}s %-${COL_BRANCH}s %-${COL_TICKET}s %-${COL_STATUS}s %-${COL_PRS}s %-${COL_CHG}s %s" \
    "──" "──" "───" "────────────────────────────────────────" "────────────" "────────────" "────────────" "──────────" "──────" >&2
  printf '%b\n' "${RESETC}" >&2

  printf '  %b\n' "${BOLD}Summary:${RESETC} ${RED}${STAT_RECOMMEND_DELETE} to delete${RESETC}, ${YELLOW}${STAT_RECOMMEND_WARN} warning(s)${RESETC}, ${GREEN}${STAT_RECOMMEND_KEEP} to keep${RESETC}" >&2
}

walk_through_deletions() {
  # Collect indices of branches recommended for action
  local -a action_indices
  local total=${#BR_NAME[@]}
  local rec

  for (( i=1; i <= total; i++ )); do
    rec="${BR_RECOMMENDATION[$i]}"
    [[ "$rec" == "DELETE" || "$rec" == "WARN_DELETE" ]] && action_indices+=($i)
  done

  local action_total=${#action_indices[@]}

  if [[ $action_total -eq 0 ]]; then
    printf '\n' >&2
    success "  $GOOD No branches recommended for deletion."
    return
  fi

  section_header "Branch Cleanup" "$CLEANUP" "$action_total branch(es) recommended for action"

  # One-time help legend
  printf '\n' >&2
  printf '%b\n' "  ${GRAY}Options at each prompt:${RESETC}" >&2
  printf '%b\n' "  ${BOLD}y${RESETC}${GRAY} = delete local + remote  ${BOLD}N${RESETC}${GRAY} = skip (default)${RESETC}" >&2
  printf '%b\n' "  ${BOLD}l${RESETC}${GRAY} = delete local only      ${BOLD}r${RESETC}${GRAY} = delete remote only${RESETC}" >&2
  printf '%b\n' "  ${BOLD}a${RESETC}${GRAY} = auto-confirm all remaining deletions${RESETC}" >&2

  local auto_confirm=0
  local action_count=0
  local branch reason scope ticket summary ticket_status
  local pr_merged pr_open pr_declined wt_path br_type has_changes

  for idx in "${action_indices[@]}"; do
    action_count=$((action_count + 1))

    branch="${BR_NAME[$idx]}"
    rec="${BR_RECOMMENDATION[$idx]}"
    reason="${BR_REASON[$idx]}"
    scope="${BR_DELETE_SCOPE[$idx]}"
    ticket="${BR_TICKET[$idx]}"
    summary="${BR_TICKET_SUMMARY[$idx]}"
    ticket_status="${BR_TICKET_STATUS[$idx]}"
    pr_merged="${BR_PR_MERGED[$idx]}"
    pr_open="${BR_PR_OPEN[$idx]}"
    pr_declined="${BR_PR_DECLINED[$idx]}"
    wt_path="${BR_WORKTREE_PATH[$idx]}"
    br_type="${BR_TYPE[$idx]}"
    has_changes="${BR_HAS_CHANGES[$idx]}"

    item_separator $action_count $action_total

    # Show recommendation header
    if [[ "$rec" == "WARN_DELETE" ]]; then
      warn "  $WARN WARN: DELETE ($scope)"
    else
      if [[ $auto_confirm -eq 1 ]]; then
        info "  [auto] DELETE ($scope)"
      else
        info "  DELETE ($scope)"
      fi
    fi

    # Show branch details
    info "    Branch:  $branch"
    [[ "$br_type" == "worktree" && -n "$wt_path" ]] && info "    Worktree: $wt_path"
    if [[ -n "$ticket" ]]; then
      info "    Ticket:  $ticket${summary:+ — $summary}"
      [[ -n "$ticket_status" ]] && info "    Status:  $ticket_status"
      if [[ -n "$pr_merged" ]]; then
        info "    PRs:     $pr_merged merged, $pr_open open, $pr_declined declined"
      fi
    fi
    info "    Reason:  $reason"

    # Show warning for uncommitted changes
    if [[ "$rec" == "WARN_DELETE" ]]; then
      if [[ "$has_changes" == "staged" ]]; then
        warn "    $WARN WARNING: Worktree has staged (uncommitted) changes!"
      elif [[ "$has_changes" == "modified" ]]; then
        warn "    $WARN WARNING: Worktree has modified files!"
      fi
    fi

    # Prompt for action (unless auto-confirming)
    local confirm="y"
    if [[ $auto_confirm -eq 0 ]]; then
      printf '\n%b' "  ${YELLOW}${QUESTION} Delete this branch? [y/N/l/r/a]: ${RESETC}" >&2
      read -r confirm </dev/tty

      # Handle "a" (delete all) with confirmation gate
      if [[ "$confirm" =~ ^[Aa]$ ]]; then
        local remaining=$((action_total - action_count + 1))
        printf '%b' "  ${RED}${QUESTION} Delete all remaining $remaining branches? [y/N]: ${RESETC}" >&2
        read -r gate_confirm </dev/tty
        if [[ "$gate_confirm" =~ ^[Yy]$ ]]; then
          auto_confirm=1
          confirm="y"
        else
          confirm="y"  # Just confirm this one
        fi
      fi
    fi

    case "$confirm" in
      [Yy])
        # Handle worktree removal first
        if [[ "$br_type" == "worktree" && -n "$wt_path" ]]; then
          if [[ "${BR_WT_DIR_MISSING[$idx]}" == "yes" ]]; then
            action "    ${CLEANUP} Pruning worktree record (directory missing)..."
            git worktree prune
          else
            action "    ${CLEANUP} Removing worktree..."
            if ! git worktree remove "$wt_path" 2>/dev/null; then
              if [[ $auto_confirm -eq 1 ]]; then
                warn "    $WARN Worktree has uncommitted changes — force removing..."
                git worktree remove --force "$wt_path"
              else
                warn "    $WARN Worktree has uncommitted changes."
                printf '%b' "    ${RED}${QUESTION} Force remove? (data loss!) [y/N]: ${RESETC}" >&2
                read -r force_confirm </dev/tty
                if [[ "$force_confirm" =~ ^[Yy]$ ]]; then
                  git worktree remove --force "$wt_path"
                else
                  warn "    Skipped"
                  STAT_SKIPPED=$((STAT_SKIPPED + 1))
                  continue
                fi
              fi
            fi
            STAT_WORKTREES_REMOVED=$((STAT_WORKTREES_REMOVED + 1))
          fi
        fi

        # Delete local branch (skip for remote-only)
        if [[ "$scope" != "remote" ]] && git show-ref --verify --quiet "refs/heads/$branch"; then
          action "    ${CLEANUP} Deleting local branch..."
          git branch -D "$branch" 2>/dev/null
          STAT_DELETED_LOCAL=$((STAT_DELETED_LOCAL + 1))
        fi

        # Delete remote branch if applicable
        if [[ "$scope" == "local+remote" || "$scope" == "remote" ]]; then
          action "    ${CLEANUP} Deleting remote branch..."
          if _delete_remote_branch "$branch"; then
            STAT_DELETED_REMOTE=$((STAT_DELETED_REMOTE + 1))
            if [[ "$scope" == "remote" ]]; then
              success "    $GOOD Deleted remote"
            else
              success "    $GOOD Deleted local + remote"
            fi
          else
            if [[ "$scope" == "remote" ]]; then
              warn "    $WARN Failed to delete remote"
            else
              warn "    $WARN Deleted local, failed to delete remote"
            fi
          fi
        else
          success "    $GOOD Deleted local"
        fi
        ;;
      [Ll])
        # Local only
        if [[ "$br_type" == "worktree" && -n "$wt_path" ]]; then
          if [[ "${BR_WT_DIR_MISSING[$idx]}" == "yes" ]]; then
            git worktree prune
          elif ! git worktree remove "$wt_path" 2>/dev/null; then
            warn "    $WARN Worktree has uncommitted changes."
            printf '%b' "    ${RED}${QUESTION} Force remove? [y/N]: ${RESETC}" >&2
            read -r force_confirm </dev/tty
            [[ "$force_confirm" =~ ^[Yy]$ ]] && git worktree remove --force "$wt_path" || { STAT_SKIPPED=$((STAT_SKIPPED + 1)); continue; }
          fi
          STAT_WORKTREES_REMOVED=$((STAT_WORKTREES_REMOVED + 1))
        fi
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          action "    ${CLEANUP} Deleting local branch only..."
          git branch -D "$branch" 2>/dev/null
          STAT_DELETED_LOCAL=$((STAT_DELETED_LOCAL + 1))
          success "    $GOOD Deleted local"
        fi
        ;;
      [Rr])
        # Remote only
        if [[ "$scope" == "local+remote" || "$scope" == "remote" ]]; then
          action "    ${CLEANUP} Deleting remote branch only..."
          if _delete_remote_branch "$branch"; then
            STAT_DELETED_REMOTE=$((STAT_DELETED_REMOTE + 1))
            success "    $GOOD Deleted remote"
          else
            warn "    $WARN Failed to delete remote"
          fi
        else
          warn "    $WARN No remote branch to delete"
        fi
        ;;
      *)
        info "    Skipped"
        STAT_SKIPPED=$((STAT_SKIPPED + 1))
        ;;
    esac
  done
}

# ═══════════════════════════════════════════════
# PHASE 3: REMOTE-ONLY LISTING
# ═══════════════════════════════════════════════

list_remote_only_branches() {
  # Remote-only branches are now included in Phase 1 discovery and the Phase 2 table.
  # This phase just reports the count for visibility.
  if [[ $STAT_REMOTE_ONLY -eq 0 ]]; then
    section_header "Phase 3: Remote-Only Branches" "$MAGNIFY" "All remote branches are tracked locally"
    success "  $GOOD Nothing to report."
  else
    section_header "Phase 3: Remote-Only Branches" "$MAGNIFY" "${STAT_REMOTE_ONLY} remote-only branch(es) included in Phase 2 analysis above"
    success "  $GOOD Remote-only branches were analyzed and presented in the report table."
  fi
}

# ═══════════════════════════════════════════════
# PHASE 4: REPO CLEANUP
# ═══════════════════════════════════════════════

git_cleanup() {
  section_header "Phase 4: Repository Cleanup" "$CLEANUP"

  local git_common_dir
  git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null || git rev-parse --git-dir)
  STAT_DISK_BEFORE=$(du -sk "$git_common_dir" 2>/dev/null | cut -f1)

  action "  $FETCH Running git garbage collection..."
  git gc --prune=now
  success "  $GOOD Garbage collection complete."

  printf '\n' >&2
  action "  $CLEANUP Cleaning up untracked files and directories..."
  git clean -fd
  success "  $GOOD Untracked file cleanup complete."

  STAT_DISK_AFTER=$(du -sk "$git_common_dir" 2>/dev/null | cut -f1)
}

# ═══════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════

print_summary() {
  printf '\n\n' >&2
  printf '%b\n' "${BOLD}${GREEN}══════════════════════════════════════════════════${RESETC}" >&2
  printf '%b\n' "${BOLD}  ${CHART}  Summary${RESETC}" >&2
  printf '%b\n' "${BOLD}${GREEN}══════════════════════════════════════════════════${RESETC}" >&2
  printf '\n' >&2

  # Branches scanned
  local ticket_count=0
  for t in "${BR_TICKET[@]}"; do
    [[ -n "$t" ]] && ticket_count=$((ticket_count + 1))
  done
  printf '%b\n' "  ${BOLD}Scanned:${RESETC}         ${STAT_BRANCHES_SCANNED} branches (${ticket_count} with JIRA tickets, ${STAT_WORKTREES_SCANNED} worktrees)" >&2

  # JIRA enrichment
  if [[ "$STAT_JIRA_STATUS" == "checked" ]]; then
    local dev_info=""
    if [[ $STAT_DEVSTATUS_QUERIED -gt 0 ]]; then
      dev_info=" + ${STAT_DEVSTATUS_QUERIED} dev-status"
      [[ $STAT_DEVSTATUS_SKIPPED -gt 0 ]] && dev_info+=" (${STAT_DEVSTATUS_SKIPPED} skipped: done)"
    fi
    printf '%b\n' "  ${BOLD}JIRA:${RESETC}            ${STAT_JIRA_QUERIED} tickets queried${dev_info} (${STAT_API_CALLS} API calls)" >&2
  else
    printf '%b\n' "  ${BOLD}JIRA:${RESETC}            ${YELLOW}${STAT_JIRA_STATUS}${RESETC}" >&2
  fi

  # Recommendations
  printf '%b\n' "  ${BOLD}Recommendations:${RESETC} ${RED}${STAT_RECOMMEND_DELETE} delete${RESETC}, ${YELLOW}${STAT_RECOMMEND_WARN} warning(s)${RESETC}, ${GREEN}${STAT_RECOMMEND_KEEP} keep${RESETC}" >&2

  # Deletions
  local del_parts=()
  [[ $STAT_DELETED_LOCAL -gt 0 ]] && del_parts+=("${STAT_DELETED_LOCAL} local")
  [[ $STAT_DELETED_REMOTE -gt 0 ]] && del_parts+=("${STAT_DELETED_REMOTE} remote")
  [[ $STAT_WORKTREES_REMOVED -gt 0 ]] && del_parts+=("${STAT_WORKTREES_REMOVED} worktree(s)")
  if [[ ${#del_parts[@]} -gt 0 ]]; then
    printf '%b\n' "  ${BOLD}Deleted:${RESETC}         ${GREEN}${(j:, :)del_parts}${RESETC}" >&2
  else
    printf '%b\n' "  ${BOLD}Deleted:${RESETC}         none" >&2
  fi
  [[ $STAT_SKIPPED -gt 0 ]] && printf '%b\n' "  ${BOLD}Skipped:${RESETC}         ${STAT_SKIPPED} by user" >&2

  # Remote-only
  if [[ $STAT_REMOTE_ONLY -gt 0 ]]; then
    printf '%b\n' "  ${BOLD}Remote-only:${RESETC}     ${STAT_REMOTE_ONLY} branch(es) not tracked locally" >&2
  else
    printf '%b\n' "  ${BOLD}Remote-only:${RESETC}     ${GREEN}all tracked${RESETC}" >&2
  fi

  # Disk space
  if [[ $STAT_DISK_BEFORE -gt 0 ]] && [[ $STAT_DISK_AFTER -gt 0 ]]; then
    local saved=$((STAT_DISK_BEFORE - STAT_DISK_AFTER))
    local before_str after_str saved_str
    before_str=$(format_size $STAT_DISK_BEFORE)
    after_str=$(format_size $STAT_DISK_AFTER)
    if [[ $saved -gt 0 ]]; then
      saved_str=$(format_size $saved)
      printf '%b\n' "  ${BOLD}Disk space:${RESETC}      ${before_str} -> ${after_str} (${GREEN}saved ${saved_str}${RESETC})" >&2
    elif [[ $saved -lt 0 ]]; then
      local grew=$(( -saved ))
      local grew_str
      grew_str=$(format_size $grew)
      printf '%b\n' "  ${BOLD}Disk space:${RESETC}      ${before_str} -> ${after_str} (grew ${grew_str} from repacking)" >&2
    else
      printf '%b\n' "  ${BOLD}Disk space:${RESETC}      ${after_str} (no change)" >&2
    fi
  fi

  # Stashes
  if [[ "$STAT_STASH" == "purged" ]]; then
    printf '%b\n' "  ${BOLD}Stashes:${RESETC}         ${GREEN}${STAT_STASH_COUNT} purged${RESETC}" >&2
  elif [[ $STAT_STASH_COUNT -gt 0 ]]; then
    printf '%b\n' "  ${BOLD}Stashes:${RESETC}         ${STAT_STASH_COUNT} kept" >&2
  else
    printf '%b\n' "  ${BOLD}Stashes:${RESETC}         none" >&2
  fi

  printf '\n' >&2
  success "$FINISH Git maintenance tasks completed successfully. $FINISH"
  printf '\n' >&2
}

# ═══════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════

printf '\n' >&2
printf '%b\n' "${BOLD}${BLUE}══════════════════════════════════════════════════${RESETC}" >&2
printf '%b\n' "${BOLD}  ${CLEANUP}  Git Repository Cleanup${RESETC}" >&2
printf '%b\n' "${BOLD}${BLUE}══════════════════════════════════════════════════${RESETC}" >&2

# Pre-flight
preflight

# Phase 1: Discovery & Enrichment
discover_branches
enrich_jira
apply_decision_matrix

# Phase 2: Report & Cleanup
print_report_table
walk_through_deletions

# Phase 3: Remote-only listing
list_remote_only_branches

# Phase 4: Repo cleanup
git_cleanup

# Optional stash purge
STAT_STASH_COUNT=$(git stash list 2>/dev/null | wc -l | tr -d ' ')

printf '\n\n' >&2
if [[ $STAT_STASH_COUNT -gt 0 ]]; then
  printf '%b' "${YELLOW}${QUESTION} You have ${BOLD}${STAT_STASH_COUNT}${RESETC}${YELLOW} stash(es). Purge all? [y/N]: ${RESETC}" >&2
  read -r confirm_stash </dev/tty
  if [[ $confirm_stash =~ ^[Yy]$ ]]; then
    git stash clear
    STAT_STASH="purged"
    success "$GOOD Stashes purged."
  else
    info "Skipping stash purge."
  fi
else
  success "$GOOD No stashes to purge."
fi

# Summary
print_summary
