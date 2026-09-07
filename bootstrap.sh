#!/usr/bin/env bash
# ==============================================================================
# Gerzain's Ubuntu / Debian System Bootstrap Script
#
# Usage (One-liner via curl):
#   curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh
#
# Or with arguments:
#   curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --timezone America/Phoenix
#
# Summary of automated actions:
#   1. Locale configuration: en_US.UTF-8 generated and set system-wide
#   2. Timezone configuration: defaults to America/Phoenix (configurable)
#   3. System upgrade: sudo apt update, full-upgrade, dist-upgrade, autoremove
#   4. Core development tools: git, build-essential, cmake, ninja, clang, lld, etc.
#   5. Modern CLI utilities: vim, btop, mosh, binutils, tmux, ripgrep, fd, bat, fzf
#   6. Embedded ARM toolchain: gcc-arm-none-eabi, gdb-multiarch, newlib libraries
#   7. Hardware access: dialout & plugdev groups, probe-rs udev rules
#   8. Shell setup: Zsh + Oh-My-Zsh with autosuggestions & syntax highlighting
#   9. Curated Dotfiles: .vimrc with badwolf/molokai themes & cross-shell aliases
#  10. Rust toolchain: rustup (stable), Cortex-M/RISC-V/Wasm targets,
#      probe-rs tools, cargo-binstall, cargo-deny, cargo-llvm-cov
# ==============================================================================

# POSIX /bin/sh compatibility trampoline:
# Allows running via: curl ... | sh as well as curl ... | bash
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        if [ -f "$0" ]; then
            exec bash "$0" "$@"
        else
            exec bash -c "$(curl -fsSL https://leftger.github.io/bootstrap.sh 2>/dev/null || curl -fsSL https://raw.githubusercontent.com/leftger/leftger.github.io/main/bootstrap.sh)" bash "$@"
        fi
    else
        echo "Error: bash is required to run this bootstrap script." >&2
        exit 1
    fi
fi

set -euo pipefail

# ------------------------------------------------------------------------------
# Default Configuration & Flags
# ------------------------------------------------------------------------------
DEFAULT_TIMEZONE="America/Phoenix"
TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"
SKIP_UPGRADE=0
SKIP_EMBEDDED=0
SKIP_RUST=0
SKIP_ZSH=0
SKIP_TOOLS=0
SKIP_DOTFILES=0
DRY_RUN=0

# Color formatting
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Asset distribution URLs
PAGES_BASE="https://leftger.github.io"
RAW_REPO_BASE="https://raw.githubusercontent.com/leftger/leftger.github.io/main"

# ------------------------------------------------------------------------------
# Helper Functions & Logging
# ------------------------------------------------------------------------------
log_info() {
    printf "${BLUE}[INFO]${RESET} %s\n" "$*"
}

log_step() {
    printf "\n${BOLD}${CYAN}==>${RESET} ${BOLD}%s${RESET}\n" "$*"
}

log_success() {
    printf "${GREEN}[✓]${RESET} %s\n" "$*"
}

log_warn() {
    printf "${YELLOW}[WARN]${RESET} %s\n" "$*" >&2
}

log_error() {
    printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2
}

