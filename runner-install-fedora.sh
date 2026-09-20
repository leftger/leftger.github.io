#!/usr/bin/env bash
# ==============================================================================
# Gerzain's Fedora GitHub Actions Self-Hosted Runner Installer
#
# Turns a bare Fedora machine into a hardened, integration-test-oriented
# GitHub Actions self-hosted runner node. Intended to be run once per machine
# in a small fleet where each machine has its own attached debug hardware.
#
# Usage (one-liner via curl):
#   curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/runner-install-fedora.sh | sudo bash -s -- \
#       --url https://github.com/OWNER/REPO --token <REGISTRATION_TOKEN>
#
# Or locally:
#   sudo ./runner-install-fedora.sh --url https://github.com/OWNER/REPO --token <TOKEN>
#
# Summary of automated actions (each section can be skipped or run alone):
#   1.  base        Fedora base packages, DNF tuning, actions/runner runtime libs
#   2.  rust        rustup + thumbv6m/thumbv7m/thumbv8m targets, cargo test tooling
#   3.  python      Python 3, pip, venv, pipx, uv
#   4.  arm         arm-none-eabi GCC/binutils/newlib, GDB, OpenOCD
#   5.  qemu        qemu-system-arm + QEMU runner defaults for Cortex-M tests
#   6.  containers  Rootless Podman + docker CLI shim (podman-docker)
#   7.  security    firewalld, sysctl hardening, SELinux relabel, dnf-automatic
#   8.  hardware    udev rules + groups for debug probes, auto-detected labels
#   9.  runner      actions/runner download, registration, hardened systemd unit
#                   (enabled at boot and restarted automatically if it dies)
#   10. shell       zsh + oh-my-zsh + plugins + fzf for the operator account
#
# Design notes:
#   * The runner never runs as root and never gets sudo. It runs as a dedicated
#     unprivileged service account with a hardened systemd unit.
#   * The registration token is used once and is never written to disk.
#   * PrivateDevices= is deliberately NOT set on the unit: on-hardware
#     integration tests need access to USB debug probes.
# ==============================================================================

# Asset distribution URLs. Defined before the trampoline below so the fallback
# re-fetch can reuse them instead of repeating literal URLs.
PAGES_BASE="https://leftger.github.io"
RAW_REPO_BASE="https://raw.githubusercontent.com/leftger/leftger.github.io/main"
SCRIPT_NAME="runner-install-fedora.sh"

# Allows running via: curl ... | sh as well as curl ... | bash
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        if [ -f "$0" ]; then
            exec bash "$0" "$@"
        else
            exec bash -c "$(curl -fsSL "${PAGES_BASE}/${SCRIPT_NAME}" 2>/dev/null || curl -fsSL "${RAW_REPO_BASE}/${SCRIPT_NAME}")" bash "$@"
        fi
    else
        echo "Error: bash is required to run this installer." >&2
        exit 1
    fi
fi

set -euo pipefail
umask 0022

# ------------------------------------------------------------------------------
# Default Configuration & Flags
# ------------------------------------------------------------------------------
RUNNER_INSTALL_VERSION="0.1.0"

# Service account and paths
RUNNER_USER="${RUNNER_USER:-ghrunner}"
RUNNER_HOME="${RUNNER_HOME:-/var/lib/ghrunner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_WORK=""
CONFIG_FILE="${CONFIG_FILE:-/etc/gh-runner/runner.conf}"
JIT_ENV_FILE="/etc/gh-runner/jit.env"
JIT_WRAPPER="/usr/local/libexec/ghrunner-jit-run"

# GitHub registration
RUNNER_URL="${GH_RUNNER_URL:-}"
RUNNER_TOKEN="${GITHUB_RUNNER_TOKEN:-}"
RUNNER_PAT="${GITHUB_RUNNER_PAT:-}"
RUNNER_NAME=""
RUNNER_LABELS=""
RUNNER_GROUP=""
RUNNER_GROUP_ID=""
RUNNER_VERSION=""
RUNNER_EPHEMERAL=0
RUNNER_REPLACE=1

# Behaviour toggles
WITH_SCCACHE=1
WITH_DOCKER_SOCKET=1
WITH_HARDWARE_LABELS=1
WITH_AUTOUPDATE=1
WITH_MOSH=1
WITH_WATCHDOG=1
WITH_SHELL=1
SHELL_USER="${GH_RUNNER_SHELL_USER:-}"
SHELL_HOME=""
SHELL_GROUP=""
SHELL_PATH=""
STRICT_HARDENING=0
HARDEN_SSH=0
WITH_FAIL2BAN=0
UNINSTALL=0
ALLOW_SSH_LOCKOUT="${GH_RUNNER_ALLOW_SSH_LOCKOUT:-0}"

# Section selection. Section names double as --skip-<name> / --<name>-only flags:
# base, rust, python, arm, qemu, containers, security, hardware, shell, runner.
SKIPPED=""
ONLY_ACTIVE=0
ONLY_SECTIONS=""

DRY_RUN=0
NEEDS_SUDO=1

# Populated later by the hardware and runner sections. Pre-declared because the
# runner section reads them even when --skip-hardware is in effect.
HW_LABELS=""
ALL_LABELS=""

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

# ------------------------------------------------------------------------------
# Helper Functions & Logging
# ------------------------------------------------------------------------------
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

downloader() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl --retry 3 --retry-connrefused -C - --proto '=https' --tlsv1.2 -fsSL "$url" -o "$dest" 2>/dev/null || \
        curl --retry 3 -fsSL "$url" -o "$dest" 2>/dev/null || \
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 -c -qO "$dest" "$url"
    else
        log_error "Neither curl nor wget was found."
        return 1
    fi
}

# Persist a plain-text copy of each log line. LOG_FILE is resolved during
# preflight; until then logging remains console-only.
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
# Section gating: --skip-<section> disables a section, --<section>-only restricts
# the run to the named sections. Only-mode always wins over skip mode.
# ------------------------------------------------------------------------------
section_enabled() {
    local section="$1"

    if [ "$ONLY_ACTIVE" -eq 1 ]; then
        case " $ONLY_SECTIONS " in
            *" $section "*) return 0 ;;
        esac
        return 1
    fi

    case " $SKIPPED " in
        *" $section "*) return 1 ;;
    esac

    return 0
}

# ------------------------------------------------------------------------------
# Privileged file/dir helpers that honour --dry-run.
# ------------------------------------------------------------------------------
ensure_dir() {
    local path="$1"
    local mode="${2:-0755}"
    local owner="${3:-}"

    if [ -d "$path" ]; then
        return 0
    fi

    if [ -n "$owner" ]; then
        run_sudo install -d -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$path"
    else
        run_sudo install -d -m "$mode" "$path"
    fi
}

# write_heredoc <path> <mode> [owner:group]
# Content is read from stdin, so call it with a quoted heredoc:
#   write_heredoc /etc/foo 0644 root:root <<'EOF'
#   ...file body...
#   EOF
write_heredoc() {
    local path="$1"
    local mode="${2:-0644}"
    local owner="${3:-}"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN-WRITE]${RESET} %s (mode %s)\n" "$path" "$mode"
        cat >/dev/null
        return 0
    fi

    run_sudo tee "$path" >/dev/null
    run_sudo chmod "$mode" "$path"
    if [ -n "$owner" ]; then
        run_sudo chown "$owner" "$path"
    fi
}

# Optional self-healing timer for the persistent runner service.
#
# The default install already survives a crash (Restart=always) and a reboot (the
# unit is enabled), so this adds two narrower things: recovery when the service was
# stopped by something other than systemd, and early detection of a runner whose
# local registration has gone missing. It deliberately stores no credentials, so it
# can report a lost registration but cannot repair one.
install_watchdog() {
    local unit="$1"

    write_heredoc /usr/local/libexec/ghrunner-watchdog 0755 root:root <<EOF
#!/usr/bin/env bash
# Managed by ${SCRIPT_NAME} - keep the GitHub Actions runner service running.
set -euo pipefail

unit='${unit}'
runner_dir='${RUNNER_DIR}'

if ! systemctl is-active --quiet "\$unit"; then
    echo "ghrunner-watchdog: \$unit is not active; restarting it" >&2
    systemctl restart "\$unit"
    exit 0
fi

if [ ! -f "\${runner_dir}/.runner" ]; then
    echo "ghrunner-watchdog: \${runner_dir}/.runner is missing, so this runner is no longer registered." >&2
    echo "ghrunner-watchdog: re-run the installer with a fresh registration token to re-register." >&2
    exit 1
fi
EOF

    write_heredoc /etc/systemd/system/ghrunner-watchdog.service 0644 root:root <<EOF
# Managed by ${SCRIPT_NAME} - do not edit by hand.
[Unit]
Description=GitHub Actions runner health check
Documentation=https://leftger.github.io/${SCRIPT_NAME}
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/ghrunner-watchdog
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
EOF

    write_heredoc /etc/systemd/system/ghrunner-watchdog.timer 0644 root:root <<EOF
# Managed by ${SCRIPT_NAME} - do not edit by hand.
[Unit]
Description=Periodic GitHub Actions runner health check
Documentation=https://leftger.github.io/${SCRIPT_NAME}

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    run_sudo systemctl daemon-reload
    run_sudo systemctl enable --now ghrunner-watchdog.timer || \
        log_warn "Could not enable ghrunner-watchdog.timer."
    log_info "Watchdog enabled: the runner service is checked every 5 minutes."
}

# ------------------------------------------------------------------------------
# Command execution wrappers.
# ------------------------------------------------------------------------------
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

# Like run_sudo, but silences the command's own chatter on a real run while still
# reporting the action under --dry-run. Redirecting at the call site would swallow
# the dry-run notice as well, because run_sudo prints it on stdout.
run_sudo_quiet() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN-SUDO]${RESET} %s\n" "$*"
    else
        run_sudo "$@" >/dev/null 2>&1
    fi
}

# Run a command as $RUNNER_USER with an explicit, minimal environment. System
# services do not inherit a login environment, so HOME/PATH are pinned here for
# both the interactive and the systemd paths.
run_as_user() {
    local run_user="$1"
    shift

    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN-USER:%s]${RESET} %s\n" "$run_user" "$*"
        return 0
    fi

    if [ "$(id -un)" = "$run_user" ]; then
        env HOME="$RUNNER_HOME" PATH="$RUNNER_PATH" "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        runuser -u "$run_user" -- env HOME="$RUNNER_HOME" PATH="$RUNNER_PATH" "$@"
    else
        sudo -u "$run_user" -- env HOME="$RUNNER_HOME" PATH="$RUNNER_PATH" "$@"
    fi
}


# Run a command string as an arbitrary user with an explicit HOME and PATH. The
# runner service account and the human operator have different homes, so the
# caller states both rather than relying on a single global.
run_as_user_env() {
    local run_user="$1"
    local run_home="$2"
    local run_path="$3"
    shift 3
    local cmd="$*"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf "${MAGENTA}[DRY-RUN-USER:%s]${RESET} %s\n" "$run_user" "$cmd"
        return 0
    fi

    if [ "$(id -un)" = "$run_user" ]; then
        HOME="$run_home" PATH="$run_path" bash -c "$cmd"
    elif [ "$(id -u)" -eq 0 ]; then
        runuser -u "$run_user" -- env HOME="$run_home" PATH="$run_path" bash -c "$cmd"
    else
        sudo -u "$run_user" -- env HOME="$run_home" PATH="$run_path" bash -c "$cmd"
    fi
}

