# developer-scripts

Personal developer workflow scripts for git operations, Homebrew automation, Docker helpers, and system utilities.

This is a portable, self-contained toolbox designed to be cloned onto any macOS/Linux machine and sourced from `.zshrc`. It is not a plugin, framework, or package manager integration.

## Quick Start

```bash
# 1. Clone (or move your existing repo)
git clone <your-remote> ~/developer-scripts

# 2. Run the installer
~/developer-scripts/install.sh

# 3. Add to .zshrc (after oh-my-zsh/plugins, before keybindings)
# developer-scripts
source "$HOME/developer-scripts/zsh/env.zsh"
source "$HOME/developer-scripts/zsh/aliases.zsh"
source "$HOME/developer-scripts/zsh/functions.zsh"

# 4. Restart your shell
exec zsh
```

## Directory Structure

| Directory | Purpose |
|-----------|---------|
| `bin/` | Executable wrappers added to `$PATH` |
| `scripts/git/` | Git workflow automation |
| `scripts/brew/` | Homebrew update with IT-managed cask exclusions |
| `scripts/docker/` | Docker/container helpers |
| `scripts/system/` | System and network utilities |
| `zsh/` | Shell integration — env, aliases, functions |
| `config/` | Configuration files (docker-compose, brew exclusions) |

## Available Commands

After installation, these commands are available on your PATH:

| Command | Description | Legacy Alias |
|---------|-------------|--------------|
| `git-cleanup` | Multi-phase branch cleanup with JIRA dev-status integration | `gitCleanup` |
| `git-worktree-create` | Create a git worktree (use via `workBranch` to auto-cd) | — |
| `git-sync-master` | Fetch and merge master into current branch (worktree-safe) | `gitSyncMaster` |
| `git-oldest-branches` | List remote branches sorted by age, color-coded | `gitOldest` |
| `git-diff` | Generate diff to file (`-b` branch name, `-s` staged, `-m` vs master) | `gitDiff` / `gitDiffS` |
| `brew-update` | Safe Homebrew update with cask exclusions and dry-run | `brewUpdate` |
| `code-climate` | Run CodeClimate analysis via Docker | `codeClimate` |
| `net-sim-stop` | Tear down pfctl/dummynet network simulation | — |

### Shell Functions

| Function | Description |
|----------|-------------|
| `workBranch <type> <ticket> <desc>` | Create a worktree and `cd` into it |

## Safety Warnings

Some scripts perform destructive operations. Use with care:

- **`git-cleanup`** — Deletes local and remote branches, drops stashes. Has interactive confirmation, but review the report before confirming.
- **`git-purge-stashes`** — Drops all stashes permanently. Cannot be undone.
- **`net-sim-stop`** — Disables pfctl and flushes dnctl pipes. Requires `sudo`.

## Configuration

### Brew Cask Exclusions

Prevent `brew-update` from upgrading IT-managed or MDM-controlled casks:

```bash
cp config/brew/.brew-exclude-casks.example config/brew/.brew-exclude-casks
# Edit the file — add one cask name per line
```

The following casks are excluded by default in the script: `docker-desktop`, `visual-studio-code`, `intellij-idea`, `slack`.

### Docker Compose Files

Located in `config/docker/`:
- `wud-docker-compose.yml` — What's Up Docker (container update notifications)
- `pgadmin/docker-compose.yml` — pgAdmin 4

## Zsh Integration Details

The shell integration is split into three files sourced independently:

| File | Contents |
|------|----------|
| `zsh/env.zsh` | Exports `$DEV_SCRIPTS`, adds `bin/` to `$PATH` |
| `zsh/aliases.zsh` | Backward-compatible aliases (optional if you use bin/ names directly) |
| `zsh/functions.zsh` | `workBranch` — the only function that needs shell context for `cd` |

No file assumes Oh-My-Zsh. No file contains heavy logic.