print_help() {
    cat <<EOF
Gerzain's Linux System Bootstrap Script

Usage:
  ./bootstrap.sh [OPTIONS]
  curl -fsSL https://raw.githubusercontent.com/leftger/leftger/main/bootstrap.sh | bash -s -- [OPTIONS]

Options:
  -t, --timezone <TZ>   Set system timezone (default: ${DEFAULT_TIMEZONE})
      --skip-upgrade    Skip apt full-upgrade / dist-upgrade
      --skip-embedded   Skip ARM Cortex-M toolchain and probe-rs setup
      --skip-rust       Skip Rust toolchain and cargo utilities installation
      --skip-zsh        Skip Oh-My-Zsh installation and shell change
      --skip-tools      Skip modern CLI utilities installation
      --skip-dotfiles   Skip curated .vimrc, themes, and shell aliases
      --dry-run         Print actions without executing commands
  -h, --help            Show this help message and exit

Environment Variables:
  TIMEZONE              Overrides the default timezone if --timezone is omitted
EOF
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--timezone)
            TIMEZONE="$2"
            shift 2
            ;;
        --skip-upgrade)
            SKIP_UPGRADE=1
            shift
            ;;
        --skip-embedded)
            SKIP_EMBEDDED=1
            shift
            ;;
        --skip-rust)
            SKIP_RUST=1
            shift
            ;;
        --skip-zsh)
            SKIP_ZSH=1
            shift
            ;;
        --skip-tools)
            SKIP_TOOLS=1
            shift
            ;;
        --skip-dotfiles)
            SKIP_DOTFILES=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Pre-flight Checks & Sudo Keepalive
# ------------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    log_info "Running in DRY RUN mode. No modifications will be made."
fi

# Ensure running on Linux
if [ "$(uname -s)" != "Linux" ]; then
    log_error "This script is designed for Ubuntu/Debian Linux systems."
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    TARGET_HOME="$HOME"
fi

# Determine script location if running from a local checkout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN]${RESET} %s\n" "$*"
    else
        "$@"
    fi
}

run_sudo() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN-SUDO]${RESET} %s\n" "$*"
    else
        if [ "$(id -u)" -eq 0 ]; then
            "$@"
        else
            sudo "$@"
        fi
    fi
}

run_user() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN-USER:${TARGET_USER}]${RESET} %s\n" "$*"
    else
        if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
            su - "${TARGET_USER}" -c "$*"
        else
            bash -c "$*"
        fi
    fi
}