# Shell command strings for the runner service account.
run_user_shell() {
    local run_user="$1"
    shift
    run_as_user_env "$run_user" "$RUNNER_HOME" "$RUNNER_PATH" "$*"
}

# ------------------------------------------------------------------------------
# DNF helpers.
# ------------------------------------------------------------------------------
DNF_FLAGS=("-y" "--setopt=install_weak_deps=False" "--setopt=assumeyes=1")

# Print only the requested packages that actually exist in the enabled repos, so
# one renamed/absent package cannot fail the whole transaction. Fedora renames
# packages between releases, so this keeps the script usable on a fleet that is
# not all on the same release.
dnf_filter_available() {
    local -a wanted=("$@")
    local -a out=()
    local -a missing=()
    local -A avail=()
    local pkg=""

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "${wanted[@]}"
        return 0
    fi

    # `dnf repoquery` lives in dnf-plugins-core. If it is unavailable, fall back
    # to letting dnf resolve the list itself rather than silently installing
    # nothing.
    if ! dnf -q repoquery --available --qf '%{name}' bash >/dev/null 2>&1; then
        log_warn "dnf repoquery unavailable; skipping package availability filtering."
        printf '%s\n' "${wanted[@]}"
        return 0
    fi

    while IFS= read -r pkg; do
        if [ -n "$pkg" ]; then
            avail["$pkg"]=1
        fi
    done < <(dnf -q repoquery --available --qf '%{name}' "${wanted[@]}" 2>/dev/null | sort -u || true)

    for pkg in "${wanted[@]}"; do
        if [ -n "${avail[$pkg]:-}" ] || rpm -q "$pkg" >/dev/null 2>&1; then
            out+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        log_warn "Not in enabled repos, skipping: ${missing[*]}"
    fi

    if [ "${#out[@]}" -gt 0 ]; then
        printf '%s\n' "${out[@]}"
    fi
}

dnf_install() {
    local -a pkgs=()
    local pkg=""

    while IFS= read -r pkg; do
        if [ -n "$pkg" ]; then
            pkgs+=("$pkg")
        fi
    done < <(dnf_filter_available "$@")

    if [ "${#pkgs[@]}" -eq 0 ]; then
        log_info "No installable packages from this group."
        return 0
    fi

    log_info "Installing ${#pkgs[@]} package(s)..."
    run_sudo dnf install "${DNF_FLAGS[@]}" "${pkgs[@]}"
}

# Install a DNF package group. Groups cannot go through the repoquery filter
# (they are not package names), and a group that was renamed or dropped between
# Fedora releases must not abort the run.
dnf_group_install() {
    local group="$1"

    log_info "Installing package group: ${group}"
    if ! run_sudo dnf group install "${DNF_FLAGS[@]}" "$group"; then
        log_warn "Package group '${group}' could not be installed; continuing."
    fi
}

# ------------------------------------------------------------------------------
# Host fingerprinting.
# ------------------------------------------------------------------------------
detect_runner_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf 'x64' ;;
        aarch64 | arm64) printf 'arm64' ;;
        armv7l) printf 'arm' ;;
        *)
            log_error "Unsupported architecture for actions/runner: $(uname -m)"
            exit 1
            ;;
    esac
}

# Collect hardware-derived labels for this machine, so jobs can target the exact
# debug probe / board attached to it.
detect_hardware_labels() {
    local -a labels=()
    local usb=""

    if [ "$WITH_HARDWARE_LABELS" -eq 0 ]; then
        return 0
    fi

    if ! command -v lsusb >/dev/null 2>&1; then
        return 0
    fi

    usb="$(lsusb 2>/dev/null || true)"

    if grep -qi '0483:' <<<"$usb"; then labels+=(stlink); fi
    if grep -qi '1366:' <<<"$usb"; then labels+=(jlink); fi
    if grep -qiE '(0d28|2e8a):' <<<"$usb"; then labels+=(cmsis-dap); fi
    if grep -qi '1d50:601' <<<"$usb"; then labels+=(blackmagic); fi
    if grep -qi '303a:' <<<"$usb"; then labels+=(espressif); fi
    if grep -qi '1915:' <<<"$usb"; then labels+=(nordic); fi
    if grep -qi '0403:60' <<<"$usb"; then labels+=(ftdi); fi
    if grep -qi '2341:' <<<"$usb"; then labels+=(arduino); fi

    if [ "${#labels[@]}" -gt 0 ]; then
        printf '%s\n' "${labels[@]}"
    fi
}

# ------------------------------------------------------------------------------
# GitHub API helpers.
# ------------------------------------------------------------------------------
# Resolve the registration endpoints from a web URL, handling both
# github.com and GitHub Enterprise Server hosts.
resolve_api_endpoints() {
    local url="$1"
    local host=""
    local owner_and_repo=""

    url="${url%/}"
    url="${url%.git}"

    case "$url" in
        https://*/*) ;;
        *)
            log_error "--url must look like https://github.com/OWNER/REPO (got: ${url})"
            exit 1
            ;;
    esac

    host="${url#https://}"
    host="${host%%/*}"
    owner_and_repo="${url#https://${host}/}"

    if [ "$host" = "github.com" ]; then
        RUNNER_API_BASE="https://api.github.com"
    else
        RUNNER_API_BASE="https://${host}/api/v3"
    fi

    # A single path element (OWNER) means an organization runner; OWNER/REPO
    # means a repository-scoped runner.
    if [ "$(printf '%s' "$owner_and_repo" | tr -cd '/' | wc -c)" -ge 1 ]; then
        RUNNER_TOKEN_API="${RUNNER_API_BASE}/repos/${owner_and_repo}/actions/runners/registration-token"
        RUNNER_JIT_API="${RUNNER_API_BASE}/repos/${owner_and_repo}/actions/runners/generate-jitconfig"
    else
        RUNNER_TOKEN_API="${RUNNER_API_BASE}/orgs/${owner_and_repo}/actions/runners/registration-token"
        RUNNER_JIT_API="${RUNNER_API_BASE}/orgs/${owner_and_repo}/actions/runners/generate-jitconfig"
    fi

    # svc.sh names the generated unit from this slug plus the runner name, so a
    # dry-run can predict the unit and preview its hardening drop-ins.
    RUNNER_SLUG="$(printf '%s' "$owner_and_repo" | tr '/' '-')"
}


