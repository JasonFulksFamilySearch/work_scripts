# developer-scripts environment
# Source this from .zshrc or .zprofile

export DEV_SCRIPTS="$HOME/developer-scripts"

# Add bin/ to PATH (idempotent — safe to source multiple times)
case ":$PATH:" in
  *":$DEV_SCRIPTS/bin:"*) ;;
  *) export PATH="$DEV_SCRIPTS/bin:$PATH" ;;
esac