# Setup sudo credentials & keep-alive (only in live mode)
SUDO_PID=""
cleanup() {
    if [ -n "$SUDO_PID" ]; then
        kill "$SUDO_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
        log_info "Sudo privileges active."
    else
        log_info "Prompting for sudo privileges..."
        if [ -t 0 ]; then
            sudo -v
        elif [ -r /dev/tty ]; then
            sudo -v </dev/tty
        else
            sudo -v
        fi
    fi

    # Keep-alive: refresh sudo timestamp in background while script executes
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done 2>/dev/null &
    SUDO_PID=$!
fi

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=("-y" "-o" "Dpkg::Options::=--force-confdef" "-o" "Dpkg::Options::=--force-confold")

# ------------------------------------------------------------------------------
# Step 1: Locale Configuration (en_US.UTF-8)
# ------------------------------------------------------------------------------
log_step "Configuring Locale to en_US.UTF-8"

run_sudo apt-get update -qq
run_sudo apt-get install "${APT_FLAGS[@]}" locales

if [ "$DRY_RUN" -eq 1 ]; then
    log_info "[DRY-RUN] Enable en_US.UTF-8 in /etc/locale.gen, run locale-gen and update-locale"
else
    if grep -q "^# en_US.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null; then
        run_sudo sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    fi
    run_sudo locale-gen en_US.UTF-8
    run_sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
fi
log_success "Locale configured to en_US.UTF-8"

# ------------------------------------------------------------------------------
# Step 2: Timezone Configuration
# ------------------------------------------------------------------------------
log_step "Configuring Timezone to ${TIMEZONE}"

if [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    log_warn "Timezone '${TIMEZONE}' not found in /usr/share/zoneinfo. Falling back to UTC."
    TIMEZONE="UTC"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log_info "[DRY-RUN] Setting system timezone to ${TIMEZONE} via timedatectl and /etc/localtime"
else
    if command -v timedatectl >/dev/null 2>&1 && timedatectl 2>/dev/null | grep -q "Time zone"; then
        run_sudo timedatectl set-timezone "$TIMEZONE" || true
    fi
    run_sudo ln -fs "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    echo "$TIMEZONE" | run_sudo tee /etc/timezone >/dev/null
    run_sudo dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
fi
log_success "Timezone set to ${TIMEZONE}"

# ------------------------------------------------------------------------------
# Step 3: System Upgrade (apt update / full-upgrade / dist-upgrade)
# ------------------------------------------------------------------------------
if [ "$SKIP_UPGRADE" -eq 0 ]; then
    log_step "Performing System Upgrades (apt update, full-upgrade, dist-upgrade)"
    run_sudo apt-get update "${APT_FLAGS[@]}"
    run_sudo apt-get full-upgrade "${APT_FLAGS[@]}"
    run_sudo apt-get dist-upgrade "${APT_FLAGS[@]}"
    run_sudo apt-get autoremove "${APT_FLAGS[@]}"
    log_success "System packages up to date"
else
    log_info "Skipping apt upgrades (--skip-upgrade specified)"
fi

# ------------------------------------------------------------------------------
# Step 4: Core Development Tools & Libraries
# ------------------------------------------------------------------------------
log_step "Installing Core Development Tools & Dependencies"

CORE_PACKAGES=(
    build-essential
    clang
    lld
    llvm
    cmake
    ninja-build
    pkg-config
    libssl-dev
    git
    git-lfs
    curl
    wget
    ca-certificates
    gnupg
    lsb-release
    software-properties-common
    unzip
    tar
    gzip
    xz-utils
    jq
    tree
    vim
    btop
    mosh
    binutils
    tmux
    command-not-found
)

run_sudo apt-get install "${APT_FLAGS[@]}" "${CORE_PACKAGES[@]}"
log_success "Core development packages installed"

# ------------------------------------------------------------------------------
# Step 5: Modern CLI Productivity Utilities
# ------------------------------------------------------------------------------
if [ "$SKIP_TOOLS" -eq 0 ]; then
    log_step "Installing Modern CLI Productivity Utilities"

    CLI_PACKAGES=(
        ripgrep
        fd-find
        bat
        fzf
        htop
    )

    run_sudo apt-get install "${APT_FLAGS[@]}" "${CLI_PACKAGES[@]}"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Symlink batcat -> ~/.local/bin/bat and fdfind -> ~/.local/bin/fd"
    else
        mkdir -p "${TARGET_HOME}/.local/bin"
        if command -v batcat >/dev/null 2>&1 && [ ! -e "${TARGET_HOME}/.local/bin/bat" ]; then
            ln -sf "$(which batcat)" "${TARGET_HOME}/.local/bin/bat"
            log_info "Symlinked batcat -> ~/.local/bin/bat"
        fi
        if command -v fdfind >/dev/null 2>&1 && [ ! -e "${TARGET_HOME}/.local/bin/fd" ]; then
            ln -sf "$(which fdfind)" "${TARGET_HOME}/.local/bin/fd"
            log_info "Symlinked fdfind -> ~/.local/bin/fd"
        fi
    fi

    log_success "Modern CLI utilities installed and configured"
fi

# ------------------------------------------------------------------------------
# Step 6: Embedded ARM Toolchain & Hardware Rules
# ------------------------------------------------------------------------------
if [ "$SKIP_EMBEDDED" -eq 0 ]; then
    log_step "Installing Embedded ARM Cross-Compilation Toolchain & Hardware Tools"

    EMBEDDED_PACKAGES=(
        gcc-arm-none-eabi
        binutils-arm-none-eabi
        libnewlib-arm-none-eabi
        libstdc++-arm-none-eabi-newlib
        gdb-multiarch
        libudev-dev
        libusb-1.0-0-dev
        picocom
        minicom
    )

    run_sudo apt-get install "${APT_FLAGS[@]}" "${EMBEDDED_PACKAGES[@]}"

    # Add user to dialout and plugdev groups
    log_info "Adding ${TARGET_USER} to dialout and plugdev groups..."
    run_sudo usermod -a -G dialout,plugdev "${TARGET_USER}" || true

    # Install probe-rs hardware udev rules
    log_info "Installing probe-rs udev rules for CMSIS-DAP, ST-Link, J-Link..."
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Install /etc/udev/rules.d/69-probe-rs.rules and reload udevadm"
    else
        UDEV_RULES_URL="https://probe.rs/files/69-probe-rs.rules"
        UDEV_TARGET="/etc/udev/rules.d/69-probe-rs.rules"
        if curl -fsSL "$UDEV_RULES_URL" -o /tmp/69-probe-rs.rules 2>/dev/null; then
            run_sudo mv /tmp/69-probe-rs.rules "$UDEV_TARGET"
            run_sudo chmod 644 "$UDEV_TARGET"
            run_sudo udevadm control --reload-rules 2>/dev/null || true
            run_sudo udevadm trigger 2>/dev/null || true
            log_success "Hardware udev rules installed"
        else
            log_warn "Could not fetch probe-rs udev rules. Continuing."
        fi
    fi

    log_success "Embedded ARM toolchain and hardware access configured"
else
    log_info "Skipping embedded setup (--skip-embedded specified)"
fi

# ------------------------------------------------------------------------------
# Step 7: Zsh & Oh-My-Zsh Installation
# ------------------------------------------------------------------------------
if [ "$SKIP_ZSH" -eq 0 ]; then
    log_step "Installing and Configuring Zsh + Oh-My-Zsh"

    run_sudo apt-get install "${APT_FLAGS[@]}" zsh

    OMZ_DIR="${TARGET_HOME}/.oh-my-zsh"
    if [ ! -d "$OMZ_DIR" ]; then
        log_info "Installing Oh-My-Zsh (unattended)..."
        run_user 'RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    else
        log_info "Oh-My-Zsh is already installed at ${OMZ_DIR}"
    fi

    # Plugins: zsh-autosuggestions & zsh-syntax-highlighting
    PLUGINS_DIR="${OMZ_DIR}/custom/plugins"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Clone zsh-autosuggestions & zsh-syntax-highlighting into ${PLUGINS_DIR}"
    else
        mkdir -p "$PLUGINS_DIR"
        if [ ! -d "${PLUGINS_DIR}/zsh-autosuggestions" ]; then
            git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "${PLUGINS_DIR}/zsh-autosuggestions" 2>/dev/null || true
        fi
        if [ ! -d "${PLUGINS_DIR}/zsh-syntax-highlighting" ]; then
            git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${PLUGINS_DIR}/zsh-syntax-highlighting" 2>/dev/null || true
        fi
    fi

    # Configure ~/.zshrc
    ZSHRC="${TARGET_HOME}/.zshrc"
    TARGET_PLUGINS="git sudo cargo rust extract z colored-man-pages command-not-found zsh-autosuggestions zsh-syntax-highlighting"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Configure plugins (${TARGET_PLUGINS}) and PATH in ${ZSHRC}"
    else
        if [ -f "$ZSHRC" ]; then
            if grep -q "^plugins=(" "$ZSHRC"; then
                sed -i "s/^plugins=(.*)/plugins=($TARGET_PLUGINS)/" "$ZSHRC"
            elif ! grep -q "plugins=" "$ZSHRC"; then
                echo "plugins=($TARGET_PLUGINS)" >> "$ZSHRC"
            fi
            if ! grep -q 'export PATH="\$HOME/\.local/bin:\$HOME/\.cargo/bin:\$PATH"' "$ZSHRC"; then
                echo '' >> "$ZSHRC"
                echo '# User custom binary search path' >> "$ZSHRC"
                echo 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"' >> "$ZSHRC"
            fi
            if ! grep -q 'DISABLE_MAGIC_FUNCTIONS="true"' "$ZSHRC"; then
                echo 'DISABLE_MAGIC_FUNCTIONS="true"' >> "$ZSHRC"
            fi
            if ! grep -q 'fzf --zsh' "$ZSHRC"; then
                cat << 'EOF' >> "$ZSHRC"

# Interactive fzf keybindings (Ctrl+R, Ctrl+T, Alt+C) and fuzzy completion
if command -v fzf >/dev/null 2>&1; then
    eval "$(fzf --zsh 2>/dev/null || true)"
fi
EOF
            fi
        fi
    fi

    # Set default shell to zsh
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Change default shell to zsh for ${TARGET_USER}"
    else
        ZSH_BIN="$(which zsh)"
        CURRENT_SHELL="$(getent passwd "${TARGET_USER}" 2>/dev/null | cut -d: -f7 || echo "")"
        if [ "$CURRENT_SHELL" != "$ZSH_BIN" ]; then
            log_info "Changing default shell to ${ZSH_BIN} for ${TARGET_USER}..."
            run_sudo chsh -s "$ZSH_BIN" "$TARGET_USER" || true
        fi
    fi

    log_success "Zsh & Oh-My-Zsh configured"
else
    log_info "Skipping Zsh setup (--skip-zsh specified)"
fi

# ------------------------------------------------------------------------------
# Step 8: Curated Dotfiles (Vim & Shell Productivity Aliases)
# ------------------------------------------------------------------------------
if [ "$SKIP_DOTFILES" -eq 0 ]; then
    log_step "Configuring Curated Dotfiles (Vim Badwolf/Molokai themes & Shell Aliases)"

    # Setup directories
    mkdir -p "${TARGET_HOME}/.vim/colors"
    mkdir -p "${TARGET_HOME}/.vim-tmp"

    # Asset download helper
    fetch_asset() {
        local rel_path="$1"
        local dest="$2"
        if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/${rel_path}" ]; then
            cp "${SCRIPT_DIR}/${rel_path}" "$dest"
        else
            curl -fsSL "${PAGES_BASE}/${rel_path}" -o "$dest" 2>/dev/null || \
            curl -fsSL "${RAW_REPO_BASE}/${rel_path}" -o "$dest" 2>/dev/null || true
        fi
        chown "${TARGET_USER}:${TARGET_USER}" "$dest" 2>/dev/null || true
    }

    # Deploy .bash_aliases
    BASH_ALIASES_DEST="${TARGET_HOME}/.bash_aliases"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy .bash_aliases to ${BASH_ALIASES_DEST}"
    else
        fetch_asset "dotfiles/.bash_aliases" "$BASH_ALIASES_DEST"

        # Ensure .zshrc sources ~/.bash_aliases safely
        ZSHRC="${TARGET_HOME}/.zshrc"
        if [ -f "$ZSHRC" ] && ! grep -q '\.bash_aliases' "$ZSHRC"; then
            cat << 'EOF' >> "$ZSHRC"

# Load shell aliases & functions (emulate ksh for seamless compatibility)
if [ -f "$HOME/.bash_aliases" ]; then
    emulate ksh -c "source '$HOME/.bash_aliases'"
fi
EOF
        fi

        # Ensure .bashrc sources ~/.bash_aliases
        BASHRC="${TARGET_HOME}/.bashrc"
        if [ -f "$BASHRC" ] && ! grep -q '\.bash_aliases' "$BASHRC"; then
            cat << 'EOF' >> "$BASHRC"

# Load shell aliases & functions
if [ -f "$HOME/.bash_aliases" ]; then
    . "$HOME/.bash_aliases"
fi
EOF
        fi
    fi

    # Deploy .vimrc
    VIMRC_DEST="${TARGET_HOME}/.vimrc"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy .vimrc to ${VIMRC_DEST}"
    else
        fetch_asset "dotfiles/.vimrc" "$VIMRC_DEST"
    fi

    # Deploy Vim Colorschemes (badwolf, molokai, monokai)
    VIM_COLORS_DIR="${TARGET_HOME}/.vim/colors"
    THEMES=(badwolf.vim molokai.vim monokai.vim)

    for theme in "${THEMES[@]}"; do
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Deploy vim theme ${theme} to ${VIM_COLORS_DIR}/${theme}"
        else
            fetch_asset "dotfiles/.vim/colors/${theme}" "${VIM_COLORS_DIR}/${theme}"
        fi
    done

    # Deploy global .gitignore
    GITIGNORE_DEST="${TARGET_HOME}/.gitignore"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy global .gitignore to ${GITIGNORE_DEST}"
    else
        fetch_asset "dotfiles/.gitignore" "$GITIGNORE_DEST"
    fi

    # Deploy git commit template
    GITMESSAGE_DEST="${TARGET_HOME}/.gitmessage"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy .gitmessage to ${GITMESSAGE_DEST}"
    else
        fetch_asset "dotfiles/.gitmessage" "$GITMESSAGE_DEST"
    fi

    # Deploy .tmux.conf
    TMUX_DEST="${TARGET_HOME}/.tmux.conf"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy .tmux.conf to ${TMUX_DEST}"
    else
        fetch_asset "dotfiles/.tmux.conf" "$TMUX_DEST"
    fi

    # Configure Git Defaults, Core Settings, and Aliases
    log_info "Configuring Git defaults, push settings, commit template, and aliases..."
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Set git core, push.autoSetupRemote, rebase/merge autoStash, commit template, and aliases"
    else
        run_user "git config --global core.editor vim"
        run_user "git config --global init.defaultBranch main"
        run_user "git config --global core.hooksPath .githooks"
        run_user "git config --global core.excludesfile ~/.gitignore"
        run_user "git config --global commit.template ~/.gitmessage"
        run_user "git config --global commit.cleanup strip"
        run_user "git config --global push.autoSetupRemote true"
        run_user "git config --global rebase.autoStash true"
        run_user "git config --global merge.autoStash true"

        # Set default git identity if not present
        CURRENT_GIT_NAME="$(run_user 'git config --global user.name' 2>/dev/null || true)"
        CURRENT_GIT_EMAIL="$(run_user 'git config --global user.email' 2>/dev/null || true)"
        if [ -z "$CURRENT_GIT_NAME" ]; then
            run_user "git config --global user.name 'Gerzain Mata'"
        fi
        if [ -z "$CURRENT_GIT_EMAIL" ]; then
            run_user "git config --global user.email 'leftger@gmail.com'"
        fi

        # Install productivity aliases
        run_user "git config --global alias.caa 'commit --amend --all'"
        run_user "git config --global alias.caane 'commit --amend --all --no-edit'"
        run_user "git config --global alias.cob 'checkout -b'"
        run_user "git config --global alias.apply-gitignore '!f() { set -ex; git rm -r --cached . >/dev/null; git add .; }; f'"

        # Install pa alias
        PA_CMD='!f() { [ -d "$1" ] && { d="$1"; shift; } || d="."; for r in "$d"/*/; do [ -e "$r/.git" ] || continue; b=$(git -C "$r" branch --show-current 2>/dev/null); [ -n "$b" ] || continue; echo "==> $(basename "$r") ($b)..."; git -C "$r" config remote.upstream.url >/dev/null 2>&1 && git -C "$r" pull upstream "$b" "$@"; git -C "$r" pull origin "$b" "$@"; done; }; f'
        run_user "git config --global alias.pa '$PA_CMD'"
    fi

    log_success "Dotfiles configured (.vimrc, themes, aliases, and Git pa configured)"
else
    log_info "Skipping dotfiles setup (--skip-dotfiles specified)"
fi

# ------------------------------------------------------------------------------
# Step 9: Rust Toolchain & Embedded Ecosystem
# ------------------------------------------------------------------------------
if [ "$SKIP_RUST" -eq 0 ]; then
    log_step "Installing Rust Toolchain & Embedded Ecosystem"

    CARGO_HOME="${TARGET_HOME}/.cargo"
    RUSTUP_BIN="${CARGO_HOME}/bin/rustup"
    CARGO_BIN="${CARGO_HOME}/bin/cargo"

    if [ ! -x "$RUSTUP_BIN" ]; then
        log_info "Installing rustup with stable toolchain..."
        run_user 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'
    else
        log_info "Rustup already installed. Updating stable toolchain..."
        run_user "${RUSTUP_BIN} update stable || true"
    fi

    # Install Rust components
    log_info "Installing Rust components (rust-src, llvm-tools, clippy, rustfmt, rust-analyzer)..."
    run_user "${RUSTUP_BIN} component add rust-src llvm-tools clippy rustfmt rust-analyzer || true"

    # Install Embedded ARM & RISC-V targets
    if [ "$SKIP_EMBEDDED" -eq 0 ]; then
        log_info "Adding ARM Cortex-M, RISC-V, and Wasm targets..."
        TARGETS=(
            thumbv6m-none-eabi
            thumbv7m-none-eabi
            thumbv7em-none-eabi
            thumbv7em-none-eabihf
            thumbv8m.main-none-eabihf
            riscv32imac-unknown-none-elf
            riscv32imc-unknown-none-elf
            wasm32-unknown-unknown
        )
        run_user "${RUSTUP_BIN} target add ${TARGETS[*]} || true"
    fi

    # Install cargo-binstall (fast binary installer)
    log_info "Installing cargo-binstall for instant precompiled cargo tools..."
    run_user 'curl -L --proto "=https" --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash || true'

    # Install probe-rs tools
    if [ "$SKIP_EMBEDDED" -eq 0 ]; then
        log_info "Installing probe-rs tools (flashing & debugging Cortex-M/RISC-V)..."
        run_user 'curl --proto "=https" --tlsv1.2 -LsSf https://github.com/probe-rs/probe-rs/releases/latest/download/probe-rs-tools-installer.sh | sh || true'
    fi

    # Install cargo subcommands via cargo-binstall
    BINSTALL_BIN="${CARGO_HOME}/bin/cargo-binstall"
    log_info "Installing cargo-deny, cargo-llvm-cov, cargo-generate..."
    run_user "${BINSTALL_BIN} --no-confirm cargo-deny cargo-llvm-cov cargo-generate || true"

    log_success "Rust toolchain and embedded tooling installed"
else
    log_info "Skipping Rust setup (--skip-rust specified)"
fi

# ------------------------------------------------------------------------------
# Summary & Completion
# ------------------------------------------------------------------------------
printf "\n${BOLD}${GREEN}================================================================${RESET}\n"
printf "${BOLD}${GREEN}              Bootstrap Completed Successfully!                 ${RESET}\n"
printf "${BOLD}${GREEN}================================================================${RESET}\n\n"

cat <<EOF
Summary of changes:
  • System upgraded (apt update, full-upgrade, dist-upgrade, autoremove)
  • Locale: en_US.UTF-8 generated and set as default
  • Timezone: ${TIMEZONE}
  • Core Dev: build-essential, cmake, ninja, clang, lld, git, jq, etc.
  • Modern CLI: vim, btop, mosh, tmux, ripgrep, fd, bat, fzf
  • Embedded ARM: gcc-arm-none-eabi, gdb-multiarch, newlib libraries
  • Hardware Access: ${TARGET_USER} added to dialout and plugdev; probe-rs udev rules installed
  • Shell: Zsh + Oh-My-Zsh with syntax-highlighting and autosuggestions
  • Dotfiles & Git: .vimrc (badwolf), .bash_aliases, git editor=vim, alias.pa
  • Rust: stable toolchain, Cortex-M/RISC-V/Wasm targets, probe-rs, cargo-binstall

Next steps:
  1. If group permissions changed, log out and back in:
       $ exit   (or reboot)
  2. Start your new shell:
       $ exec zsh
  3. Happy hacking! 🦀⚡
EOF