# Whether anything in this run needs the runner service account. A --shell-only run
# must not create it.
runner_account_needed() {
    if [ "$ONLY_ACTIVE" -eq 1 ]; then
        case " $ONLY_SECTIONS " in
            *" rust "* | *" hardware "* | *" containers "* | *" runner "*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# ------------------------------------------------------------------------------
# The runner service account is created before any section runs, because the
# containers section needs it to exist for socket ownership and the systemd
# units reference it by name.
# ------------------------------------------------------------------------------
ensure_runner_account() {
    # Unprivileged by design: system account, nologin shell, home under /var/lib
    # so that ProtectHome=yes on the unit does not hide it.
    if ! id "$RUNNER_USER" >/dev/null 2>&1; then
        log_info "Creating service account ${RUNNER_USER}..."
        run_sudo useradd --system --create-home \
            --home-dir "$RUNNER_HOME" \
            --shell /usr/sbin/nologin \
            --comment "GitHub Actions self-hosted runner" \
            "$RUNNER_USER"
    else
        log_info "Service account ${RUNNER_USER} already exists."
    fi

    # CI jobs must never be able to escalate to root.
    if id -nG "$RUNNER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx wheel; then
        log_warn "${RUNNER_USER} is in the wheel group. Removing it: CI jobs must not have sudo."
        run_sudo gpasswd -d "$RUNNER_USER" wheel || true
    fi

    if [ -f "/etc/sudoers.d/${RUNNER_USER}" ]; then
        log_warn "Removing /etc/sudoers.d/${RUNNER_USER}: CI jobs must not have sudo."
        run_sudo rm -f "/etc/sudoers.d/${RUNNER_USER}"
    fi

    # Serial consoles used by OpenOCD/probe-rs UART sessions live in 'dialout'.
    for grp in dialout plugdev; do
        if getent group "$grp" >/dev/null 2>&1; then
            run_sudo usermod -aG "$grp" "$RUNNER_USER" || true
        fi
    done
}

# Whether toolchain steps can target the service account. Under --dry-run nothing
# is actually created, so treat the account as available rather than emitting
# spurious "missing account" errors.
runner_account_ready() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    id "$RUNNER_USER" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Uninstall path: stop and remove the runner, its service, and its account.
# ------------------------------------------------------------------------------
uninstall_runner() {
    log_step "Removing GitHub Actions runner from this machine"

    local unit_file="" dropin_dir="" svc_unit=""

    for svc_unit in /etc/systemd/system/actions.runner.*.service; do
        [ -e "$svc_unit" ] || continue
        unit_file="$svc_unit"
    done

    if [ -n "$unit_file" ]; then
        run_sudo systemctl disable --now "$(basename "$unit_file")" || true
        dropin_dir="${unit_file}.d"
        run_sudo rm -rf "$dropin_dir"
    fi

    if [ -d "$RUNNER_DIR" ]; then
        if [ -n "$RUNNER_TOKEN" ] && [ -x "${RUNNER_DIR}/config.sh" ]; then
            log_info "Deregistering runner from GitHub..."
            run_as_user "$RUNNER_USER" bash -c "cd $(printf '%q' "$RUNNER_DIR") && ./config.sh remove --token $(printf '%q' "$RUNNER_TOKEN")" || \
                log_warn "Could not deregister (token may be expired). Remove the runner entry from GitHub settings if it lingers."
        else
            log_warn "No --token supplied; the runner entry may remain visible in GitHub settings."
        fi
        run_sudo rm -rf "$RUNNER_DIR"
    fi

    run_sudo systemctl disable --now ghrunner-podman.service 2>/dev/null || true
    run_sudo rm -f /etc/systemd/system/ghrunner-podman.service
    run_sudo rm -f /usr/lib/systemd/system/ghrunner-podman.service
    run_sudo rm -f "$JIT_WRAPPER"
    run_sudo rm -rf /etc/gh-runner
    run_sudo rm -f /etc/udev/rules.d/70-gh-runner-probes.rules
    # Only remove the socket if it is the symlink this installer created.
    if [ -L /var/run/docker.sock ] && [ "$(readlink /var/run/docker.sock)" = "/run/ghrunner/podman/podman.sock" ]; then
        run_sudo rm -f /var/run/docker.sock
    fi
    run_sudo systemctl daemon-reload || true
    run_sudo udevadm control --reload-rules || true

    if id "$RUNNER_USER" >/dev/null 2>&1; then
        run_sudo userdel -r "$RUNNER_USER" 2>/dev/null || run_sudo userdel "$RUNNER_USER" || true
    fi

    log_success "Runner removal complete."
}

# ------------------------------------------------------------------------------
# Usage / help
# ------------------------------------------------------------------------------
print_help() {
    cat <<EOF
Gerzain's Fedora GitHub Actions Runner Installer v${RUNNER_INSTALL_VERSION}

Usage:
  ./runner-install-fedora.sh [OPTIONS]
  curl -fsSL https://leftger.github.io/runner-install-fedora.sh | sudo bash -s -- [OPTIONS]

Registration:
      --url <URL>           Repo or org URL, e.g. https://github.com/OWNER/REPO
                            (env: GH_RUNNER_URL). Required unless --uninstall.
      --token <TOKEN>       One-time runner registration token (env: GITHUB_RUNNER_TOKEN).
                            Used once and never persisted. Get one from
                            Settings -> Actions -> Runners -> New self-hosted runner.
      --pat <TOKEN>         Fine-grained PAT with "Administration: Read and write"
                            (env: GITHUB_RUNNER_PAT). Only needed for --ephemeral;
                            stored root-readable at ${JIT_ENV_FILE}.
      --ephemeral           Register as an ephemeral (just-in-time) runner that runs
                            exactly one job then re-registers. Requires --pat.
                            Best for machines without special hardware.
      --name <NAME>         Runner name (default: short hostname)
      --labels <CSV>        Extra labels, comma-separated. Hardware probes are
                            detected automatically and added as labels.
      --runner-group <NAME> Runner group name (org/enterprise runners only)
      --runner-group-id <N> Numeric runner group id, needed for org-scoped
                            --ephemeral runners (JIT config wants an id, not a name)
      --runner-version <V>  Pin an actions/runner version instead of resolving the
                            latest published release
      --work-dir <PATH>     Work folder (default: <runner-dir>/_work)
      --runner-dir <PATH>   Install directory (default: /opt/actions-runner)
      --user <NAME>         Service account name (default: ghrunner)
      --config <FILE>       Machine-local config file to source before flag parsing
                            (default: /etc/gh-runner/runner.conf)

Behaviour:
      --no-hardware-labels  Do not derive labels from attached USB probes
      --no-sccache          Do not configure sccache as the rustc wrapper
      --no-docker-socket    Do not point /var/run/docker.sock at rootless Podman
      --no-autoupdate       Skip dnf-automatic security-update timer
      --no-mosh             Skip mosh and its firewall exception
      --no-watchdog         Skip the ghrunner-watchdog.timer health check
      --no-shell            Skip the zsh / oh-my-zsh operator shell setup
      --shell-user <NAME>   Account that gets zsh, oh-my-zsh and the fzf
                            keybindings (default: the operator who ran the
                            installer, detected via SUDO_USER). The runner service
                            account is never targeted.
      --strict-hardening    Keep NoNewPrivileges and ProtectControlGroups enabled
                            even when containers are installed. This breaks
                            rootless Podman in jobs; only use it on container-free
                            machines.
      --harden-ssh          Apply an sshd hardening drop-in (key-only auth, no root
                            login). Refuses to run if no authorized_keys exist
                            anywhere unless GH_RUNNER_ALLOW_SSH_LOCKOUT=1.
      --with-fail2ban       Install and enable fail2ban for the sshd jail
      --dry-run             Print actions without executing system commands
      --uninstall           Stop, deregister, and remove the runner and its account

Sections (combine --*-only flags to run a subset):
      --skip-base           Skip Fedora base packages and runner runtime libraries
      --skip-rust           Skip rustup, embedded targets, and cargo tooling
      --skip-python         Skip Python 3, pip, venv, pipx, and uv
      --skip-arm            Skip arm-none-eabi GCC/GDB/OpenOCD
      --skip-qemu           Skip qemu-system-arm and QEMU cargo-runner defaults
      --skip-containers     Skip rootless Podman and the docker CLI shim
      --skip-security       Skip firewalld, sysctl, SELinux, and dnf-automatic setup
      --skip-hardware       Skip debug-probe udev rules and group membership
      --skip-shell          Skip the zsh / oh-my-zsh operator shell setup
      --skip-runner         Skip downloading, registering, and starting the runner
      --base-only --rust-only --python-only --arm-only --qemu-only
      --containers-only --security-only --hardware-only --shell-only --runner-only

  -v, --version             Print the installer version and exit
  -h, --help                Show this help message and exit

Notes:
  * The runner always runs as an unprivileged service account. It is never added
    to wheel/sudoers, and the unit sets NoNewPrivileges=yes.
  * --ephemeral stores a PAT on disk in ${JIT_ENV_FILE} (mode 0640,
    group ${RUNNER_USER}). That token can register runners for the whole repo or
    org, so treat the machine as a credential holder and prefer repo-scoped PATs.
  * Every run is logged. User files are never modified by this script.
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
# Load the machine-local config so operators can keep per-machine hardware
# specifics (url, runner name, labels) outside of the script itself.
#
# --config is resolved in a pre-pass over argv, before the main flag loop, so
# that command-line flags always win no matter where --config appears.
# ------------------------------------------------------------------------------
ARGV=("$@")
for ((i = 0; i < ${#ARGV[@]}; i++)); do
    if [ "${ARGV[i]}" = "--config" ]; then
        if [ $((i + 1)) -ge ${#ARGV[@]} ]; then
            log_error "--config requires a file path."
            exit 1
        fi
        CONFIG_FILE="${ARGV[i + 1]}"
        if [ ! -f "$CONFIG_FILE" ]; then
            log_error "Config file not found: ${CONFIG_FILE}"
            exit 1
        fi
    fi
done
unset ARGV

if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    if [ "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo '000')" != "600" ] &&
        grep -qE '(TOKEN|PAT)=' "$CONFIG_FILE" 2>/dev/null; then
        log_warn "${CONFIG_FILE} contains a token but is not mode 0600."
    fi
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

# Re-apply environment-supplied values so precedence is flags > environment >
# config file.
RUNNER_USER="${RUNNER_USER:-ghrunner}"
RUNNER_HOME="${RUNNER_HOME:-/var/lib/ghrunner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_URL="${GH_RUNNER_URL:-$RUNNER_URL}"
RUNNER_TOKEN="${GITHUB_RUNNER_TOKEN:-$RUNNER_TOKEN}"
RUNNER_PAT="${GITHUB_RUNNER_PAT:-$RUNNER_PAT}"
SHELL_USER="${GH_RUNNER_SHELL_USER:-$SHELL_USER}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            RUNNER_URL="$2"
            shift 2
            ;;
        --token)
            RUNNER_TOKEN="$2"
            shift 2
            ;;
        --pat)
            RUNNER_PAT="$2"
            shift 2
            ;;
        --ephemeral)
            RUNNER_EPHEMERAL=1
            shift
            ;;
        --name)
            RUNNER_NAME="$2"
            shift 2
            ;;
        --labels)
            RUNNER_LABELS="$2"
            shift 2
            ;;
        --runner-group)
            RUNNER_GROUP="$2"
            shift 2
            ;;
        --runner-group-id)
            RUNNER_GROUP_ID="$2"
            shift 2
            ;;
        --runner-version)
            RUNNER_VERSION="$2"
            shift 2
            ;;
        --work-dir)
            RUNNER_WORK="$2"
            shift 2
            ;;
        --runner-dir)
            RUNNER_DIR="$2"
            shift 2
            ;;
        --user)
            RUNNER_USER="$2"
            shift 2
            ;;
        --config)
            # Already resolved and sourced by the argv pre-pass above, so that
            # command-line flags take precedence over config file values.
            shift 2
            ;;
        --no-hardware-labels)
            WITH_HARDWARE_LABELS=0
            shift
            ;;
        --no-sccache)
            WITH_SCCACHE=0
            shift
            ;;
        --no-docker-socket)
            WITH_DOCKER_SOCKET=0
            shift
            ;;
        --no-autoupdate)
            WITH_AUTOUPDATE=0
            shift
            ;;
        --no-mosh)
            WITH_MOSH=0
            shift
            ;;
        --no-watchdog)
            WITH_WATCHDOG=0
            shift
            ;;
        --no-shell)
            WITH_SHELL=0
            shift
            ;;
        --shell-user)
            SHELL_USER="$2"
            shift 2
            ;;
        --strict-hardening)
            STRICT_HARDENING=1
            shift
            ;;
        --harden-ssh)
            HARDEN_SSH=1
            shift
            ;;
        --with-fail2ban)
            WITH_FAIL2BAN=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        --skip-base | --skip-rust | --skip-python | --skip-arm | --skip-qemu | \
            --skip-containers | --skip-security | --skip-hardware | --skip-shell | \
            --skip-runner)
            SKIPPED="$SKIPPED ${1#--skip-}"
            shift
            ;;
        --base-only | --rust-only | --python-only | --arm-only | --qemu-only | \
            --containers-only | --security-only | --hardware-only | --shell-only | \
            --runner-only)
            ONLY_ACTIVE=1
            ONLY_SECTIONS="$ONLY_SECTIONS ${1#--}"
            ONLY_SECTIONS="${ONLY_SECTIONS%-only}"
            shift
            ;;
        -v | --version)
            printf 'runner-install-fedora.sh %s\n' "$RUNNER_INSTALL_VERSION"
            exit 0
            ;;
        -h | --help)
            print_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            printf '\n'
            print_help
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
LOG_FILE=""
if [ "$(id -u)" -eq 0 ] || [ "${DRY_RUN}" -eq 1 ]; then
    LOG_FILE="${HOME:-/root}/.cache/gh-runner-install.log"
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE=""
    fi
else
    LOG_FILE="${HOME:-/tmp}/.cache/gh-runner-install.log"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE=""
fi

if [ ! -r /etc/os-release ]; then
    log_error "Cannot read /etc/os-release; this installer only supports Fedora."
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_VERSION="${VERSION_ID:-unknown}"
OS_NAME="${PRETTY_NAME:-Fedora}"

if [ -e /run/ostree-booted ]; then
    log_error "${OS_NAME} is an image-based (ostree) system. dnf installs would not persist."
    log_error "Use 'rpm-ostree install' for packages, or run this installer on a traditional Fedora install."
    exit 1
fi

case "$OS_ID" in
    fedora) ;;
    rhel | centos | rocky | almalinux | nobara | bazzite)
        log_warn "${OS_NAME} is not Fedora proper. Proceeding, but package names may differ."
        ;;
    *)
        case " $OS_LIKE " in
            *" fedora "* | *" rhel "*) log_warn "Untested distribution '${OS_ID}'. Proceeding anyway." ;;
            *)
                log_error "Unsupported distribution '${OS_ID}'. This installer targets Fedora."
                exit 1
                ;;
        esac
        ;;
esac

if ! command -v dnf >/dev/null 2>&1; then
    log_error "dnf was not found. This installer requires Fedora's package manager."
    exit 1
fi

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    log_error "This installer needs root privileges, and sudo is not available."
    exit 1
fi

# A dedicated, non-root service account is a hard requirement. Running GitHub's
# runner as root would hand repository-scoped code full control of the host.
if [ "$RUNNER_USER" = "root" ]; then
    log_error "Refusing to run the Actions runner as root. Pick an unprivileged user via --user."
    exit 1
fi

ARCH_TYPE="$(detect_runner_arch)"
RUNNER_PATH="${RUNNER_HOME}/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

if [ -z "$RUNNER_NAME" ]; then
    # Short hostname: no domain suffix, so labels stay readable.
    RUNNER_NAME="$(hostname -s 2>/dev/null || hostname)"
fi

if [ -z "$RUNNER_WORK" ]; then
    RUNNER_WORK="${RUNNER_DIR}/_work"
fi

if [ "$RUNNER_EPHEMERAL" -eq 1 ] && [ "$RUNNER_USER" = "ghrunner" ]; then
    # The PAT-backed JIT wrapper lives outside the runner dir, so keep the default
    # user unless the operator explicitly overrode it.
    :
fi

# ------------------------------------------------------------------------------
# Sudo keep-alive
# ------------------------------------------------------------------------------
BOOTSTRAP_TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'ghrunner_tmp')"
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

    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done 2>/dev/null &
    SUDO_PID=$!
fi

if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_runner
    exit 0
