#!/usr/bin/env bash
# ==============================================================================
# Gerzain's Linux & macOS System Bootstrap Script
#
# Usage (One-liner via curl):
#   curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh
#
# Or with arguments:
#   curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --timezone America/Phoenix
#
# Summary of automated actions:
#   1. Locale configuration: en_US.UTF-8 generated and set system-wide
#   2. Timezone configuration: autodetects system timezone (configurable via --timezone)
#   3. Package manager: APT (Debian/Ubuntu) or Homebrew (macOS) upgrades
#   4. Core development tools: git, cmake, ninja, clang/llvm, pkg-config, etc.
#   5. Modern CLI utilities: vim, btop, mosh, tmux, ripgrep, fd, bat, fzf
#   6. Embedded ARM toolchain: gcc-arm-none-eabi, gdb, newlib, openocd, probe-rs
#   7. Hardware access: dialout & plugdev groups, probe-rs udev rules (Linux)
#   8. Shell setup: Zsh + Oh-My-Zsh with autosuggestions & syntax highlighting
#   9. Curated Dotfiles: .vimrc, .tmux.conf, .editorconfig, .hushlogin, .gitmessage,
#      ~/.githooks dispatcher (forwards to ./.githooks), ~/.git_template,
#      unified full-upgrade script (alias: up), and shell aliases
#  10. Rust toolchain: rustup (stable), Cortex-M/RISC-V/Wasm targets,
#      probe-rs tools, cargo-binstall, cargo-binutils, espflash, cargo-deny, cargo-llvm-cov
#  11. Zed Editor: high-performance code editor
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
umask 0022

# ------------------------------------------------------------------------------
# Default Configuration & Flags
# ------------------------------------------------------------------------------
TIMEZONE="${TIMEZONE:-}"
TIMEZONE_EXPLICIT=0
if [ -n "$TIMEZONE" ]; then
    TIMEZONE_EXPLICIT=1
fi
SKIP_UPGRADE=0
SKIP_EMBEDDED=0
SKIP_RUST=0
SKIP_ZSH=0
SKIP_TOOLS=0
SKIP_DOTFILES=0
SKIP_ZED=0
SKIP_KEYS=0
FORCE_GIT_DEFAULTS=0
DRY_RUN=0
NEEDS_SUDO=1
BOOTSTRAP_VERSION="0.1.1"
ROLLBACK=0
CHECK_UPDATE=0
ONLY_ACTIVE=0
ONLY_SECTIONS=""

# Color formatting (disabled when stdout is redirected to maintain clean logs)
if [ -t 1 ]; then
    BOLD='\033[1m'
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    RESET='\033[0m'
else
    BOLD=''
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    RESET=''
fi

# Asset distribution URLs
PAGES_BASE="https://leftger.github.io"
RAW_REPO_BASE="https://raw.githubusercontent.com/leftger/leftger.github.io/main"

# ------------------------------------------------------------------------------
# Helper Functions & Logging
# ------------------------------------------------------------------------------
# Portable which using bash type -P
which() {
    type -P "$@"
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command '$1' is missing. Please install it to continue."
        exit 1
    fi
}

retry() {
    local tries="$1" n="$1" pause=2
    shift
    if ! "$@"; then
        while [ $((--n)) -gt 0 ]; do
            log_warn "Command failed. Retrying in ${pause}s: $*"
            sleep "${pause}"
            pause=$((pause * 2))
            if "$@"; then return 0; fi
        done
        log_error "Failed ${tries} times executing: $*"
        return 1
    fi
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local computed=""

    if [ ! -f "$file" ]; then
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        computed="$(sha256sum -b "$file" 2>/dev/null | cut -c1-64)"
    elif command -v shasum >/dev/null 2>&1; then
        computed="$(shasum -a 256 -b "$file" 2>/dev/null | cut -c1-64)"
    elif command -v openssl >/dev/null 2>&1; then
        computed="$(openssl dgst -r -sha256 "$file" 2>/dev/null | cut -c1-64)"
    else
        log_warn "Cannot verify SHA-256 (no sha256sum, shasum, or openssl available)."
        return 0
    fi

    [ "$computed" = "$expected" ]
}

# Portable in-place sed (handles BSD sed on macOS and GNU sed on Linux)
sed_i() {
    if [ "${OS_TYPE:-$(uname -s)}" = "Darwin" ]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

detect_system_arch() {
    local arch
    arch="$(uname -m)"
    local os
    os="${OS_TYPE:-$(uname -s)}"

    if [ "$os" = "Darwin" ]; then
        # Check sysctl directly to avoid Rosetta 2 translation reporting x86_64 on Apple Silicon
        if (sysctl hw.optional.arm64 2>/dev/null || true) | grep -q ': 1'; then
            arch="arm64"
        elif (sysctl hw.optional.x86_64 2>/dev/null || true) | grep -q ': 1'; then
            arch="x86_64"
        fi
    fi

    echo "$arch"
}

downloader() {
    local url="$1"
    local dest="$2"
    local dld="curl"

    if command -v curl >/dev/null 2>&1; then
        local curl_bin
        curl_bin="$(command -v curl)"
        # Check for snap-confined curl
        if echo "$curl_bin" | grep -q "/snap/"; then
            if command -v wget >/dev/null 2>&1; then
                dld="wget"
            else
                log_warn "curl is installed via Snap and may have filesystem sandbox restrictions."
            fi
        fi
    elif command -v wget >/dev/null 2>&1; then
        dld="wget"
    else
        log_error "Neither curl nor wget was found."
        return 1
    fi

    if [ "$dld" = "curl" ]; then
        curl --retry 3 --retry-connrefused -C - --proto '=https' --tlsv1.2 -fsSL "$url" -o "$dest" 2>/dev/null || \
        curl --retry 3 -fsSL "$url" -o "$dest" 2>/dev/null || \
        curl -fsSL "$url" -o "$dest"
    else
        wget --tries=3 -c -qO "$dest" "$url"
    fi
}

detect_system_timezone() {
    local detected_tz=""
    local os_name
    os_name="${OS_TYPE:-$(uname -s)}"

    if [ "$os_name" = "Darwin" ]; then
        if [ -L /etc/localtime ]; then
            detected_tz="$(readlink /etc/localtime 2>/dev/null | sed -E 's/.*zoneinfo\///')"
        fi
        if [ -z "$detected_tz" ] && command -v systemsetup >/dev/null 2>&1; then
            detected_tz="$(systemsetup -gettimezone 2>/dev/null | sed -n 's/^Time Zone: //p')"
        fi
        if [ -z "$detected_tz" ] && command -v defaults >/dev/null 2>&1; then
            detected_tz="$(defaults read /Library/Preferences/.GlobalPreferences.plist com.apple.TimeZone 2>/dev/null || true)"
        fi
    else
        if command -v timedatectl >/dev/null 2>&1; then
            detected_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
        fi
        if [ -z "$detected_tz" ] && [ -L /etc/localtime ]; then
            detected_tz="$(readlink -f /etc/localtime 2>/dev/null | sed -E 's/.*zoneinfo\///')"
        fi
        if [ -z "$detected_tz" ] && [ -f /etc/timezone ]; then
            detected_tz="$(head -n 1 /etc/timezone 2>/dev/null | tr -d '[:space:]')"
        fi
    fi

    # Fallback to UTC if undetectable or malformed
    if [ -z "$detected_tz" ] || [ "$detected_tz" = "localtime" ]; then
        detected_tz="UTC"
    fi

    echo "$detected_tz"
}

# Persist a plain-text copy of each log line. LOG_FILE is set after the
# target user/home is resolved; until then logging remains console-only.
log_append() {
    if [ -n "${LOG_FILE:-}" ]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

log_info() {
    printf "${BLUE}[INFO]${RESET} %s\n" "$*"
    log_append "INFO: $*"
}

log_step() {
    printf "\n${BOLD}${CYAN}==>${RESET} ${BOLD}%s${RESET}\n" "$*"
    log_append "STEP: $*"
}

log_success() {
    printf "${GREEN}[✓]${RESET} %s\n" "$*"
    log_append "SUCCESS: $*"
}

log_warn() {
    printf "${YELLOW}[WARN]${RESET} %s\n" "$*" >&2
    log_append "WARN: $*"
}

log_error() {
    printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2
    log_append "ERROR: $*"
}

# ------------------------------------------------------------------------------
# Section gating for positive --*-only modes.
# ------------------------------------------------------------------------------
only_allows() {
    local section="$1"

    if [ "$ONLY_ACTIVE" -eq 0 ]; then
        return 0
    fi

    case " $ONLY_SECTIONS " in
        *" $section "*) return 0 ;;
    esac
    return 1
}

# ------------------------------------------------------------------------------
# Timestamped backup / rollback helpers.
# Backups are stored under:
#   ~/.local/state/leftger-bootstrap/backups/<YYYYmmdd_HHMMSS>
# Each backup keeps a manifest of the relative paths that existed before this
# bootstrap run. --rollback restores the newest manifest-backed originals.
# ------------------------------------------------------------------------------
backup_init() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    if [ -z "$BACKUP_DIR" ]; then
        BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        : >"$BACKUP_DIR/manifest.txt"
        chown -R "${TARGET_USER}" "$BACKUP_DIR" 2>/dev/null || true
        log_info "Created backup directory: ${BACKUP_DIR}"
    fi
}

