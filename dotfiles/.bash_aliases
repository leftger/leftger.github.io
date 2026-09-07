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

# Quick jump to project repositories (checks my-repos, Projects, and repos)
cdr() {
    local target="${1:-}"
    if [ -z "$target" ]; then
        if [ -d "${HOME}/Projects/my-repos" ]; then
            cd "${HOME}/Projects/my-repos"
        elif [ -d "${HOME}/Projects" ]; then
            cd "${HOME}/Projects"
        elif [ -d "${HOME}/repos" ]; then
            cd "${HOME}/repos"
        fi
        return
    fi
    if [ -d "${HOME}/Projects/my-repos/${target}" ]; then
        cd "${HOME}/Projects/my-repos/${target}"
    elif [ -d "${HOME}/Projects/${target}" ]; then
        cd "${HOME}/Projects/${target}"
    elif [ -d "${HOME}/repos/${target}" ]; then
        cd "${HOME}/repos/${target}"
    else
        echo "Repository directory '${target}' not found in ~/Projects or ~/repos." >&2
        return 1
    fi
}

# Reload current shell in place
refreshenv() {
    exec "${SHELL:-$0}"
}

# Unified system and package upgrade
if [ -x "${HOME}/.local/bin/full-upgrade" ]; then
    alias up="${HOME}/.local/bin/full-upgrade"
fi

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

# WSL / Windows interop (if running inside WSL)
if [ -d "/mnt/c" ] || grep -qi microsoft /proc/version 2>/dev/null; then
    alias exp='explorer.exe'
    if [ -f "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" ]; then
        alias chrome='/mnt/c/Program\ Files/Google/Chrome/Application/chrome.exe'
    fi
    if command -v wslview >/dev/null 2>&1; then
        export BROWSER="wslview"
    fi
    # Jump to Windows User Profile directory
    cdw() {
        local win_home=""
        if command -v wslvar >/dev/null 2>&1; then
            win_home="$(wslpath "$(wslvar USERPROFILE 2>/dev/null)" 2>/dev/null)"
        fi
        if [ -z "$win_home" ] || [ ! -d "$win_home" ]; then
            win_home="/mnt/c/Users/$(whoami 2>/dev/null || echo '')"
            [ -d "$win_home" ] || win_home="/mnt/c/Users"
        fi
        cd "$win_home" || return 1
    }
    # Run command elevated with Windows gsudo if installed
    if command -v gsudo.exe >/dev/null 2>&1; then
        gsudo() {
            local shell
            shell=$(ps -p $$ -ocomm=)
            gsudo.exe wsl -d "${WSL_DISTRO_NAME:-Ubuntu}" -e "${shell}" -c "$*"
        }
    fi
fi