fi

# Validate registration inputs only when the runner section will actually run.
if section_enabled runner; then
    if [ -z "$RUNNER_URL" ]; then
        log_error "--url is required (or set GH_RUNNER_URL / GH_RUNNER_URL in ${CONFIG_FILE})."
        log_error "Example: --url https://github.com/OWNER/REPO"
        exit 1
    fi

    resolve_api_endpoints "$RUNNER_URL"

    if [ "$RUNNER_EPHEMERAL" -eq 1 ]; then
        if [ -z "$RUNNER_PAT" ]; then
            log_error "--ephemeral requires --pat (fine-grained PAT, Administration: Read and write)."
            log_error "Generate one at: https://github.com/settings/personal-access-tokens/new"
            exit 1
        fi
    else
        if [ -z "$RUNNER_TOKEN" ]; then
            log_error "--token is required for a persistent runner (registration tokens expire in 1 hour)."
            log_error "Fetch one with: gh api -X POST ${RUNNER_TOKEN_API//https:\/\/api.github.com/}"
            exit 1
        fi
    fi
fi

log_info "Installer v${RUNNER_INSTALL_VERSION} on ${OS_NAME} (${ARCH_TYPE})"
log_info "Runner user: ${RUNNER_USER}  dir: ${RUNNER_DIR}  home: ${RUNNER_HOME}"
if [ -n "${LOG_FILE:-}" ]; then
    log_info "Logging to ${LOG_FILE}"
fi

# dnf repoquery (used for package availability filtering) ships in
# dnf-plugins-core, so install it before the first filtered dnf_install call.
dnf_install dnf-plugins-core

# The interactive-shell section targets a human account. It is never the runner
# service account, which is nologin by design, so resolve and validate the target
# here and disable the section rather than reconfiguring the wrong account.
if [ "$WITH_SHELL" -eq 1 ] && section_enabled shell; then
    if [ -z "$SHELL_USER" ]; then
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            SHELL_USER="$SUDO_USER"
        elif [ "$(id -u)" -ne 0 ] && [ -n "${USER:-}" ]; then
            SHELL_USER="$USER"
        fi
    fi

    if [ -z "$SHELL_USER" ]; then
        log_warn "Could not detect an operator account (running as root without sudo)."
        log_warn "Skipping the shell section; pass --shell-user <NAME> to target an account."
        WITH_SHELL=0
    elif [ "$SHELL_USER" = "$RUNNER_USER" ]; then
        log_error "Refusing to configure ${RUNNER_USER} as an interactive account."
        log_error "It is the runner service account (nologin) that executes untrusted code."
        log_error "Pass --shell-user <NAME> if you meant a different account."
        exit 1
    else
        SHELL_HOME="$(getent passwd "$SHELL_USER" 2>/dev/null | cut -d: -f6 || echo "")"
        if [ -z "$SHELL_HOME" ] || [ ! -d "$SHELL_HOME" ]; then
            log_error "Operator account '${SHELL_USER}' has no usable home directory."
            exit 1
        fi
        SHELL_GROUP="$(id -gn "$SHELL_USER" 2>/dev/null || echo "$SHELL_USER")"
        SHELL_PATH="${SHELL_HOME}/.local/bin:${SHELL_HOME}/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
        log_info "Interactive shell setup will target account: ${SHELL_USER} (${SHELL_HOME})"
    fi
fi

# The service account must exist before the containers section, which chowns the
# Podman runtime directory to it and installs a unit that references it by name.
if runner_account_needed; then
    ensure_runner_account
fi



# ------------------------------------------------------------------------------
# Section: base packages
# ------------------------------------------------------------------------------
if section_enabled base; then
    log_step "Installing base packages and runner runtime libraries"

    run_sudo dnf -y upgrade --refresh

    # actions/runner's own runtime dependencies on Fedora/RHEL family.
    dnf_install openssl-libs krb5-libs zlib libicu

    dnf_group_install development-tools

    dnf_install \
        gcc gcc-c++ make cmake ninja-build meson pkgconf \
        autoconf automake libtool bison flex gdb strace \
        clang clang-devel llvm lld compiler-rt mold \
        openssl-devel zlib-devel bzip2-devel xz-devel readline-devel sqlite-devel \
        elfutils-libelf-devel libusb1-devel libudev-devel libffi-devel \
        ncurses-devel gmp-devel mpfr-devel libmpc-devel \
        git git-lfs curl wget rsync jq tree file unzip zip tar \
        ca-certificates gnupg2 which hostname findutils procps-ng psmisc lsof \
        util-linux shadow-utils dnf-plugins-core \
        openssh-clients openssh-server \
        ripgrep fd-find bat fzf tmux htop mosh btop \
        usbutils pciutils usbip

    run_sudo dnf -y clean all || true
    log_success "Base packages installed."
fi

# ------------------------------------------------------------------------------
# Section: Rust toolchain
# ------------------------------------------------------------------------------
if section_enabled rust; then
    log_step "Installing Rust toolchain with embedded targets"

    if ! runner_account_ready; then
        log_error "Service account ${RUNNER_USER} is missing; cannot install the Rust toolchain."
        exit 1
    fi

    RUSTUP_BIN="${RUNNER_HOME}/.cargo/bin/rustup"

    if [ ! -x "$RUSTUP_BIN" ]; then
        log_info "Installing rustup (stable) for ${RUNNER_USER}..."
        run_user_shell "$RUNNER_USER" \
            'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile default --default-toolchain stable'
    else
        log_info "rustup already present; updating toolchains."
        run_as_user "$RUNNER_USER" "$RUSTUP_BIN" update || log_warn "rustup update failed; continuing."
    fi

    log_info "Adding cross-compilation and analysis components..."
    run_as_user "$RUNNER_USER" "$RUSTUP_BIN" component add rustfmt clippy rust-src llvm-tools || \
        log_warn "Some rustup components failed to install."

    # Core Cortex-M targets. thumbv6m is ARMv6-M (Cortex-M0/M0+), the thumbv8m
    # pair covers ARMv8-M Baseline (M23) and Mainline (M33/M35P). The extra
    # v7 targets are included because a lot of embedded crates still build for
    # them in CI matrices.
    TARGETS=(
        thumbv6m-none-eabi
        thumbv7m-none-eabi
        thumbv7em-none-eabi
        thumbv7em-none-eabihf
        thumbv8m.base-none-eabi
        thumbv8m.main-none-eabi
        thumbv8m.main-none-eabihf
    )
    log_info "Adding targets: ${TARGETS[*]}"
    run_as_user "$RUNNER_USER" "$RUSTUP_BIN" target add "${TARGETS[@]}" || \
        log_warn "Some targets failed to install; re-run with --rust-only to retry."

    # cargo-binstall lets the remaining tools arrive as prebuilt binaries instead
    # of being compiled from source on every machine.
    BINSTALL_BIN="${RUNNER_HOME}/.cargo/bin/cargo-binstall"
    if [ ! -x "$BINSTALL_BIN" ]; then
        log_info "Installing cargo-binstall..."
        run_user_shell "$RUNNER_USER" \
            'curl -L --proto "=https" --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash'
    fi

    if [ -x "$BINSTALL_BIN" ]; then
        log_info "Installing cargo tooling via cargo-binstall..."
        run_as_user "$RUNNER_USER" "$BINSTALL_BIN" -y \
            cargo-nextest cargo-llvm-cov cargo-deny cargo-binutils probe-rs-tools \
            || log_warn "Some cargo tools failed to install."
    else
        log_warn "cargo-binstall unavailable; install cargo-nextest/cargo-llvm-cov manually if needed."
    fi

    # sccache comes from DNF because the packaged build is already optimized and
    # avoids a source build. It is wired in as the rustc wrapper by the systemd
    # unit unless --no-sccache was passed.
    if [ "$WITH_SCCACHE" -eq 1 ]; then
        dnf_install sccache
    fi

    log_success "Rust toolchain ready for ${RUNNER_USER}."
fi

# ------------------------------------------------------------------------------
# Section: Python
# ------------------------------------------------------------------------------
if section_enabled python; then
    log_step "Installing Python toolchain"

    dnf_install python3 python3-pip python3-devel python3-setuptools python3-wheel \
        python3-virtualenv pipx uv

    log_info "Note: Fedora marks the system Python as externally managed (PEP 668)."
    log_info "Use 'python3 -m venv', 'uv venv', or 'pipx' instead of system-wide pip installs."

    log_success "Python toolchain installed."
fi

# ------------------------------------------------------------------------------
# Section: ARM bare-metal toolchain
# ------------------------------------------------------------------------------
if section_enabled arm; then
    log_step "Installing arm-none-eabi toolchain and debugger support"

    # Fedora ships the ARM bare-metal toolchain under the "-cs" (community
    # supported) package names, unlike Debian's gcc-arm-none-eabi.
    dnf_install arm-none-eabi-gcc-cs arm-none-eabi-gcc-cs-c++ arm-none-eabi-binutils-cs \
        arm-none-eabi-newlib arm-none-eabi-gdb openocd stlink

    if command -v arm-none-eabi-gcc >/dev/null 2>&1; then
        log_info "$(arm-none-eabi-gcc --version | head -n 1)"
    else
        log_warn "arm-none-eabi-gcc is not on PATH; check the package list for your Fedora release."
    fi

    log_success "ARM toolchain installed."
fi

# ------------------------------------------------------------------------------
# Section: QEMU
# ------------------------------------------------------------------------------
if section_enabled qemu; then
    log_step "Installing QEMU for on-host Cortex-M integration tests"

    dnf_install qemu-system-arm qemu-user-static qemu-img

    if command -v qemu-system-arm >/dev/null 2>&1; then
        log_info "Available Cortex-M machines:"
        qemu-system-arm -M help 2>/dev/null | grep -iE 'microbit|mps2|musca' || true
    fi

    log_success "QEMU installed."
fi

# ------------------------------------------------------------------------------
# Section: Container runtime (rootless Podman)
# ------------------------------------------------------------------------------
if section_enabled containers; then
    log_step "Setting up rootless Podman with a docker CLI shim"

    dnf_install podman podman-docker buildah skopeo crun conmon \
        fuse-overlayfs slirp4netns passt containers-common

    # Rootless containers need subordinate UID/GID ranges allocated to the user.
    if ! grep -q "^${RUNNER_USER}:" /etc/subuid 2>/dev/null; then
        log_info "Allocating subordinate UID/GID ranges for ${RUNNER_USER}..."
        run_sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$RUNNER_USER" || \
            log_warn "Could not allocate subordinate ID ranges; rootless Podman may fail."
    fi

    # Linger keeps a user manager around for ${RUNNER_USER} even when nobody is
    # logged in, which is what makes rootless Podman reliable on a headless box.
    run_sudo loginctl enable-linger "$RUNNER_USER" || \
        log_warn "Could not enable linger for ${RUNNER_USER}."

    # A dedicated rootless Podman API socket so container-based Actions and
    # testcontainers-style suites can talk to a Docker-compatible endpoint.
    ensure_dir /run/ghrunner 0755 "${RUNNER_USER}:${RUNNER_USER}"

    write_heredoc /etc/systemd/system/ghrunner-podman.service 0644 root:root <<EOF
