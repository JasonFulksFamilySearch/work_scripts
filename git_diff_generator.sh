#!/usr/bin/env bash
set -euo pipefail

# Usage:
# gitdiff.sh [-f filename] [-b] [-s] [-o] [-m]
# Options:
# -f filename Output filename (default: diff.txt)
# -b Append current branch (or short SHA if detached) to filename
# -s Diff staged (indexed) changes only (--staged)
# -o Open the file in default editor after saving
# -m Diff against origin/master (fetches latest first)

# Defaults
filename="diff.txt"
append_branch=false
staged_only=false
open_file=false
master_diff=false

run_dir="$PWD"

# Parse options
while getopts ":f:bsom" opt; do
  case $opt in
    f) filename="$OPTARG" ;;
    b) append_branch=true ;;
    s) staged_only=true ;;
    o) open_file=true ;;
    m) master_diff=true ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done

# Ensure we're in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "❌ Not a Git repository." >&2
  exit 1
fi

# If -m is set, fetch origin/master
if $master_diff; then
  echo "🔄 Fetching latest origin/master..."
  git fetch origin
fi

# Prepare filename
name_only="$(basename -- "$filename")"
if $append_branch; then
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  if [[ "$branch" == "HEAD" ]]; then
    branch="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
  fi
  safe_branch="$(echo "$branch" | tr '/ ' '__' | sed 's/[^A-Za-z0-9._-]/_/g')"
  base="${name_only%.*}"
  ext="${name_only##*.}"
  if [[ "$name_only" == "$ext" ]]; then
    name_only="${base}-${safe_branch}"
  else
    name_only="${base}-${safe_branch}.${ext}"
  fi
fi

out_path="${run_dir}/${name_only}"

# Build git diff command
diff_cmd=(git diff)
if $staged_only; then
  diff_cmd+=(--staged)
fi
if $master_diff; then
  diff_cmd+=("origin/master")
fi

# Run git diff and save
"${diff_cmd[@]}" > "$out_path"
echo "✅ Git diff saved to ${out_path}"

# Open file if requested
if $open_file; then
  if command -v xdg-open &>/dev/null; then
    xdg-open "$out_path" >/dev/null 2>&1 &
  elif command -v open &>/dev/null; then
    open "$out_path"
  else
    echo "⚠️ Could not detect a file opener."
  fi
fi