backup_path() {
    local src="$1"
    local rel=""
    local dest=""

    [ -e "$src" ] || [ -L "$src" ] || return 0
    rel="${src#"${TARGET_HOME}/"}"
    if [ -z "$rel" ] || [ "$rel" = "$src" ]; then
        # Only paths inside the target home directory are backed up for now.
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Would back up ${src}"
        return 0
    fi

    backup_init
    if grep -Fxq "$rel" "$BACKUP_DIR/manifest.txt" 2>/dev/null; then
        return 0
    fi

    dest="$BACKUP_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
    echo "$rel" >>"$BACKUP_DIR/manifest.txt"
}

backup_dotfiles() {
    # Files/directories the dotfiles step is about to touch. This is called
    # after backup_path() was already used by the Zsh step where applicable, so
    # re-entry is harmless: the manifest keeps the ORIGINAL pre-bootstrap copy.
    backup_path "${TARGET_HOME}/.bash_aliases"
    backup_path "${TARGET_HOME}/.bashrc"
    backup_path "${TARGET_HOME}/.zshrc"
    backup_path "${TARGET_HOME}/.vimrc"
    backup_path "${TARGET_HOME}/.vim/colors"
    backup_path "${TARGET_HOME}/.gitignore"
    backup_path "${TARGET_HOME}/.gitmessage"
    backup_path "${TARGET_HOME}/.tmux.conf"
    backup_path "${TARGET_HOME}/.editorconfig"
    backup_path "${TARGET_HOME}/.githooks"
    backup_path "${TARGET_HOME}/.git_template"
    backup_path "${TARGET_HOME}/.gitconfig"
    backup_path "${TARGET_HOME}/.config/git/config"
    backup_path "${TARGET_HOME}/.hushlogin"
    backup_path "${TARGET_HOME}/.local/bin/full-upgrade"
    backup_path "${TARGET_HOME}/.oh-my-zsh/custom/plugins"
    backup_path "${TARGET_HOME}/.oh-my-zsh/custom/completions"
}

find_latest_backup() {
    find "$BACKUP_ROOT" -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]' -print 2>/dev/null | sort | tail -n 1 || true
}

rollback_bootstrap() {
    local backup=""
    local rel=""
    local src=""
    local dest=""

    backup="$(find_latest_backup)"
    if [ -z "$backup" ]; then
        log_error "No bootstrap backup found under ${BACKUP_ROOT}."
        exit 1
    fi
    if [ ! -f "$backup/manifest.txt" ]; then
        log_error "Backup ${backup} has no manifest.txt; refusing to roll back."
        exit 1
    fi

    log_step "Rolling back bootstrap changes from ${backup}"

    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        case "$rel" in
            \#* | manifest.txt) continue ;;
        esac
        src="$backup/$rel"
        dest="${TARGET_HOME}/$rel"

        if [ ! -e "$src" ] && [ ! -L "$src" ]; then
            log_warn "Backup entry missing on disk: ${src}"
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Restore ${rel} from ${backup}"
            continue
        fi

        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        cp -a "$src" "$dest"
        chown -R "${TARGET_USER}" "$dest" 2>/dev/null || true
        log_info "Restored ${rel}"
    done <"$backup/manifest.txt"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "Dry-run rollback completed. No files were modified."
    else
        log_success "Rollback complete. Files from ${backup} were restored."
    fi
}