# Managed by runner-install-fedora.sh - do not edit by hand.
[Unit]
Description=Rootless Podman API socket for the GitHub Actions runner user
Documentation=https://leftger.github.io/runner-install-fedora.sh
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}
RuntimeDirectory=ghrunner
RuntimeDirectoryMode=0755
StateDirectory=ghrunner
CacheDirectory=ghrunner
Environment=HOME=${RUNNER_HOME}
Environment=XDG_RUNTIME_DIR=/run/ghrunner
ExecStart=/usr/bin/podman system service --time=0 unix:///run/ghrunner/podman/podman.sock
Restart=always
RestartSec=3

# Rootless Podman needs three capabilities that the strict profile below would
# otherwise remove, so they are relaxed here and only here:
#   * newuidmap/newgidmap are setuid-root helpers that must acquire CAP_SETUID
#     and CAP_SETGID. An empty capability bounding set (CapabilityBoundingSet=)
#     masks those bits across exec, which breaks user namespace creation.
#   * NoNewPrivileges=yes stops the setuid bit from taking effect at all.
#   * ProtectControlGroups=yes makes the cgroup subtree read-only, which blocks
#     cgroup delegation. Delegate=yes is what grants it to this service.
NoNewPrivileges=no
CapabilityBoundingSet=~
RestrictSUIDSGID=no
Delegate=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=no
ReadWritePaths=/run/ghrunner
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
RestrictRealtime=yes
LockPersonality=yes
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

    run_sudo systemctl daemon-reload
    run_sudo systemctl enable --now ghrunner-podman.service

    # Point the conventional Docker socket path at the rootless Podman socket so
    # actions that bind-mount /var/run/docker.sock keep working. Jobs then drive
    # containers owned by the runner user rather than a root daemon.
    if [ "$WITH_DOCKER_SOCKET" -eq 1 ]; then
        # Never clobber an existing socket: the machine may already run Docker CE,
        # or use a symlink the operator set up deliberately.
        EXISTING_DOCKER_TARGET=""
        if [ -L /var/run/docker.sock ]; then
            EXISTING_DOCKER_TARGET="$(readlink /var/run/docker.sock)"
        fi

        if [ "$EXISTING_DOCKER_TARGET" = "/run/ghrunner/podman/podman.sock" ]; then
            log_info "/var/run/docker.sock already points at the runner's Podman socket."
        elif [ -e /var/run/docker.sock ] || [ -n "$EXISTING_DOCKER_TARGET" ]; then
            log_warn "/var/run/docker.sock already exists (target: ${EXISTING_DOCKER_TARGET:-regular file}); leaving it untouched."
            log_warn "Jobs can still reach Podman via DOCKER_HOST=unix:///run/ghrunner/podman/podman.sock."
        else
            run_sudo ln -sfn /run/ghrunner/podman/podman.sock /var/run/docker.sock
            log_info "Linked /var/run/docker.sock -> /run/ghrunner/podman/podman.sock"
        fi
    fi

    log_success "Rootless Podman ready."
fi

# ------------------------------------------------------------------------------
# Section: security defaults
# ------------------------------------------------------------------------------
if section_enabled security; then
    log_step "Applying security defaults"

    # --- firewalld: enabled, default zone, no inbound except SSH ---------------
    dnf_install firewalld
    run_sudo systemctl enable --now firewalld || log_warn "Could not start firewalld."
    if command -v firewall-cmd >/dev/null 2>&1; then
        log_info "$(firewall-cmd --state 2>/dev/null || echo 'firewalld not running')"
        log_info "Default zone: $(firewall-cmd --get-default-zone 2>/dev/null || echo unknown)"
    fi
    # mosh needs its UDP transport range open. Without it the SSH handshake
    # succeeds and the session then hangs, because the UDP leg is dropped.
    # firewalld ships no mosh service definition, so the range is opened directly
    # (mosh's default is 60000-61000/udp).
    if [ "$WITH_MOSH" -eq 1 ] && command -v firewall-cmd >/dev/null 2>&1; then
        run_sudo_quiet firewall-cmd --permanent --add-port=60000-61000/udp
        run_sudo_quiet firewall-cmd --reload
        log_info "Opened udp/60000-61000 for mosh."
    fi

    # --- kernel/network sysctl hardening --------------------------------------
    write_heredoc /etc/sysctl.d/60-gh-runner-hardening.conf 0644 root:root <<'EOF'
# Managed by runner-install-fedora.sh - kernel and network hardening for a CI node.
# Loosen individual keys here if a specific test suite needs them.

# Restrict kernel log and pointer leaks.
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# Restrict ptrace to child processes. Note: attaching gdb to an unrelated
# running process requires setting this to 0 temporarily.
kernel.yama.ptrace_scope = 1

# Restrict unprivileged BPF and harden the BPF JIT against spray attacks.
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Disallow kernel profiling by unprivileged users.
kernel.perf_event_paranoid = 3

# Never dump setuid process memory.
fs.suid_dumpable = 0

# Reverse-path filtering and SYN cookies.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1

# Ignore ICMP redirects and source-routed packets.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF
    run_sudo_quiet sysctl --system || log_warn "Some sysctl keys could not be applied."

    # --- SELinux --------------------------------------------------------------
    if command -v getenforce >/dev/null 2>&1; then
        SELINUX_STATE="$(getenforce 2>/dev/null || echo Unknown)"
        log_info "SELinux mode: ${SELINUX_STATE}"
        if [ "$SELINUX_STATE" != "Disabled" ]; then
            log_info "Relabelling runner paths so the service can execute them."
            run_sudo restorecon -R "$RUNNER_DIR" 2>/dev/null || true
            run_sudo restorecon -R "$RUNNER_HOME" 2>/dev/null || true
        fi
    fi

    # --- bounded journald usage ----------------------------------------------
    ensure_dir /etc/systemd/journald.conf.d 0755
    write_heredoc /etc/systemd/journald.conf.d/60-gh-runner.conf 0644 root:root <<'EOF'
# Managed by runner-install-fedora.sh - CI logs are chatty, keep them bounded.
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=100M
MaxRetentionSec=2week
EOF
    run_sudo systemctl restart systemd-journald 2>/dev/null || true

    # --- unattended security updates -----------------------------------------
    if [ "$WITH_AUTOUPDATE" -eq 1 ]; then
        dnf_install dnf-automatic
        write_heredoc /etc/dnf/automatic.conf 0644 root:root <<'EOF'
# Managed by runner-install-fedora.sh - security updates only, applied automatically.
[commands]
upgrade_type = security
network_online_timeout = 60
download_updates = yes
apply_updates = yes

[emitters]
emit_via = stdio
EOF
        run_sudo systemctl enable --now dnf-automatic.timer || \
            log_warn "Could not enable dnf-automatic.timer."
        log_info "Security updates will be applied automatically by dnf-automatic.timer."
    fi

    # --- optional fail2ban ----------------------------------------------------
    if [ "$WITH_FAIL2BAN" -eq 1 ]; then
        dnf_install fail2ban fail2ban-firewalld
        run_sudo systemctl enable --now fail2ban || log_warn "Could not start fail2ban."
    fi

    # --- optional sshd hardening ---------------------------------------------
    if [ "$HARDEN_SSH" -eq 1 ]; then
        SSH_KEYS_FOUND=0
        for keyfile in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
            if [ -s "$keyfile" ]; then
                SSH_KEYS_FOUND=1
                break
            fi
        done

        if [ "$SSH_KEYS_FOUND" -eq 0 ] && [ "$ALLOW_SSH_LOCKOUT" != "1" ]; then
            log_error "Refusing to harden sshd: no non-empty authorized_keys found anywhere."
            log_error "Password logins would be disabled with no key to fall back on."
            log_error "Install a key first, or set GH_RUNNER_ALLOW_SSH_LOCKOUT=1 to override."
        else
            ensure_dir /etc/ssh/sshd_config.d 0755
            write_heredoc /etc/ssh/sshd_config.d/60-gh-runner-hardening.conf 0644 root:root <<'EOF'
# Managed by runner-install-fedora.sh - hardening for a headless CI node.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 4
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
            if run_sudo sshd -t 2>/dev/null; then
                run_sudo systemctl reload sshd 2>/dev/null || run_sudo systemctl reload sshd.service 2>/dev/null || \
                    log_warn "Could not reload sshd; changes apply on next restart."
                log_success "sshd hardened (key-only authentication)."
            else
                log_error "sshd config validation failed; removing the drop-in to avoid breaking SSH."
                run_sudo rm -f /etc/ssh/sshd_config.d/60-gh-runner-hardening.conf
            fi
        fi
    fi

    log_success "Security defaults applied."
fi

# ------------------------------------------------------------------------------
# Section: hardware access (service account, udev rules, labels)
# ------------------------------------------------------------------------------
if section_enabled hardware; then
    log_step "Configuring debug-probe access"

    # The service account is created by ensure_runner_account() before any
    # section runs, because the containers section needs it to already exist.
    if ! runner_account_ready; then
        log_error "Service account ${RUNNER_USER} is missing; cannot configure probe access."
        exit 1
    fi

    # --- udev rules for debug probes -----------------------------------------
    # SYSTEMD_WANTS/TAG+="uaccess" only grants access to a seat-bound interactive
    # user, so a headless service account needs explicit GROUP/MODE rules.
    write_heredoc /etc/udev/rules.d/70-gh-runner-probes.rules 0644 root:root <<EOF
# Managed by runner-install-fedora.sh - USB debug probe access for the ${RUNNER_USER} group.
# Grants rw access to bare-metal debuggers used by probe-rs / OpenOCD / pyOCD.

# STMicroelectronics ST-LINK/V2, V2-1, V3
SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="374?", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="375?", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0483", MODE="0660", GROUP="${RUNNER_USER}"

# SEGGER J-Link (vendor-wide: SEGGER only ships debug probes)
SUBSYSTEM=="usb", ATTR{idVendor}=="1366", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1366", MODE="0660", GROUP="${RUNNER_USER}"

# ARM mbed DAPLink / CMSIS-DAP
SUBSYSTEM=="usb", ATTR{idVendor}=="0d28", ATTR{idProduct}=="02??", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0d28", MODE="0660", GROUP="${RUNNER_USER}"

# Raspberry Pi Debug Probe / picoprobe
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="000[0-9a-f]", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", MODE="0660", GROUP="${RUNNER_USER}"

# Black Magic Probe
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="6017", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="6018", MODE="0660", GROUP="${RUNNER_USER}"

# FTDI FT2232/FT232H based probes (many vendor boards, e.g. ESP32 dev kits)
SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="60??", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0660", GROUP="${RUNNER_USER}"

# Espressif USB JTAG/serial
SUBSYSTEM=="usb", ATTR{idVendor}=="303a", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", MODE="0660", GROUP="${RUNNER_USER}"

# Nordic Semiconductor development kits
SUBSYSTEM=="usb", ATTR{idVendor}=="1915", MODE="0660", GROUP="${RUNNER_USER}"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1915", MODE="0660", GROUP="${RUNNER_USER}"

# hidraw nodes for probes that expose a HID interface
KERNEL=="hidraw*", ATTRS{idVendor}=="0483", MODE="0660", GROUP="${RUNNER_USER}"
KERNEL=="hidraw*", ATTRS{idVendor}=="1366", MODE="0660", GROUP="${RUNNER_USER}"
KERNEL=="hidraw*", ATTRS{idVendor}=="0d28", MODE="0660", GROUP="${RUNNER_USER}"
EOF

    run_sudo udevadm control --reload-rules
    run_sudo udevadm trigger

    # --- detected hardware labels --------------------------------------------
    HW_LABELS="$(detect_hardware_labels | paste -sd, -)"
    if [ -n "$HW_LABELS" ]; then
        log_info "Detected debug hardware: ${HW_LABELS}"
    else
        log_info "No USB debug probes detected (labels can be added later with --labels)."
    fi

    # --- convenience shell for the service account ---------------------------
    # The account uses nologin, but operators debug via `sudo -u ghrunner -i`.
    write_heredoc "${RUNNER_HOME}/.bashrc" 0644 "${RUNNER_USER}:${RUNNER_USER}" <<'EOF'
