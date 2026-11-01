#!/bin/sh
set -eu

export GHOSTTY_RESOURCES_DIR=/usr/share/ghosntty/ghostty
export GHOSTTY_NVIM_RUNTIME=/usr/share/ghosntty/nvim

# Use the bundled WezTerm-style profile on a fresh install. Existing Ghostty
# configuration continues to take precedence and is never overwritten.
ghosntty_cli=false
for ghosntty_arg in "$@"; do
    case "$ghosntty_arg" in +*|--help|--version) ghosntty_cli=true ;; esac
done
ghosntty_config="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
if [ "$ghosntty_cli" = false ] &&
    [ ! -f "$ghosntty_config/config" ] &&
    [ ! -f "$ghosntty_config/config.ghostty" ]; then
    set -- --config-file=/usr/share/ghosntty/profile/config.ghostty "$@"
fi
exec /usr/lib/ghosntty/bin/ghostty "$@"
