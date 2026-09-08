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