# Managed by runner-install-fedora.sh
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$PATH"
EOF

    log_success "Runner account and probe access configured."
fi

# ------------------------------------------------------------------------------
# Section: interactive shell for the operator account
#
# Ported from bootstrap.sh. Everything in this section targets the human who
# administers the machine, never the runner service account: ghrunner is a nologin
# account that executes untrusted pull-request code, so it deliberately gets no
# prompt, no oh-my-zsh, and no login shell.
# ------------------------------------------------------------------------------
if section_enabled shell && [ "$WITH_SHELL" -eq 1 ]; then
    log_step "Configuring zsh, oh-my-zsh, and fzf for ${SHELL_USER}"

    dnf_install zsh fzf

    ZSH_BIN="$(command -v zsh 2>/dev/null || true)"
    if [ -z "$ZSH_BIN" ] && [ "$DRY_RUN" -eq 1 ]; then
        # Nothing was really installed, so preview the rest of the section.
        ZSH_BIN="/usr/bin/zsh"
        log_info "[DRY-RUN] Assuming zsh lands at ${ZSH_BIN}"
    fi

    if [ -z "$ZSH_BIN" ]; then
        log_warn "zsh is not available on this system; skipping the shell setup."
    else
        SHELL_OMZ_DIR="${SHELL_HOME}/.oh-my-zsh"
        SHELL_PLUGINS_DIR="${SHELL_OMZ_DIR}/custom/plugins"
        SHELL_ZSHRC="${SHELL_HOME}/.zshrc"
        SHELL_TARGET_PLUGINS="git sudo rust extract z colored-man-pages command-not-found zsh-autosuggestions zsh-syntax-highlighting"

        # Append a block to .zshrc once, keyed on a marker string, so re-running the
        # installer never stacks duplicate blocks.
        append_zshrc_block() {
            local marker="$1"
            local block="$2"

            if [ -f "$SHELL_ZSHRC" ] && grep -qF "$marker" "$SHELL_ZSHRC" 2>/dev/null; then
                return 0
            fi
            printf '%s\n' "$block" | run_sudo_quiet tee -a "$SHELL_ZSHRC"
        }

        # --- preserve the existing .zshrc before touching it -------------------
        if [ -f "$SHELL_ZSHRC" ] && [ "$DRY_RUN" -eq 0 ]; then
            SHELL_BACKUP_DIR="${SHELL_HOME}/.local/state/gh-runner-install/backups/$(date +%Y%m%d_%H%M%S)"
            ensure_dir "$SHELL_BACKUP_DIR" 0755 "${SHELL_USER}:${SHELL_GROUP}"
            run_sudo cp -p "$SHELL_ZSHRC" "${SHELL_BACKUP_DIR}/.zshrc"
            log_info "Backed up .zshrc to ${SHELL_BACKUP_DIR}/.zshrc"
        fi

        # --- oh-my-zsh --------------------------------------------------------
        if [ -d "$SHELL_OMZ_DIR" ]; then
            log_info "oh-my-zsh is already installed at ${SHELL_OMZ_DIR}."
        else
            log_info "Installing oh-my-zsh (unattended) for ${SHELL_USER}..."
            # KEEP_ZSHRC=yes so an existing .zshrc is never replaced, and CHSH=no
            # because the login shell is changed explicitly further down.
            run_as_user_env "$SHELL_USER" "$SHELL_HOME" "$SHELL_PATH" \
                'RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
        fi

        # --- third-party plugins ---------------------------------------------
        ensure_dir "$SHELL_PLUGINS_DIR" 0755 "${SHELL_USER}:${SHELL_GROUP}"
        for plugin_spec in \
            "zsh-autosuggestions:https://github.com/zsh-users/zsh-autosuggestions" \
            "zsh-syntax-highlighting:https://github.com/zsh-users/zsh-syntax-highlighting.git" \
            "zsh-completions:https://github.com/zsh-users/zsh-completions.git"; do
            plugin_name="${plugin_spec%%:*}"
            plugin_url="${plugin_spec#*:}"
            plugin_dir="${SHELL_PLUGINS_DIR}/${plugin_name}"

            if [ -d "$plugin_dir" ]; then
                log_info "Plugin ${plugin_name} is already present."
            else
                log_info "Cloning plugin ${plugin_name}..."
                run_as_user_env "$SHELL_USER" "$SHELL_HOME" "$SHELL_PATH" \
                    "git clone --depth=1 $(printf '%q' "$plugin_url") $(printf '%q' "$plugin_dir") || true"
            fi
        done

        # --- .zshrc: merge plugins and add quality-of-life settings ----------
        if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$SHELL_ZSHRC" ]; then
            run_sudo touch "$SHELL_ZSHRC"
            run_sudo chmod 0644 "$SHELL_ZSHRC"
            run_sudo chown "${SHELL_USER}:${SHELL_GROUP}" "$SHELL_ZSHRC"
        fi

        if [ "$DRY_RUN" -eq 0 ] && grep -q '^plugins=(' "$SHELL_ZSHRC" 2>/dev/null; then
            # Merge with whatever plugins are already enabled rather than
            # overwriting the line, so existing choices are not dropped.
            SHELL_CURRENT_LINE="$(grep -m1 '^plugins=(' "$SHELL_ZSHRC")"
            SHELL_CURRENT_STR="${SHELL_CURRENT_LINE#plugins=(}"
            SHELL_CURRENT_STR="${SHELL_CURRENT_STR%)}"
            # shellcheck disable=SC2206 # intentional word-splitting of the plugin list
            SHELL_CURRENT_ARR=($SHELL_CURRENT_STR)
            # shellcheck disable=SC2206
            SHELL_TARGET_ARR=($SHELL_TARGET_PLUGINS)
            SHELL_MERGED=""
            for plugin_name in "${SHELL_CURRENT_ARR[@]-}" "${SHELL_TARGET_ARR[@]-}"; do
                [ -n "$plugin_name" ] || continue
                case " ${SHELL_MERGED} " in
                    *" $plugin_name "*) ;;
                    *) SHELL_MERGED="${SHELL_MERGED} ${plugin_name}" ;;
                esac
            done
            SHELL_MERGED="${SHELL_MERGED# }"
            run_sudo sed -i "s/^plugins=(.*)/plugins=(${SHELL_MERGED})/" "$SHELL_ZSHRC"
            log_info "Merged zsh plugins: ${SHELL_MERGED}"
        elif [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Merge plugins=(${SHELL_TARGET_PLUGINS}) into ${SHELL_ZSHRC}"
        else
            append_zshrc_block "plugins=(" "plugins=(${SHELL_TARGET_PLUGINS})"
            log_info "Set zsh plugins: ${SHELL_TARGET_PLUGINS}"
        fi

        append_zshrc_block "GPG_TTY" '

# Attach GPG pinentry to the active terminal
if [ -t 0 ]; then
    export GPG_TTY=$(tty)
fi'

        append_zshrc_block 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"' '

# User custom binary search path
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"'

        # Anchored matches so a commented-out template default such as
        # `# DISABLE_MAGIC_FUNCTIONS="true"` is not mistaken for a live setting.
        if [ ! -f "$SHELL_ZSHRC" ] || ! grep -qE '^DISABLE_MAGIC_FUNCTIONS="true"' "$SHELL_ZSHRC" 2>/dev/null; then
            append_zshrc_block 'DISABLE_MAGIC_FUNCTIONS="true"' 'DISABLE_MAGIC_FUNCTIONS="true"'
        fi
        if [ ! -f "$SHELL_ZSHRC" ] || ! grep -qE '^DISABLE_UNTRACKED_FILES_DIRTY="true"' "$SHELL_ZSHRC" 2>/dev/null; then
            append_zshrc_block 'DISABLE_UNTRACKED_FILES_DIRTY="true"' 'DISABLE_UNTRACKED_FILES_DIRTY="true"'
        fi

        append_zshrc_block "fzf --zsh" '

# Interactive fzf keybindings (Ctrl+R, Ctrl+T, Alt+C) and fuzzy completion
if command -v fzf >/dev/null 2>&1; then
    eval "$(fzf --zsh 2>/dev/null || true)"
fi'

        # --- make zsh the login shell ----------------------------------------
        # chsh rejects a shell that is not listed in /etc/shells.
        if ! grep -Fxq "$ZSH_BIN" /etc/shells 2>/dev/null; then
            printf '%s\n' "$ZSH_BIN" | run_sudo_quiet tee -a /etc/shells
        fi

        SHELL_CURRENT_SHELL="$(getent passwd "$SHELL_USER" 2>/dev/null | cut -d: -f7 || echo "")"
        if [ "$SHELL_CURRENT_SHELL" = "$ZSH_BIN" ]; then
            log_info "Login shell for ${SHELL_USER} is already ${ZSH_BIN}."
        else
            log_info "Changing the login shell for ${SHELL_USER} to ${ZSH_BIN}..."
            run_sudo chsh -s "$ZSH_BIN" "$SHELL_USER" || \
                log_warn "Could not change the login shell for ${SHELL_USER}; set it manually with 'chsh -s ${ZSH_BIN}'."
        fi

        # Ownership: every file above was written by root.
        if [ "$DRY_RUN" -eq 0 ]; then
            run_sudo chown -R "${SHELL_USER}:${SHELL_GROUP}" "$SHELL_OMZ_DIR" 2>/dev/null || true
            run_sudo chown "${SHELL_USER}:${SHELL_GROUP}" "$SHELL_ZSHRC" 2>/dev/null || true
        fi

        log_success "zsh, oh-my-zsh, and fzf configured for ${SHELL_USER}."
    fi
fi

# ------------------------------------------------------------------------------
# Section: runner install / registration / service
# ------------------------------------------------------------------------------
if section_enabled runner; then
    log_step "Installing the GitHub Actions runner"

    if ! runner_account_ready; then
        log_error "Service account ${RUNNER_USER} does not exist. Run with --hardware-only first."
        exit 1
    fi

    # --- resolve version ------------------------------------------------------
    if [ -z "$RUNNER_VERSION" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "[DRY-RUN] Would resolve the latest actions/runner release from the GitHub API."
            RUNNER_VERSION="0.0.0"
        else
            need_cmd jq
            log_info "Resolving the latest actions/runner release..."
            api_args=()
            if [ -n "$RUNNER_PAT" ]; then
                api_args=(--header "Authorization: Bearer ${RUNNER_PAT}")
            fi
            RUNNER_VERSION="$(curl -fsSL --retry 3 "${api_args[@]}" \
                https://api.github.com/repos/actions/runner/releases/latest 2>/dev/null \
                | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')" || true
            if [ -z "$RUNNER_VERSION" ]; then
                log_error "Could not resolve the latest actions/runner release (API rate limit or no network)."
                log_error "Re-run with --runner-version <VERSION> to pin one explicitly."
                exit 1
            fi
        fi
    fi
    log_info "actions/runner version: ${RUNNER_VERSION}"

    ASSET_NAME="actions-runner-linux-${ARCH_TYPE}-${RUNNER_VERSION}.tar.gz"
    ASSET_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${ASSET_NAME}"
    TARBALL="${BOOTSTRAP_TMP_DIR}/${ASSET_NAME}"
    EXPECTED_SHA=""

    if [ "$DRY_RUN" -eq 0 ]; then
        # Prefer the digest GitHub publishes on the release asset itself; fall
        # back to a .sha256 sibling asset when present.
        if command -v jq >/dev/null 2>&1; then
            EXPECTED_SHA="$(curl -fsSL --retry 3 "${api_args[@]}" \
                "https://api.github.com/repos/actions/runner/releases/tags/v${RUNNER_VERSION}" 2>/dev/null \
                | jq -r --arg n "$ASSET_NAME" '.assets[]? | select(.name==$n) | .digest // empty' 2>/dev/null \
                | sed 's/^sha256://')" || true
        fi

        log_info "Downloading ${ASSET_NAME}..."
        downloader "$ASSET_URL" "$TARBALL"

        if [ -z "$EXPECTED_SHA" ]; then
            if downloader "${ASSET_URL}.sha256" "${TARBALL}.sha256" 2>/dev/null; then
                EXPECTED_SHA="$(cut -d' ' -f1 <"${TARBALL}.sha256" | tr -d '[:space:]')"
            fi
        fi

        if [ -n "$EXPECTED_SHA" ]; then
            if verify_sha256 "$TARBALL" "$EXPECTED_SHA"; then
                log_success "Tarball SHA-256 verified."
            else
                log_error "SHA-256 mismatch for ${ASSET_NAME}. Aborting."
                exit 1
            fi
        else
            log_warn "No published checksum found for ${ASSET_NAME}; continuing without verification."
        fi
    fi

    # --- unpack ---------------------------------------------------------------
    run_sudo install -d -m 0755 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"
    run_sudo install -d -m 0755 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_WORK"

    if [ "$DRY_RUN" -eq 0 ]; then
        log_info "Extracting runner into ${RUNNER_DIR}..."
        run_sudo tar -xzf "$TARBALL" -C "$RUNNER_DIR"
        run_sudo chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
    fi

    # Label set shared by both runner modes: what this machine is provisioned for,
    # plus hardware-detected labels, plus any operator-supplied ones. Ephemeral
    # runners need this too, otherwise workflow `runs-on` filters would never
    # match them.
    DEFAULT_LABELS="rust,embedded,arm-none-eabi,qemu,thumbv6m,thumbv8m,fedora${OS_VERSION}"
    if [ "$WITH_SCCACHE" -eq 1 ]; then
        DEFAULT_LABELS="${DEFAULT_LABELS},sccache"
    fi
    if section_enabled containers; then
        DEFAULT_LABELS="${DEFAULT_LABELS},podman"
    fi
    CUSTOM_LABELS="${RUNNER_LABELS},${HW_LABELS:-}"
    CUSTOM_LABELS="$(printf '%s' "$CUSTOM_LABELS" | tr -d ' ' | sed 's/^,//; s/,,*/,/g; s/,$//')"
    ALL_LABELS="${DEFAULT_LABELS},${CUSTOM_LABELS}"
    ALL_LABELS="$(printf '%s' "$ALL_LABELS" | sed 's/,,*/,/g; s/,$//')"
    log_info "Labels: ${ALL_LABELS}"

    if [ "$RUNNER_EPHEMERAL" -eq 1 ]; then
        # ---------------------------------------------------------------------
        # Ephemeral / just-in-time mode: fetch a single-use JIT config per job.
        # JIT-registered runners are implicitly ephemeral, so no --ephemeral
        # flag is passed to run.sh.
        # ---------------------------------------------------------------------
        log_info "Configuring ephemeral (JIT) runner mode."

        ensure_dir /etc/gh-runner 0750 "root:${RUNNER_USER}"

        write_heredoc "$JIT_ENV_FILE" 0640 "root:${RUNNER_USER}" <<EOF
# Managed by runner-install-fedora.sh - contains a GitHub PAT. Mode 0640 root:${RUNNER_USER}.
GH_JIT_API='${RUNNER_JIT_API}'
GH_JIT_PAT='${RUNNER_PAT}'
GH_JIT_NAME='${RUNNER_NAME}'
GH_JIT_LABELS='${ALL_LABELS}'
GH_JIT_WORK='${RUNNER_WORK}'
GH_JIT_RUNNER_DIR='${RUNNER_DIR}'
GH_JIT_GROUP_ID='${RUNNER_GROUP_ID}'
EOF

        ensure_dir /usr/local/libexec 0755
        write_heredoc "$JIT_WRAPPER" 0755 root:root <<'EOF'
#!/usr/bin/env bash
# Managed by runner-install-fedora.sh - fetch a one-shot JIT config, then run one job.
# Exits when the single job completes; systemd restarts this unit to re-register.
set -euo pipefail

env_file=/etc/gh-runner/jit.env
if [ ! -r "$env_file" ]; then
    echo "ghrunner: ${env_file} is missing or unreadable" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$env_file"

cd "$GH_JIT_RUNNER_DIR"

labels_json="$(printf '%s\n' "$GH_JIT_LABELS" | tr ',' '\n' | jq -R . | jq -s 'map(select(length > 0))')"
payload="$(jq -n --arg name "$GH_JIT_NAME" --arg work "$GH_JIT_WORK" --argjson labels "$labels_json" \
    '{name: $name, labels: $labels, work_folder: $work}')"
if [ -n "${GH_JIT_GROUP_ID:-}" ]; then
    payload="$(jq -c --argjson gid "$GH_JIT_GROUP_ID" '. + {runner_group_id: $gid}' <<<"$payload")"
fi

resp="$(curl -sSL --retry 3 -X POST \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${GH_JIT_PAT}" \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$GH_JIT_API" -d "$payload" 2>/dev/null)" || resp=""

jit="$(printf '%s' "$resp" | jq -r '.encoded_jit_config // empty' 2>/dev/null || true)"

if [ -z "$jit" ]; then
    echo "ghrunner: could not obtain a JIT config from ${GH_JIT_API}" >&2
    # Surface the API's own message (never the token) to help with diagnosis.
    printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null | sed 's/^/ghrunner: API said: /' >&2 || true
    exit 1
fi

exec ./run.sh --jitconfig "$jit"
EOF

        write_heredoc /etc/systemd/system/ghrunner-jit.service 0644 root:root <<EOF
# Managed by runner-install-fedora.sh - do not edit by hand.
[Unit]
Description=Ephemeral GitHub Actions runner (${RUNNER_NAME})
Documentation=https://leftger.github.io/runner-install-fedora.sh
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}
WorkingDirectory=${RUNNER_DIR}
ExecStart=${JIT_WRAPPER}
Restart=always
RestartSec=15
KillMode=mixed
TimeoutStopSec=5min

