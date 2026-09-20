# leftger.github.io

Personal website and automated Linux/macOS workstation bootstrapping service for [**@leftger**](https://github.com/leftger).

![License](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)

## 🚀 One-Liner Install

To bootstrap a fresh Ubuntu / Debian installation:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh
```

Or pass custom flags:

```bash
# Explicit timezone
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --timezone America/Phoenix

# Preview without making system changes
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --dry-run

# Re-run only the curated dotfiles and keys section
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --dotfiles-only

# Restore the newest backup of user dotfiles/configs
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --rollback

# Check whether the locally recorded bootstrap version is outdated
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --check-update
```

---

## 🛠️ What Gets Installed & Configured

1. **System Maintenance**: `apt update`, `full-upgrade`, `dist-upgrade`, `autoremove` (non-interactive, config-preserving).
2. **Localization & Timezone**: `en_US.UTF-8` generated and set system-wide; timezone autodetected from host system (configurable via `--timezone`).
3. **Core Development**: `build-essential`, `cmake`, `ninja-build`, `clang`, `lld`, `llvm`, `pkg-config`, `libssl-dev`, `git`, `git-lfs`, `jq`, `tmux`, `tree`.
4. **Modern CLI Productivity**: `vim`, `btop`, `mosh`, `binutils`, `ripgrep`, `fd-find` (`fd`), `bat` (`bat`), `fzf` (with Ctrl+R, Ctrl+T, Alt+C shell integration).
5. **Embedded ARM Toolchain**: `gcc-arm-none-eabi`, `binutils-arm-none-eabi`, `libnewlib-arm-none-eabi`, `libstdc++-arm-none-eabi-newlib`, `gdb-multiarch`, `openocd`, `tio` (serial monitor), `libusb`, `libudev`.
6. **Hardware Access**: Adds user to `dialout` and `plugdev` groups; installs `probe-rs` udev rules for CMSIS-DAP, ST-Link, and J-Link debuggers.
7. **Shell & Terminal**: `zsh` + Oh-My-Zsh configured as default user shell with plugins:
   - `git`, `sudo`, `rust`, `extract`, `z`, `colored-man-pages`, `command-not-found`, `zsh-autosuggestions`, `zsh-syntax-highlighting`.
   - Dynamic `cdr <TAB>` completion installed separately.
   - Fast prompt response (`DISABLE_UNTRACKED_FILES_DIRTY="true"`).
   - URL paste fix (`DISABLE_MAGIC_FUNCTIONS="true"`).
   - Safe POSIX alias sourcing with `emulate ksh`.
8. **Curated Dotfiles & Utilities**:
   - `~/.vimrc` with Badwolf theme, line numbers, automatic trailing whitespace stripping, and 4-space indentation.
   - `~/.tmux.conf` with mouse support, TrueColor, 10,000 line scrollback, vi mode keys, and GitHub dark theme status bar.
   - `~/.gitmessage` standard conventional commit template.
   - `~/.editorconfig` standard cross-editor formatting rules.
   - `~/.hushlogin` to silence distracting login MOTD banners.
   - `~/.local/bin/full-upgrade` (alias: `up`): one-stop unattended updater for APT, Rust, Zed, Flatpak, Snap, pipx, npm, WSL, Oh-My-Zsh, and the bootstrap itself.
   - `~/.bash_aliases` with directory navigation, quick helpers, WSL interop, parallel compilation, and git web viewer (`gho`).
   - Global `~/.gitignore` (`core.excludesfile`).
   - Git defaults & productivity: `core.editor = vim`, `init.defaultBranch = main`, `push.autoSetupRemote = true`, `rebase.autoStash = true`, `merge.autoStash = true`, `git caane`, `git caa`, `git cob`, `git apply-gitignore`, and `git pa`.
9. **Security & Cryptographic Keys**: automated check and creation of `ed25519` SSH and GPG keys when none exist; auto-configures `git commit.gpgsign true` and `user.signingkey`.
10. **Rust Ecosystem**: `rustup` stable toolchain, Cortex-M/RISC-V/Wasm targets, `probe-rs`, `cargo-binstall`, `cargo-binutils`, `espflash` / `cargo-espflash`, `cargo-generate`, `cargo-deny`, and `cargo-llvm-cov`.
11. **Zed Editor**: installs the latest stable release of [Zed](https://zed.dev) to `~/.local/bin/zed`.

---

## 🛡️ Safety Features

- **Timestamped backups**: before modifying existing dotfiles, shell configs, or Git configs, originals are copied to:

  ```text
  ~/.local/state/leftger-bootstrap/backups/<YYYYmmdd_HHMMSS>/
  ```

- **Rollback**: restore the newest backup with `--rollback`.

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/bootstrap.sh | sh -s -- --rollback
  ```

  > Note: rollback restores files that existed before the run. Files created
  > fresh by the bootstrap (for example a brand-new `~/.githooks` directory)
  > are not automatically removed.

- **Persistent logs**: every run writes a timestamped plain-text log to:

  ```text
  ~/.cache/leftger-bootstrap/bootstrap-*.log
  ```

- **Version state & update checks**: after a successful run, the applied version is stored at:

  ```text
  ~/.local/state/leftger-bootstrap/version
  ```

  Use `--check-update` to compare it with the remote `bootstrap.sh`, or run
  `up` / `full-upgrade` to see a reminder when a new bootstrap is available.

- **Dry-run**: `--dry-run` prints proposed actions without executing system commands.

- **Selective runs**: combine `--*-only` flags to run only the sections you need.

---

## ⚙️ CLI Flags

| Flag | Description | Default |
| :--- | :--- | :--- |
| `-t`, `--timezone <TZ>` | Set system timezone | `Auto-detected` |
| `--skip-upgrade` | Skip package manager and system upgrades | `false` |
| `--skip-embedded` | Skip ARM GCC toolchain, probe-rs, and udev rules | `false` |
| `--skip-rust` | Skip Rust toolchain and cargo tools | `false` |
| `--skip-zed` | Skip Zed editor installation | `false` |
| `--skip-zsh` | Skip Zsh, Oh-My-Zsh, and shell change | `false` |
| `--skip-tools` | Skip modern CLI productivity tools | `false` |
| `--skip-dotfiles` | Skip curated dotfiles, tmux, vim, and shell aliases | `false` |
| `--skip-keys` | Skip ED25519 SSH and GPG key generation | `false` |
| `--dry-run` | Print proposed actions without making modifications | `false` |
| `--rollback` | Restore the newest backup of user dotfiles/configs | `false` |
| `--check-update` | Compare local bootstrap version state with the remote script | `false` |
| `--locale-only` | Run only the locale section | `false` |
| `--timezone-only` | Run only the timezone section | `false` |
| `--system-only` | Run only the package manager / system upgrade section | `false` |
| `--core-only` | Run only the core development packages section | `false` |
| `--tools-only` | Run only the modern CLI tools section | `false` |
| `--embedded-only` | Run only the embedded ARM/hardware section | `false` |
| `--zsh-only` | Run only the Zsh / Oh-My-Zsh section | `false` |
| `--dotfiles-only` | Run only the curated dotfiles and keys section | `false` |
| `--rust-only` | Run only the Rust toolchain section | `false` |
| `--zed-only` | Run only the Zed editor section | `false` |
| `-v`, `--version` | Print the bootstrap version and exit | |
| `-h`, `--help` | Display help screen and exit | |

Multiple `--*-only` flags may be combined, e.g.:

```bash
./bootstrap.sh --dotfiles-only --rust-only
```

---

## 🏗️ CI Runner Installers

Two sibling scripts turn a machine into a hardened, integration-test focused
**GitHub Actions self-hosted runner** node, aimed at small fleets where each
machine has its own attached debug hardware:

| Script | Target | Package manager |
| :--- | :--- | :--- |
| `runner-install-fedora.sh` | Fedora (and RHEL-family, with a warning) | `dnf` |
| `runner-install-ubuntu.sh` | Ubuntu LTS (and Debian-family, with a warning) | `apt` |

Both share the same section layout, flags, runner modes, udev rules, systemd
hardening, and operator shell setup. Only the package names, firewall, MAC layer,
and update mechanism differ.

```bash
# Fedora
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/runner-install-fedora.sh | sudo bash -s -- \
  --url https://github.com/OWNER/REPO --token <REGISTRATION_TOKEN> --labels microbit

# Ubuntu
curl --proto '=https' --tlsv1.2 -sSf https://leftger.github.io/runner-install-ubuntu.sh | sudo bash -s -- \
  --url https://github.com/OWNER/REPO --token <REGISTRATION_TOKEN> --labels microbit

# Preview every action without touching the system
sudo ./runner-install-ubuntu.sh --dry-run --url https://github.com/OWNER/REPO --token <TOKEN>

# Remove the runner, its service, and its account
sudo ./runner-install-ubuntu.sh --uninstall --token <TOKEN>
```

### What Gets Installed

| Section | Contents |
| :--- | :--- |
| `base` | Compiler toolchain (GCC/Clang/LLVM, `mold`), `rustup` prerequisites, `git`, `jq`, `ripgrep`, `btop`, `mosh`, plus the `libicu`/`libssl`/`zlib`/`krb5` runtime libraries `actions/runner` needs |
| `rust` | `rustup` stable, `rustfmt`/`clippy`/`rust-src`/`llvm-tools`, `sccache`, `cargo-nextest`, `cargo-llvm-cov`, `cargo-deny`, `cargo-binutils`, `probe-rs` |
| `python` | Python 3 (plus `-dev`/`-venv`), `pip`, `pipx`, `uv` |
| `arm` | ARM bare-metal GCC/G++/binutils/newlib, a target-capable GDB, `openocd`, ST-LINK tools, `tio` |
| `qemu` | `qemu-system-arm` (`microbit`, `mps2-an505`, `mps2-an521`) for on-host Cortex-M tests |
| `containers` | Rootless Podman, `podman-docker` shim, `buildah`, `skopeo`, rootless API socket |
| `security` | Host firewall, sysctl hardening, mandatory access control, bounded journald, automatic security updates |
| `hardware` | udev rules and group access for ST-LINK, J-Link, CMSIS-DAP, Black Magic, FTDI, Espressif, and Nordic probes |
| `runner` | `actions/runner` download (latest release, SHA-256 verified), registration, hardened systemd unit |
| `shell` | zsh + oh-my-zsh + plugins + fzf keybindings for the **operator account** (not the runner account) |

Rust targets installed: `thumbv6m-none-eabi`, `thumbv7m-none-eabi`,
`thumbv7em-none-eabi`, `thumbv7em-none-eabihf`, `thumbv8m.base-none-eabi`,
`thumbv8m.main-none-eabi`, `thumbv8m.main-none-eabihf`.

### Distribution Differences

| Concern | Fedora | Ubuntu |
| :--- | :--- | :--- |
| ARM toolchain | `arm-none-eabi-gcc-cs` (plus `-c++`, `-binutils-cs`, `-newlib`) | `gcc-arm-none-eabi`, `g++-arm-none-eabi`, `binutils-arm-none-eabi`, `libnewlib-arm-none-eabi` |
| Target GDB | `arm-none-eabi-gdb` | `gdb-multiarch` (no ARM-specific GDB package) |
| Probe tools | `stlink` | `stlink-tools` |
| Firewall | `firewalld` (public zone, SSH allowed, `udp/60000-61000` for mosh) | `ufw` (default deny inbound, OpenSSH allowed before enabling, `udp/60000-61000` for mosh) |
| Mandatory access control | SELinux, with `restorecon` on runner paths | AppArmor, with `userns` profiles (see below) |
| Security updates | `dnf-automatic.timer`, security-only | `unattended-upgrades` via `apt-daily` timers |
| CLI name clashes | none | Ubuntu ships `bat` as `batcat` and `fd` as `fdfind`; both are symlinked into the runner's `~/.local/bin` |
| Rootless containers | `uidmap`/`newuidmap` come with the base system | `uidmap` package is installed explicitly |
| Service supervision | identical: `05-restart.conf` drop-in plus `ghrunner-watchdog.timer` | identical: `05-restart.conf` drop-in plus `ghrunner-watchdog.timer` |
| `universe` component | n/a | enabled automatically if a `universe`-only package is unresolvable |

### AppArmor and Rootless Containers (Ubuntu)

Ubuntu 23.10+ sets `kernel.apparmor_restrict_unprivileged_userns=1`, which denies
user namespace creation to unconfined processes. That breaks rootless Podman,
`crun`, `buildah`, and the helpers they spawn, so container-based integration
tests fail with `EPERM`.

By default the Ubuntu script installs small AppArmor profiles that grant
`userns,` to `podman`, `crun`, `buildah`, `conmon`, `slirp4netns`, `pasta`,
`fuse-overlayfs`, and `rootlessport`, leaving the kernel restriction in place for
everything else. If a test suite creates user namespaces from binaries that
cannot be enumerated ahead of time (`bubblewrap`, `kind`, `nsjail`, `fakeroot`),
pass `--relax-userns`, which sets the sysctl to `0` instead and warns that a
kernel mitigation has been removed host-wide.

### Runner Modes


- **Persistent** (default) — register once with a short-lived registration token
  that is never written to disk. Best for machines with attached hardware, where
  you want a stable, label-addressable node.
- **Ephemeral / JIT** (`--ephemeral` + `--pat`) — fetch a single-use just-in-time
  config per job and self-deregister afterwards. Best for hardware-free machines.
  GitHub deprecated classic PATs for the registration-token API in 2025, so this
  mode uses a fine-grained PAT with `Administration: Read and write`, stored at
  `/etc/gh-runner/jit.env` (mode `0640`, group `ghrunner`).

### Service Supervision

A runner is useless if it is quietly offline, so both scripts make the service
self-managing rather than relying on someone noticing:

- **Enabled at boot.** `svc.sh install` already runs `systemctl enable`; the
  installer re-asserts it and then logs the real `is-enabled`/`is-active` state
  instead of assuming the change took effect.
- **Restarted on failure.** GitHub's own `actions.runner.service.template` ships
  **no** `Restart=` directive, so a crashed or OOM-killed listener would otherwise
  stay down. A `05-restart.conf` drop-in adds `Restart=always` and `RestartSec=5`.
- **Retried forever.** The same drop-in sets `StartLimitIntervalSec=0`, so a crash
  loop keeps being restarted instead of the unit landing in a failed state after
  systemd's default limit of five starts in ten seconds.
- **Waits for the network.** `Wants=network-online.target` is added, because the
  `After=` that `svc.sh` sets does nothing on its own without something pulling the
  target in, and a runner that starts before DNS is reachable cannot register.
- **Health check.** `ghrunner-watchdog.timer` runs every five minutes and restarts
  the service if it is not active. It is deliberately credential-free, so it cannot
  re-register a runner that has been deregistered; it reports that condition
  clearly (`.runner` missing) instead of failing silently. Turn it off with
  `--no-watchdog`.

The one failure a watchdog cannot fix is a **lost registration** — if the runner is
removed in GitHub or its local `.runner` config is gone, recovery needs a fresh
registration token. That is inherent to not storing credentials on the box; the
ephemeral/JIT mode is the alternative, since it re-registers from a PAT on every
job.

```bash
# Check on a node
systemctl is-enabled 'actions.runner.*.service'
systemctl status 'actions.runner.*.service'
journalctl -u 'actions.runner.*.service' -b --no-pager
systemctl list-timers ghrunner-watchdog.timer
```

### Operator Shell

The `shell` section ports the interactive-shell perks from `bootstrap.sh` so the
boxes are pleasant to work on:

- zsh and fzf installed, then oh-my-zsh unattended with `KEEP_ZSHRC=yes` so an
  existing `~/.zshrc` is never replaced.
- `zsh-autosuggestions`, `zsh-syntax-highlighting`, and `zsh-completions` cloned
  into `~/.oh-my-zsh/custom/plugins`.
- The `plugins=` line is **merged** with whatever is already enabled rather than
  overwritten, so your existing choices survive.
- `GPG_TTY`, the `~/.local/bin` + `~/.cargo/bin` PATH entries,
  `DISABLE_MAGIC_FUNCTIONS`, `DISABLE_UNTRACKED_FILES_DIRTY`, and the fzf
  Ctrl+R / Ctrl+T / Alt+C bindings — each appended once and marker-guarded, so
  re-running the installer never duplicates a block.
- `chsh` makes zsh the login shell, with the binary registered in `/etc/shells`
  first.

**It targets the operator account, never the runner account.** `ghrunner` stays a
`nologin` account with no prompt and no oh-my-zsh, because it executes untrusted
pull-request code. The target defaults to the human who ran the installer (detected
via `SUDO_USER`); override with `--shell-user <NAME>`, or skip the whole thing with
`--no-shell`. Naming the runner account is rejected outright, and a run that cannot
identify an operator (root without sudo) skips the section rather than
reconfiguring root.

Before any change, an existing `~/.zshrc` is copied to
`~/.local/state/gh-runner-install/backups/<timestamp>/`.

### Hardware Labels

Every machine gets `rust`, `embedded`, `arm-none-eabi`, `qemu`, `thumbv6m`,
`thumbv8m`, `fedora<VERSION>`, plus `sccache`/`podman` when those sections run.
Attached probes add labels such as `stlink`, `jlink`, `cmsis-dap`, and `nordic`,
so a workflow can require the exact hardware it needs:

```yaml
jobs:
  thumb-integration-tests:
    runs-on: [self-hosted, linux, x64, thumbv6m, stlink]
    steps:
      - uses: actions/checkout@v4
      - run: cargo nextest run --target thumbv6m-none-eabi
```

### Fleet Configuration

Put machine-specific values in `/etc/gh-runner/runner.conf` to avoid long
command lines on each node. Precedence is flags > environment > config file.

```bash
RUNNER_URL="https://github.com/OWNER/REPO"
RUNNER_NAME="bench-01"
RUNNER_LABELS="stm32f4,nrf52840"
```

### Security Model

- The runner is a dedicated `nologin` system account, never `root`, and never
  added to `wheel` or `sudoers`.
- The systemd unit applies `ProtectSystem=strict`, `ProtectHome=yes`,
  `NoNewPrivileges=yes`, an empty `CapabilityBoundingSet`, `PrivateTmp=yes`,
  `RestrictSUIDSGID=yes`, and a restricted kernel/`/proc` surface.
- `PrivateDevices=yes` is intentionally **not** set, so jobs can reach USB debug
  probes. `MemoryDenyWriteExecute` and `SystemCallFilter` are also omitted, since
  JIT runtimes and cross toolchains need them.
- With containers enabled, `NoNewPrivileges`, `CapabilityBoundingSet`,
  `RestrictSUIDSGID`, and `ProtectControlGroups` are relaxed, because rootless
  user namespaces depend on the setuid `newuidmap`/`newgidmap` helpers and on
  cgroup delegation. Use `--strict-hardening` on container-free machines.
- Install and uninstall never clobber or delete a `/var/run/docker.sock` that
  this installer did not create.
- `--harden-ssh` is opt-in and refuses to disable password logins when no
  `authorized_keys` exist anywhere (override with
  `GH_RUNNER_ALLOW_SSH_LOCKOUT=1`).
- `mosh` adds an inbound UDP listener, so its transport range (`60000-61000`) is
  opened in the firewall. Skip the package and the rule together with `--no-mosh`.

> **Note:** any fork pull request running on this node executes code as
> `ghrunner`. Require approval for first-time contributors, and think twice
> before attaching a public repository to a persistent machine.

---

## 🧪 Local Checks

A repository-local pre-commit hook runs ShellCheck on staged shell scripts at
warning severity. It is stored as `.githooks/pre-commit` and is enabled in this
clone with:

```bash
git config core.hooksPath .githooks
```

Install ShellCheck from your package manager or from
<https://github.com/koalaman/shellcheck>. CI runs the same ShellCheck checks in
`.github/workflows/lint.yml`.

---

## 📚 Project Docs

- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security](SECURITY.md)
- [Support](SUPPORT.md)
- [Changelog](CHANGELOG.md)

---

## 📄 License

Licensed under either of:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this project shall be dual-licensed as above, without any
additional terms or conditions.