# ------------------------------------------------------------------------------
# Version / update helpers.
# ------------------------------------------------------------------------------
fetch_remote_bootstrap_version() {
    local version=""

    if command -v curl >/dev/null 2>&1; then
        version="$(curl -m 10 -fsSL "${RAW_REPO_BASE}/bootstrap.sh" 2>/dev/null | sed -n 's/^BOOTSTRAP_VERSION="\([^"]*\)".*/\1/p' | head -n 1 || true)"
    elif command -v wget >/dev/null 2>&1; then
        version="$(wget -T 10 -qO- "${RAW_REPO_BASE}/bootstrap.sh" 2>/dev/null | sed -n 's/^BOOTSTRAP_VERSION="\([^"]*\)".*/\1/p' | head -n 1 || true)"
    else
        log_error "Neither curl nor wget is available to check for updates."
        return 1
    fi

    printf '%s' "$version"
}

check_for_update() {
    local local_v=""
    local remote_v=""
    local state_file="${STATE_DIR}/version"

    if [ -f "$state_file" ]; then
        # shellcheck disable=SC1090
        . "$state_file"
        local_v="${BOOTSTRAP_VERSION:-}"
    fi

    if [ -z "$local_v" ]; then
        local_v="none"
        log_info "No previous bootstrap version recorded at ${state_file}"
    fi
    log_info "Local bootstrap version: ${local_v}"

    remote_v="$(fetch_remote_bootstrap_version || true)"
    if [ -z "$remote_v" ]; then
        log_error "Could not determine the remote bootstrap version."
        exit 1
    fi
    log_info "Remote bootstrap version: ${remote_v}"

    if [ "$remote_v" = "$local_v" ]; then
        log_success "Bootstrap is up to date (${local_v})."
    else
        log_info "A new bootstrap version is available: ${local_v} -> ${remote_v}"
        log_info "Re-run: curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh"
    fi
}

write_version_state() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    mkdir -p "$STATE_DIR"
    cat >"${STATE_DIR}/version" <<EOF
BOOTSTRAP_VERSION="$BOOTSTRAP_VERSION"
EOF
    chown "${TARGET_USER}" "${STATE_DIR}/version" 2>/dev/null || true
    log_success "Bootstrap version ${BOOTSTRAP_VERSION} recorded in ${STATE_DIR}/version"
}

print_help() {
    cat <<EOF
Gerzain's Linux & macOS System Bootstrap Script v${BOOTSTRAP_VERSION}

Usage:
  ./bootstrap.sh [OPTIONS]
  curl -fsSL https://raw.githubusercontent.com/leftger/leftger.github.io/main/bootstrap.sh | bash -s -- [OPTIONS]

Options:
  -t, --timezone <TZ>   Set system timezone (default: autodetect system timezone)
      --skip-upgrade    Skip system / package manager upgrades
      --skip-embedded   Skip ARM Cortex-M toolchain and probe-rs setup
      --skip-rust       Skip Rust toolchain and cargo utilities installation
      --skip-zed        Skip Zed editor installation
      --skip-zsh        Skip Oh-My-Zsh installation and shell configuration
      --skip-tools      Skip modern CLI utilities installation
      --skip-dotfiles   Skip curated dotfiles, tmux, vim, and shell aliases
      --skip-keys       Skip ED25519 SSH and GPG key generation
      --force-git-defaults
                        Overwrite existing git config values with this script's
                        opinionated defaults (by default, only unset values are
                        applied so your current git config is left alone)
      --dry-run         Print actions without executing commands
      --rollback        Restore the newest bootstrap backup (user dotfiles)
      --check-update    Compare local state against the remote bootstrap version
      --locale-only     Run only the locale section
      --timezone-only   Run only the timezone section
      --system-only     Run only the package manager / system upgrade section
      --core-only       Run only the core development packages section
      --tools-only      Run only the modern CLI tools section
      --embedded-only   Run only the embedded ARM/hardware section
      --zsh-only        Run only the Zsh / Oh-My-Zsh section
      --dotfiles-only   Run only the curated dotfiles and keys section
      --rust-only       Run only the Rust toolchain section
      --zed-only        Run only the Zed editor section
  -v, --version         Print the bootstrap version and exit
  -h, --help            Show this help message and exit

Environment Variables:
  TIMEZONE              Overrides auto-detected timezone if --timezone is omitted

Notes:
  Multiple --*-only flags may be combined to run a subset of sections.
  The current run is logged to ~/.cache/leftger-bootstrap/ and user files are
  backed up under ~/.local/state/leftger-bootstrap/backups/ before changes.
EOF
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t | --timezone)
            TIMEZONE="$2"
            TIMEZONE_EXPLICIT=1
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
        --skip-zed)
            SKIP_ZED=1
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
        --skip-keys)
            SKIP_KEYS=1
            shift
            ;;
        --force-git-defaults)
            FORCE_GIT_DEFAULTS=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --rollback)
            ROLLBACK=1
            shift
            ;;
        --check-update)
            CHECK_UPDATE=1
            shift
            ;;
        --locale-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} locale "
            shift
            ;;
        --timezone-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} timezone "
            shift
            ;;
        --system-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} system "
            shift
            ;;
        --core-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} core "
            shift
            ;;
        --tools-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} tools "
            shift
            ;;
        --embedded-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} embedded "
            shift
            ;;
        --zsh-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} zsh "
            shift
            ;;
        --dotfiles-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} dotfiles "
            shift
            ;;
        --rust-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} rust "
            shift
            ;;
        --zed-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="${ONLY_SECTIONS} zed "
            shift
            ;;
        -v | --version)
            echo "leftger.github.io bootstrap v${BOOTSTRAP_VERSION}"
            exit 0
            ;;
        -h | --help)
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
if [ "$ROLLBACK" -eq 1 ] && [ "$CHECK_UPDATE" -eq 1 ]; then
    log_error "--rollback and --check-update cannot be used together."
    exit 1
fi
if [ "$ROLLBACK" -eq 1 ] && [ "$ONLY_ACTIVE" -eq 1 ]; then
    log_error "--rollback cannot be combined with --*-only modes."
    exit 1
fi
if [ "$CHECK_UPDATE" -eq 1 ] && [ "$ONLY_ACTIVE" -eq 1 ]; then
    log_error "--check-update cannot be combined with --*-only modes."
    exit 1
fi

# Positive --*-only modes should not prompt for sudo unless the selected
# sections actually need root/administrator privileges.
if [ "$ONLY_ACTIVE" -eq 1 ]; then
    NEEDS_SUDO=0
    case "$ONLY_SECTIONS" in
        *" locale "* | *" timezone "* | *" system "* | *" core "* | *" tools "* | *" embedded "* | *" zsh "*) NEEDS_SUDO=1 ;;
    esac
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log_info "Running in DRY RUN mode. No modifications will be made."
fi

# Verify essential system commands upfront
need_cmd uname
need_cmd mktemp
need_cmd chmod
need_cmd mkdir
need_cmd rm
need_cmd sed
need_cmd grep
need_cmd cat

# Ensure running on supported operating system (Linux or macOS)
OS_TYPE="$(uname -s)"
if [ "$OS_TYPE" != "Linux" ] && [ "$OS_TYPE" != "Darwin" ]; then
    log_error "Unsupported operating system: ${OS_TYPE}. This script supports Linux (Ubuntu/Debian) and macOS."
    exit 1
fi

ARCH_TYPE="$(detect_system_arch)"

IS_WSL=0
if [ -f /proc/version ] && grep -qi "microsoft" /proc/version 2>/dev/null; then
    IS_WSL=1
fi 

TARGET_USER="${SUDO_USER:-$USER}"
if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")"
elif command -v dscl >/dev/null 2>&1; then
    TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || echo "$HOME")"
else
    TARGET_HOME="$HOME"
fi

if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    TARGET_HOME="$HOME"
fi

# Autodetect timezone if not explicitly provided
if [ -z "$TIMEZONE" ]; then
    TIMEZONE="$(detect_system_timezone)"
fi

# Determine script location if running from a local checkout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

# Runtime state/log locations under the target user's home.
STATE_DIR="${TARGET_HOME}/.local/state/leftger-bootstrap"
BACKUP_ROOT="${STATE_DIR}/backups"
BACKUP_DIR=""

# --check-update is a read-only shortcut that exits before any system changes.
if [ "$CHECK_UPDATE" -eq 1 ]; then
    check_for_update
    exit 0
fi

LOG_FILE=""
if [ "$DRY_RUN" -eq 0 ]; then
    LOG_DIR="${TARGET_HOME}/.cache/leftger-bootstrap"
    mkdir -p "$LOG_DIR" "$STATE_DIR" "$BACKUP_ROOT"
    chown -R "${TARGET_USER}" "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
    LOG_FILE="${LOG_DIR}/bootstrap-$(date +%Y%m%d_%H%M%S).log"
    : >"$LOG_FILE"
    chown "${TARGET_USER}" "$LOG_FILE" 2>/dev/null || true
    log_info "Installation log: ${LOG_FILE}"
fi

# --rollback is also non-interactive and exits before package/system changes.
if [ "$ROLLBACK" -eq 1 ]; then
    rollback_bootstrap
    exit 0
fi

run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN]${RESET} %s\n" "$*"
    else
        "$@"
    fi
}

run_sudo() {
    local -a sudo_cmd=()
    if [ -n "${SUDO_ASKPASS-}" ]; then
        sudo_cmd=(sudo -A)
    else
        sudo_cmd=(sudo)
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN-SUDO]${RESET} %s\n" "$*"
    else
        if [ "$(id -u)" -eq 0 ]; then
            "$@"
        else
            "${sudo_cmd[@]}" "$@"
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

# Sets a global git config value only if it isn't already configured, so a
# re-run never clobbers config you set up yourself. Pass --force-git-defaults
# to intentionally reset a key to this script's opinionated default.
set_git_default() {
    local key="$1"
    local value="$2"
    local current=""

    current="$(run_user "git config --global --get $(printf '%q' "$key")" 2>/dev/null || true)"
    if [ -n "$current" ] && [ "$FORCE_GIT_DEFAULTS" -eq 0 ]; then
        log_info "Keeping existing git config ${key}=${current} (use --force-git-defaults to override)"
        return 0
    fi
    run_user "git config --global $(printf '%q' "$key") $(printf '%q' "$value")"
}