Environment=HOME=${RUNNER_HOME}
Environment=PATH=${RUNNER_PATH}
Environment=CARGO_TERM_COLOR=always
Environment=RUST_BACKTRACE=1
Environment=RUSTUP_HOME=${RUNNER_HOME}/.rustup
Environment=CARGO_HOME=${RUNNER_HOME}/.cargo
Environment=ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=${RUNNER_DIR}/.action-archive-cache
Environment=SCCACHE_DIR=/var/cache/ghrunner/sccache

# Filesystem sandbox: read-only system, writable runner dir and state dir only.
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${RUNNER_DIR}
StateDirectory=ghrunner
CacheDirectory=ghrunner
PrivateTmp=yes

# Privilege restrictions.
NoNewPrivileges=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=
AmbientCapabilities=
LockPersonality=yes
RestrictRealtime=yes

# Kernel surface. PrivateDevices is intentionally NOT set: on-hardware
# integration tests need the USB debug probes granted by the udev rules.
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
SystemCallArchitectures=native
EOF

        run_sudo systemctl daemon-reload
        run_sudo systemctl enable --now ghrunner-jit.service
        log_success "Ephemeral runner service enabled."
    else
        # ---------------------------------------------------------------------
        # Persistent runner: register once with a one-time token, then install
        # the generated systemd unit with hardening drop-ins on top.
        # ---------------------------------------------------------------------
        log_info "Registering runner '${RUNNER_NAME}' with ${RUNNER_URL}..."

        CONFIG_ARGS=(--unattended
            --url "$RUNNER_URL"
            --name "$RUNNER_NAME"
            --work "$RUNNER_WORK"
            --labels "$ALL_LABELS"
            --token "$RUNNER_TOKEN")
        if [ -n "$RUNNER_GROUP" ]; then
            CONFIG_ARGS+=(--runnergroup "$RUNNER_GROUP")
        fi
        if [ "$RUNNER_REPLACE" -eq 1 ]; then
            CONFIG_ARGS+=(--replace)
        fi

        # Arguments are passed as argv rather than interpolated into a shell
        # string, so labels/URLs never need quoting or escaping.
        run_as_user "$RUNNER_USER" bash -c \
            'cd "$1" || exit 1; shift; exec ./config.sh "$@"' _ \
            "$RUNNER_DIR" "${CONFIG_ARGS[@]}"

        # The registration token is single-use; drop it from memory.
        RUNNER_TOKEN=""
        unset RUNNER_TOKEN

        log_info "Installing the systemd service via svc.sh..."
        run_sudo bash -c 'cd "$1" || exit 1; shift; exec ./svc.sh "$@"' _ \
            "$RUNNER_DIR" install "$RUNNER_USER"

        # ---------------------------------------------------------------------
        # Hardening drop-ins. svc.sh emits an unhardened unit, so we layer
        # numbered drop-ins on top: 10-* always, 20-* only for containers.
        # ---------------------------------------------------------------------
        UNIT_FILE=""
        for candidate in /etc/systemd/system/actions.runner.*.service; do
            if [ -e "$candidate" ]; then
                UNIT_FILE="$candidate"
            fi
        done

        if [ -n "$UNIT_FILE" ]; then
            UNIT_NAME="$(basename "$UNIT_FILE")"
        elif [ "$DRY_RUN" -eq 1 ]; then
            # Nothing was generated under --dry-run; predict the name svc.sh would
            # use so the hardening drop-ins can still be previewed.
            UNIT_NAME="actions.runner.${RUNNER_SLUG}.${RUNNER_NAME}.service"
        else
            UNIT_NAME=""
        fi

        if [ -n "$UNIT_NAME" ]; then
            DROPIN_DIR="/etc/systemd/system/${UNIT_NAME}.d"
            ensure_dir "$DROPIN_DIR" 0755

            # GitHub's own actions.runner.service.template ships no Restart= directive,
            # so a crashed or OOM-killed listener stays down until a human notices.
            # This drop-in is what makes the service self-healing at runtime; boot
            # startup is already handled by the systemctl enable that svc.sh performs.
            write_heredoc "${DROPIN_DIR}/05-restart.conf" 0644 root:root <<'EOF'
# Managed by runner-install-fedora.sh - do not edit by hand.
[Unit]
# Retry a crash loop indefinitely rather than letting the unit land in a failed
# state after systemd's default limit of five starts in ten seconds.
StartLimitIntervalSec=0
# svc.sh already sets After=network-online.target, but nothing pulls that target in
# without a Wants=, and a runner that starts before DNS is reachable cannot register.
Wants=network-online.target

[Service]
# Restart on any exit, including a clean exit(0) from the listener.
Restart=always
RestartSec=5
EOF

            write_heredoc "${DROPIN_DIR}/10-hardening.conf" 0644 root:root <<EOF
