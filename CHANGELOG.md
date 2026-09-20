# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-09-20

### Added

- New `shell` section in both installers, ported from `bootstrap.sh`: installs zsh
  and fzf, runs the oh-my-zsh installer unattended (`KEEP_ZSHRC=yes`, `CHSH=no`),
  clones the zsh-autosuggestions / zsh-syntax-highlighting / zsh-completions
  plugins, merges the `plugins=` line instead of overwriting it, adds `GPG_TTY`,
  `DISABLE_MAGIC_FUNCTIONS`, `DISABLE_UNTRACKED_FILES_DIRTY`, the `~/.local/bin` and
  `~/.cargo/bin` PATH entries and the fzf Ctrl+R / Ctrl+T / Alt+C bindings, then
  makes zsh the login shell.
- `--shell-user <NAME>` (or `GH_RUNNER_SHELL_USER`) picks the account that receives
  the shell setup. `--no-shell`, `--skip-shell` and `--shell-only` control the
  section like every other one.
- `btop` added to the Fedora base package set (Ubuntu already installed it).

### Security

- The shell section targets the **operator account**, never the runner service
  account. `ghrunner` stays a `nologin` account with no prompt and no oh-my-zsh,
  because it executes untrusted pull-request code; passing `--shell-user` naming the
  runner account is rejected with an explanation.
- A run that cannot identify an operator (root without `SUDO_USER`) skips the shell
  section with a warning rather than reconfiguring root.
- An existing `~/.zshrc` is copied to
  `~/.local/state/gh-runner-install/backups/<timestamp>/` before any modification,
  and every appended block is marker-guarded so re-runs never duplicate it.

### Changed

- New `run_as_user_env` helper runs a command as an arbitrary account with an
  explicit HOME and PATH; `run_user_shell` is now a thin wrapper over it.
- The runner service account is created only when the selected sections need it, so
  `--shell-only` no longer creates `ghrunner`.
- `--shell-user` validation now happens before any system mutation, so a bad value
  fails fast instead of after the account is created.

## [0.4.0] - 2026-09-20

### Added