# Setup isolated temporary workspace and sudo keep-alive
BOOTSTRAP_TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'bootstrap_tmp')"
SUDO_PID=""

cleanup() {
    if [ -n "$SUDO_PID" ]; then
        kill "$SUDO_PID" 2>/dev/null || true
    fi
    if [ -n "$BOOTSTRAP_TMP_DIR" ] && [ -d "$BOOTSTRAP_TMP_DIR" ]; then
        rm -rf "$BOOTSTRAP_TMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT QUIT TERM

if [ "$DRY_RUN" -eq 0 ] && [ "$NEEDS_SUDO" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
        log_info "Sudo privileges active."
    else
        log_info "Prompting for sudo privileges..."
        if [ -n "${SUDO_ASKPASS-}" ]; then
            sudo -A -v
        elif [ -t 0 ]; then
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
if only_allows locale; then
log_step "Configuring Locale to en_US.UTF-8"

if [ "$OS_TYPE" = "Linux" ]; then
    run_sudo apt-get update -qq
    run_sudo apt-get install "${APT_FLAGS[@]}" locales

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Enable en_US.UTF-8 in /etc/locale.gen, run locale-gen and update-locale"
    else
        if grep -q "^# en_US.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null; then
            run_sudo sed_i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        fi
        run_sudo locale-gen en_US.UTF-8
        run_sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
        export LANG=en_US.UTF-8
        export LC_ALL=en_US.UTF-8
    fi
else
    log_info "macOS detected. Standard en_US.UTF-8 locale is enabled by default."
fi
log_success "Locale configured to en_US.UTF-8"
fi

# ------------------------------------------------------------------------------
# Step 2: Timezone Configuration
# ------------------------------------------------------------------------------
if only_allows timezone; then
if [ "$TIMEZONE_EXPLICIT" -eq 1 ]; then
    log_step "Configuring Timezone to ${TIMEZONE}"
else
    log_step "Timezone Configuration (Preserving detected: ${TIMEZONE})"
fi

if [ "$OS_TYPE" = "Darwin" ]; then
    if [ "$TIMEZONE_EXPLICIT" -eq 1 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Set system timezone to ${TIMEZONE} via systemsetup"
        else
            run_sudo systemsetup -settimezone "$TIMEZONE" 2>/dev/null || true
        fi
        log_success "Timezone set to ${TIMEZONE}"
    else
        log_info "macOS system timezone retained: ${TIMEZONE}"
        log_success "Timezone preserved as ${TIMEZONE}"
    fi
else
    if [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
        log_warn "Timezone '${TIMEZONE}' not found in /usr/share/zoneinfo. Falling back to UTC."
        TIMEZONE="UTC"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$TIMEZONE_EXPLICIT" -eq 1 ]; then
            log_info "[DRY-RUN] Setting system timezone to ${TIMEZONE} via timedatectl and /etc/localtime"
        else
            log_info "[DRY-RUN] Ensuring tzdata matches detected timezone ${TIMEZONE}"
        fi
    else
        if [ "$TIMEZONE_EXPLICIT" -eq 1 ]; then
            if command -v timedatectl >/dev/null 2>&1 && timedatectl 2>/dev/null | grep -q "Time zone"; then
                run_sudo timedatectl set-timezone "$TIMEZONE" || true
            fi
            run_sudo ln -fs "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
            echo "$TIMEZONE" | run_sudo tee /etc/timezone >/dev/null
            run_sudo dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
            log_success "Timezone set to ${TIMEZONE}"
        else
            if [ ! -e /etc/localtime ] || [ -L /etc/localtime ]; then
                run_sudo ln -fs "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
            fi
            echo "$TIMEZONE" | run_sudo tee /etc/timezone >/dev/null
            run_sudo dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
            log_success "Timezone configured as ${TIMEZONE} (autodetected)"
        fi
    fi
fi
fi

# ------------------------------------------------------------------------------
# Step 3: Package Manager & System Upgrades
# ------------------------------------------------------------------------------
if only_allows system; then
if [ "$OS_TYPE" = "Darwin" ]; then
    log_step "Setting Up Homebrew on macOS"

    # Install Xcode Command Line Tools if missing
    if ! xcode-select -p >/dev/null 2>&1; then
        log_info "Xcode Command Line Tools missing. Initiating installation..."
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Install Xcode Command Line Tools via softwareupdate or xcode-select"
        else
            # Attempt headless installation first using softwareupdate trigger file
            clt_placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
            run_sudo touch "${clt_placeholder}"
            clt_label="$(/usr/sbin/softwareupdate -l 2>/dev/null | grep -B 1 -E 'Command Line Tools' | awk -F'*' '/^ *\*/ {print $2}' | sed -e 's/^ *Label: //' -e 's/^ *//' | sort -V | tail -n1)"
            if [ -n "${clt_label}" ]; then
                log_info "Installing ${clt_label} headlessly via softwareupdate..."
                run_sudo /usr/sbin/softwareupdate -i "${clt_label}" || true
                run_sudo /usr/bin/xcode-select --switch /Library/Developer/CommandLineTools 2>/dev/null || true
            fi
            run_sudo rm -f "${clt_placeholder}"

            # Fallback to standard xcode-select if not yet active
            if ! xcode-select -p >/dev/null 2>&1; then
                run_cmd xcode-select --install || true
            fi
        fi
    fi

    # Enable Touch ID for sudo on macOS (persists across OS updates via sudo_local)
    if [ -f /etc/pam.d/sudo_local.template ] && [ ! -f /etc/pam.d/sudo_local ]; then
        log_info "Enabling Touch ID for sudo via /etc/pam.d/sudo_local..."
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Enable pam_tid.so in /etc/pam.d/sudo_local"
        else
            run_sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local
            run_sudo sed_i 's/^#auth/auth/' /etc/pam.d/sudo_local
        fi
    fi

    # Install Homebrew if not already installed
    if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
        log_info "Installing Homebrew..."
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Install Homebrew via curl https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
        else
            run_user 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        fi
    else
        log_info "Homebrew is already installed."
    fi

    # Activate brew shell environment in current session
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    if [ "$SKIP_UPGRADE" -eq 0 ]; then
        log_info "Updating Homebrew and formula index..."
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] brew update && brew upgrade"
        else
            run_user "brew update && brew upgrade" || true
        fi
    fi
    log_success "Homebrew ready"
else
    # Linux (Debian / Ubuntu)
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
fi
fi

# ------------------------------------------------------------------------------
# Step 4: Core Development Tools & Dependencies
# ------------------------------------------------------------------------------
if only_allows core; then
log_step "Installing Core Development Tools & Dependencies"

if [ "$OS_TYPE" = "Darwin" ]; then
    BREW_CORE_PACKAGES=(
        cmake
        ninja
        pkg-config
        llvm
        git
        git-lfs
        curl
        wget
        jq
        tree
        vim
        mosh
        tmux
    )
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] brew install ${BREW_CORE_PACKAGES[*]}"
    else
        run_user "brew install ${BREW_CORE_PACKAGES[*]}" || true
    fi
    log_success "Core development packages installed via Homebrew"
else
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
        mosh
        binutils
        tmux
        command-not-found
    )
    run_sudo apt-get install "${APT_FLAGS[@]}" "${CORE_PACKAGES[@]}"
    log_success "Core development packages installed via APT"
fi
fi

# ------------------------------------------------------------------------------
# Step 5: Modern CLI Productivity Utilities
# ------------------------------------------------------------------------------
if only_allows tools && [ "$SKIP_TOOLS" -eq 0 ]; then
    log_step "Installing Modern CLI Productivity Utilities"

    if [ "$OS_TYPE" = "Darwin" ]; then
        BREW_CLI_PACKAGES=(
            ripgrep
            fd
            bat
            fzf
            btop
        )
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] brew install ${BREW_CLI_PACKAGES[*]}"
        else
            run_user "brew install ${BREW_CLI_PACKAGES[*]}" || true
        fi
    else
        CLI_PACKAGES=(
            ripgrep
            fd-find
            bat
            fzf
            btop
        )
        run_sudo apt-get install "${APT_FLAGS[@]}" "${CLI_PACKAGES[@]}"

        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Symlink batcat -> ~/.local/bin/bat and fdfind -> ~/.local/bin/fd"
        else
            mkdir -p "${TARGET_HOME}/.local/bin"
            if command -v batcat >/dev/null 2>&1 && [ ! -e "${TARGET_HOME}/.local/bin/bat" ]; then
                ln -sf "$(command -v batcat)" "${TARGET_HOME}/.local/bin/bat"
                log_info "Symlinked batcat -> ~/.local/bin/bat"
            fi
            if command -v fdfind >/dev/null 2>&1 && [ ! -e "${TARGET_HOME}/.local/bin/fd" ]; then
                ln -sf "$(command -v fdfind)" "${TARGET_HOME}/.local/bin/fd"
                log_info "Symlinked fdfind -> ~/.local/bin/fd"
            fi
        fi
    fi

    log_success "Modern CLI utilities installed and configured"