# Managed by runner-install-fedora.sh - do not edit by hand.
[Service]
# --- Filesystem sandbox -------------------------------------------------------
# The whole system becomes read-only; only the runner directory and the systemd
# state/cache directories stay writable.
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${RUNNER_DIR}
StateDirectory=ghrunner
CacheDirectory=ghrunner
PrivateTmp=yes

# --- Privilege restrictions ---------------------------------------------------
NoNewPrivileges=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=
AmbientCapabilities=
LockPersonality=yes
RestrictRealtime=yes

# --- Kernel surface -----------------------------------------------------------
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
SystemCallArchitectures=native

# PrivateDevices is intentionally NOT set: on-hardware integration tests need
# access to USB debug probes exposed by /etc/udev/rules.d/70-gh-runner-probes.rules.
#
# MemoryDenyWriteExecute and SystemCallFilter are also intentionally omitted:
# V8/JIT runtimes and cross toolchains need writable-executable memory and a
# broad syscall surface.

# --- Job environment ----------------------------------------------------------
# System services do not inherit a login environment, so PATH/toolchain roots are
# pinned explicitly. HOME points at the systemd state directory.
Environment=HOME=${RUNNER_HOME}
Environment=PATH=${RUNNER_PATH}
Environment=RUSTUP_HOME=${RUNNER_HOME}/.rustup
Environment=CARGO_HOME=${RUNNER_HOME}/.cargo
Environment=CARGO_TERM_COLOR=always
Environment=CARGO_NET_RETRY=5
Environment=CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
Environment=RUST_BACKTRACE=1
Environment=ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=${RUNNER_DIR}/.action-archive-cache
Environment=SCCACHE_DIR=/var/cache/ghrunner/sccache
Environment=SCCACHE_CACHE_SIZE=20G
EOF

            if [ "$WITH_SCCACHE" -eq 1 ]; then
                # sccache as a global rustc wrapper: a big win for a fleet running
                # the same build matrix on every machine.
                write_heredoc "${DROPIN_DIR}/15-sccache.conf" 0644 root:root <<'EOF'
# Managed by runner-install-fedora.sh - sccache as the global rustc wrapper.
# Remove this file (or set --no-sccache) if a project needs a plain rustc.
[Service]
Environment=RUSTC_WRAPPER=sccache
EOF
            fi

            if section_enabled containers; then
                if [ "$STRICT_HARDENING" -eq 1 ]; then
                    log_warn "--strict-hardening set: keeping NoNewPrivileges=yes and ProtectControlGroups=yes."
                    log_warn "Rootless Podman will very likely fail inside jobs on this machine."
                else
                    write_heredoc "${DROPIN_DIR}/20-containers.conf" 0644 root:root <<'EOF'
# Managed by runner-install-fedora.sh - relaxations required for rootless Podman.
#
# Creating a rootless user namespace goes through the setuid-root newuidmap and
# newgidmap helpers, which need CAP_SETUID/CAP_SETGID. Three settings from
# 10-hardening.conf would prevent that, so they are relaxed on machines that are
# built with containers enabled:
#   * CapabilityBoundingSet= (empty) masks capabilities across exec, so the
#     setuid helpers could never gain CAP_SETUID/CAP_SETGID.
#   * NoNewPrivileges=yes stops setuid binaries from gaining privileges at all.
#   * ProtectControlGroups=yes makes the cgroup subtree read-only, blocking the
#     delegation that rootless containers need.
# Machines installed with --strict-hardening keep the strict values and are
# expected to be container-free.
[Service]
NoNewPrivileges=no
CapabilityBoundingSet=~
RestrictSUIDSGID=no
ProtectControlGroups=no
Delegate=yes
RuntimeDirectory=ghrunner
RuntimeDirectoryMode=0755
Environment=XDG_RUNTIME_DIR=/run/ghrunner
Environment=DOCKER_HOST=unix:///run/ghrunner/podman/podman.sock
EOF
                fi
            fi

            run_sudo systemctl daemon-reload
        else
            log_warn "Could not locate the generated systemd unit; skipping hardening drop-ins."
        fi

        run_sudo bash -c 'cd "$1" || exit 1; shift; exec ./svc.sh "$@"' _ "$RUNNER_DIR" start

        # svc.sh install already runs systemctl enable, but assert it here so a machine
        # whose unit was previously disabled cannot silently lose its runner at the
        # next reboot. Report the real state instead of assuming it took effect.
        if [ -n "$UNIT_NAME" ]; then
            run_sudo_quiet systemctl enable "$UNIT_NAME" || \
                log_warn "Could not enable ${UNIT_NAME}; the runner may not start at boot."
            if [ "$DRY_RUN" -eq 0 ]; then
                log_info "Service state: $(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || echo unknown) / $(systemctl is-active "$UNIT_NAME" 2>/dev/null || echo unknown)"
            fi
            if [ "$WITH_WATCHDOG" -eq 1 ]; then
                install_watchdog "$UNIT_NAME"
            fi
        fi

        log_success "Persistent runner service started."
    fi

    # --- QEMU / cargo defaults for the runner account -------------------------
    # A per-user cargo config means `cargo test` for a thumb target can boot the
    # built ELF under QEMU without any repo-local setup. Repository config still
    # takes precedence, so projects can override this freely.
    if section_enabled qemu; then
        CARGO_CONFIG="${RUNNER_HOME}/.cargo/config.toml"
        if [ "$DRY_RUN" -eq 1 ] || [ ! -e "$CARGO_CONFIG" ]; then
            ensure_dir "${RUNNER_HOME}/.cargo" 0755 "${RUNNER_USER}:${RUNNER_USER}"
            write_heredoc "$CARGO_CONFIG" 0644 "${RUNNER_USER}:${RUNNER_USER}" <<'EOF'
# Managed by runner-install-fedora.sh - CI-friendly cargo defaults with QEMU runners.
# Repository-local .cargo/config.toml files take precedence over this one.

[build]
incremental = false

[term]
color = "always"

[net]
retry = 5
git-fetch-with-cli = true

# Cortex-M0/M0+ (nRF51 micro:bit and similar boards)
[target.thumbv6m-none-eabi]
runner = "qemu-system-arm -M microbit -cpu cortex-m0 -nographic -semihosting -kernel"

# ARMv8-M Baseline (Cortex-M23)
[target.thumbv8m.base-none-eabi]
runner = "qemu-system-arm -M mps2-an521 -cpu cortex-m23 -nographic -semihosting -kernel"

# ARMv8-M Mainline (Cortex-M33)
[target.thumbv8m.main-none-eabi]
runner = "qemu-system-arm -M mps2-an505 -cpu cortex-m33 -nographic -semihosting -kernel"

[target.thumbv8m.main-none-eabihf]
runner = "qemu-system-arm -M mps2-an505 -cpu cortex-m33 -nographic -semihosting -kernel"
EOF
        else
            log_info "Existing ${CARGO_CONFIG} kept (not overwriting)."
        fi
    fi

    # --- git defaults for the runner account ---------------------------------
    # CI-friendly non-interactive git behaviour for the service account only.
    run_as_user "$RUNNER_USER" git config --global init.defaultBranch main || true
    run_as_user "$RUNNER_USER" git config --global fetch.prune true || true
    run_as_user "$RUNNER_USER" git config --global gc.autoDetach false || true
    run_as_user "$RUNNER_USER" git config --global core.fsmonitor false || true
    run_as_user "$RUNNER_USER" git config --global advice.detachedHead false || true

    log_success "Runner installation complete."
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
log_step "Summary"

printf '%s\n' "  • Host             : ${OS_NAME} (${ARCH_TYPE})"
printf '%s\n' "  • Runner user      : ${RUNNER_USER} (no sudo, nologin shell)"
printf '%s\n' "  • Runner dir       : ${RUNNER_DIR}"
printf '%s\n' "  • Runner home      : ${RUNNER_HOME}"
if [ "$RUNNER_EPHEMERAL" -eq 1 ]; then
    printf '%s\n' "  • Mode             : ephemeral (JIT), service ghrunner-jit.service"
else
    printf '%s\n' "  • Mode             : persistent, name '${RUNNER_NAME}'"
    printf '%s\n' "  • Labels           : ${ALL_LABELS}"
fi
if [ -n "${LOG_FILE:-}" ]; then
    printf '%s\n' "  • Log              : ${LOG_FILE}"
fi
if [ "$RUNNER_EPHEMERAL" -eq 0 ]; then
    printf '%s\n' "  • Supervision      : enabled at boot, Restart=always, retries forever"
    if [ "$WITH_WATCHDOG" -eq 1 ]; then
        printf '%s\n' "                       plus ghrunner-watchdog.timer (5 min health check)"
    fi
fi
if [ "$WITH_MOSH" -eq 1 ] && section_enabled security; then
    printf '%s\n' "  • Remote shell     : mosh installed (udp/60000-61000 opened in the firewall)"
fi
if [ "$WITH_SHELL" -eq 1 ] && section_enabled shell && [ -n "$SHELL_USER" ]; then
    printf '%s\n' "  • Operator shell   : zsh + oh-my-zsh + fzf for ${SHELL_USER}"
fi

printf '\n%s\n' "${BOLD}Next steps${RESET}"
printf '%s\n' "  1. Confirm the service is healthy:"
if [ "$RUNNER_EPHEMERAL" -eq 1 ]; then
    printf '%s\n' "       systemctl status ghrunner-jit.service"
else
    printf '%s\n' "       systemctl status 'actions.runner.*.service'"
fi
printf '%s\n' "  2. Confirm the runner appears under Settings -> Actions -> Runners."
printf '%s\n' "  3. Target this machine from a workflow, e.g.:"
printf '\n'
printf '%s\n' "       jobs:"
printf '%s\n' "         thumb-integration-tests:"
printf '%s\n' "           runs-on: [self-hosted, linux, x64, thumbv6m]"
printf '%s\n' "           steps:"
printf '%s\n' "             - uses: actions/checkout@v4"
printf '%s\n' "             - run: rustup target add thumbv6m-none-eabi"
printf '%s\n' "             - run: cargo build --target thumbv6m-none-eabi"
printf '%s\n' "             - run: cargo nextest run --target thumbv6m-none-eabi"
printf '\n'

if [ "$HARDEN_SSH" -eq 0 ]; then
    printf '%s\n' "${BOLD}Security notes${RESET}"
    printf '%s\n' "  • sshd was left untouched. Re-run with --harden-ssh to disable password"
    printf '%s\n' "    logins and root SSH (only after a working key is in place)."
fi
if section_enabled containers && [ "$STRICT_HARDENING" -eq 0 ]; then
    printf '%s\n' "  • Rootless Podman required NoNewPrivileges=no on the runner unit. Jobs can"
    printf '%s\n' "    still only affect containers owned by ${RUNNER_USER}, never the host root."
fi
if [ "$RUNNER_EPHEMERAL" -eq 1 ]; then
    printf '%s\n' "  • ${JIT_ENV_FILE} holds a PAT with runner-registration rights for this"
    printf '%s\n' "    repo/org. Keep the host treated as a credential holder and scope the PAT"
    printf '%s\n' "    as narrowly as possible."
fi
printf '%s\n' "  • Any fork PR running on this machine executes code as ${RUNNER_USER}."
printf '%s\n' "    Prefer 'pull_request' workflows that require approval for first-time"
printf '%s\n' "    contributors, and keep this node off any public repository without review."
printf '\n'
printf '%s\n' "To remove everything: sudo ./runner-install-fedora.sh --uninstall --token <TOKEN>"
