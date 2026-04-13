#!/usr/bin/env bash
set -euo pipefail

# Resolve the directory where install.sh lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "developer-scripts installer"
echo "=========================="
echo ""
echo "Repository: $SCRIPT_DIR"
echo ""

# --- 1. Permissions on bin/ wrappers ---
echo "[1/3] Setting permissions on bin/ wrappers..."
chmod +x "$SCRIPT_DIR"/bin/*
echo "      Done."

# --- 2. Permissions on scripts ---
echo "[2/3] Setting permissions on scripts..."
find "$SCRIPT_DIR/scripts" -type f \( -name '*.sh' -o -name '*.zsh' \) -exec chmod +x {} +
echo "      Done."

# --- 3. Shell integration check ---
echo "[3/3] Checking shell integration..."
if grep -q 'developer-scripts/zsh/env.zsh' "$HOME/.zshrc" 2>/dev/null; then
    echo "      Shell integration already present in .zshrc"
else
    echo ""
    echo "  Add the following to your .zshrc (after oh-my-zsh/plugins, before keybindings):"
    echo ""
    echo '      # developer-scripts'
    echo '      source "$HOME/developer-scripts/zsh/env.zsh"'
    echo '      source "$HOME/developer-scripts/zsh/aliases.zsh"'
    echo '      source "$HOME/developer-scripts/zsh/functions.zsh"'
    echo ""
fi

# --- Optional: detect old config location ---
if [ -f "$HOME/scripts/.brew-exclude-casks" ]; then
    echo ""
    echo "  Found old brew config at ~/scripts/.brew-exclude-casks"
    echo "  Move it:  mv ~/scripts/.brew-exclude-casks $SCRIPT_DIR/config/brew/.brew-exclude-casks"
fi

# --- Optional: brew config reminder ---
if [ ! -f "$SCRIPT_DIR/config/brew/.brew-exclude-casks" ]; then
    echo ""
    echo "  Optional — set up brew cask exclusions:"
    echo "      cp $SCRIPT_DIR/config/brew/.brew-exclude-casks.example \\"
    echo "         $SCRIPT_DIR/config/brew/.brew-exclude-casks"
fi

echo ""
echo "Done. Restart your shell or run:  source ~/.zshrc"