fi

# ------------------------------------------------------------------------------
# Step 6: Embedded ARM Toolchain & Hardware Tools
# ------------------------------------------------------------------------------
if only_allows embedded && [ "$SKIP_EMBEDDED" -eq 0 ]; then
    log_step "Installing Embedded ARM Cross-Compilation Toolchain & Hardware Tools"

    if [ "$OS_TYPE" = "Darwin" ]; then
        BREW_EMBEDDED_PACKAGES=(
            openocd
            libusb
            hidapi
            tio
        )
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] brew install ${BREW_EMBEDDED_PACKAGES[*]}"
            log_info Behind [DRY-RUN] brew install --cask gcc-arm-embedded
        else
            log_info "Installing embedded utilities via Homebrew..."
            run_user "brew install ${BREW_EMBEDDED_PACKAGES[*]}" || true
            log_info "Installing ARM GNU embedded toolchain via Homebrew cask..."
            run_user "brew install --cask gcc-arm-embedded || brew install arm-none-eabi-gcc || true"
        fi
        log_info "macOS manages serial and USB debugger access automatically."
    else
        EMBEDDED_PACKAGES=(
            gcc-arm-none-eabi
            binutils-arm-none-eabi
            libnewlib-arm-none-eabi
            libstdc++-arm-none-eabi-newlib
            gdb-multiarch
            openocd
            libudev-dev
            libusb-1.0-0-dev
            tio
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
            UDEV_TEMP="${BOOTSTRAP_TMP_DIR}/69-probe-rs.rules"
            if downloader "$UDEV_RULES_URL" "$UDEV_TEMP"; then
                run_sudo mv "$UDEV_TEMP" "$UDEV_TARGET"
                run_sudo chmod 644 "$UDEV_TARGET"
                run_sudo udevadm control --reload-rules 2>/dev/null || true
                run_sudo udevadm trigger 2>/dev/null || true
                log_success "Hardware udev rules installed"
            else
                log_warn "Could not fetch probe-rs udev rules. Continuing."
            fi
        fi
    fi

    log_success "Embedded ARM toolchain and hardware access configured"
else
    if [ "$SKIP_EMBEDDED" -eq 1 ]; then
        log_info "Skipping embedded setup (--skip-embedded specified)"
    else
        log_info "Skipping embedded section (not selected by --*-only)"
    fi
fi

# ------------------------------------------------------------------------------
# Step 7: Zsh & Oh-My-Zsh Installation
# ------------------------------------------------------------------------------
if only_allows zsh && [ "$SKIP_ZSH" -eq 0 ]; then
    log_step "Installing and Configuring Zsh + Oh-My-Zsh"

    # Preserve the user's existing shell state before any file is modified.
    backup_path "${TARGET_HOME}/.zshrc"
    backup_path "${TARGET_HOME}/.bashrc"
    backup_path "${TARGET_HOME}/.oh-my-zsh/custom/plugins"
    backup_path "${TARGET_HOME}/.oh-my-zsh/custom/completions"

    if [ "$OS_TYPE" = "Linux" ]; then
        run_sudo apt-get install "${APT_FLAGS[@]}" zsh
    fi

    OMZ_DIR="${TARGET_HOME}/.oh-my-zsh"
    if [ ! -d "$OMZ_DIR" ]; then
        log_info "Installing Oh-My-Zsh (unattended)..."
        run_user 'RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    else
        log_info "Oh-My-Zsh is already installed at ${OMZ_DIR}"
    fi

    # Plugins: zsh-autosuggestions, zsh-syntax-highlighting & official zsh-completions repository
    PLUGINS_DIR="${OMZ_DIR}/custom/plugins"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Clone zsh-autosuggestions, zsh-syntax-highlighting & zsh-completions into ${PLUGINS_DIR}"
    else
        mkdir -p "$PLUGINS_DIR"
        if [ ! -d "${PLUGINS_DIR}/zsh-autosuggestions" ]; then
            git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "${PLUGINS_DIR}/zsh-autosuggestions" 2>/dev/null || true
        fi
        if [ ! -d "${PLUGINS_DIR}/zsh-syntax-highlighting" ]; then
            git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${PLUGINS_DIR}/zsh-syntax-highlighting" 2>/dev/null || true
        fi
        if [ ! -d "${PLUGINS_DIR}/zsh-completions" ]; then
            git clone https://github.com/zsh-users/zsh-completions.git "${PLUGINS_DIR}/zsh-completions" 2>/dev/null || true
        fi
    fi

    # Configure ~/.zshrc
    ZSHRC="${TARGET_HOME}/.zshrc"
    # purged 'cargo' and 'my-completions'; migrated 'cargo' features to the native 'rust' plugin
    TARGET_PLUGINS="git sudo rust extract z colored-man-pages command-not-found zsh-autosuggestions zsh-syntax-highlighting"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Configure plugins (${TARGET_PLUGINS}) and PATH in ${ZSHRC}"
    else
        if [ -f "$ZSHRC" ]; then
            if grep -q "^plugins=(" "$ZSHRC"; then
                sed_i "s/^plugins=(.*)/plugins=($TARGET_PLUGINS)/" "$ZSHRC"
            elif ! grep -q "plugins=" "$ZSHRC"; then
                echo "plugins=($TARGET_PLUGINS)" >>"$ZSHRC"
            fi
            if ! grep -q 'GPG_TTY' "$ZSHRC"; then
                cat <<'EOF' >>"$ZSHRC"

# Attach GPG pinentry to the active terminal
if [ -t 0 ]; then
    export GPG_TTY=$(tty)
fi
EOF
            fi
            if ! grep -q 'export PATH="\$HOME/\.local/bin:\$HOME/\.cargo/bin:\$PATH"' "$ZSHRC"; then
                echo '' >>"$ZSHRC"
                echo '# User custom binary search path' >>"$ZSHRC"
                echo 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"' >>"$ZSHRC"
            fi
            if [ "$OS_TYPE" = "Darwin" ] && ! grep -q 'brew shellenv' "$ZSHRC"; then
                cat <<'EOF' >>"$ZSHRC"

# Initialize Homebrew environment on macOS
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi
EOF
            fi
            if ! grep -q 'DISABLE_MAGIC_FUNCTIONS="true"' "$ZSHRC"; then
                echo 'DISABLE_MAGIC_FUNCTIONS="true"' >>"$ZSHRC"
            fi
            if ! grep -q 'DISABLE_UNTRACKED_FILES_DIRTY="true"' "$ZSHRC"; then
                echo 'DISABLE_UNTRACKED_FILES_DIRTY="true"' >>"$ZSHRC"
            fi
            if ! grep -q 'fzf --zsh' "$ZSHRC"; then
                cat <<'EOF' >>"$ZSHRC"

# Interactive fzf keybindings (Ctrl+R, Ctrl+T, Alt+C) and fuzzy completion
if command -v fzf >/dev/null 2>&1; then
    eval "$(fzf --zsh 2>/dev/null || true)"
fi
EOF
            fi
        fi
    fi

    # Set default shell to zsh (Linux & macOS)
    ZSH_BIN="$(command -v zsh)"
    if [ -n "$ZSH_BIN" ]; then
        if [ "$OS_TYPE" = "Darwin" ]; then
            # Ensure Homebrew/custom Zsh is registered in /etc/shells on macOS
            if ! grep -Fxq "$ZSH_BIN" /etc/shells 2>/dev/null; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    log_info "[DRY-RUN] Add ${ZSH_BIN} to /etc/shells"
                else
                    echo "$ZSH_BIN" | run_sudo tee -a /etc/shells >/dev/null
                fi
            fi
        fi
        CURRENT_SHELL="$(getent passwd "${TARGET_USER}" 2>/dev/null | cut -d: -f7 || echo "$SHELL")"
        if [ "$CURRENT_SHELL" != "$ZSH_BIN" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info "[DRY-RUN] Change default shell to ${ZSH_BIN} for ${TARGET_USER}"
            else
                log_info "Changing default shell to ${ZSH_BIN} for ${TARGET_USER}..."
                run_sudo chsh -s "$ZSH_BIN" "$TARGET_USER" || true
            fi
        fi
    fi

    log_success "Zsh & Oh-My-Zsh configured"
else
    if [ "$SKIP_ZSH" -eq 1 ]; then
        log_info "Skipping Zsh setup (--skip-zsh specified)"
    else
        log_info "Skipping Zsh section (not selected by --*-only)"
    fi
fi

# ------------------------------------------------------------------------------
# Step 8: Curated Dotfiles (Vim, Tmux, Standards & Shell Productivity)
# ------------------------------------------------------------------------------
if only_allows dotfiles && [ "$SKIP_DOTFILES" -eq 0 ]; then
    log_step "Configuring Curated Dotfiles & Shell Environment"

    # Preserve every pre-existing dotfile / git config that is about to change.
    backup_dotfiles

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
            retry 3 downloader "${PAGES_BASE}/${rel_path}" "$dest" || \
                retry 3 downloader "${RAW_REPO_BASE}/${rel_path}" "$dest" || true
        fi
        chown "${TARGET_USER}" "$dest" 2>/dev/null || true
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
            cat <<'EOF' >>"$ZSHRC"

# Load shell aliases & functions (emulate ksh for seamless compatibility)
if [ -f "$HOME/.bash_aliases" ]; then
    emulate ksh -c "source '$HOME/.bash_aliases'"
fi
EOF
        fi

        # Ensure .bashrc sources ~/.bash_aliases
        BASHRC="${TARGET_HOME}/.bashrc"
        if [ -f "$BASHRC" ] && ! grep -q '\.bash_aliases' "$BASHRC"; then
            cat <<'EOF' >>"$BASHRC"

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

    # Deploy .editorconfig
    EDITORCONFIG_DEST="${TARGET_HOME}/.editorconfig"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy .editorconfig to ${EDITORCONFIG_DEST}"
    else
        fetch_asset "dotfiles/.editorconfig" "$EDITORCONFIG_DEST"
    fi

    # Deploy global Git hooks dispatcher (~/.githooks) — forwards to ./.githooks/*
    GITHOOKS_DIR="${TARGET_HOME}/.githooks"
    GIT_HOOK_NAMES=(
        applypatch-msg pre-applypatch post-applypatch
        pre-commit prepare-commit-msg commit-msg post-commit
        pre-rebase post-checkout post-merge pre-push
        pre-auto-gc post-rewrite push-to-checkout sendemail-validate
    )
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy global Git hooks dispatcher to ${GITHOOKS_DIR}"
    else
        mkdir -p "$GITHOOKS_DIR"
        fetch_asset "dotfiles/.githooks/_dispatch" "${GITHOOKS_DIR}/_dispatch"
        chmod +x "${GITHOOKS_DIR}/_dispatch" 2>/dev/null || true
        for hook in "${GIT_HOOK_NAMES[@]}"; do
            ln -sfn _dispatch "${GITHOOKS_DIR}/${hook}"
        done
        chown -R "${TARGET_USER}" "$GITHOOKS_DIR" 2>/dev/null || true
    fi

    # Deploy Git init template (editorconfig seed source for post-checkout)
    GIT_TEMPLATE_DIR="${TARGET_HOME}/.git_template"
    GIT_TEMPLATE_EDITORCONFIG="${GIT_TEMPLATE_DIR}/root/.editorconfig"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy Git template editorconfig to ${GIT_TEMPLATE_EDITORCONFIG}"
    else
        mkdir -p "${GIT_TEMPLATE_DIR}/root"
        fetch_asset "dotfiles/.git_template/root/.editorconfig" "$GIT_TEMPLATE_EDITORCONFIG"
        chown -R "${TARGET_USER}" "$GIT_TEMPLATE_DIR" 2>/dev/null || true
    fi

    # Deploy .hushlogin (silence login MOTD)
    HUSHLOGIN_DEST="${TARGET_HOME}/.hushlogin"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy .hushlogin to ${HUSHLOGIN_DEST}"
    else
        touch "$HUSHLOGIN_DEST"
        chown "${TARGET_USER}" "$HUSHLOGIN_DEST" 2>/dev/null || true
    fi

    # Deploy full-upgrade script
    FULL_UPGRADE_DEST="${TARGET_HOME}/.local/bin/full-upgrade"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy full-upgrade script to ${FULL_UPGRADE_DEST}"
    else
        mkdir -p "${TARGET_HOME}/.local/bin"
        fetch_asset "dotfiles/bin/full-upgrade" "$FULL_UPGRADE_DEST"
        chmod +x "$FULL_UPGRADE_DEST" 2>/dev/null || true
    fi

    # Deploy Zsh completion for cdr (_cdr) into its dedicated local directory
    CDR_COMPLETION_DIR="${TARGET_HOME}/.oh-my-zsh/custom/completions"
    CDR_COMPLETION_DEST="${CDR_COMPLETION_DIR}/_cdr"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Deploy _cdr completion to ${CDR_COMPLETION_DEST}"
    else
        mkdir -p "$CDR_COMPLETION_DIR"
        fetch_asset "dotfiles/.oh-my-zsh/custom/plugins/my-completions/_cdr" "$CDR_COMPLETION_DEST"
        chown -R "${TARGET_USER}" "$CDR_COMPLETION_DIR" 2>/dev/null || true
    fi

    # Inject optimized initialization configuration hooks before oh-my-zsh setup block
    ZSHRC="${TARGET_HOME}/.zshrc"
    if [ "$DRY_RUN" -eq 0 ] && [ -f "$ZSHRC" ]; then
        if ! grep -q 'plugins/zsh-completions/src' "$ZSHRC"; then
            log_info "Injecting optimized zsh-completions configurations hooks..."

            # Custom code block template engine rules
            ZSH_COMP_BLOCK=$(
                cat <<'EOF'

# zsh-completions optimized initialization (prevents double compinit performance issues)
fpath+=${ZSH_CUSTOM:-${ZSH:-~/.oh-my-zsh}/custom}/plugins/zsh-completions/src
fpath+=${ZSH_CUSTOM:-${ZSH:-~/.oh-my-zsh}/custom}/completions
autoload -U compinit && compinit
EOF
            )
            # Find and dynamically split right before sourcing oh-my-zsh main binary script
            if grep -q 'source "$ZSH/oh-my-zsh.sh"' "$ZSHRC"; then
                awk -v block="$ZSH_COMP_BLOCK" '/source "\$ZSH\/oh-my-zsh.sh"/{print block}1' "$ZSHRC" >"$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
            else
                # Fallback safety validation mount append point if line structure changes
                echo "$ZSH_COMP_BLOCK" >>"$ZSHRC"
            fi
        fi
    fi

    # Ensure systemd is enabled if running inside WSL
    if grep -qi microsoft /proc/version 2>/dev/null; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Ensure boot.systemd=true in /etc/wsl.conf"
        else
            if [ ! -f /etc/wsl.conf ] || ! grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
                log_info "Configuring systemd in /etc/wsl.conf for WSL..."
                run_sudo bash -c 'printf "[boot]\nsystemd=true\n" >> /etc/wsl.conf' || true
            fi
        fi
    fi

    # Configure Git Defaults, Core Settings, and Aliases
    log_info "Configuring Git defaults, push settings, commit template, and aliases..."
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Set git core (hooksPath=~/.githooks, templateDir), push.autoSetupRemote, rebase/merge autoStash, commit template, and aliases (only for values not already configured, unless --force-git-defaults)"
    else
        set_git_default "core.editor" "vim"
        set_git_default "init.defaultBranch" "main"
        set_git_default "init.templateDir" "${TARGET_HOME}/.git_template"
        set_git_default "core.hooksPath" "${TARGET_HOME}/.githooks"
        set_git_default "core.excludesfile" "${TARGET_HOME}/.gitignore"
        set_git_default "commit.template" "${TARGET_HOME}/.gitmessage"
        set_git_default "commit.cleanup" "strip"
        set_git_default "push.autoSetupRemote" "true"
        set_git_default "rebase.autoStash" "true"
        set_git_default "merge.autoStash" "true"

        # Platform-specific Git Credential Manager
        if [ "$OS_TYPE" = "Darwin" ]; then
            set_git_default "credential.helper" "osxkeychain"
        elif [ "$IS_WSL" -eq 1 ]; then
            if [ -x "/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager.exe" ]; then
                set_git_default "credential.helper" "/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager.exe"
            elif [ -x "/mnt/c/Program Files/Git/mingw64/libexec/git-core/git-credential-manager.exe" ]; then
                set_git_default "credential.helper" "/mnt/c/Program Files/Git/mingw64/libexec/git-core/git-credential-manager.exe"
            fi
        fi

        # Prompt for git identity if not already configured
        prompt_for_value() {
            local prompt_text="$1"
            local answer=""

            if [ -t 0 ]; then
                printf "${CYAN}%s${RESET}" "$prompt_text" >&2
                read -r answer || true
            elif [ -r /dev/tty ]; then
                printf "${CYAN}%s${RESET}" "$prompt_text" >&2
                read -r answer </dev/tty || true
            fi

            printf '%s' "$answer"
            return 0
        }

        CURRENT_GIT_NAME="$(run_user 'git config --global user.name' 2>/dev/null || true)"
        CURRENT_GIT_EMAIL="$(run_user 'git config --global user.email' 2>/dev/null || true)"

        if [ -z "$CURRENT_GIT_NAME" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info "[DRY-RUN] Prompt for git user.name (not currently configured)"
            else
                GIT_NAME_INPUT="$(prompt_for_value 'Git user.name is not set. Enter the name to use for commits: ')"
                if [ -n "$GIT_NAME_INPUT" ]; then
                    run_user "git config --global user.name $(printf '%q' "$GIT_NAME_INPUT")"
                    CURRENT_GIT_NAME="$GIT_NAME_INPUT"
                else
                    log_warn "No git user.name provided (no terminal input available or empty response); leaving user.name unconfigured."
                fi
            fi
        fi

        if [ -z "$CURRENT_GIT_EMAIL" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info "[DRY-RUN] Prompt for git user.email (not currently configured)"
            else
                GIT_EMAIL_INPUT="$(prompt_for_value 'Git user.email is not set. Enter the email to use for commits: ')"
                if [ -n "$GIT_EMAIL_INPUT" ]; then
                    run_user "git config --global user.email $(printf '%q' "$GIT_EMAIL_INPUT")"
                    CURRENT_GIT_EMAIL="$GIT_EMAIL_INPUT"
                else
                    log_warn "No git user.email provided (no terminal input available or empty response); leaving user.email unconfigured."
                fi
            fi
        fi

        # Install productivity aliases
        set_git_default "alias.caa" "commit --amend --all"
        set_git_default "alias.caane" "commit --amend --all --no-edit"
        set_git_default "alias.cob" "checkout -b"
        set_git_default "alias.apply-gitignore" '!f() { set -ex; git rm -r --cached . >/dev/null; git add .; }; f'

        # Install pa alias
        PA_CMD='!f() { [ -d "$1" ] && { d="$1"; shift; } || d="."; for r in "$d"/*/; do [ -e "$r/.git" ] || continue; b=$(git -C "$r" branch --show-current 2>/dev/null); [ -n "$b" ] || continue; echo "==> $(basename "$r") ($b)..."; git -C "$r" config remote.upstream.url >/dev/null 2>&1 && git -C "$r" pull upstream "$b" "$@"; git -C "$r" pull origin "$b" "$@"; done; }; f'
        set_git_default "alias.pa" "$PA_CMD"
    fi

    # --------------------------------------------------------------------------
    # SSH & GPG Key Configuration (ED25519)
    # --------------------------------------------------------------------------
    if [ "$SKIP_KEYS" -eq 0 ]; then
        log_info "Verifying ED25519 SSH and GPG keys..."

        KEY_USER_NAME="$(run_user 'git config --global user.name' 2>/dev/null || true)"
        KEY_USER_EMAIL="$(run_user 'git config --global user.email' 2>/dev/null || true)"

        # 1. ED25519 SSH Key
        SSH_DIR="${TARGET_HOME}/.ssh"
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chown "${TARGET_USER}" "$SSH_DIR" 2>/dev/null || true

        if [ ! -f "${SSH_DIR}/id_ed25519" ] && [ ! -f "${SSH_DIR}/id_rsa" ] && [ ! -f "${SSH_DIR}/id_ecdsa" ]; then
            log_info "No SSH key found. Generating new ED25519 SSH key..."
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info "[DRY-RUN] ssh-keygen -t ed25519 -C '${KEY_USER_EMAIL}' -f '${SSH_DIR}/id_ed25519' -N ''"
            else
                run_user "ssh-keygen -t ed25519 -C '${KEY_USER_EMAIL}' -f '${SSH_DIR}/id_ed25519' -N ''"
                chmod 600 "${SSH_DIR}/id_ed25519"
                chmod 644 "${SSH_DIR}/id_ed25519.pub"
                chown "${TARGET_USER}" "${SSH_DIR}/id_ed25519" "${SSH_DIR}/id_ed25519.pub" 2>/dev/null || true
                log_success "ED25519 SSH key generated at ${SSH_DIR}/id_ed25519"
            fi
        else
            log_info "SSH key already present in ${SSH_DIR}"
        fi

        # 2. ED25519 GPG Key
        if command -v gpg >/dev/null 2>&1; then
            if ! run_user "gpg --list-secret-keys 2>/dev/null" | grep -q 'sec'; then
                if [ -z "$KEY_USER_NAME" ] || [ -z "$KEY_USER_EMAIL" ]; then
                    log_warn "Git user.name/user.email are not configured; skipping GPG key generation."
                else
                    log_info "No GPG secret key found. Generating ED25519 GPG key..."
                    if [ "$DRY_RUN" -eq 1 ]; then
                        log_info "[DRY-RUN] gpg --batch --passphrase '' --quick-generate-key '${KEY_USER_NAME} <${KEY_USER_EMAIL}>' ed25519 default 0"
                    else
                        run_user "gpg --batch --passphrase '' --quick-generate-key '${KEY_USER_NAME} <${KEY_USER_EMAIL}>' ed25519 default 0"
                        GPG_KEY_ID="$(run_user "gpg --list-secret-keys --with-colons '${KEY_USER_EMAIL}' 2>/dev/null | awk -F: '/^sec:/ {print \$5}' | head -n1")"
                        if [ -n "$GPG_KEY_ID" ]; then
                            set_git_default "user.signingkey" "$GPG_KEY_ID"
                            set_git_default "commit.gpgsign" "true"
                            set_git_default "gpg.program" "gpg"
                            log_success "ED25519 GPG key generated (Key ID: ${GPG_KEY_ID}) and configured for Git commit signing"
                        fi
                    fi
                fi
            else
                log_info "GPG secret key already present."
                EXISTING_GPG_KEY=""
                if [ -n "$KEY_USER_EMAIL" ]; then
                    EXISTING_GPG_KEY="$(run_user "gpg --list-secret-keys --with-colons '${KEY_USER_EMAIL}' 2>/dev/null | awk -F: '/^sec:/ {print \$5}' | head -n1")"
                fi
                if [ -n "$EXISTING_GPG_KEY" ] && [ "$DRY_RUN" -eq 0 ]; then
                    set_git_default "user.signingkey" "$EXISTING_GPG_KEY"
                    set_git_default "commit.gpgsign" "true"
                    set_git_default "gpg.program" "gpg"
                else
                    log_info "No GPG secret key matches ${KEY_USER_EMAIL:-your configured git email}; leaving existing signing configuration untouched."
                fi
            fi
        fi
    fi

    log_success "Dotfiles configured (.vimrc, themes, aliases, ~/.githooks dispatcher, and Git pa configured)"
else
    if [ "$SKIP_DOTFILES" -eq 1 ]; then
        log_info "Skipping dotfiles setup (--skip-dotfiles specified)"
    else
        log_info "Skipping dotfiles section (not selected by --*-only)"
    fi
fi

# ------------------------------------------------------------------------------
# Step 9: Rust Toolchain & Embedded Ecosystem
# ------------------------------------------------------------------------------
if only_allows rust && [ "$SKIP_RUST" -eq 0 ]; then
    log_step "Installing Rust Toolchain & Embedded Ecosystem"

    CARGO_HOME="${TARGET_HOME}/.cargo"
    RUSTUP_BIN="${CARGO_HOME}/bin/rustup"

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

    # Install cargo subcommands & embedded utilities via cargo-binstall
    BINSTALL_BIN="${CARGO_HOME}/bin/cargo-binstall"
    CARGO_TOOLS=(cargo-deny cargo-llvm-cov cargo-generate cargo-binutils)
    if [ "$SKIP_EMBEDDED" -eq 0 ]; then
        CARGO_TOOLS+=(espflash cargo-espflash)
    fi
    log_info "Installing cargo tools: ${CARGO_TOOLS[*]}..."
    run_user "${BINSTALL_BIN} --no-confirm ${CARGO_TOOLS[*]} || true"

    log_success "Rust toolchain and embedded tooling installed"
else
    if [ "$SKIP_RUST" -eq 1 ]; then
        log_info "Skipping Rust setup (--skip-rust specified)"
    else
        log_info "Skipping Rust section (not selected by --*-only)"
    fi
fi

# ------------------------------------------------------------------------------
# Step 10: Zed Editor
# ------------------------------------------------------------------------------
if only_allows zed && [ "$SKIP_ZED" -eq 0 ]; then
    log_step "Installing Zed Editor"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Install Zed editor via curl -f https://zed.dev/install.sh | sh"
    else
        if ! run_user "command -v zed >/dev/null 2>&1" && [ ! -f "${TARGET_HOME}/.local/bin/zed" ]; then
            log_info "Installing Zed editor..."
            run_user "curl -f https://zed.dev/install.sh | sh || true"
            log_success "Zed editor installed"
        else
            log_info "Zed editor is already installed at $(run_user 'command -v zed 2>/dev/null' || echo "${TARGET_HOME}/.local/bin/zed")"
        fi
    fi
else
    if [ "$SKIP_ZED" -eq 1 ]; then
        log_info "Skipping Zed setup (--skip-zed specified)"
    else
        log_info "Skipping Zed section (not selected by --*-only)"
    fi
fi

# Record the successfully applied bootstrap version for future update checks.
write_version_state

# ------------------------------------------------------------------------------
# Summary & Completion
# ------------------------------------------------------------------------------
SUMMARY_LOG="${LOG_FILE:-not created (dry-run)}"
SUMMARY_BACKUP="${BACKUP_DIR:-none created (dry-run or no user files to protect)}"

printf "\n${BOLD}${GREEN}================================================================${RESET}\n"
printf "${BOLD}${GREEN}              Bootstrap Completed Successfully!                 ${RESET}\n"
printf "${BOLD}${GREEN}================================================================${RESET}\n\n"

cat <<EOF
Summary of changes:
  • Bootstrap Version: ${BOOTSTRAP_VERSION}
  • Operating System: ${OS_TYPE} (${ARCH_TYPE})
  • Package Manager: $([ "$OS_TYPE" = "Darwin" ] && echo "Homebrew" || echo "APT (Debian/Ubuntu)")
  • Timezone: ${TIMEZONE}
  • Core Dev: cmake, ninja, clang/llvm, git, jq, tmux, tree, etc.
  • Modern CLI: vim, btop, mosh, tmux, ripgrep, fd, bat, fzf
  • Embedded Tools: gcc-arm-none-eabi, gdb, newlib, openocd, tio, probe-rs
  • Shell: Zsh + Oh-My-Zsh with syntax-highlighting, autosuggestions, zsh-completions optimization hooks
  • Dotfiles & Git: .vimrc (badwolf), .tmux.conf, .bash_aliases, git editor=vim, alias.pa, .gitmessage
  • Git hooks: ~/.githooks dispatcher (seeds .editorconfig, forwards to ./.githooks)
  • Maintenance: ~/.local/bin/full-upgrade (alias: up) with omz & brew update
  • Productivity: .editorconfig, .hushlogin, optimized custom global cdr completions setup
  • Security: ED25519 SSH & GPG signing keys verified / configured
  • Rust: stable toolchain, Cortex-M/RISC-V/Wasm targets, probe-rs, cargo-binstall, cargo-binutils, espflash
  • Editor: Zed editor installed to ~/.local/bin/zed
  • Install log: ${SUMMARY_LOG}
  • Backup: ${SUMMARY_BACKUP}

Next steps:
  1. Start your new shell:
       $ exec zsh
  2. Happy hacking! 🦀⚡

Rollback (restores the newest backup of user dotfiles/config):
  curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --rollback
EOF
