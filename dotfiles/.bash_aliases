# ==============================================================================
# Shell Productivity Aliases & Helpers (usable by both bash and zsh)
# ==============================================================================

# Directory Navigation & Utilities
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

# Create directory and immediately cd into it
mcd() {
    mkdir -p "$1" && cd "$1"
}

# Quick jump to project repositories
cdr() {
    local target="${1:-}"
    cd "${HOME}/Projects/my-repos/${target}"
}

# Reload current shell in place
refreshenv() {
    exec "${SHELL:-$0}"
}

# Directory Listings
alias l='ls -CF'
alias la='ls -lah'
alias lac='ls -lah --color=none'
alias ll='ls -alF'
alias ls='ls --color=auto'

# Search with color & smart case
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
if command -v rg >/dev/null 2>&1; then
    alias rg='rg --smart-case'
fi

# Modern CLI fallbacks (Debian/Ubuntu batcat/fdfind naming)
if ! command -v bat >/dev/null 2>&1 && command -v batcat >/dev/null 2>&1; then
    alias bat='batcat'
fi
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    alias fd='fdfind'
fi

# Development & Build
alias mk='make -j$(nproc 2>/dev/null || echo 4)'
alias py-env='python3 -m venv env && source env/bin/activate'

# Git shortcuts
alias gh='xdg-open "$(git remote -v 2>/dev/null | grep fetch | head -1 | awk '\''{print $2}'\'' | sed -e '\''s/:/\//'\'' -e '\''s/git@/https:\/\//'\'')"'

# WSL / Windows interop (if applicable)
if [ -d "/mnt/c" ]; then
    alias exp='explorer.exe'
    if [ -f "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" ]; then
        alias chrome='/mnt/c/Program\ Files/Google/Chrome/Application/chrome.exe'
    fi
fi