- Self-healing supervision for the persistent runner service. GitHub's own
  `actions.runner.service.template` ships **no** `Restart=` directive, so a crashed
  or OOM-killed listener previously stayed down until someone noticed. A
  `05-restart.conf` drop-in now sets `Restart=always`, `RestartSec=5`,
  `StartLimitIntervalSec=0` (so a crash loop keeps being retried instead of the unit
  landing in a failed state after systemd's default five starts in ten seconds), and
  `Wants=network-online.target`, which `After=` alone does not actually pull in.
- Both scripts assert `systemctl enable` on the generated runner unit and log its
  real enabled/active state, so a machine whose unit was previously disabled cannot
  silently come back without a runner after a reboot.
- `ghrunner-watchdog.timer` and its oneshot service, installed by default. Every five
  minutes it restarts the runner service if it is not active. It deliberately stores
  no credentials, so it detects that a runner's local registration has gone missing
  (`.runner` absent) but cannot re-register one; it says so explicitly instead.
  Disabled with `--no-watchdog`.
- `mosh` in the base package set of both scripts, together with the UDP transport
  range `60000-61000` in the host firewall. Without that rule the SSH handshake
  succeeds and the session then hangs on the UDP leg. Disabled with `--no-mosh`.
- `run_sudo_quiet` helper for actions whose output is noise on a real run
  (`sysctl --system`, `firewall-cmd`, `systemctl enable`) so that `--dry-run` still
  reports them. A call-site redirect previously swallowed the dry-run notice too.

### Changed

- The ephemeral (JIT) and rootless Podman API units also set
  `StartLimitIntervalSec=0`, for the same never-give-up behaviour.

## [0.3.0] - 2026-09-20

### Added

- `runner-install-ubuntu.sh` (script version `0.1.0`): the same hardened
  self-hosted runner node, targeting Ubuntu LTS and the Debian family. Shares the
  section layout, flags, runner modes, udev rules, and systemd hardening with the
  Fedora script; only package names, firewall, MAC layer, and the update
  mechanism differ.
- Ubuntu package mapping: `gcc-arm-none-eabi`/`g++-arm-none-eabi`/
  `binutils-arm-none-eabi`/`libnewlib-arm-none-eabi` instead of the Fedora `-cs`
  packages, `gdb-multiarch` for target debugging, `stlink-tools`, `qemu-utils`,
  and `uidmap` for rootless container UID mapping.
- Automatic `universe` component enablement when a universe-only package
  (`podman`, `sccache`, `uv`, `qemu-system-arm`) is unresolvable.
- `batcat`/`fdfind` symlinks under the runner account's `~/.local/bin` to recover
  the conventional `bat`/`fd` names that Ubuntu renames to avoid clashes.
- Ubuntu security defaults: `ufw` (OpenSSH allowed before the default-deny policy
  is applied, and an existing active ruleset is left alone), `unattended-upgrades`
  driven by the `apt-daily` timers, and a `fail2ban` sshd jail.
- AppArmor `userns` profiles for `podman`, `crun`, `buildah`, `conmon`,
  `slirp4netns`, `pasta`, `fuse-overlayfs`, and `rootlessport`, so rootless
  containers work on Ubuntu 23.10+ where
  `kernel.apparmor_restrict_unprivileged_userns=1` denies user namespace creation
  to unconfined processes.
- `--relax-userns` flag that sets
  `kernel.apparmor_restrict_unprivileged_userns=0` instead, for test suites that
  create user namespaces from binaries that cannot be enumerated ahead of time
  (`bubblewrap`, `kind`, `nsjail`, `fakeroot`). Off by default, because it removes
  a kernel mitigation for the whole host.

### Changed

- Renamed `runner-install.sh` to `runner-install-fedora.sh` now that a second
  distribution is supported. The old name was never published, so no live URL
  changed.
- Both scripts now install `~/.local/bin` into the runner unit's `PATH`, so
  per-user CLI shims resolve inside jobs.

## [0.2.0] - 2026-09-20

### Added

- `runner-install-fedora.sh` (script version `0.1.0`): a Fedora-focused installer
  that turns a machine into a hardened GitHub Actions self-hosted runner node for
  integration testing. Sections can be skipped or run alone:
  `base`, `rust`, `python`, `arm`, `qemu`, `containers`, `security`, `hardware`,
  `runner`.
- Rust targets for bare-metal CI: `thumbv6m-none-eabi`, the `thumbv7m`/
  `thumbv7em` pair, and `thumbv8m.base`/`thumbv8m.main` (soft- and hard-float).
- QEMU-based on-host integration testing defaults, including a per-user cargo
  config wiring `cargo test` for thumb targets to `qemu-system-arm` machines.
- Hardware-aware runner labelling: attached USB debug probes (ST-LINK, J-Link,
  CMSIS-DAP, Black Magic, FTDI, Espressif, Nordic) are detected and turned into
  runner labels, with matching udev rules granting the service account access.
- Two registration modes: persistent (default, one-time registration token that
  is never persisted) and ephemeral just-in-time runners driven by a
  fine-grained PAT, for machines without attached hardware.
- Rootless Podman with the `podman-docker` CLI shim, a rootless Podman API
  socket, and an optional `/var/run/docker.sock` symlink so container-based
  Actions work without a root daemon.
- Security defaults: firewalld, kernel/network sysctl hardening, SELinux
  relabelling, bounded journald, and `dnf-automatic` security updates. Opt-in
  `--harden-ssh` (key-only SSH) and `--with-fail2ban`.
- A per-machine config file (`/etc/gh-runner/runner.conf`) so fleet nodes can
  keep machine-specific URLs, labels, and names outside the script.

### Security

- The runner never runs as root and is never granted `sudo`; the service account
  is a `nologin` system user, and a hardened systemd unit applies
  `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`, an empty
  capability bounding set, and a locked-down kernel surface.
- `PrivateDevices=yes` is deliberately not applied, because on-hardware
  integration tests need USB debug probe access.
- Machines with containers enabled relax `NoNewPrivileges`,
  `CapabilityBoundingSet`, `RestrictSUIDSGID`, and `ProtectControlGroups`,
  because rootless user namespace creation depends on the setuid
  `newuidmap`/`newgidmap` helpers and cgroup delegation. `--strict-hardening`
  keeps the strict profile for container-free nodes.
- Install and uninstall refuse to clobber or delete an existing
  `/var/run/docker.sock` that was not created by this installer.

## [0.1.1] - 2026-09-08

### Added

- Timestamped backups of pre-existing dotfiles and Git configs before
  modification, stored under `~/.local/state/leftger-bootstrap/backups/`.
- `--rollback` mode that restores the newest backup of user dotfiles/configs.
- Persistent install logs under `~/.cache/leftger-bootstrap/`.
- Bootstrap version state under `~/.local/state/leftger-bootstrap/version`.
- `--check-update` and `--version` CLI flags.
- Bootstrap update notification inside `~/.local/bin/full-upgrade`.
- Positive `--*-only` execution modes:
  - `--locale-only`
  - `--timezone-only`
  - `--system-only`
  - `--core-only`
  - `--tools-only`
  - `--embedded-only`
  - `--zsh-only`
  - `--dotfiles-only`
  - `--rust-only`
  - `--zed-only`
- Dual licensing under MIT and Apache-2.0.
- Repository-local `.githooks/pre-commit` hook that runs ShellCheck on staged
  shell scripts (warning severity, matching CI).
- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`, and
  this `CHANGELOG.md`.

### Changed

- Logging helpers now append plain-text entries to the active install log.
- Final summary now reports bootstrap version, log path, backup path, and the
  rollback one-liner.
- Help output and README updated with the new flags and safety features.

## [0.1.0] - 2026-09-07

### Added

- Public GitHub Pages site (`index.html`).
- Single-file `bootstrap.sh` with remote `curl | sh` support.
- Ubuntu/Debian APT and macOS Homebrew bootstrap support.
- Locale, timezone, core development, CLI, embedded ARM, Zsh, dotfiles,
  Rust, and Zed installation sections.
- `--skip-*` flags, `--timezone`, `--dry-run`, and `--help`.
- Curated dotfiles: Vim, Tmux, EditorConfig, Git hooks/templates, aliases,
  and the `full-upgrade` helper.
- ShellCheck lint workflow.
